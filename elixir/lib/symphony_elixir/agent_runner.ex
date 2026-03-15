defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, Pipeline, PromptBuilder, Tracker, Workspace}

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

  defp run_with_pipeline(pipeline, issue, codex_update_recipient, opts) do
    Logger.info("Starting agent run for #{issue_context(issue)}#{pipeline_log_context(pipeline)}")

    {create_workspace, before_run_hook, after_run_hook} =
      case pipeline do
        %Pipeline{} = pipeline ->
          {
            fn -> Workspace.create_for_issue(pipeline, issue) end,
            fn workspace -> Workspace.run_before_run_hook(pipeline, workspace, issue) end,
            fn workspace -> Workspace.run_after_run_hook(pipeline, workspace, issue) end
          }

        _ ->
          {
            fn -> Workspace.create_for_issue(issue) end,
            fn workspace -> Workspace.run_before_run_hook(workspace, issue) end,
            fn workspace -> Workspace.run_after_run_hook(workspace, issue) end
          }
      end

    case create_workspace.() do
      {:ok, workspace} ->
        try do
          with :ok <- before_run_hook.(workspace),
               :ok <- run_codex_turns(pipeline, workspace, issue, codex_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              raise_agent_run_failure(issue, reason, pipeline)
          end
        after
          after_run_hook.(workspace)
        end

      {:error, reason} ->
        raise_agent_run_failure(issue, reason, pipeline)
    end
  end

  defp run_codex_turns(pipeline, workspace, issue, codex_update_recipient, opts) do
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

    with {:ok, session} <- AppServer.start_session(workspace, pipeline) do
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

  defp pipeline_log_context(%Pipeline{id: pipeline_id}), do: " pipeline_id=#{pipeline_id}"
  defp pipeline_log_context(_pipeline), do: ""
end
