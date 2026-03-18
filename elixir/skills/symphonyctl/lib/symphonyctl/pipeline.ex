defmodule Symphonyctl.Pipeline do
  @moduledoc """
  Wraps `mix pipeline.scaffold` for the Symphony repo.
  """

  @type deps :: %{
          optional(:run_command) => (String.t(), [String.t()], keyword() -> {:ok, term()} | {:error, term()})
        }

  @spec create(map(), map(), deps()) :: {:ok, term()} | {:error, term()}
  def create(params, config, deps \\ runtime_deps())
      when is_map(params) and is_map(config) and is_map(deps) do
    with {:ok, id} <- fetch_required(params, :id),
         {:ok, project_slug} <- fetch_required(params, :project_slug),
         {:ok, repo} <- fetch_required(params, :repo),
         {:ok, workspace_root} <- fetch_required(params, :workspace_root) do
      argv = [
        "pipeline.scaffold",
        id,
        "--pipelines-root",
        config.pipelines_root,
        "--project-slug",
        project_slug,
        "--repo",
        repo,
        "--workspace-root",
        workspace_root
      ]

      deps.run_command.("mix", argv, cd: config.project_root)
    end
  end

  defp runtime_deps do
    %{
      run_command: &run_command/3
    }
  end

  defp run_command(command, argv, opts) do
    case System.find_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      executable ->
        case System.cmd(executable, argv, Keyword.merge([stderr_to_stdout: true], opts)) do
          {output, 0} -> {:ok, String.trim(output)}
          {output, status} -> {:error, {:command_failed, status, String.trim(output)}}
        end
    end
  end

  defp fetch_required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end
end
