defmodule Symphonyctl.WorkflowTest do
  use ExUnit.Case, async: true

  alias Symphonyctl.{Issue, Monitor, Pipeline, Start}

  test "start skips launch when target port is already listening" do
    config = %{
      project_root: "/repo/symphony/elixir",
      pipelines_root: "/repo/symphony/elixir/pipelines",
      port: 4000,
      start: %{command: "make run", log_path: "/tmp/symphonyctl.log"},
      notify: %{telegram: %{enabled: false}}
    }

    deps = %{
      port_open?: fn 4000 -> true end,
      spawn_command: fn _cmd, _opts -> flunk("should not spawn process") end,
      notify: fn level, message -> send(self(), {:notify, level, message}) end
    }

    assert {:ok, :already_running} = Start.run(config, deps)
    assert_received {:notify, :info, message}
    assert message =~ "4000"
  end

  test "start launches symphony with configured command when port is free" do
    config = %{
      project_root: "/repo/symphony/elixir",
      pipelines_root: "/repo/symphony/elixir/pipelines",
      port: 4100,
      start: %{command: "make run", log_path: "/tmp/symphonyctl.log"},
      notify: %{telegram: %{enabled: false}}
    }

    deps = %{
      port_open?: fn 4100 -> false end,
      spawn_command: fn cmd, opts ->
        send(self(), {:spawned, cmd, opts})
        {:ok, 12_345}
      end,
      notify: fn level, message -> send(self(), {:notify, level, message}) end
    }

    assert {:ok, :started} = Start.run(config, deps)

    assert_received {:spawned, command, opts}
    assert command =~ "make run"
    assert command =~ "PORT=4100"
    assert command =~ "PIPELINE_ROOT="
    assert command =~ "/repo/symphony/elixir/pipelines"
    assert opts[:cd] == "/repo/symphony/elixir"
    assert opts[:log_path] == "/tmp/symphonyctl.log"
    assert_received {:notify, :info, message}
    assert message =~ "12345"
  end

  test "pipeline create shells out to mix pipeline.scaffold with required args" do
    config = %{
      project_root: "/repo/symphony/elixir",
      pipelines_root: "/repo/symphony/elixir/pipelines",
      workspace_root: "/repo/symphony/workspaces"
    }

    deps = %{
      run_command: fn cmd, argv, opts ->
        send(self(), {:ran, cmd, argv, opts})
        {:ok, "ok"}
      end
    }

    params = %{
      id: "delivery",
      project_slug: "delivery-slug",
      repo: "/repo/source",
      workspace_root: "/repo/workspaces"
    }

    assert {:ok, "ok"} = Pipeline.create(params, config, deps)

    assert_received {:ran, "mix", argv, opts}

    assert argv == [
             "pipeline.scaffold",
             "delivery",
             "--pipelines-root",
             "/repo/symphony/elixir/pipelines",
             "--project-slug",
             "delivery-slug",
             "--repo",
             "/repo/source",
             "--workspace-root",
             "/repo/workspaces"
           ]

    assert opts[:cd] == "/repo/symphony/elixir"
  end

  test "issue create resolves project by slug and creates a Linear issue" do
    config = %{
      linear: %{
        api_url: "https://api.linear.app/graphql",
        api_token: "linear-token",
        project_slug: "delivery"
      }
    }

    project_response = %{
      "data" => %{
        "projects" => %{
          "nodes" => [
            %{"id" => "project-1", "slugId" => "delivery", "teams" => %{"nodes" => [%{"id" => "team-9"}]}}
          ]
        }
      }
    }

    issue_response = %{
      "data" => %{
        "issueCreate" => %{
          "success" => true,
          "issue" => %{
            "id" => "issue-id",
            "identifier" => "DEL-123",
            "title" => "Implement orchestration skill",
            "url" => "https://linear.app/example/issue/DEL-123"
          }
        }
      }
    }

    parent = self()

    deps = %{
      graphql: fn query, variables, cfg ->
        send(parent, {:graphql, query, variables, cfg})

        cond do
          String.contains?(query, "projects(") -> {:ok, project_response}
          String.contains?(query, "issueCreate(") -> {:ok, issue_response}
          true -> flunk("unexpected query: #{query}")
        end
      end
    }

    attrs = %{title: "Implement orchestration skill", description: "Need a CLI wrapper"}

    assert {:ok, issue} = Issue.create(attrs, config, deps)
    assert issue.identifier == "DEL-123"
    assert issue.id == "issue-id"

    assert_received {:graphql, project_query, project_vars, _cfg}
    assert project_query =~ "projects"
    assert project_vars == %{slug: "delivery"}

    assert_received {:graphql, mutation, mutation_vars, _cfg}
    assert mutation =~ "issueCreate"
    assert mutation_vars.projectId == "project-1"
    assert mutation_vars.teamId == "team-9"
    assert mutation_vars.title == "Implement orchestration skill"
  end

  test "monitor polls until terminal state and sends completion reminder" do
    config = %{
      monitor: %{poll_interval_ms: 25, terminal_states: ["Done", "Closed"]},
      notify: %{telegram: %{enabled: false}}
    }

    {:ok, agent} =
      Agent.start_link(fn ->
        [
          {:ok, %{identifier: "DEL-123", state: "In Progress", url: "https://linear/DEL-123"}},
          {:ok, %{identifier: "DEL-123", state: "Done", url: "https://linear/DEL-123"}}
        ]
      end)

    deps = %{
      fetch_issue: fn "DEL-123", _config ->
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {{:ok, %{identifier: "DEL-123", state: "Done", url: "https://linear/DEL-123"}}, []}
        end)
      end,
      sleep: fn interval ->
        send(self(), {:slept, interval})
        :ok
      end,
      notify: fn level, message -> send(self(), {:notify, level, message}) end
    }

    assert {:ok, issue} = Monitor.run("DEL-123", config, deps)
    assert issue.state == "Done"
    assert_received {:slept, 25}
    assert_received {:notify, :info, message}
    assert message =~ "DEL-123"
    assert message =~ "Done"
  end
end
