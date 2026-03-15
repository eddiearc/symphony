defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues(%{id: pipeline_id, tracker: %{project_slug: project_slug}}) do
      send(self(), {:fetch_candidate_issues_called, pipeline_id, project_slug})
      {:ok, [{pipeline_id, project_slug}]}
    end

    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(%{id: pipeline_id}, states) do
      send(self(), {:fetch_issues_by_states_called, pipeline_id, states})
      {:ok, states}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(%{id: pipeline_id}, issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, pipeline_id, issue_ids})
      {:ok, issue_ids}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(%{id: pipeline_id}, query, variables) do
      send(self(), {:graphql_called, pipeline_id, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      snapshot =
        state
        |> Keyword.fetch!(:snapshot)
        |> Map.put(:paused, Keyword.get(state, :paused, false))

      {:reply, snapshot, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call(:pause, _from, state) do
      paused? = Keyword.get(state, :paused, false)
      updated_state = Keyword.put(state, :paused, true)
      reply = %{paused: true, changed: not paused?, requested_at: DateTime.utc_now(), operations: ["pause"]}

      {:reply, reply, updated_state}
    end

    def handle_call(:resume, _from, state) do
      paused? = Keyword.get(state, :paused, false)
      updated_state = Keyword.put(state, :paused, false)
      reply = %{paused: false, changed: paused?, requested_at: DateTime.utc_now(), operations: ["resume", "poll"]}

      {:reply, reply, updated_state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow parser preserves utf-8 prompt text for config panel serialization" do
    chinese_prompt = """
    你正在处理 Linear 工单 `{{ issue.identifier }}`

    执行要求：
    - 只汇报已完成动作
    - 不要包含“给用户的下一步”
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: chinese_prompt)

    assert {:ok, workflow} = Workflow.load()
    assert String.valid?(workflow.prompt)
    assert String.valid?(workflow.prompt_template)
    assert {:ok, _json} = Jason.encode(workflow.prompt_template)
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    memory_pipeline = pipeline_fixture("memory-pipeline", "memory", nil)

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter(memory_pipeline) == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues(memory_pipeline)

    assert {:ok, [^issue]} =
             SymphonyElixir.Tracker.fetch_issues_by_states(memory_pipeline, [" in progress ", 42])

    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(memory_pipeline, ["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment(memory_pipeline, "issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state(memory_pipeline, "issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    linear_pipeline = pipeline_fixture("linear-pipeline", "linear", "linear-project")
    assert SymphonyElixir.Tracker.adapter(linear_pipeline) == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    pipeline = pipeline_fixture("pipeline-a", "linear", "project-a")

    assert {:ok, [{"pipeline-a", "project-a"}]} = Adapter.fetch_candidate_issues(pipeline)
    assert_receive {:fetch_candidate_issues_called, "pipeline-a", "project-a"}

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(pipeline, ["Todo"])
    assert_receive {:fetch_issues_by_states_called, "pipeline-a", ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(pipeline, ["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, "pipeline-a", ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment(pipeline, "issue-1", "hello")
    assert_receive {:graphql_called, "pipeline-a", create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment(pipeline, "issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment(pipeline, "issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment(pipeline, "issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment(pipeline, "issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state(pipeline, "issue-1", "Done")
    assert_receive {:graphql_called, "pipeline-a", state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, "pipeline-a", update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state(pipeline, "issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state(pipeline, "issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state(pipeline, "issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state(pipeline, "issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state(pipeline, "issue-1", "Odd")
  end

  test "tracker and adapter keep different project slugs isolated per pipeline" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    pipeline_a = pipeline_fixture("pipeline-a", "linear", "project-a")
    pipeline_b = pipeline_fixture("pipeline-b", "linear", "project-b")

    assert {:ok, [{"pipeline-a", "project-a"}]} = SymphonyElixir.Tracker.fetch_candidate_issues(pipeline_a)
    assert {:ok, [{"pipeline-b", "project-b"}]} = SymphonyElixir.Tracker.fetch_candidate_issues(pipeline_b)
    assert_receive {:fetch_candidate_issues_called, "pipeline-a", "project-a"}
    assert_receive {:fetch_candidate_issues_called, "pipeline-b", "project-b"}
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)
    log_root = Path.join(System.tmp_dir!(), "symphony-observability-logs-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")

    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "info booted\nwarn retrying issue\n")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom"
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "logs" => %{
               "path" => log_path,
               "available" => true,
               "source_paths" => [log_path],
               "truncated" => false,
               "lines" => ["info booted", "warn retrying issue"]
             }
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{"path" => Path.join(Config.settings!().workspace.root, "MT-HTTP")},
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "phoenix observability api exposes per-pipeline state and controls" do
    alpha_orchestrator = Module.concat(__MODULE__, :AlphaPipelineOrchestrator)
    beta_orchestrator = Module.concat(__MODULE__, :BetaPipelineOrchestrator)
    alpha_pipeline = pipeline_fixture("alpha", "linear", "alpha-project")
    beta_pipeline = pipeline_fixture("beta", "linear", "beta-project")

    {:ok, _alpha_pid} =
      StaticOrchestrator.start_link(
        name: alpha_orchestrator,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        },
        paused: false
      )

    {:ok, _beta_pid} =
      StaticOrchestrator.start_link(
        name: beta_orchestrator,
        snapshot: %{
          running: [],
          retrying: [],
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          rate_limits: nil,
          polling: %{checking?: false, next_poll_in_ms: 15_000, poll_interval_ms: 15_000}
        },
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        },
        paused: true
      )

    start_test_endpoint(
      pipelines: [alpha_pipeline, beta_pipeline],
      pipeline_orchestrators: %{
        "alpha" => alpha_orchestrator,
        "beta" => beta_orchestrator
      },
      snapshot_timeout_ms: 50
    )

    pipelines_payload = json_response(get(build_conn(), "/api/v1/pipelines"), 200)

    assert pipelines_payload == %{
             "generated_at" => pipelines_payload["generated_at"],
             "pipelines" => [
               %{
                 "id" => "alpha",
                 "enabled" => true,
                 "available" => true,
                 "paused" => false,
                 "running_agents" => 1,
                 "retrying_agents" => 1,
                 "project_slug" => "alpha-project",
                 "project_url" => "https://linear.app/project/alpha-project/issues",
                 "workflow_path" => nil,
                 "polling" => %{
                   "checking" => false,
                   "next_poll_in_ms" => nil,
                   "poll_interval_ms" => nil
                 }
               },
               %{
                 "id" => "beta",
                 "enabled" => true,
                 "available" => true,
                 "paused" => true,
                 "running_agents" => 0,
                 "retrying_agents" => 0,
                 "project_slug" => "beta-project",
                 "project_url" => "https://linear.app/project/beta-project/issues",
                 "workflow_path" => nil,
                 "polling" => %{
                   "checking" => false,
                   "next_poll_in_ms" => 15_000,
                   "poll_interval_ms" => 15_000
                 }
               }
             ]
           }

    alpha_payload = json_response(get(build_conn(), "/api/v1/pipelines/alpha"), 200)

    assert alpha_payload == %{
             "generated_at" => alpha_payload["generated_at"],
             "pipeline" => %{
               "id" => "alpha",
               "enabled" => true,
               "available" => true,
               "paused" => false,
               "project_slug" => "alpha-project",
               "project_url" => "https://linear.app/project/alpha-project/issues",
               "workflow_path" => nil
             },
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => alpha_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => alpha_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom"
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "polling" => %{
               "checking" => false,
               "next_poll_in_ms" => nil,
               "poll_interval_ms" => nil
             }
           }

    assert %{"id" => "alpha", "paused" => false, "operations" => ["poll", "reconcile"]} =
             json_response(post(build_conn(), "/api/v1/pipelines/alpha/refresh", %{}), 202)

    assert %{"id" => "beta", "paused" => true, "operations" => ["pause"]} =
             json_response(post(build_conn(), "/api/v1/pipelines/beta/pause", %{}), 202)

    assert %{"id" => "beta", "paused" => false, "operations" => ["resume", "poll"]} =
             json_response(post(build_conn(), "/api/v1/pipelines/beta/resume", %{}), 202)

    resumed_payload = json_response(get(build_conn(), "/api/v1/pipelines/beta"), 200)
    assert resumed_payload["pipeline"]["paused"] == false

    assert json_response(get(build_conn(), "/api/v1/pipelines/missing"), 404) ==
             %{
               "error" => %{"code" => "pipeline_not_found", "message" => "Pipeline not found"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()
    log_root = Path.join(System.tmp_dir!(), "symphony-dashboard-logs-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")

    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "info dashboard ready\nwarn no active agents\n")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "编排席"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "累计用时"
    assert html =~ "在线"
    assert html =~ "离线"
    assert html =~ "日志区"
    assert html =~ "复制会话 ID"
    assert html =~ "最新动态"
    assert html =~ "配额视窗"
    assert html =~ "在途会话"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "Agent 内容流：structured update"
    end)
  end

  test "dashboard liveview renders a multi-pipeline host summary" do
    alpha_orchestrator = Module.concat(__MODULE__, :DashboardAlphaOrchestrator)
    beta_orchestrator = Module.concat(__MODULE__, :DashboardBetaOrchestrator)
    alpha_pipeline = pipeline_fixture("alpha", "linear", "alpha-project")
    beta_pipeline = pipeline_fixture("beta", "linear", "beta-project")

    {:ok, _alpha_pid} =
      StaticOrchestrator.start_link(
        name: alpha_orchestrator,
        snapshot: static_snapshot(),
        refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]},
        paused: false
      )

    {:ok, _beta_pid} =
      StaticOrchestrator.start_link(
        name: beta_orchestrator,
        snapshot: %{
          running: [],
          retrying: [
            %{
              issue_id: "issue-beta-retry",
              identifier: "MT-BETA",
              attempt: 1,
              due_in_ms: 5_000,
              error: "paused upstream"
            }
          ],
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          rate_limits: nil,
          polling: %{checking?: false, next_poll_in_ms: nil, poll_interval_ms: 15_000}
        },
        refresh: %{queued: false, coalesced: true, requested_at: DateTime.utc_now(), operations: []},
        paused: true
      )

    start_test_endpoint(
      pipelines: [alpha_pipeline, beta_pipeline],
      pipeline_orchestrators: %{
        "alpha" => alpha_orchestrator,
        "beta" => beta_orchestrator
      },
      snapshot_timeout_ms: 50
    )

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "托管管线"
    assert html =~ "alpha"
    assert html =~ "beta"
    assert html =~ "运行中"
    assert html =~ "暂停中"
    assert html =~ "alpha-project"
    assert html =~ "beta-project"
    assert html =~ "pipelines"
  end

  test "dashboard liveview renders camelCase rate limits and wrapped log sources" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardCamelCaseRateLimitOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:rate_limits, %{
        "planType" => "priority",
        "primary" => %{
          "usedPercent" => 52,
          "windowDurationMins" => 300,
          "resetsAt" => 1
        },
        "secondary" => %{
          "usedPercent" => 66,
          "windowDurationMins" => 10_080,
          "resetsAt" => 2
        }
      })

    log_root = Path.join(System.tmp_dir!(), "symphony-dashboard-wrap-logs-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")
    wrapped_log_path = log_path <> ".1"
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(wrapped_log_path, "wrap-dashboard-1\nwrap-dashboard-2\n")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _logs_view, logs_html} = live(build_conn(), "/panel/logs")
    assert logs_html =~ log_path
    assert logs_html =~ wrapped_log_path
    assert logs_html =~ "wrap-dashboard-1"
    assert logs_html =~ "wrap-dashboard-2"

    {:ok, _home_view, home_html} = live(build_conn(), "/")
    assert home_html =~ "priority"
    assert home_html =~ "52%"
    assert home_html =~ "5小时窗口"
    assert home_html =~ "重置 1970-01-01 00:00:01Z"
    assert home_html =~ "66%"
    assert home_html =~ "7天窗口"
    assert home_html =~ "重置 1970-01-01 00:00:02Z"
  end

  test "dashboard exposes a config panel that edits and saves WORKFLOW.md" do
    orchestrator_name = Module.concat(__MODULE__, :WorkflowEditorOrchestrator)
    snapshot = static_snapshot()

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    workflow_path = Workflow.workflow_file_path()

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "观测区"
    assert html =~ "配置区"

    {:ok, config_view, config_html} = live(build_conn(), "/panel/config")

    assert config_html =~ "WORKFLOW.md 编辑台"
    assert config_html =~ workflow_path
    assert config_html =~ "project_slug:"
    assert config_html =~ "&quot;project&quot;"

    updated_workflow =
      workflow_path
      |> File.read!()
      |> String.replace("project_slug: \"project\"", "project_slug: \"updated-project\"")
      |> String.replace("You are an agent for this repository.", "Updated workflow prompt")

    saved_html =
      config_view
      |> form("#workflow-editor-form", workflow: %{body: updated_workflow})
      |> render_submit()

    assert saved_html =~ "已保存并重新加载运行配置。"
    assert File.read!(workflow_path) == updated_workflow
    assert SymphonyElixir.Config.linear_project_slug() == "updated-project"
  end

  test "config panel exposes save confirmation metadata and keyboard shortcut hook" do
    orchestrator_name = Module.concat(__MODULE__, :WorkflowEditorHooksOrchestrator)
    snapshot = static_snapshot()

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/panel/config")

    assert html =~ "phx-hook=\"WorkflowEditor\""
    assert html =~ "data-save-shortcut=\"meta+s,ctrl+s\""
    assert html =~ "data-confirm-message="
    assert html =~ "即将保存 WORKFLOW.md"
    assert html =~ "当前草稿和已装载配置一致。"
    assert html =~ "结构化"
    assert html =~ "YAML"
    assert html =~ "config-tab config-tab-active"
    assert html =~ "保存 WORKFLOW.md"
    assert html =~ "id=\"workflow-save-form\""
    refute html =~ "Memory"
    assert html =~ "决定 Symphony 去哪里拉任务"
    assert html =~ "优先使用这里的值；留空则回退到环境变量"
    assert html =~ "控制 orchestrator 轮询节奏"
    assert html =~ "决定每次会话如何启动 Codex"
    assert html =~ "这是发给每个任务 agent 的核心执行说明"
  end

  test "config panel offers structured controls that update the markdown draft" do
    orchestrator_name = Module.concat(__MODULE__, :StructuredWorkflowEditorOrchestrator)
    snapshot = static_snapshot()

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/panel/config")

    updated_html =
      view
      |> form("#workflow-structured-form",
        workflow_form: %{
          "tracker_project_slug" => "designer-project",
          "workspace_root" => "/tmp/designer-workspaces",
          "prompt_template" => "Structured prompt body"
        }
      )
      |> render_change()

    assert updated_html =~ "结构化字段"
    assert updated_html =~ "designer-project"
    assert updated_html =~ "/tmp/designer-workspaces"
    assert updated_html =~ "Structured prompt body"
  end

  test "config panel saves the latest structured draft even if the textarea posts stale content" do
    orchestrator_name = Module.concat(__MODULE__, :StructuredWorkflowSaveOrchestrator)
    snapshot = static_snapshot()

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    workflow_path = Workflow.workflow_file_path()
    original_workflow = File.read!(workflow_path)

    {:ok, view, _html} = live(build_conn(), "/panel/config")

    updated_draft_html =
      view
      |> form("#workflow-structured-form",
        workflow_form: %{
          "tracker_project_slug" => "structured-save-project"
        }
      )
      |> render_change()

    assert updated_draft_html =~ "structured-save-project"

    saved_html =
      view
      |> form("#workflow-editor-form", workflow: %{body: original_workflow})
      |> render_submit()

    assert saved_html =~ "已保存并重新加载运行配置。"
    assert File.read!(workflow_path) =~ "structured-save-project"
    assert SymphonyElixir.Config.linear_project_slug() == "structured-save-project"
  end

  test "config panel rejects tracker.kind memory in yaml mode" do
    orchestrator_name = Module.concat(__MODULE__, :MemoryTrackerKindRejectedOrchestrator)
    snapshot = static_snapshot()

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    workflow_path = Workflow.workflow_file_path()
    original_workflow = File.read!(workflow_path)
    invalid_workflow = String.replace(original_workflow, "kind: \"linear\"", "kind: \"memory\"")

    {:ok, view, _html} = live(build_conn(), "/panel/config")

    saved_html =
      view
      |> form("#workflow-editor-form", workflow: %{body: invalid_workflow})
      |> render_submit()

    assert saved_html =~ "配置区不支持 `tracker.kind: memory`，请改为 `linear`。"
    assert File.read!(workflow_path) == original_workflow
  end

  test "config panel exposes hooks controls and persists structured hook edits" do
    orchestrator_name = Module.concat(__MODULE__, :StructuredWorkflowHooksOrchestrator)
    snapshot = static_snapshot()

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    workflow_path = Workflow.workflow_file_path()
    original_workflow = File.read!(workflow_path)

    {:ok, view, html} = live(build_conn(), "/panel/config")

    assert html =~ "Hooks"
    assert html =~ "after create"
    assert html =~ "before remove"
    assert html =~ "创建 workspace 后立刻执行"
    assert html =~ "限制单个 hook 最长运行时间"

    updated_html =
      view
      |> form("#workflow-structured-form",
        workflow_form: %{
          "hooks_after_create" => "git clone https://example.com/repo .\npnpm install\n",
          "hooks_before_run" => "pnpm lint\n",
          "hooks_after_run" => "pnpm test\n",
          "hooks_before_remove" => "echo cleanup\n",
          "hooks_timeout_ms" => "900000"
        }
      )
      |> render_change()

    assert updated_html =~ "git clone https://example.com/repo ."
    assert updated_html =~ "pnpm lint"
    assert updated_html =~ "pnpm test"
    assert updated_html =~ "echo cleanup"
    assert updated_html =~ "900000"

    saved_html =
      view
      |> form("#workflow-editor-form", workflow: %{body: original_workflow})
      |> render_submit()

    saved_workflow = File.read!(workflow_path)

    assert saved_html =~ "已保存并重新加载运行配置。"
    assert saved_workflow =~ "after_create:"
    assert saved_workflow =~ "git clone https://example.com/repo ."
    assert saved_workflow =~ "before_run:"
    assert saved_workflow =~ "pnpm lint"
    assert saved_workflow =~ "after_run:"
    assert saved_workflow =~ "pnpm test"
    assert saved_workflow =~ "before_remove:"
    assert saved_workflow =~ "echo cleanup"
    assert saved_workflow =~ "timeout_ms: 900000"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "快照暂不可用"
    assert html =~ "snapshot_unavailable"
  end

  test "logs panel renders from left nav even when the log file is empty" do
    orchestrator_name = Module.concat(__MODULE__, :LogsPanelOrchestrator)
    snapshot = static_snapshot()
    log_root = Path.join(System.tmp_dir!(), "symphony-logs-panel-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: %{}})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/panel/logs")

    assert html =~ "日志区"
    assert html =~ log_path
    assert html =~ "当前日志文件还没有可展示内容。"
    assert html =~ "control-nav-link control-nav-link-active"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp pipeline_fixture(id, kind, project_slug) do
    tracker =
      %{
        "kind" => kind
      }
      |> maybe_put("api_key", "token")
      |> maybe_put("project_slug", project_slug)

    assert {:ok, pipeline} =
             SymphonyElixir.Pipeline.parse(%{
               "id" => id,
               "tracker" => tracker
             })

    pipeline
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
