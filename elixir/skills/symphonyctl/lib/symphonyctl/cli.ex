defmodule Symphonyctl.CLI do
  @moduledoc """
  CLI entrypoint for the `syctl` helper.
  """

  alias Symphonyctl.{Config, Issue, Monitor, Pipeline, Start}

  @switches [
    config: :string,
    description: :string,
    help: :boolean,
    issue_id: :string,
    pipelines_root: :string,
    poll_interval_ms: :integer,
    port: :integer,
    project_root: :string,
    project_slug: :string,
    project_id: :string,
    repo: :string,
    team_id: :string,
    title: :string,
    workspace_root: :string
  ]

  @type cli_result :: {:ok, term()} | {:error, String.t()}

  @type deps :: %{
          optional(:issue_create) => (map(), map(), map() -> {:ok, map()} | {:error, term()}),
          optional(:load_config) => (Path.t() | nil, map() -> {:ok, map()} | {:error, term()}),
          optional(:monitor_run) => (String.t(), map(), map() -> {:ok, map()} | {:error, term()}),
          optional(:pipeline_create) => (map(), map(), map() -> {:ok, term()} | {:error, term()}),
          optional(:puts) => (String.t() -> term()),
          optional(:start_run) => (map(), map() -> {:ok, term()} | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) when is_list(args) do
    case evaluate(args) do
      {:ok, _result} ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: cli_result()
  def evaluate(args, deps \\ runtime_deps()) when is_list(args) and is_map(deps) do
    case OptionParser.parse(args, strict: @switches, aliases: [h: :help]) do
      {opts, command, []} ->
        route(command, opts, deps)

      {_opts, _command, invalid} ->
        {:error, "Invalid options: #{inspect(invalid)}\n\n#{usage()}"}
    end
  end

  @spec usage() :: String.t()
  def usage do
    """
    Symphonyctl - Symphony workflow helper

    Usage:
      syctl start [--port PORT] [--project-root PATH] [--pipelines-root PATH]
      syctl pipeline create <id> --project-slug SLUG --repo PATH --workspace-root PATH
      syctl issue create --title TITLE [--description TEXT] [--project-slug SLUG] [--team-id ID]
      syctl monitor --issue-id ISSUE-123 [--poll-interval-ms 15000]
      syctl help
    """
  end

  defp route(["help"], _opts, deps) do
    deps.puts.(usage())
    {:ok, :help}
  end

  defp route(command, opts, deps) do
    if Keyword.get(opts, :help, false) do
      deps.puts.(usage())
      {:ok, :help}
    else
      do_route(command, opts, deps)
    end
  end

  defp do_route(["help"], _opts, deps) do
    deps.puts.(usage())
    {:ok, :help}
  end

  defp do_route(["start"], opts, deps) do
    with {:ok, config} <- load_config(opts, deps),
         {:ok, result} <- deps.start_run.(override_start_config(config, opts), %{}) do
      {:ok, result}
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp do_route(["pipeline", "create", id], opts, deps) do
    with {:ok, config} <- load_config(opts, deps),
         {:ok, project_slug} <- fetch_required_opt(opts, :project_slug, "--project-slug is required"),
         {:ok, repo} <- fetch_required_opt(opts, :repo, "--repo is required"),
         {:ok, workspace_root} <-
           fetch_required_opt(opts, :workspace_root, "--workspace-root is required"),
         {:ok, result} <-
           deps.pipeline_create.(
             %{id: id, project_slug: project_slug, repo: repo, workspace_root: workspace_root},
             override_pipeline_config(config, opts),
             %{}
           ) do
      {:ok, result}
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp do_route(["issue", "create"], opts, deps) do
    with {:ok, config} <- load_config(opts, deps),
         {:ok, title} <- fetch_required_opt(opts, :title, "--title is required"),
         {:ok, result} <-
           deps.issue_create.(
             %{
               description: Keyword.get(opts, :description, ""),
               project_id: Keyword.get(opts, :project_id),
               project_slug: Keyword.get(opts, :project_slug),
               team_id: Keyword.get(opts, :team_id),
               title: title
             },
             config,
             %{}
           ) do
      deps.puts.("Created Linear issue #{result.identifier}")
      {:ok, result}
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp do_route(["monitor"], opts, deps) do
    with {:ok, config} <- load_config(opts, deps),
         {:ok, issue_id} <- fetch_required_opt(opts, :issue_id, "--issue-id is required"),
         {:ok, result} <-
           deps.monitor_run.(issue_id, override_monitor_config(config, opts), %{}) do
      {:ok, result}
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp do_route(_command, _opts, _deps), do: {:error, usage()}

  defp load_config(opts, deps) do
    deps.load_config.(Keyword.get(opts, :config, Config.default_path()), System.get_env())
  end

  defp override_start_config(config, opts) do
    config
    |> maybe_put(:port, Keyword.get(opts, :port))
    |> maybe_put(:project_root, Keyword.get(opts, :project_root))
    |> maybe_put(:pipelines_root, Keyword.get(opts, :pipelines_root))
  end

  defp override_pipeline_config(config, opts) do
    config
    |> maybe_put(:project_root, Keyword.get(opts, :project_root))
    |> maybe_put(:pipelines_root, Keyword.get(opts, :pipelines_root))
  end

  defp override_monitor_config(config, opts) do
    monitor =
      config.monitor
      |> maybe_put(:poll_interval_ms, Keyword.get(opts, :poll_interval_ms))

    Map.put(config, :monitor, monitor)
  end

  defp fetch_required_opt(opts, key, error_message) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error_message}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp runtime_deps do
    %{
      issue_create: &Issue.create/3,
      load_config: &Config.load/2,
      monitor_run: &Monitor.run/3,
      pipeline_create: &Pipeline.create/3,
      puts: &IO.puts/1,
      start_run: &Start.run/2
    }
  end
end
