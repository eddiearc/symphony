defmodule SymphonyElixir.PipelineSupervisor do
  @moduledoc """
  Supervises one orchestrator per enabled pipeline.
  """

  use Supervisor

  alias SymphonyElixir.{Config, Orchestrator, Pipeline, PipelineLoader, Workflow}

  @default_registry SymphonyElixir.PipelineRegistry

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:id, SymphonyElixir.Orchestrator)
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @spec lookup(String.t(), module()) :: {:ok, pid()} | :error
  def lookup(pipeline_id, registry_name \\ @default_registry) when is_binary(pipeline_id) do
    case Registry.lookup(registry_name, pipeline_id) do
      [{pid, _value}] when is_pid(pid) ->
        {:ok, pid}

      _ ->
        lookup_default_orchestrator(pipeline_id)
    end
  end

  @spec via_tuple(String.t(), module()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(pipeline_id, registry_name \\ @default_registry) when is_binary(pipeline_id) do
    {:via, Registry, {registry_name, pipeline_id}}
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry_name, @default_registry)
    pipelines = Keyword.get_lazy(opts, :pipelines, &load_pipelines!/0)

    children =
      [
        {Registry, keys: :unique, name: registry_name}
      ] ++
        Enum.map(enabled_pipelines(pipelines), &orchestrator_child_spec(&1, registry_name, opts))

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp enabled_pipelines(pipelines) when is_list(pipelines) do
    Enum.filter(pipelines, & &1.enabled)
  end

  defp orchestrator_child_spec(%Pipeline{} = pipeline, registry_name, opts) do
    %{
      id: {:orchestrator, pipeline.id},
      start:
        {Orchestrator, :start_link,
         [
           Keyword.merge(
             [pipeline: pipeline],
             orchestrator_name_opts(pipeline, registry_name, opts)
           )
         ]},
      type: :worker,
      restart: :permanent
    }
  end

  defp orchestrator_name_opts(%Pipeline{id: "default"}, registry_name, opts) do
    if registry_name == @default_registry and Keyword.get(opts, :name, __MODULE__) == __MODULE__ do
      [name: SymphonyElixir.Orchestrator]
    else
      [name: via_tuple("default", registry_name)]
    end
  end

  defp orchestrator_name_opts(%Pipeline{id: pipeline_id}, registry_name, _opts) do
    [name: via_tuple(pipeline_id, registry_name)]
  end

  defp load_pipelines! do
    pipeline_root_path = Workflow.pipeline_root_path()

    if File.dir?(pipeline_root_path) do
      case PipelineLoader.load_pipeline_root(pipeline_root_path) do
        {:ok, pipelines} -> pipelines
        {:error, _reason} -> [current_pipeline!()]
      end
    else
      [current_pipeline!()]
    end
  end

  defp current_pipeline! do
    case Config.current_pipeline() do
      {:ok, pipeline} ->
        pipeline

      {:error, reason} ->
        raise ArgumentError, "unable to load current pipeline: #{inspect(reason)}"
    end
  end

  defp lookup_default_orchestrator("default") do
    case Process.whereis(SymphonyElixir.Orchestrator) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp lookup_default_orchestrator(_pipeline_id), do: :error
end
