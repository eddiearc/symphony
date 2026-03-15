defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with either WORKFLOW.md or a pipelines root directory.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.LogFile
  alias SymphonyElixir.PipelineLoader

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type run_target :: {:workflow, String.t()} | {:pipelines, String.t()}

  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          dir_exists?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_pipeline_root_path: (String.t() -> :ok | {:error, term()}),
          load_pipelines: (String.t() -> {:ok, [SymphonyElixir.Pipeline.t()]} | {:error, term()}),
          validate_pipeline: (SymphonyElixir.Pipeline.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run_default_target(deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(path, deps) do
    expanded_path = Path.expand(path)

    cond do
      dir_exists?(deps, expanded_path) ->
        run_pipeline_root(expanded_path, deps)

      file_regular?(deps, expanded_path) ->
        run_workflow_file(expanded_path, deps)

      true ->
        missing_path_error(expanded_path)
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md|path-to-pipelines-root]"
  end

  @spec run_default_target(deps()) :: :ok | {:error, String.t()}
  defp run_default_target(deps) do
    default_pipelines_root = Path.expand("pipelines")

    if dir_exists?(deps, default_pipelines_root) do
      run_pipeline_root(default_pipelines_root, deps)
    else
      run_workflow_file(Path.expand("WORKFLOW.md"), deps)
    end
  end

  @spec run_workflow_file(String.t(), deps()) :: :ok | {:error, String.t()}
  defp run_workflow_file(workflow_path, deps) do
    if file_regular?(deps, workflow_path) do
      :ok = deps.set_workflow_file_path.(workflow_path)
      start_runtime({:workflow, workflow_path}, deps)
    else
      {:error, "Workflow file not found: #{workflow_path}"}
    end
  end

  @spec run_pipeline_root(String.t(), deps()) :: :ok | {:error, String.t()}
  defp run_pipeline_root(pipeline_root_path, deps) do
    with {:ok, pipelines} <- load_pipelines(deps, pipeline_root_path),
         {:ok, enabled_pipelines} <- enabled_pipelines(pipelines),
         :ok <- validate_enabled_pipelines(enabled_pipelines, deps),
         {:ok, compatibility_workflow_path} <- compatibility_workflow_path(enabled_pipelines) do
      :ok = set_pipeline_root_path(deps, pipeline_root_path)
      :ok = deps.set_workflow_file_path.(compatibility_workflow_path)
      start_runtime({:pipelines, pipeline_root_path}, deps)
    else
      {:error, {:invalid_enabled_pipeline, pipeline_id, reason}} ->
        {:error, "Invalid enabled pipeline: #{pipeline_id} (#{inspect(reason)})"}

      {:error, :no_enabled_pipelines} ->
        {:error, "No enabled pipelines found under #{pipeline_root_path}"}

      {:error, reason} ->
        {:error, "Failed to load pipelines from #{pipeline_root_path}: #{inspect(reason)}"}
    end
  end

  @spec start_runtime(run_target(), deps()) :: :ok | {:error, String.t()}
  defp start_runtime({:workflow, workflow_path}, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with workflow #{workflow_path}: #{inspect(reason)}"}
    end
  end

  defp start_runtime({:pipelines, pipeline_root_path}, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with pipeline root #{pipeline_root_path}: #{inspect(reason)}"}
    end
  end

  @spec enabled_pipelines([SymphonyElixir.Pipeline.t()]) ::
          {:ok, [SymphonyElixir.Pipeline.t(), ...]} | {:error, :no_enabled_pipelines}
  defp enabled_pipelines(pipelines) when is_list(pipelines) do
    enabled_pipelines = Enum.filter(pipelines, & &1.enabled)

    case enabled_pipelines do
      [] ->
        {:error, :no_enabled_pipelines}

      pipelines ->
        {:ok, pipelines}
    end
  end

  @spec validate_enabled_pipeline(SymphonyElixir.Pipeline.t(), deps()) ::
          :ok | {:error, {:invalid_enabled_pipeline, String.t(), term()}}
  defp validate_enabled_pipeline(pipeline, deps) do
    case validate_pipeline(deps, pipeline) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_enabled_pipeline, pipeline.id, reason}}
    end
  end

  @spec validate_enabled_pipelines([SymphonyElixir.Pipeline.t()], deps()) ::
          :ok | {:error, {:invalid_enabled_pipeline, String.t(), term()}}
  defp validate_enabled_pipelines(pipelines, deps) when is_list(pipelines) do
    Enum.reduce_while(pipelines, :ok, fn pipeline, :ok ->
      case validate_enabled_pipeline(pipeline, deps) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec compatibility_workflow_path([SymphonyElixir.Pipeline.t()]) ::
          {:ok, String.t()} | {:error, :missing_compatibility_workflow}
  defp compatibility_workflow_path(pipelines) when is_list(pipelines) do
    pipelines
    |> Enum.sort_by(& &1.id)
    |> List.first()
    |> case do
      %{workflow_path: workflow_path} when is_binary(workflow_path) and workflow_path != "" ->
        {:ok, workflow_path}

      _ ->
        {:error, :missing_compatibility_workflow}
    end
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      dir_exists?: &File.dir?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_pipeline_root_path: &SymphonyElixir.Workflow.set_pipeline_root_path/1,
      load_pipelines: &PipelineLoader.load/1,
      validate_pipeline: &Config.validate_pipeline/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp file_regular?(deps, path) do
    Map.get(deps, :file_regular?, &File.regular?/1).(path)
  end

  defp dir_exists?(deps, path) do
    Map.get(deps, :dir_exists?, &File.dir?/1).(path)
  end

  defp load_pipelines(deps, pipeline_root_path) do
    Map.get(deps, :load_pipelines, &PipelineLoader.load/1).(pipeline_root_path)
  end

  defp validate_pipeline(deps, pipeline) do
    Map.get(deps, :validate_pipeline, &Config.validate_pipeline/1).(pipeline)
  end

  defp set_pipeline_root_path(deps, pipeline_root_path) do
    Map.get(deps, :set_pipeline_root_path, &SymphonyElixir.Workflow.set_pipeline_root_path/1).(pipeline_root_path)
  end

  @spec missing_path_error(String.t()) :: {:error, String.t()}
  defp missing_path_error(path) do
    if workflow_file_name?(path) do
      {:error, "Workflow file not found: #{path}"}
    else
      {:error, "Pipeline root not found: #{path}"}
    end
  end

  @spec workflow_file_name?(String.t()) :: boolean()
  defp workflow_file_name?(path) when is_binary(path) do
    Path.basename(path) == "WORKFLOW.md"
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
