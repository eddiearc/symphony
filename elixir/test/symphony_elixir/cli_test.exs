defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI
  alias SymphonyElixir.Pipeline

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      dir_exists?: fn _path ->
        send(parent, :dir_checked)
        true
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["pipelines"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :dir_checked
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to pipelines directory when path is missing" do
    parent = self()
    default_pipelines_root = Path.expand("~/.symphony/pipelines")

    deps = %{
      dir_exists?: fn _path -> flunk("default pipeline root should not require a preflight dir check") end,
      set_pipeline_root_path: fn path ->
        send(parent, {:pipeline_root_set, path})
        :ok
      end,
      load_pipelines: fn path ->
        send(parent, {:pipelines_loaded, path})
        {:ok, [%Pipeline{id: "default", enabled: true}]}
      end,
      validate_pipeline: fn _pipeline -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:pipelines_loaded, ^default_pipelines_root}
    assert_received {:pipeline_root_set, ^default_pipelines_root}
  end

  test "uses an explicit pipeline root override when provided" do
    parent = self()
    pipeline_root = "tmp/custom/pipelines"
    expanded_path = Path.expand(pipeline_root)

    deps = %{
      dir_exists?: fn path ->
        send(parent, {:pipeline_root_checked, path})
        path == expanded_path
      end,
      set_pipeline_root_path: fn path ->
        send(parent, {:pipeline_root_set, path})
        :ok
      end,
      load_pipelines: fn path ->
        send(parent, {:pipelines_loaded, path})
        {:ok, [%Pipeline{id: "default", enabled: true}]}
      end,
      validate_pipeline: fn _pipeline -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, pipeline_root], deps)
    assert_received {:pipeline_root_checked, ^expanded_path}
    assert_received {:pipelines_loaded, ^expanded_path}
    assert_received {:pipeline_root_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      dir_exists?: fn _path -> true end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path -> {:ok, [%Pipeline{id: "default", enabled: true}]} end,
      validate_pipeline: fn _pipeline -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "pipelines"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when pipeline root does not exist" do
    deps = %{
      dir_exists?: fn _path -> false end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "pipelines"], deps)
    assert message =~ "Pipeline root not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      dir_exists?: fn _path -> true end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path -> {:ok, [%Pipeline{id: "default", enabled: true}]} end,
      validate_pipeline: fn _pipeline -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "pipelines"], deps)
    assert message =~ "Failed to start Symphony with pipeline root"
    assert message =~ ":boom"
  end

  test "returns ok when pipeline root exists and app starts" do
    deps = %{
      dir_exists?: fn _path -> true end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path -> {:ok, [%Pipeline{id: "default", enabled: true}]} end,
      validate_pipeline: fn _pipeline -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "pipelines"], deps)
  end

  test "defaults to pipelines directory when path is missing and pipelines exists" do
    parent = self()
    pipelines_root = Path.expand("~/.symphony/pipelines")

    enabled_pipeline = %Pipeline{
      id: "workcow",
      enabled: true,
      workflow_path: Path.join(pipelines_root, "workcow/WORKFLOW.md")
    }

    disabled_pipeline = %Pipeline{
      id: "repo-b",
      enabled: false,
      workflow_path: Path.join(pipelines_root, "repo-b/WORKFLOW.md")
    }

    deps = %{
      dir_exists?: fn _path -> flunk("default pipeline root should not require a preflight dir check") end,
      set_pipeline_root_path: fn path ->
        send(parent, {:pipeline_root_set, path})
        :ok
      end,
      load_pipelines: fn path ->
        send(parent, {:pipelines_loaded, path})
        {:ok, [enabled_pipeline, disabled_pipeline]}
      end,
      validate_pipeline: fn pipeline ->
        send(parent, {:pipeline_validated, pipeline.id})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:pipelines_loaded, ^pipelines_root}
    assert_received {:pipeline_root_set, ^pipelines_root}
    assert_received {:pipeline_validated, "workcow"}
    refute_received {:pipeline_validated, "repo-b"}
  end

  test "rejects explicit workflow file paths" do
    parent = self()
    explicit_workflow_path = Path.expand("tmp/explicit/WORKFLOW.md")

    deps = %{
      dir_exists?: fn path ->
        send(parent, {:dir_checked, path})
        path == Path.expand("pipelines")
      end,
      set_pipeline_root_path: fn path ->
        send(parent, {:pipeline_root_set, path})
        :ok
      end,
      load_pipelines: fn path ->
        send(parent, {:pipelines_loaded, path})
        {:ok, []}
      end,
      validate_pipeline: fn _pipeline ->
        send(parent, :pipeline_validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, explicit_workflow_path], deps)
    assert message =~ "Pipeline root not found:"
    refute_received {:pipelines_loaded, _path}
    refute_received {:pipeline_root_set, _path}
    refute_received :pipeline_validated
  end

  test "returns startup error when one enabled pipeline is invalid" do
    pipelines_root = Path.expand("~/.symphony/pipelines")

    invalid_pipeline = %Pipeline{
      id: "project-a",
      enabled: true,
      workflow_path: Path.join(pipelines_root, "project-a/WORKFLOW.md")
    }

    deps = %{
      dir_exists?: fn path -> path == pipelines_root end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path -> {:ok, [invalid_pipeline]} end,
      validate_pipeline: fn
        %Pipeline{id: "project-a"} -> {:error, :missing_linear_project_slug}
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag], deps)
    assert message =~ "Invalid enabled pipeline: project-a"
    assert message =~ "missing_linear_project_slug"
  end

  test "starts even when pipeline root has no enabled pipelines" do
    pipelines_root = Path.expand("~/.symphony/pipelines")
    parent = self()

    deps = %{
      dir_exists?: fn path -> path == pipelines_root end,
      set_pipeline_root_path: fn path ->
        send(parent, {:pipeline_root_set, path})
        :ok
      end,
      load_pipelines: fn _path ->
        {:ok,
         [
           %Pipeline{id: "project-a", enabled: false},
           %Pipeline{id: "project-b", enabled: false}
         ]}
      end,
      validate_pipeline: fn _pipeline ->
        send(parent, :pipeline_validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:pipeline_root_set, ^pipelines_root}
    assert_received :started
    refute_received :pipeline_validated
  end

  test "starts from a pipeline root with multiple enabled pipelines" do
    pipelines_root = Path.expand("~/.symphony/pipelines")

    deps = %{
      dir_exists?: fn path -> path == pipelines_root end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path ->
        {:ok,
         [
           %Pipeline{id: "project-b", enabled: true},
           %Pipeline{id: "project-a", enabled: true}
         ]}
      end,
      validate_pipeline: fn _pipeline ->
        send(self(), :pipeline_validated)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received :pipeline_validated
    assert_received :pipeline_validated
  end
end
