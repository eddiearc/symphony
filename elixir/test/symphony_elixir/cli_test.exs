defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI
  alias SymphonyElixir.Pipeline

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
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

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "defaults to pipelines directory when path is missing and pipelines exists" do
    parent = self()
    pipelines_root = Path.expand("pipelines")

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
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        false
      end,
      dir_exists?: fn path ->
        send(parent, {:dir_checked, path})
        path == pipelines_root
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
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
    assert_received {:dir_checked, ^pipelines_root}
    assert_received {:pipelines_loaded, ^pipelines_root}
    assert_received {:pipeline_root_set, ^pipelines_root}
    assert_received {:pipeline_validated, "workcow"}
    refute_received {:pipeline_validated, "repo-b"}
    assert_received {:workflow_set, workflow_path}
    assert workflow_path == Path.join(pipelines_root, "workcow/WORKFLOW.md")
  end

  test "explicit workflow path bypasses pipelines auto-detection" do
    parent = self()
    explicit_workflow_path = Path.expand("tmp/explicit/WORKFLOW.md")

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == explicit_workflow_path
      end,
      dir_exists?: fn path ->
        send(parent, {:dir_checked, path})
        path == Path.expand("pipelines")
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
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

    assert :ok = CLI.evaluate([@ack_flag, explicit_workflow_path], deps)
    assert_received {:workflow_checked, ^explicit_workflow_path}
    assert_received {:workflow_set, ^explicit_workflow_path}
    refute_received {:pipelines_loaded, _path}
    refute_received {:pipeline_root_set, _path}
    refute_received :pipeline_validated
  end

  test "returns startup error when one enabled pipeline is invalid" do
    pipelines_root = Path.expand("pipelines")

    invalid_pipeline = %Pipeline{
      id: "project-a",
      enabled: true,
      workflow_path: Path.join(pipelines_root, "project-a/WORKFLOW.md")
    }

    deps = %{
      file_regular?: fn _path -> false end,
      dir_exists?: fn path -> path == pipelines_root end,
      set_workflow_file_path: fn _path -> :ok end,
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

  test "returns startup error when pipeline root has no enabled pipelines" do
    pipelines_root = Path.expand("pipelines")

    deps = %{
      file_regular?: fn _path -> false end,
      dir_exists?: fn path -> path == pipelines_root end,
      set_workflow_file_path: fn _path -> :ok end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path ->
        {:ok,
         [
           %Pipeline{id: "project-a", enabled: false},
           %Pipeline{id: "project-b", enabled: false}
         ]}
      end,
      validate_pipeline: fn _pipeline -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag], deps)
    assert message =~ "No enabled pipelines found under"
  end

  test "returns startup error when pipeline root has multiple enabled pipelines" do
    pipelines_root = Path.expand("pipelines")

    deps = %{
      file_regular?: fn _path -> false end,
      dir_exists?: fn path -> path == pipelines_root end,
      set_workflow_file_path: fn _path -> :ok end,
      set_pipeline_root_path: fn _path -> :ok end,
      load_pipelines: fn _path ->
        {:ok,
         [
           %Pipeline{id: "project-a", enabled: true},
           %Pipeline{id: "project-b", enabled: true}
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

    assert {:error, message} = CLI.evaluate([@ack_flag], deps)
    assert message =~ "Exactly one enabled pipeline is required"
    assert message =~ "project-a"
    assert message =~ "project-b"
    refute_received :pipeline_validated
  end
end
