defmodule SymphonyElixir.PipelineLoader do
  @moduledoc """
  Loads pipeline definitions from either a pipeline root directory or a legacy WORKFLOW.md file.
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

    cond do
      File.dir?(expanded_path) ->
        load_pipeline_root(expanded_path)

      File.regular?(expanded_path) ->
        load_legacy_workflow(expanded_path)

      true ->
        {:error, {:missing_pipeline_path, expanded_path}}
    end
  end

  @spec load_pipeline_root(Path.t()) :: {:ok, [Pipeline.t()]} | {:error, load_error()}
  def load_pipeline_root(root_path) when is_binary(root_path) do
    expanded_root = Path.expand(root_path)

    with {:ok, entries} <- File.ls(expanded_root) do
      entries
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
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
      end)
      |> case do
        {:ok, pipelines} -> {:ok, Enum.reverse(pipelines)}
        {:error, _reason} = error -> error
      end
    else
      {:error, reason} ->
        {:error, {:invalid_pipeline_root, expanded_root, reason}}
    end
  end

  @spec load_legacy_workflow(Path.t()) :: {:ok, [Pipeline.t()]} | {:error, load_error()}
  def load_legacy_workflow(workflow_path) when is_binary(workflow_path) do
    expanded_path = Path.expand(workflow_path)

    with {:ok, workflow} <- Workflow.load(expanded_path),
         {:ok, pipeline} <-
           Pipeline.from_workflow(
             workflow,
             default_id: "default",
             source_path: expanded_path,
             workflow_path: expanded_path
           ) do
      {:ok, [pipeline]}
    end
  end

  defp load_pipeline_entry(pipeline_dir) do
    pipeline_config_path = Path.join(pipeline_dir, @pipeline_config_file)
    workflow_path = Path.join(pipeline_dir, @workflow_file)

    with {:ok, pipeline_config} <- read_pipeline_config(pipeline_config_path),
         {:ok, workflow} <- Workflow.load(workflow_path) do
      Pipeline.parse(
        pipeline_config,
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
end
