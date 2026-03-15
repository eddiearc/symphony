defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{Pipeline, PipelineStore, Workflow}

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          read_timeout_ms: pos_integer(),
          thread_sandbox: String.t(),
          turn_timeout_ms: pos_integer(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    case current_pipeline() do
      {:ok, pipeline} -> pipeline.tracker.project_slug
      {:error, _reason} -> nil
    end
  end

  @spec current_pipeline() :: {:ok, Pipeline.t()} | {:error, term()}
  def current_pipeline do
    case PipelineStore.current() do
      {:error, {:invalid_pipeline_config, message}} ->
        {:error, {:invalid_workflow_config, message}}

      other ->
        other
    end
  end

  @spec validate_pipeline(Pipeline.t()) :: :ok | {:error, term()}
  def validate_pipeline(%Pipeline{} = pipeline) do
    tracker = pipeline.tracker

    cond do
      is_nil(tracker.kind) ->
        {:error, :missing_tracker_kind}

      tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, tracker.kind}}

      tracker.kind == "linear" and not is_binary(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      tracker.kind == "linear" and not is_binary(tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  def validate_pipeline(_pipeline), do: {:error, :invalid_pipeline}

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, pipeline} <- current_pipeline() do
      validate_pipeline(pipeline)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           read_timeout_ms: settings.codex.read_timeout_ms,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_timeout_ms: settings.codex.turn_timeout_ms,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
