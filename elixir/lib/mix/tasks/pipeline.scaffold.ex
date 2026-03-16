defmodule Mix.Tasks.Pipeline.Scaffold do
  use Mix.Task

  alias SymphonyElixir.Workflow

  @moduledoc """
  Generates a lightweight pipeline directory with `pipeline.yaml` and `WORKFLOW.md`.
  """
  @shortdoc "Scaffold a pipeline directory under pipelines/"

  @switches [
    pipelines_root: :string,
    project_slug: :string,
    repo: :string,
    workspace_root: :string,
    codex_command: :string
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) when is_list(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    pipeline_id =
      case argv do
        [id] ->
          trimmed = String.trim(id)

          if trimmed == "" do
            Mix.raise("Usage: mix pipeline.scaffold <id> [--project-slug <slug>] [--repo <path-or-url>]")
          else
            trimmed
          end

        _ ->
          Mix.raise("Usage: mix pipeline.scaffold <id> [--project-slug <slug>] [--repo <path-or-url>]")
      end

    pipelines_root = Path.expand(Keyword.get(opts, :pipelines_root, Workflow.pipeline_root_path()))
    pipeline_dir = Path.join(pipelines_root, pipeline_id)
    pipeline_config_path = Path.join(pipeline_dir, "pipeline.yaml")
    workflow_path = Path.join(pipeline_dir, "WORKFLOW.md")
    project_slug = Keyword.get(opts, :project_slug)
    workspace_root = Path.expand(Keyword.get(opts, :workspace_root, Path.join(File.cwd!(), "workspaces")))
    codex_command = Keyword.get(opts, :codex_command, "codex app-server")
    repo = normalize_repo_source(Keyword.get(opts, :repo))

    if is_nil(project_slug) or String.trim(project_slug) == "" do
      Mix.raise("--project-slug is required")
    end

    if File.exists?(pipeline_dir) do
      Mix.raise("Pipeline directory already exists: #{pipeline_dir}")
    end

    File.mkdir_p!(pipeline_dir)
    File.write!(pipeline_config_path, render_pipeline_yaml(pipeline_id, project_slug, workspace_root, codex_command, repo))
    File.write!(workflow_path, render_workflow_prompt(pipeline_id, repo))

    Mix.shell().info("Created #{pipeline_config_path}")
    Mix.shell().info("Created #{workflow_path}")
    :ok
  end

  defp render_pipeline_yaml(pipeline_id, project_slug, workspace_root, codex_command, repo) do
    repo_hook =
      case repo do
        value when is_binary(value) ->
          """
          hooks:
            after_create: |
              git clone "#{value}" .
          """

        _ ->
          """
          hooks: {}
          """
      end

    """
    id: #{yaml_string(pipeline_id)}
    enabled: true
    tracker:
      kind: linear
      project_slug: #{yaml_string(project_slug)}
    workspace:
      root: #{yaml_string(workspace_root)}
    codex:
      command: #{yaml_string(codex_command)}
    #{String.trim_trailing(repo_hook)}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp render_workflow_prompt(pipeline_id, repo) do
    repo_line =
      case repo do
        value when is_binary(value) ->
          "Repository bootstrap source: #{value}\n"

        _ ->
          ""
      end

    """
    You are working inside pipeline `#{pipeline_id}`.

    #{repo_line}Current issue:
    - Identifier: {{ issue.identifier }}
    - Title: {{ issue.title }}

    Work only inside the current workspace. Keep progress clear and concrete.
    """
    |> String.replace("\n\n\n", "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp normalize_repo_source(nil), do: nil

  defp normalize_repo_source(repo) when is_binary(repo) do
    trimmed = String.trim(repo)

    cond do
      trimmed == "" -> nil
      String.contains?(trimmed, "://") -> trimmed
      String.starts_with?(trimmed, "git@") -> trimmed
      true -> Path.expand(trimmed)
    end
  end

  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end
