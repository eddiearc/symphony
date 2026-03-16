defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, Pipeline, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          logs: logs_payload()
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec pipelines_payload([Pipeline.t()], (String.t() -> GenServer.name() | pid() | nil), timeout()) ::
          map()
  def pipelines_payload(pipelines, orchestrator_resolver, snapshot_timeout_ms)
      when is_list(pipelines) and is_function(orchestrator_resolver, 1) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      generated_at: generated_at,
      pipelines:
        Enum.map(pipelines, fn
          %Pipeline{} = pipeline ->
            pipeline_summary_payload(
              pipeline,
              snapshot_for_pipeline(pipeline, orchestrator_resolver, snapshot_timeout_ms)
            )

          pipeline ->
            %{id: inspect(pipeline), enabled: false, available: false, paused: false}
        end)
    }
  end

  @spec dashboard_payload([Pipeline.t()], (String.t() -> GenServer.name() | pid() | nil), timeout()) ::
          map()
  def dashboard_payload(pipelines, orchestrator_resolver, snapshot_timeout_ms)
      when is_list(pipelines) and is_function(orchestrator_resolver, 1) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    pipeline_snapshots =
      Enum.map(pipelines, fn
        %Pipeline{} = pipeline ->
          %{
            pipeline: pipeline,
            snapshot: snapshot_for_pipeline(pipeline, orchestrator_resolver, snapshot_timeout_ms)
          }

        pipeline ->
          %{pipeline: pipeline, snapshot: :unavailable}
      end)

    running = Enum.flat_map(pipeline_snapshots, &dashboard_running_entries/1)
    retrying = Enum.flat_map(pipeline_snapshots, &dashboard_retry_entries/1)

    %{
      generated_at: generated_at,
      counts: %{running: length(running), retrying: length(retrying)},
      running: running,
      retrying: retrying,
      codex_totals: aggregate_codex_totals(pipeline_snapshots),
      rate_limits: aggregate_rate_limits(pipeline_snapshots),
      pipelines:
        Enum.map(pipeline_snapshots, fn
          %{pipeline: %Pipeline{} = pipeline, snapshot: snapshot} ->
            pipeline_summary_payload(pipeline, snapshot)

          %{pipeline: pipeline} ->
            %{id: inspect(pipeline), enabled: false, available: false, paused: false}
        end),
      logs: logs_payload()
    }
  end

  @spec pipeline_payload(Pipeline.t(), GenServer.name() | pid() | nil, timeout()) :: {:ok, map()} | {:error, term()}
  def pipeline_payload(%Pipeline{} = pipeline, orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case snapshot_for_orchestrator(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        {:ok,
         %{
           generated_at: generated_at,
           pipeline: pipeline_metadata_payload(pipeline, snapshot, true),
           counts: %{
             running: length(snapshot.running),
             retrying: length(snapshot.retrying)
           },
           running: Enum.map(snapshot.running, &running_entry_payload/1),
           retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
           codex_totals: snapshot.codex_totals,
           rate_limits: snapshot.rate_limits,
           polling: polling_payload(Map.get(snapshot, :polling))
         }}

      :timeout ->
        {:ok,
         %{
           generated_at: generated_at,
           pipeline: pipeline_metadata_payload(pipeline, %{}, false),
           error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
         }}

      :unavailable ->
        {:error, :unavailable}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec pipeline_refresh_payload(Pipeline.t(), GenServer.name() | pid() | nil) :: {:ok, map()} | {:error, :unavailable}
  def pipeline_refresh_payload(%Pipeline{} = pipeline, orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok,
         payload
         |> Map.put_new(:paused, false)
         |> Map.update!(:requested_at, &DateTime.to_iso8601/1)
         |> Map.put(:id, pipeline.id)}
    end
  end

  @spec pipeline_pause_payload(Pipeline.t(), GenServer.name() | pid() | nil) :: {:ok, map()} | {:error, :unavailable}
  def pipeline_pause_payload(%Pipeline{} = pipeline, orchestrator) do
    case Orchestrator.pause(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok,
         payload
         |> Map.update!(:requested_at, &DateTime.to_iso8601/1)
         |> Map.put(:id, pipeline.id)}
    end
  end

  @spec pipeline_resume_payload(Pipeline.t(), GenServer.name() | pid() | nil) :: {:ok, map()} | {:error, :unavailable}
  def pipeline_resume_payload(%Pipeline{} = pipeline, orchestrator) do
    case Orchestrator.resume(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok,
         payload
         |> Map.update!(:requested_at, &DateTime.to_iso8601/1)
         |> Map.put(:id, pipeline.id)}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec logs_payload() :: map()
  def logs_payload do
    SymphonyElixir.LogFile.recent_log_view()
  end

  defp pipeline_summary_payload(%Pipeline{} = pipeline, snapshot) do
    pipeline_metadata_payload(pipeline, snapshot, snapshot != :unavailable and snapshot != :timeout)
    |> Map.merge(%{
      running_agents: snapshot_running_count(snapshot),
      retrying_agents: snapshot_retrying_count(snapshot),
      polling: snapshot_polling_payload(snapshot)
    })
  end

  defp pipeline_metadata_payload(%Pipeline{} = pipeline, snapshot, available) do
    %{
      id: pipeline.id,
      enabled: pipeline.enabled,
      available: available,
      paused: snapshot_paused?(snapshot),
      project_slug: pipeline.tracker.project_slug,
      project_url: pipeline_project_url(pipeline.tracker.project_slug),
      workflow_path: pipeline.workflow_path
    }
  end

  defp dashboard_running_entries(%{pipeline: %Pipeline{id: pipeline_id}, snapshot: %{} = snapshot}) do
    snapshot
    |> Map.get(:running, [])
    |> Enum.map(fn entry ->
      entry
      |> Map.put(:pipeline_id, pipeline_id)
      |> dashboard_running_entry_payload()
    end)
  end

  defp dashboard_running_entries(_entry), do: []

  defp dashboard_retry_entries(%{pipeline: %Pipeline{id: pipeline_id}, snapshot: %{} = snapshot}) do
    snapshot
    |> Map.get(:retrying, [])
    |> Enum.map(fn entry ->
      entry
      |> Map.put(:pipeline_id, pipeline_id)
      |> dashboard_retry_entry_payload()
    end)
  end

  defp dashboard_retry_entries(_entry), do: []

  defp dashboard_running_entry_payload(entry) when is_map(entry) do
    running_entry_payload(entry)
    |> Map.put(:pipeline_id, Map.get(entry, :pipeline_id))
  end

  defp dashboard_retry_entry_payload(entry) when is_map(entry) do
    retry_entry_payload(entry)
    |> Map.put(:pipeline_id, Map.get(entry, :pipeline_id))
  end

  defp snapshot_for_pipeline(%Pipeline{} = pipeline, orchestrator_resolver, snapshot_timeout_ms) do
    pipeline.id
    |> orchestrator_resolver.()
    |> snapshot_for_orchestrator(snapshot_timeout_ms)
  end

  defp snapshot_for_orchestrator(nil, _snapshot_timeout_ms), do: :unavailable
  defp snapshot_for_orchestrator(orchestrator, snapshot_timeout_ms), do: Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)

  defp snapshot_running_count(%{} = snapshot), do: length(Map.get(snapshot, :running, []))
  defp snapshot_running_count(_snapshot), do: 0

  defp snapshot_retrying_count(%{} = snapshot), do: length(Map.get(snapshot, :retrying, []))
  defp snapshot_retrying_count(_snapshot), do: 0

  defp snapshot_polling_payload(%{} = snapshot), do: polling_payload(Map.get(snapshot, :polling))

  defp snapshot_polling_payload(_snapshot) do
    polling_payload(nil)
  end

  defp snapshot_paused?(%{} = snapshot), do: Map.get(snapshot, :paused, false) == true
  defp snapshot_paused?(_snapshot), do: false

  defp aggregate_codex_totals(pipeline_snapshots) when is_list(pipeline_snapshots) do
    Enum.reduce(
      pipeline_snapshots,
      %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      fn
        %{snapshot: %{codex_totals: codex_totals}}, acc when is_map(codex_totals) ->
          %{
            input_tokens: Map.get(acc, :input_tokens, 0) + Map.get(codex_totals, :input_tokens, 0),
            output_tokens: Map.get(acc, :output_tokens, 0) + Map.get(codex_totals, :output_tokens, 0),
            total_tokens: Map.get(acc, :total_tokens, 0) + Map.get(codex_totals, :total_tokens, 0),
            seconds_running: Map.get(acc, :seconds_running, 0) + Map.get(codex_totals, :seconds_running, 0)
          }

        _entry, acc ->
          acc
      end
    )
  end

  defp aggregate_rate_limits(pipeline_snapshots) when is_list(pipeline_snapshots) do
    pipeline_snapshots
    |> Enum.find_value(fn
      %{snapshot: %{} = snapshot} -> Map.get(snapshot, :rate_limits)
      _entry -> nil
    end)
  end

  defp polling_payload(%{} = polling) do
    %{
      checking: Map.get(polling, :checking?, false) == true,
      next_poll_in_ms: Map.get(polling, :next_poll_in_ms),
      poll_interval_ms: Map.get(polling, :poll_interval_ms)
    }
  end

  defp polling_payload(_polling) do
    %{
      checking: false,
      next_poll_in_ms: nil,
      poll_interval_ms: nil
    }
  end

  defp pipeline_project_url(project_slug) when is_binary(project_slug) and project_slug != "" do
    "https://linear.app/project/#{project_slug}/issues"
  end

  defp pipeline_project_url(_project_slug), do: nil

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
