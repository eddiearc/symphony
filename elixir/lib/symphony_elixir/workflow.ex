defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Helpers for reading and rendering pipeline workflow files.
  """

  @workflow_file_name "WORKFLOW.md"
  @pipelines_dir_name "pipelines"
  @top_level_key_order [
    "tracker",
    "polling",
    "workspace",
    "agent",
    "codex",
    "hooks",
    "observability",
    "server"
  ]

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join([pipeline_root_path(), "default", @workflow_file_name])
  end

  @spec pipeline_root_path() :: Path.t()
  def pipeline_root_path do
    Application.get_env(:symphony_elixir, :pipeline_root_path) ||
      ensure_directory(default_pipeline_root_path())
  end

  @spec default_pipeline_root_path() :: Path.t()
  def default_pipeline_root_path do
    home = System.get_env("HOME") || System.user_home!()
    Path.join([home, ".symphony", @pipelines_dir_name]) |> Path.expand()
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    :ok
  end

  @spec set_pipeline_root_path(Path.t()) :: :ok
  def set_pipeline_root_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :pipeline_root_path, path)
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    :ok
  end

  @spec clear_pipeline_root_path() :: :ok
  def clear_pipeline_root_path do
    Application.delete_env(:symphony_elixir, :pipeline_root_path)
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    load()
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec raw_content() :: {:ok, String.t()} | {:error, term()}
  def raw_content do
    raw_content(workflow_file_path())
  end

  @spec raw_content(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def raw_content(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec validate_content(String.t()) :: :ok | {:error, term()}
  def validate_content(content) when is_binary(content) do
    case parse_content(content) do
      {:ok, _workflow} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec save(String.t()) :: :ok | {:error, term()}
  def save(content) when is_binary(content) do
    case validate_content(content) do
      :ok -> File.write(workflow_file_path(), content)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_content(String.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def parse_content(content) when is_binary(content) do
    parse(content)
  end

  @spec default_pipeline_template() :: {:ok, loaded_workflow()} | {:error, term()}
  def default_pipeline_template do
    {pipeline_config_path, workflow_path} = default_pipeline_template_paths()

    with {:ok, workflow} <- load(workflow_path),
         {:ok, pipeline_config} <- read_pipeline_config(pipeline_config_path) do
      {:ok,
       %{
         config: merge_template_config(pipeline_config, workflow.config),
         prompt: workflow.prompt,
         prompt_template: workflow.prompt_template
       }}
    end
  end

  @spec render_content(map(), String.t()) :: String.t()
  def render_content(config, prompt_template)
      when is_map(config) and is_binary(prompt_template) do
    yaml =
      config
      |> normalize_render_keys()
      |> render_yaml_map(0, @top_level_key_order)

    [
      "---",
      yaml,
      "---",
      String.trim_trailing(prompt_template)
    ]
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, content} <- raw_content(path) do
      parse(content)
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    # Use Unicode-aware line splitting so UTF-8 prompt text is never torn apart by
    # byte-level regex matching on multibyte characters.
    lines = String.split(content, ~r/\R/u, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp default_pipeline_template_paths do
    repo_root = Path.expand("../../..", __DIR__)
    pipeline_dir = Path.join(repo_root, "elixir/pipelines/default")
    {Path.join(pipeline_dir, "pipeline.yaml"), Path.join(pipeline_dir, @workflow_file_name)}
  end

  defp ensure_directory(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok -> path
      {:error, _reason} -> path
    end
  end

  defp read_pipeline_config(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- YamlElixir.read_from_string(content),
         true <- is_map(parsed) do
      {:ok, parsed}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:missing_pipeline_config, path, reason}}

      {:error, reason} ->
        {:error, {:pipeline_config_parse_error, path, reason}}

      false ->
        {:error, {:pipeline_config_not_a_map, path}}
    end
  end

  defp merge_template_config(%{} = pipeline_config, %{} = workflow_config) do
    Map.merge(pipeline_config, workflow_config, fn _key, left, right ->
      merge_template_config_value(left, right)
    end)
  end

  defp merge_template_config_value(%{} = left, %{} = right),
    do: merge_template_config(left, right)

  defp merge_template_config_value(_left, right), do: right

  defp normalize_render_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_render_keys(nested))
    end)
  end

  defp normalize_render_keys(value) when is_list(value),
    do: Enum.map(value, &normalize_render_keys/1)

  defp normalize_render_keys(value), do: value

  defp render_yaml_map(map, indent, _preferred_order) when map == %{}, do: indent(indent) <> "{}"

  defp render_yaml_map(map, indent, preferred_order) when is_map(map) do
    ordered_keys =
      preferred_order ++
        (Map.keys(map)
         |> Enum.map(&to_string/1)
         |> Enum.reject(&(&1 in preferred_order))
         |> Enum.sort())

    ordered_keys
    |> Enum.filter(&Map.has_key?(map, &1))
    |> Enum.map_join("\n", fn key ->
      render_yaml_entry(key, Map.get(map, key), indent)
    end)
  end

  defp render_yaml_entry(key, value, indent) when is_map(value) do
    "#{indent(indent)}#{key}:\n#{render_yaml_map(value, indent + 2, [])}"
  end

  defp render_yaml_entry(key, value, indent) when is_list(value) do
    "#{indent(indent)}#{key}: #{render_yaml_list(value, indent)}"
  end

  defp render_yaml_entry(key, value, indent) do
    "#{indent(indent)}#{key}: #{render_yaml_scalar(value, indent)}"
  end

  defp render_yaml_list(values, _indent) when values == [], do: "[]"

  defp render_yaml_list(values, indent) when is_list(values) do
    if Enum.all?(values, &yaml_scalar?/1) do
      "[" <> Enum.map_join(values, ", ", &render_yaml_scalar(&1, indent)) <> "]"
    else
      "\n" <>
        Enum.map_join(values, "\n", fn value ->
          render_yaml_list_item(value, indent + 2)
        end)
    end
  end

  defp render_yaml_list_item(value, indent) when is_map(value) do
    rendered = render_yaml_map(value, indent + 2, [])
    "#{indent(indent)}-\n#{rendered}"
  end

  defp render_yaml_list_item(value, indent) when is_list(value) do
    "#{indent(indent)}- #{render_yaml_list(value, indent)}"
  end

  defp render_yaml_list_item(value, indent) do
    "#{indent(indent)}- #{render_yaml_scalar(value, indent)}"
  end

  defp render_yaml_scalar(value, _indent) when is_integer(value), do: Integer.to_string(value)

  defp render_yaml_scalar(value, _indent) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 6)

  defp render_yaml_scalar(true, _indent), do: "true"
  defp render_yaml_scalar(false, _indent), do: "false"
  defp render_yaml_scalar(nil, _indent), do: "null"

  defp render_yaml_scalar(value, indent) when is_binary(value) do
    if String.contains?(value, "\n") do
      render_yaml_multiline(value, indent)
    else
      quote_yaml_string(value)
    end
  end

  defp render_yaml_scalar(value, _indent), do: quote_yaml_string(to_string(value))

  defp render_yaml_multiline(value, indent) do
    lines =
      value
      |> String.trim_trailing("\n")
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", fn line -> indent(indent + 2) <> line end)

    "|\n#{lines}"
  end

  defp quote_yaml_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp yaml_scalar?(value) when is_binary(value) or is_integer(value) or is_float(value), do: true
  defp yaml_scalar?(value) when is_boolean(value) or is_nil(value), do: true
  defp yaml_scalar?(_value), do: false

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp indent(size), do: String.duplicate(" ", size)
end
