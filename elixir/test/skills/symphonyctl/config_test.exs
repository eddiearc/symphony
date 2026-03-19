defmodule Symphonyctl.ConfigTest do
  use ExUnit.Case, async: true

  alias Symphonyctl.Config

  test "loads yaml config and resolves env-backed secrets with defaults" do
    config_path =
      Path.join(
        System.tmp_dir!(),
        "symphonyctl-config-#{System.unique_integer([:positive, :monotonic])}.yaml"
      )

    File.write!(config_path, """
    project_root: /tmp/symphony
    pipelines_root: /tmp/pipelines
    workspace_root: /tmp/workspaces
    port: 4100
    linear:
      project_slug: delivery
      api_token_env: CUSTOM_LINEAR_TOKEN
    notify:
      telegram:
        enabled: true
        bot_token_env: TELEGRAM_TOKEN_ENV
        chat_id_env: TELEGRAM_CHAT_ID_ENV
    monitor:
      poll_interval_ms: 5000
    """)

    env = %{
      "CUSTOM_LINEAR_TOKEN" => "linear-token",
      "TELEGRAM_TOKEN_ENV" => "bot-token",
      "TELEGRAM_CHAT_ID_ENV" => "chat-id"
    }

    assert {:ok, config} = Config.load(config_path, env)
    assert config.project_root == "/tmp/symphony"
    assert config.port == 4100
    assert config.linear.project_slug == "delivery"
    assert config.linear.api_token == "linear-token"
    assert config.notify.telegram.enabled == true
    assert config.notify.telegram.bot_token == "bot-token"
    assert config.notify.telegram.chat_id == "chat-id"
    assert config.monitor.poll_interval_ms == 5_000
    assert config.start.command == "make run"
    assert config.linear.api_url == "https://api.linear.app/graphql"
  end

  test "returns defaults when config file is missing" do
    assert {:ok, config} =
             Config.load("/tmp/does-not-exist-#{System.unique_integer([:positive])}.yaml", %{})

    assert config.port == 4000
    assert config.start.command == "make run"
    assert config.monitor.poll_interval_ms == 30_000
    assert config.notify.telegram.enabled == false
  end
end
