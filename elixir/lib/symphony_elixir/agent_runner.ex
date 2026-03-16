defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, Pipeline, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map()) :: :ok | no_return()
  def run(issue), do: run(issue, nil, [])

  @spec run(map(), pid() | nil) :: :ok | no_return()
  def run(issue, codex_update_recipient), do: run(issue, codex_update_recipient, [])

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient, opts)
      when (is_map(issue) or is_struct(issue)) and
             (is_pid(codex_update_recipient) or is_nil(codex_update_recipient)) and
             is_list(opts) do
    run_with_pipeline(nil, issue, codex_update_recipient, opts)
  end

  @spec run(Pipeline.t(), map(), keyword()) :: :ok | no_return()
  def run(%Pipeline{} = pipeline, issue, opts) when is_list(opts) do
    run(pipeline, issue, nil, opts)
  end

  @spec run(Pipeline.t(), map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(%Pipeline{} = pipeline, issue, codex_update_recipient, opts)
      when (is_map(issue) or is_struct(issue)) and
             (is_pid(codex_update_recipient) or is_nil(codex_update_recipient)) and
             is_list(opts) do
    run_with_pipeline(pipeline, issue, codex_update_recipient, opts)
  end

  defp run_with_pipeline(pipeline, issue, codex_update_recipient, opts) do
    worker_hosts = candidate_worker_hosts(Keyword.get(opts, :worker_host), ssh_hosts(pipeline))

    Logger.info("Starting agent run for #{issue_context(issue)}#{pipeline_log_context(pipeline)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(pipeline, issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise_agent_run_failure(issue, reason, pipeline)
    end
  end

  defp run_on_worker_hosts(pipeline, issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(pipeline, issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning(
          "Agent run failed for #{issue_context(issue)}#{pipeline_log_context(pipeline)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host"
        )

        run_on_worker_hosts(pipeline, issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_pipeline, _issue, _codex_update_recipient, _opts, []),
    do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(pipeline, issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)}#{pipeline_log_context(pipeline)} worker_host=#{worker_host_for_log(worker_host)}")

    case create_workspace_for_issue(pipeline, issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- run_before_run_hook(pipeline, workspace, issue, worker_host) do
            run_codex_turns(pipeline, workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          run_after_run_hook(pipeline, workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(pipeline, workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, max_turns(pipeline))

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, default_issue_state_fetcher(pipeline))

    run_context = %{
      pipeline: pipeline,
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns
    }

    with {:ok, session} <- AppServer.start_session(workspace, app_server_opts(pipeline, worker_host)) do
      try do
        do_run_codex_turns(session, run_context, issue, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, run_context, issue, turn_number) do
    prompt =
      build_turn_prompt(
        run_context.pipeline,
        issue,
        run_context.opts,
        turn_number,
        run_context.max_turns
      )

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(run_context.codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{run_context.workspace} turn=#{turn_number}/#{run_context.max_turns}")

      case continue_with_issue?(run_context.pipeline, issue, run_context.issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < run_context.max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{run_context.max_turns}")

          do_run_codex_turns(app_session, run_context, refreshed_issue, turn_number + 1)

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(nil, issue, opts, 1, _max_turns),
    do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(%Pipeline{} = pipeline, issue, opts, 1, _max_turns) do
    PromptBuilder.build_prompt(pipeline, issue, opts)
  end

  defp build_turn_prompt(_pipeline, _issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(pipeline, %Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(pipeline, refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(_pipeline, issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(pipeline, state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    active_states(pipeline)
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_pipeline, _state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp raise_agent_run_failure(issue, reason, pipeline) do
    Logger.error("Agent run failed for #{issue_context(issue)}#{pipeline_log_context(pipeline)}: #{inspect(reason)}")

    raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
  end

  defp max_turns(%Pipeline{agent: agent}), do: agent.max_turns
  defp max_turns(_pipeline), do: Config.settings!().agent.max_turns

  defp default_issue_state_fetcher(%Pipeline{} = pipeline) do
    fn issue_ids -> Tracker.fetch_issue_states_by_ids(pipeline, issue_ids) end
  end

  defp default_issue_state_fetcher(_pipeline), do: &Tracker.fetch_issue_states_by_ids/1

  defp active_states(%Pipeline{tracker: tracker}), do: tracker.active_states
  defp active_states(_pipeline), do: Config.settings!().tracker.active_states

  defp ssh_hosts(%Pipeline{worker: worker}), do: worker.ssh_hosts || []
  defp ssh_hosts(_pipeline), do: Config.settings!().worker.ssh_hosts || []

  defp create_workspace_for_issue(%Pipeline{} = pipeline, issue, nil),
    do: Workspace.create_for_issue(pipeline, issue)

  defp create_workspace_for_issue(%Pipeline{} = pipeline, issue, worker_host)
       when is_binary(worker_host),
       do: Workspace.create_for_issue(pipeline, issue, worker_host)

  defp create_workspace_for_issue(_pipeline, issue, nil), do: Workspace.create_for_issue(issue)
  defp create_workspace_for_issue(_pipeline, issue, worker_host), do: Workspace.create_for_issue(issue, worker_host)

  defp run_before_run_hook(%Pipeline{} = pipeline, workspace, issue, nil),
    do: Workspace.run_before_run_hook(pipeline, workspace, issue)

  defp run_before_run_hook(%Pipeline{} = pipeline, workspace, issue, worker_host)
       when is_binary(worker_host),
       do: Workspace.run_before_run_hook(pipeline, workspace, issue, worker_host)

  defp run_before_run_hook(_pipeline, workspace, issue, nil),
    do: Workspace.run_before_run_hook(workspace, issue)

  defp run_before_run_hook(_pipeline, workspace, issue, worker_host),
    do: Workspace.run_before_run_hook(workspace, issue, worker_host)

  defp run_after_run_hook(%Pipeline{} = pipeline, workspace, issue, nil),
    do: Workspace.run_after_run_hook(pipeline, workspace, issue)

  defp run_after_run_hook(%Pipeline{} = pipeline, workspace, issue, worker_host)
       when is_binary(worker_host),
       do: Workspace.run_after_run_hook(pipeline, workspace, issue, worker_host)

  defp run_after_run_hook(_pipeline, workspace, issue, nil),
    do: Workspace.run_after_run_hook(workspace, issue)

  defp run_after_run_hook(_pipeline, workspace, issue, worker_host),
    do: Workspace.run_after_run_hook(workspace, issue, worker_host)

  defp app_server_opts(pipeline, worker_host) do
    []
    |> maybe_put_pipeline(pipeline)
    |> maybe_put_worker_host(worker_host)
  end

  defp maybe_put_pipeline(opts, %Pipeline{} = pipeline), do: Keyword.put(opts, :pipeline, pipeline)
  defp maybe_put_pipeline(opts, _pipeline), do: opts

  defp maybe_put_worker_host(opts, worker_host) when is_binary(worker_host),
    do: Keyword.put(opts, :worker_host, worker_host)

  defp maybe_put_worker_host(opts, _worker_host), do: opts

  defp pipeline_log_context(%Pipeline{id: pipeline_id}), do: " pipeline_id=#{pipeline_id}"
  defp pipeline_log_context(_pipeline), do: ""
end
