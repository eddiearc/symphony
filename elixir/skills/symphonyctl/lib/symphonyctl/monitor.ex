defmodule Symphonyctl.Monitor do
  @moduledoc """
  Polls Linear for issue status changes until a terminal state is reached.
  """

  alias Symphonyctl.{Issue, Notifier}

  @type deps :: %{
          optional(:fetch_issue) => (String.t(), map() -> {:ok, map()} | {:error, term()}),
          optional(:notify) => (atom(), String.t() -> :ok),
          optional(:sleep) => (non_neg_integer() -> :ok)
        }

  @spec run(String.t(), map(), deps()) :: {:ok, map()} | {:error, term()}
  def run(issue_id, config, deps \\ runtime_deps())
      when is_binary(issue_id) and is_map(config) and is_map(deps) do
    do_run(issue_id, nil, config, deps)
  end

  defp do_run(issue_id, previous_state, config, deps) do
    with {:ok, issue} <- deps.fetch_issue.(issue_id, config) do
      state_name = issue.state || "Unknown"

      cond do
        terminal_state?(state_name, config.monitor.terminal_states) ->
          _ =
            deps.notify.(
              :info,
              "Issue #{issue.identifier || issue_id} reached terminal state #{state_name}. #{issue.url || ""}"
            )

          {:ok, issue}

        true ->
          maybe_notify_state_change(issue, previous_state, deps)
          :ok = deps.sleep.(config.monitor.poll_interval_ms)
          do_run(issue_id, state_name, config, deps)
      end
    end
  end

  defp maybe_notify_state_change(_issue, nil, _deps), do: :ok

  defp maybe_notify_state_change(issue, previous_state, deps) do
    if issue.state != previous_state do
      deps.notify.(
        :info,
        "Issue #{issue.identifier} moved from #{previous_state} to #{issue.state}."
      )
    else
      :ok
    end
  end

  defp terminal_state?(state_name, terminal_states) do
    Enum.any?(terminal_states, &(&1 == state_name))
  end

  defp runtime_deps do
    %{
      fetch_issue: &Issue.fetch/3,
      notify: fn level, message -> Notifier.notify(%{}, level, message) end,
      sleep: fn interval ->
        Process.sleep(interval)
        :ok
      end
    }
  end
end
