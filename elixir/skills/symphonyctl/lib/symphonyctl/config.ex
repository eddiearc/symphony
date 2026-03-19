defmodule Symphonyctl.Config do
  @moduledoc """
  Loads `syctl` configuration from YAML with env-backed secrets.
  """

  @default_linear_api_url "https://api.linear.app/graphql"
  @default_monitor_terminal_states ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"]

  @type config :: %{
          linear: map(),
          monitor: map(),
          notify: map(),
          pipelines_root: String.t(),
          port: non_neg_integer(),
          project_root: String.t(),
          start: map(),
          workspace_root: String.t()
        }

  @spec default_path() :: String.t()
  def default_path do
    Path.join(System.user_home!(), ".symphonyctl/config.yaml")
  end

  @spec load(Path.t() | nil, map()) :: {:ok, config()} | {:error, term()}
  def load(path \\ default_path(), env \\ System.get_env()) when is_map(env) do
    config_path = if is_binary(path) and path != "", do: path, else: default_path()
    base_dir = config_path |> Path.expand() |> Path.dirname()

    with {:ok, overrides} <- load_overrides(config_path) do
      config =
        defaults()
        |> deep_merge(overrides)
        |> finalize(base_dir, env)

      {:ok, config}
    end
  end

  @spec defaults() :: config()
  def defaults do
    project_root = project_root()

    %{
      linear: %{
        api_token: nil,
        api_token_env: "LINEAR_API_KEY",
        api_url: @default_linear_api_url,
        project_slug: nil
      },
      monitor: %{
        poll_interval_ms: 30_000,
        terminal_states: @default_monitor_terminal_states
      },
      notify: %{
        telegram: %{
          bot_token: nil,
          bot_token_env: "TELEGRAM_BOT_TOKEN",
          chat_id: nil,
          chat_id_env: "TELEGRAM_CHAT_ID",
          enabled: false
        }
      },
      pipelines_root: Path.join(project_root, "pipelines"),
      port: 4000,
      project_root: project_root,
      start: %{
        command: "make run",
        log_path: Path.join(project_root, "log/symphonyctl.log")
      },
      workspace_root: Path.join(project_root, "workspaces")
    }
  end

  defp load_overrides(path) do
    case File.read(path) do
      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, parsed} when is_map(parsed) -> {:ok, normalize_keys(parsed)}
          {:ok, _parsed} -> {:error, :config_not_a_map}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize(config, base_dir, env) do
    project_root = expand_path(config.project_root, base_dir)

    linear =
      config.linear
      |> resolve_secret(:api_token, :api_token_env, env)
      |> Map.put(:api_url, config.linear.api_url || @default_linear_api_url)

    telegram =
      config.notify.telegram
      |> resolve_secret(:bot_token, :bot_token_env, env)
      |> resolve_secret(:chat_id, :chat_id_env, env)

    %{
      config
      | linear: linear,
        notify: %{telegram: telegram},
        pipelines_root: expand_path(config.pipelines_root, project_root),
        project_root: project_root,
        start: %{
          command: config.start.command || "make run",
          log_path: expand_path(config.start.log_path, project_root)
        },
        workspace_root: expand_path(config.workspace_root, project_root)
    }
  end

  defp resolve_secret(section, value_key, env_key, env) do
    case Map.get(section, value_key) do
      value when is_binary(value) and value != "" ->
        Map.put(section, value_key, value)

      _ ->
        env_name = Map.get(section, env_key)
        Map.put(section, value_key, fetch_env(env_name, env))
    end
  end

  defp fetch_env(value, env) when is_binary(value) and value != "" do
    Map.get(env, value) || Map.get(env, String.trim_leading(value, "$"))
  end

  defp fetch_env(_value, _env), do: nil

  defp project_root do
    Path.expand("../..", __DIR__)
  end

  defp expand_path(value, base_dir) when is_binary(value) do
    cond do
      value == "" -> base_dir
      String.starts_with?(value, "~") -> Path.expand(value)
      Path.type(value) == :absolute -> Path.expand(value)
      true -> Path.expand(value, base_dir)
    end
  end

  defp expand_path(_value, base_dir), do: Path.expand(base_dir)

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
