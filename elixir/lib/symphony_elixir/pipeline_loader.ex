defmodule SymphonyElixir.PipelineLoader do
  @moduledoc """
  Loads pipeline definitions from a pipeline root directory.
  """

  alias SymphonyElixir.{Pipeline, Workflow}

  @pipeline_config_file "pipeline.yaml"
  @workflow_file "WORKFLOW.md"

  @type load_error ::
          {:missing_pipeline_path, Path.t()}
          | {:invalid_pipeline_root, Path.t(), term()}
          | {:invalid_pipeline_entry, Path.t(), term()}
          | {:missing_workflow_file, Path.t(), term()}
          | {:workflow_parse_error, term()}
          | :workflow_front_matter_not_a_map
          | term()

  @spec load(Path.t()) :: {:ok, [Pipeline.t()]} | {:error, load_error()}
  def load(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    if File.dir?(expanded_path) do
      load_pipeline_root(expanded_path)
    else
      {:error, {:missing_pipeline_path, expanded_path}}
    end
  end

  @spec load_pipeline_root(Path.t()) :: {:ok, [Pipeline.t()]} | {:error, load_error()}
  def load_pipeline_root(root_path) when is_binary(root_path) do
    expanded_root = Path.expand(root_path)

    case File.ls(expanded_root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, &accumulate_pipeline_entry(&1, expanded_root, &2))
        |> case do
          {:ok, pipelines} -> {:ok, Enum.reverse(pipelines)}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, {:invalid_pipeline_root, expanded_root, reason}}
    end
  end

  @spec load_pipeline_dir(Path.t()) :: {:ok, Pipeline.t()} | {:error, load_error()}
  def load_pipeline_dir(pipeline_dir) when is_binary(pipeline_dir) do
    expanded_dir = Path.expand(pipeline_dir)

    if File.dir?(expanded_dir) do
      load_pipeline_entry(expanded_dir)
    else
      {:error, {:missing_pipeline_path, expanded_dir}}
    end
  end

  @spec reload_pipeline(Pipeline.t()) :: {:ok, Pipeline.t()} | {:error, load_error()}
  def reload_pipeline(%Pipeline{} = pipeline) do
    if is_binary(pipeline.source_path) and File.dir?(pipeline.source_path) do
      load_pipeline_dir(pipeline.source_path)
    else
      {:error, {:missing_pipeline_path, pipeline.source_path || pipeline.workflow_path || pipeline.id}}
    end
  end

  defp load_pipeline_entry(pipeline_dir) do
    pipeline_config_path = Path.join(pipeline_dir, @pipeline_config_file)
    workflow_path = Path.join(pipeline_dir, @workflow_file)

    with {:ok, pipeline_config} <- read_pipeline_config(pipeline_config_path),
         {:ok, workflow} <- Workflow.load(workflow_path) do
      merged_config = merge_pipeline_config(pipeline_config, workflow.config)

      Pipeline.parse(
        merged_config,
        source_path: pipeline_dir,
        workflow_path: workflow_path,
        prompt_template: workflow.prompt_template,
        default_id: Path.basename(pipeline_dir)
      )
    end
  end

  defp read_pipeline_config(pipeline_config_path) do
    with {:ok, content} <- File.read(pipeline_config_path),
         {:ok, parsed} <- YamlElixir.read_from_string(content),
         true <- is_map(parsed) do
      {:ok, parsed}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:missing_pipeline_config, pipeline_config_path, reason}}

      {:error, reason} ->
        {:error, {:pipeline_config_parse_error, pipeline_config_path, reason}}

      false ->
        {:error, {:pipeline_config_not_a_map, pipeline_config_path}}
    end
  end

  defp accumulate_pipeline_entry(entry, expanded_root, {:ok, acc}) do
    pipeline_dir = Path.join(expanded_root, entry)

    if File.dir?(pipeline_dir) do
      case load_pipeline_entry(pipeline_dir) do
        {:ok, pipeline} ->
          {:cont, {:ok, [pipeline | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_pipeline_entry, pipeline_dir, reason}}}
      end
    else
      {:cont, {:ok, acc}}
    end
  end

  defp merge_pipeline_config(%{} = pipeline_config, %{} = workflow_config) do
    Map.merge(pipeline_config, workflow_config, fn _key, left, right ->
      merge_pipeline_config_value(left, right)
    end)
  end

  defp merge_pipeline_config_value(%{} = left, %{} = right),
    do: merge_pipeline_config(left, right)

  defp merge_pipeline_config_value(_left, right), do: right
end
