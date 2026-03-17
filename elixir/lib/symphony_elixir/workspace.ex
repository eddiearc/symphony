defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, Pipeline, SSH}

  @excluded_entries MapSet.new([".elixir_ls"])
  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    create_for_issue(issue_or_identifier, nil)
  end

  @spec create_for_issue(Pipeline.t(), map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(%Pipeline{} = pipeline, issue_or_identifier) do
    create_for_issue(pipeline, issue_or_identifier, nil)
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host)
      when is_binary(worker_host) or is_nil(worker_host) do
    do_create_for_issue(nil, issue_or_identifier, worker_host)
  end

  @spec create_for_issue(Pipeline.t(), map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(%Pipeline{} = pipeline, issue_or_identifier, worker_host)
      when is_binary(worker_host) or is_nil(worker_host) do
    do_create_for_issue(pipeline, issue_or_identifier, worker_host)
  end

  defp do_create_for_issue(pipeline, issue_or_identifier, worker_host) do
    issue_context = issue_context(issue_or_identifier)
    workspace_root = workspace_root(pipeline)
    hooks = hooks(pipeline)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(workspace_root, safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, workspace_root, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host, hooks),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, hooks, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")

        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil, hooks) do
    cond do
      File.dir?(workspace) and stale_bootstrap_workspace?(workspace, hooks) ->
        create_workspace(workspace)

      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host, hooks) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  if #{remote_stale_workspace_check(hooks)}; then",
        "    rm -rf \"$workspace\"",
        "    mkdir -p \"$workspace\"",
        "    created=1",
        "  else",
        "    created=0",
        "  fi",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, hooks.timeout_ms, "workspace_prepare") do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host) when is_binary(worker_host) or is_nil(worker_host) do
    remove_workspace(workspace, workspace_root(nil), hooks(nil), worker_host)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host)
      when is_binary(identifier) and (is_binary(worker_host) or is_nil(worker_host)) do
    do_remove_issue_workspaces(nil, identifier, worker_host)
  end

  @spec remove_issue_workspaces(Pipeline.t(), term()) :: :ok
  def remove_issue_workspaces(%Pipeline{} = pipeline, identifier) do
    remove_issue_workspaces(pipeline, identifier, nil)
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec remove_issue_workspaces(Pipeline.t(), term(), worker_host()) :: :ok
  def remove_issue_workspaces(%Pipeline{} = pipeline, identifier, worker_host)
      when is_binary(identifier) and (is_binary(worker_host) or is_nil(worker_host)) do
    do_remove_issue_workspaces(pipeline, identifier, worker_host)
  end

  def remove_issue_workspaces(_pipeline, _identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    run_before_run_hook(workspace, issue_or_identifier, nil)
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host)
      when is_binary(workspace) and (is_binary(worker_host) or is_nil(worker_host)) do
    do_run_before_run_hook(nil, workspace, issue_or_identifier, worker_host)
  end

  @spec run_before_run_hook(Pipeline.t(), Path.t(), map() | String.t() | nil) ::
          :ok | {:error, term()}
  def run_before_run_hook(%Pipeline{} = pipeline, workspace, issue_or_identifier)
      when is_binary(workspace) do
    do_run_before_run_hook(pipeline, workspace, issue_or_identifier, nil)
  end

  @spec run_before_run_hook(Pipeline.t(), Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(%Pipeline{} = pipeline, workspace, issue_or_identifier, worker_host)
      when is_binary(workspace) and (is_binary(worker_host) or is_nil(worker_host)) do
    do_run_before_run_hook(pipeline, workspace, issue_or_identifier, worker_host)
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    run_after_run_hook(workspace, issue_or_identifier, nil)
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host)
      when is_binary(workspace) and (is_binary(worker_host) or is_nil(worker_host)) do
    do_run_after_run_hook(nil, workspace, issue_or_identifier, worker_host)
  end

  @spec run_after_run_hook(Pipeline.t(), Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(%Pipeline{} = pipeline, workspace, issue_or_identifier)
      when is_binary(workspace) do
    do_run_after_run_hook(pipeline, workspace, issue_or_identifier, nil)
  end

  @spec run_after_run_hook(Pipeline.t(), Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(%Pipeline{} = pipeline, workspace, issue_or_identifier, worker_host)
      when is_binary(workspace) and (is_binary(worker_host) or is_nil(worker_host)) do
    do_run_after_run_hook(pipeline, workspace, issue_or_identifier, worker_host)
  end

  defp do_remove_issue_workspaces(pipeline, identifier, nil) when is_binary(identifier) do
    case configured_worker_hosts(pipeline) do
      [] ->
        remove_issue_workspace(pipeline, identifier, nil)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspace(pipeline, identifier, &1))
    end

    :ok
  end

  defp do_remove_issue_workspaces(pipeline, identifier, worker_host)
       when is_binary(identifier) and is_binary(worker_host) do
    remove_issue_workspace(pipeline, identifier, worker_host)
    :ok
  end

  defp remove_issue_workspace(pipeline, identifier, worker_host) do
    safe_id = safe_identifier(identifier)
    workspace_root = workspace_root(pipeline)
    hooks = hooks(pipeline)

    case workspace_path_for_issue(workspace_root, safe_id, worker_host) do
      {:ok, workspace} ->
        remove_workspace(workspace, workspace_root, hooks, worker_host)

      {:error, _reason} ->
        :ok
    end
  end

  defp remove_workspace(workspace, workspace_root, hooks, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, workspace_root, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, hooks, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  defp remove_workspace(workspace, _workspace_root, hooks, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, hooks, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, hooks.timeout_ms, "before_remove") do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp do_run_before_run_hook(pipeline, workspace, issue_or_identifier, worker_host) do
    issue_context = issue_context(issue_or_identifier)
    hooks = hooks(pipeline)

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", hooks.timeout_ms, worker_host)
    end
  end

  defp do_run_after_run_hook(pipeline, workspace, issue_or_identifier, worker_host) do
    issue_context = issue_context(issue_or_identifier)
    hooks = hooks(pipeline)

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", hooks.timeout_ms, worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(workspace_root, safe_id, nil)
       when is_binary(workspace_root) and is_binary(safe_id) do
    workspace_root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(workspace_root, safe_id, worker_host)
       when is_binary(workspace_root) and is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(workspace_root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp stale_bootstrap_workspace?(workspace, hooks) do
    clean_tmp_artifacts(workspace)

    case hooks.after_create do
      nil ->
        false

      _command ->
        workspace
        |> File.ls!()
        |> Enum.reject(&MapSet.member?(@excluded_entries, &1))
        |> Enum.empty?()
    end
  rescue
    _error -> true
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, hooks, worker_host) do
    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_after_create_hook(command, workspace, issue_context, hooks.timeout_ms, worker_host)
        end

      false ->
        :ok
    end
  end

  defp run_after_create_hook(command, workspace, issue_context, timeout_ms, worker_host) do
    case run_hook(command, workspace, issue_context, "after_create", timeout_ms, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        cleanup_failed_workspace(workspace, worker_host)
        {:error, reason}
    end
  end

  defp maybe_run_before_remove_hook(workspace, hooks, nil) do
    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              hooks.timeout_ms,
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, hooks, worker_host) when is_binary(worker_host) do
    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, hooks.timeout_ms, "before_remove")
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, timeout_ms, nil) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, timeout_ms, worker_host)
       when is_binary(worker_host) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(
           worker_host,
           "cd #{shell_escape(workspace)} && #{command}",
           timeout_ms,
           hook_name
         ) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp cleanup_failed_workspace(workspace, nil) do
    File.rm_rf(workspace)
    :ok
  rescue
    error ->
      Logger.warning("Failed cleaning workspace after bootstrap error workspace=#{workspace} worker_host=local error=#{Exception.message(error)}")
      :ok
  end

  defp cleanup_failed_workspace(workspace, worker_host) when is_binary(worker_host) do
    case run_remote_command(
           worker_host,
           remote_shell_assign("workspace", workspace) <> "\nrm -rf \"$workspace\"",
           30_000,
           "workspace_cleanup"
         ) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Failed cleaning workspace after bootstrap error workspace=#{workspace} worker_host=#{worker_host} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}")

        :ok

      {:error, reason} ->
        Logger.warning("Failed cleaning workspace after bootstrap error workspace=#{workspace} worker_host=#{worker_host} reason=#{inspect(reason)}")

        :ok
    end
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp remote_stale_workspace_check(%{after_create: nil}), do: "false"

  defp remote_stale_workspace_check(_hooks) do
    "[ -z \"$(find \\\"$workspace\\\" -mindepth 1 -maxdepth 1 ! -name .elixir_ls -print -quit 2>/dev/null)\" ]"
  end

  defp validate_workspace_path(workspace, workspace_root, nil)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, _workspace_root, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms, hook_name)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp workspace_root(%Pipeline{} = pipeline), do: pipeline_workspace_root(pipeline)
  defp workspace_root(_pipeline), do: Config.settings!().workspace.root

  defp pipeline_workspace_root(%Pipeline{workspace: %{root: root}, id: pipeline_id})
       when is_binary(root) and is_binary(pipeline_id) do
    Path.join(root, safe_identifier(pipeline_id))
  end

  defp hooks(%Pipeline{hooks: hooks}) when is_map(hooks) or is_struct(hooks), do: hooks
  defp hooks(_pipeline), do: Config.settings!().hooks

  defp configured_worker_hosts(%Pipeline{worker: worker}) do
    normalize_worker_hosts(worker.ssh_hosts)
  end

  defp configured_worker_hosts(_pipeline) do
    normalize_worker_hosts(Config.settings!().worker.ssh_hosts)
  end

  defp normalize_worker_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_worker_hosts(_hosts), do: []
end
