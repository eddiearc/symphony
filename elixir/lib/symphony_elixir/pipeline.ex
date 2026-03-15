defmodule SymphonyElixir.Pipeline do
  @moduledoc """
  Pipeline runtime model for tracker/workspace/agent execution settings.
  """

  alias SymphonyElixir.Config.Schema

  @type t :: %__MODULE__{
          id: String.t(),
          enabled: boolean(),
          source_path: String.t() | nil,
          workflow_path: String.t() | nil,
          prompt_template: String.t(),
          tracker: map(),
          polling: map(),
          workspace: map(),
          worker: map(),
          agent: map(),
          codex: map(),
          hooks: map(),
          observability: map(),
          server: map()
        }

  defstruct [
    :id,
    :source_path,
    :workflow_path,
    prompt_template: "",
    enabled: true,
    tracker: %Schema.Tracker{},
    polling: %Schema.Polling{},
    workspace: %Schema.Workspace{},
    worker: %Schema.Worker{},
    agent: %Schema.Agent{},
    codex: %Schema.Codex{},
    hooks: %Schema.Hooks{},
    observability: %Schema.Observability{},
    server: %Schema.Server{}
  ]

  @spec parse(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    normalized = normalize_keys(attrs)
    settings_config = Schema.settings_config(normalized)

    with {:ok, settings} <- Schema.parse(settings_config),
         {:ok, id} <- parse_id(normalized, opts),
         {:ok, enabled} <- parse_enabled(normalized),
         {:ok, source_path} <- parse_optional_string(normalized, "source_path", Keyword.get(opts, :source_path)),
         {:ok, workflow_path} <-
           parse_optional_string(normalized, "workflow_path", Keyword.get(opts, :workflow_path)),
         {:ok, prompt_template} <-
           parse_prompt_template(normalized, Keyword.get(opts, :prompt_template, "")) do
      {:ok,
       %__MODULE__{
         id: id,
         enabled: enabled,
         source_path: source_path,
         workflow_path: workflow_path,
         prompt_template: prompt_template,
         tracker: settings.tracker,
         polling: settings.polling,
         workspace: settings.workspace,
         worker: settings.worker,
         agent: settings.agent,
         codex: settings.codex,
         hooks: settings.hooks,
         observability: settings.observability,
         server: settings.server
       }}
    else
      {:error, {:invalid_workflow_config, message}} ->
        {:error, {:invalid_pipeline_config, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec from_workflow(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_workflow(%{config: config, prompt_template: prompt_template}, opts \\ [])
      when is_map(config) and is_binary(prompt_template) and is_list(opts) do
    workflow_path = Keyword.get(opts, :workflow_path)
    source_path = Keyword.get(opts, :source_path, workflow_path)
    default_id = Keyword.get(opts, :default_id, "default")

    config
    |> normalize_keys()
    |> Map.put_new("id", default_id)
    |> Map.put("prompt_template", prompt_template)
    |> maybe_put_path("workflow_path", workflow_path)
    |> maybe_put_path("source_path", source_path)
    |> parse(opts)
  end

  defp parse_id(normalized, opts) do
    raw_id = Map.get(normalized, "id", Keyword.get(opts, :default_id))

    case raw_id do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, :missing_pipeline_id}
        else
          {:ok, trimmed}
        end

      nil ->
        {:error, :missing_pipeline_id}

      _other ->
        {:error, :invalid_pipeline_id}
    end
  end

  defp parse_enabled(normalized) do
    case Map.get(normalized, "enabled", true) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, true}
      _other -> {:error, :invalid_pipeline_enabled}
    end
  end

  defp parse_prompt_template(normalized, fallback) do
    case Map.get(normalized, "prompt_template", fallback) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:ok, ""}
      _other -> {:error, :invalid_pipeline_prompt_template}
    end
  end

  defp parse_optional_string(normalized, key, fallback) do
    case Map.get(normalized, key, fallback) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:ok, nil}
      _other -> {:error, {:invalid_pipeline_path, key}}
    end
  end

  defp maybe_put_path(config, _key, nil), do: config
  defp maybe_put_path(config, key, value), do: Map.put_new(config, key, value)

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)
end
