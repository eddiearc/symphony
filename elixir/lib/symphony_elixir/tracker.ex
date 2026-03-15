defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_candidate_issues(map()) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(map(), String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_candidate_issues(map()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(pipeline) when is_map(pipeline) do
    pipeline
    |> adapter()
    |> dispatch(:fetch_candidate_issues, [pipeline])
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_states(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(pipeline, states) when is_map(pipeline) and is_list(states) do
    pipeline
    |> adapter()
    |> dispatch(:fetch_issues_by_states, [pipeline, states], [states])
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_states_by_ids(map(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(pipeline, issue_ids) when is_map(pipeline) and is_list(issue_ids) do
    pipeline
    |> adapter()
    |> dispatch(:fetch_issue_states_by_ids, [pipeline, issue_ids], [issue_ids])
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec create_comment(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(pipeline, issue_id, body)
      when is_map(pipeline) and is_binary(issue_id) and is_binary(body) do
    pipeline
    |> adapter()
    |> dispatch(:create_comment, [pipeline, issue_id, body], [issue_id, body])
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_state(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(pipeline, issue_id, state_name)
      when is_map(pipeline) and is_binary(issue_id) and is_binary(state_name) do
    pipeline
    |> adapter()
    |> dispatch(:update_issue_state, [pipeline, issue_id, state_name], [issue_id, state_name])
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end

  @spec adapter(map()) :: module()
  def adapter(%{tracker: %{kind: "memory"}}), do: SymphonyElixir.Tracker.Memory
  def adapter(%{tracker: %{kind: _kind}}), do: SymphonyElixir.Linear.Adapter
  def adapter(_pipeline), do: adapter()

  defp dispatch(adapter, function_name, preferred_args, fallback_args \\ []) do
    with {:module, _module} <- Code.ensure_loaded(adapter) do
      cond do
        function_exported?(adapter, function_name, length(preferred_args)) ->
          apply(adapter, function_name, preferred_args)

        fallback_args != [] and function_exported?(adapter, function_name, length(fallback_args)) ->
          apply(adapter, function_name, fallback_args)

        function_exported?(adapter, function_name, 0) ->
          apply(adapter, function_name, [])

        true ->
          {:error, {:unsupported_tracker_function, adapter, function_name}}
      end
    else
      _ ->
        {:error, {:unsupported_tracker_function, adapter, function_name}}
    end
  end
end
