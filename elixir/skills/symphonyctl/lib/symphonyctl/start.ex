defmodule Symphonyctl.Start do
  @moduledoc """
  Starts Symphony in the background when the target port is free.
  """

  alias Symphonyctl.Notifier

  @type deps :: %{
          optional(:notify) => (atom(), String.t() -> :ok),
          optional(:port_open?) => (non_neg_integer() -> boolean()),
          optional(:spawn_command) => (String.t(), map(), keyword() -> {:ok, integer()} | {:error, term()})
        }

  @spec run(map(), deps()) :: {:ok, :already_running | :started} | {:error, term()}
  def run(config, deps \\ runtime_deps()) when is_map(config) and is_map(deps) do
    port = Map.fetch!(config, :port)

    if deps.port_open?.(port) do
      _ = deps.notify.(:info, "Symphony is already listening on port #{port}.")
      {:ok, :already_running}
    else
      launch(config, deps)
    end
  end

  defp launch(config, deps) do
    linear_token =
      System.get_env("LINEAR_API_KEY") ||
        dot_env("LINEAR_API_KEY", "~/.zshrc") ||
        dot_env("LINEAR_API_KEY", "~/.zprofile") ||
        ""

    env_prefix =
      "env PORT=#{config.port} PIPELINE_ROOT=#{shell_value(config.pipelines_root)} LINEAR_API_KEY=#{shell_value(linear_token)}"

    command = "#{env_prefix} #{config.start.command}"

    case deps.spawn_command.(command, config, cd: config.project_root, log_path: config.start.log_path) do
      {:ok, pid} ->
        _ =
          deps.notify.(
            :info,
            "Started Symphony on http://127.0.0.1:#{config.port} with pid #{pid}."
          )

        {:ok, :started}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def runtime_deps do
    %{
      notify: fn level, message ->
        Notifier.notify(%{}, level, message)
      end,
      port_open?: &port_open?/1,
      spawn_command: &spawn_command/3
    }
  end

  defp port_open?(port) when is_integer(port) and port >= 0 do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp spawn_command(command, config, opts) do
    cd = Keyword.fetch!(opts, :cd)
    log_path = config.start.log_path

    File.mkdir_p!(Path.dirname(log_path))

    shell = System.find_executable("sh") || System.find_executable("bash")

    case shell do
      nil ->
        {:error, :missing_shell}

      shell_path ->
        full_command =
          "nohup env PORT=#{config.port} PIPELINE_ROOT=#{shell_value(config.pipelines_root)} #{command} >> #{shell_value(log_path)} 2>&1 < /dev/null & echo $!"

        case System.cmd(shell_path, ["-lc", full_command], cd: cd, stderr_to_stdout: true) do
          {output, 0} ->
            parse_pid(output)

          {output, status} ->
            {:error, {:command_failed, status, String.trim(output)}}
        end
    end
  end

  defp parse_pid(output) do
    case output |> String.trim() |> Integer.parse() do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> {:error, {:invalid_pid_output, String.trim(output)}}
    end
  end

  defp shell_value(value) when is_binary(value) do
    "'#{String.replace(value, "'", "'\"'\"'")}'"
  end

  defp dot_env(key, path) do
    expanded = Path.expand(path)
    regex = ~r/#{key}="([^"]*)"/

    case File.read(expanded) do
      {:ok, content} ->
        case Regex.run(regex, content) do
          [_, value] -> value
          nil -> nil
        end

      {:error, _} ->
        nil
    end
  end
end
