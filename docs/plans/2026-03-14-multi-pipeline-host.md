# Multi-Pipeline Host Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor Symphony Elixir from a single-project Linear runner into a lightweight multi-pipeline host that can manage multiple repositories/projects concurrently and be operated equally well by humans and agents.

**Architecture:** Introduce a first-class `Pipeline` runtime model and load pipelines from a filesystem directory instead of a single global `WORKFLOW.md`. Run one orchestrator per pipeline under a shared supervisor, while keeping each pipeline operationally isolated across config, workspace paths, prompts, logs, and status surfaces. Preserve a compatibility path for the current single-workflow mode so the refactor can land incrementally.

**Tech Stack:** Elixir/OTP, Ecto embedded schemas, Phoenix LiveView/JSON API, Linear GraphQL, ExUnit.

---

### Task 1: Define the pipeline runtime model and compatibility contract

**Files:**
- Create: `elixir/lib/symphony_elixir/pipeline.ex`
- Create: `elixir/lib/symphony_elixir/pipeline_store.ex`
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`

**Step 1: Write the failing tests**

Add coverage in `elixir/test/symphony_elixir/core_test.exs` for:
- parsing a pipeline config with `id`, `enabled`, `tracker`, `workspace`, `agent`, `codex`, `hooks`
- validating that a pipeline has its own tracker target instead of relying on one global `project_slug`
- preserving compatibility when only the legacy root `WORKFLOW.md` exists

Example test shape:

```elixir
test "pipeline config validates per-pipeline tracker targets" do
  assert {:ok, pipeline} = SymphonyElixir.Pipeline.parse(%{
           "id" => "workcow",
           "enabled" => true,
           "tracker" => %{"kind" => "linear", "project_slug" => "workcow-project"}
         })

  assert pipeline.id == "workcow"
  assert pipeline.tracker.project_slug == "workcow-project"
end
```

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/core_test.exs`
Expected: FAIL with undefined `Pipeline` module and missing multi-pipeline validation paths.

**Step 3: Implement the minimal runtime model**

Create a dedicated `SymphonyElixir.Pipeline` struct/schema that contains:
- `id`
- `enabled`
- `source_path`
- `workflow_path`
- `prompt_template`
- embedded runtime settings for tracker/workspace/agent/codex/hooks/server-ish overrides

Keep `SymphonyElixir.Config` as a compatibility layer, but stop treating it as the sole source of truth for runtime execution.

**Step 4: Implement compatibility rules**

Implement a compatibility adapter so the current single `WORKFLOW.md` still loads as a synthetic default pipeline, for example:

```elixir
%Pipeline{
  id: "default",
  source_path: workflow_path,
  workflow_path: workflow_path,
  ...
}
```

**Step 5: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/core_test.exs`
Expected: PASS for the new config/runtime assertions.

**Step 6: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/pipeline.ex \
  elixir/lib/symphony_elixir/pipeline_store.ex \
  elixir/lib/symphony_elixir/config/schema.ex \
  elixir/lib/symphony_elixir/config.ex \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: introduce pipeline runtime model"
```

### Task 2: Replace the single workflow file with a pipeline directory loader

**Files:**
- Create: `elixir/lib/symphony_elixir/pipeline_loader.ex`
- Modify: `elixir/lib/symphony_elixir/workflow.ex`
- Modify: `elixir/lib/symphony_elixir/cli.ex`
- Modify: `elixir/README.md`
- Test: `elixir/test/symphony_elixir/cli_test.exs`
- Test: `elixir/test/symphony_elixir/core_test.exs`

**Step 1: Write the failing tests**

Add coverage for:
- defaulting to `pipelines/` when present
- continuing to accept explicit legacy `WORKFLOW.md`
- validating every enabled pipeline before boot
- surfacing a useful startup error when one pipeline is invalid

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/cli_test.exs test/symphony_elixir/core_test.exs`
Expected: FAIL because the CLI and loader still assume a single workflow file.

**Step 3: Implement the loader**

Support this lightweight layout:

```text
pipelines/
  workcow/
    pipeline.yaml
    WORKFLOW.md
  repo-b/
    pipeline.yaml
    WORKFLOW.md
```

Rules:
- `pipeline.yaml` contains structured settings
- `WORKFLOW.md` contains the prompt template
- disabled pipelines load but do not start
- legacy single-file mode still works

**Step 4: Update CLI semantics**

Make CLI accept either:
- a workflow file path
- a pipeline root directory path
- no explicit path, in which case it auto-detects `pipelines/` first, then falls back to `WORKFLOW.md`

**Step 5: Update docs**

Revise `elixir/README.md` so the primary documented setup is directory-based multi-pipeline hosting, with legacy single-workflow mode described as compatibility mode.

**Step 6: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/cli_test.exs test/symphony_elixir/core_test.exs`
Expected: PASS.

**Step 7: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/pipeline_loader.ex \
  elixir/lib/symphony_elixir/workflow.ex \
  elixir/lib/symphony_elixir/cli.ex \
  elixir/README.md \
  elixir/test/symphony_elixir/cli_test.exs \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: load pipelines from filesystem directories"
```

### Task 3: Make the Linear tracker and runtime APIs pipeline-aware

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`
- Modify: `elixir/lib/symphony_elixir/linear/issue.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

**Step 1: Write the failing tests**

Add coverage for:
- fetching candidate issues for a specific pipeline
- ensuring two pipelines with different `project_slug` values do not leak issue selection into each other
- carrying pipeline metadata into the normalized issue record where useful for observability

Example shape:

```elixir
assert {:ok, issues} = Tracker.fetch_candidate_issues(pipeline)
assert Enum.all?(issues, &(&1.pipeline_id == pipeline.id))
```

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs`
Expected: FAIL because tracker reads still come from global config.

**Step 3: Refactor tracker APIs**

Change tracker-facing functions from implicit global config:

```elixir
Tracker.fetch_candidate_issues()
```

to explicit pipeline scope:

```elixir
Tracker.fetch_candidate_issues(pipeline)
Tracker.fetch_issue_states_by_ids(pipeline, issue_ids)
Tracker.update_issue_state(pipeline, issue_id, state_name)
```

Keep temporary wrapper functions only if needed for incremental migration.

**Step 4: Refactor Linear queries**

Pass `pipeline.tracker.project_slug` and related filters directly into `Linear.Client`, removing dependence on `Config.settings!().tracker`.

**Step 5: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs`
Expected: PASS.

**Step 6: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/tracker.ex \
  elixir/lib/symphony_elixir/linear/adapter.ex \
  elixir/lib/symphony_elixir/linear/client.ex \
  elixir/lib/symphony_elixir/linear/issue.ex \
  elixir/test/symphony_elixir/core_test.exs \
  elixir/test/symphony_elixir/extensions_test.exs
git commit -m "refactor: scope linear tracker calls by pipeline"
```

### Task 4: Isolate workspaces, hooks, and prompts by pipeline

**Files:**
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Test: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

**Step 1: Write the failing tests**

Add coverage for:
- workspace paths being namespaced as `<workspace_root>/<pipeline_id>/<issue_identifier>`
- hooks resolving from the pipeline instead of global config
- prompt building using the pipeline-specific prompt template

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/workspace_and_config_test.exs`
Expected: FAIL because workspace and hook resolution are still global.

**Step 3: Implement workspace namespacing**

Refactor `Workspace.create_for_issue/1` into pipeline-aware APIs, for example:

```elixir
Workspace.create_for_issue(pipeline, issue)
Workspace.remove_issue_workspaces(pipeline, identifier)
```

Do not reuse the current flat directory layout across multiple pipelines.

**Step 4: Refactor prompt and runner path**

Pass the pipeline all the way through `AgentRunner.run/3` and `PromptBuilder.build_prompt/2`, so the agent session no longer depends on global config reads for prompt/hook/workspace behavior.

**Step 5: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/workspace_and_config_test.exs`
Expected: PASS.

**Step 6: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/workspace.ex \
  elixir/lib/symphony_elixir/prompt_builder.ex \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/test/symphony_elixir/workspace_and_config_test.exs
git commit -m "refactor: isolate pipeline workspaces and prompts"
```

### Task 5: Run one orchestrator per pipeline under supervision

**Files:**
- Create: `elixir/lib/symphony_elixir/pipeline_supervisor.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Test: `elixir/test/symphony_elixir/core_test.exs`

**Step 1: Write the failing tests**

Add coverage for:
- starting one orchestrator per enabled pipeline
- keeping pipeline runtime state isolated
- restarting one failed pipeline orchestrator without affecting others

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs`
Expected: FAIL because there is only one global orchestrator process and one global snapshot.

**Step 3: Implement per-pipeline orchestration**

Refactor `SymphonyElixir.Orchestrator` to hold `pipeline_id` and `pipeline` in state, then add a `PipelineSupervisor` that starts children like:

```elixir
{SymphonyElixir.Orchestrator, name: via_tuple(pipeline.id), pipeline: pipeline}
```

**Step 4: Preserve compatibility**

When booting legacy mode, start a single orchestrator for the synthetic `default` pipeline.

**Step 5: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs`
Expected: PASS.

**Step 6: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/pipeline_supervisor.ex \
  elixir/lib/symphony_elixir/orchestrator.ex \
  elixir/lib/symphony_elixir.ex \
  elixir/test/symphony_elixir/orchestrator_status_test.exs \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: supervise one orchestrator per pipeline"
```

### Task 6: Expose agent-friendly pipeline control surfaces

**Files:**
- Modify: `elixir/lib/symphony_elixir/http_server.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`
- Modify: `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Test: `elixir/test/symphony_elixir/extensions_test.exs`

**Step 1: Write the failing tests**

Add API coverage for:
- `GET /api/v1/pipelines`
- `GET /api/v1/pipelines/:id`
- `POST /api/v1/pipelines/:id/refresh`
- `POST /api/v1/pipelines/:id/pause`
- `POST /api/v1/pipelines/:id/resume`

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: FAIL because the JSON API is still single-runtime oriented.

**Step 3: Implement thin control endpoints**

Expose minimal machine-friendly JSON, for example:

```json
{"id":"workcow","enabled":true,"running_agents":2,"paused":false}
```

Do not build a rich control plane or persistence layer in this step.

**Step 4: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/extensions_test.exs`
Expected: PASS.

**Step 5: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/http_server.ex \
  elixir/lib/symphony_elixir_web/router.ex \
  elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex \
  elixir/lib/symphony_elixir_web/presenter.ex \
  elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat: add pipeline control api"
```

### Task 7: Update the dashboard and status rendering for multiple pipelines

**Files:**
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Test: `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`

**Step 1: Write the failing tests**

Add snapshot coverage for:
- showing a pipeline list instead of one global project link
- drilling into per-pipeline runtime state
- displaying per-pipeline project URLs, concurrency, and next refresh time

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`
Expected: FAIL because the dashboard currently renders one `project_slug`.

**Step 3: Implement the minimal UI change**

Render:
- a pipeline summary section
- per-pipeline running/backoff sections
- per-pipeline project links

Avoid building a new navigation system unless the current LiveView becomes unworkable.

**Step 4: Re-run the targeted tests**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`
Expected: PASS.

**Step 5: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/status_dashboard.ex \
  elixir/lib/symphony_elixir_web/live/dashboard_live.ex \
  elixir/lib/symphony_elixir_web/presenter.ex \
  elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs
git commit -m "feat: render multi-pipeline status"
```

### Task 8: Add pipeline scaffolding and end-to-end verification

**Files:**
- Create: `elixir/lib/mix/tasks/pipeline.scaffold.ex`
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`
- Modify: `elixir/README.md`
- Modify: `README.md`

**Step 1: Write the failing tests**

Add coverage for:
- scaffolding a new pipeline directory with `pipeline.yaml` and `WORKFLOW.md`
- booting two disposable pipelines in test mode
- proving one pipeline can complete work without affecting the other

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/live_e2e_test.exs`
Expected: FAIL because there is no scaffolding task or multi-pipeline e2e path.

**Step 3: Implement scaffolding**

Create a mix task like:

```bash
mix pipeline.scaffold workcow --project-slug workcow-3ded0ff156f2 --repo https://github.com/eddiearc/workcow
```

The task should generate:
- `pipelines/workcow/pipeline.yaml`
- `pipelines/workcow/WORKFLOW.md`

This is the lightest operator interface for both humans and agents.

**Step 4: Update docs**

Document:
- how to add a new pipeline
- how to pause/resume/reload one pipeline
- how agents should operate the host through file edits plus JSON API/CLI

**Step 5: Re-run targeted and full validation**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/live_e2e_test.exs`
Expected: PASS.

Run: `cd /Users/eddiearc/repo/symphony/elixir && make all`
Expected: PASS for format, lint, coverage, and dialyzer gates.

**Step 6: Commit**

```bash
git add \
  elixir/lib/mix/tasks/pipeline.scaffold.ex \
  elixir/test/symphony_elixir/live_e2e_test.exs \
  elixir/README.md \
  README.md
git commit -m "feat: scaffold and verify multi-pipeline hosting"
```

### Task 9: Remove leftover global-config shortcuts and document invariants

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/lib/symphony_elixir/workflow_store.ex`
- Modify: `elixir/lib/symphony_elixir/specs_check.ex`
- Modify: `SPEC.md`
- Test: `elixir/test/symphony_elixir/core_test.exs`

**Step 1: Write the failing tests**

Add coverage that proves:
- execution paths do not rely on one global `Config.settings!()` singleton for pipeline-specific operations
- workflow reloads affect only the intended pipeline
- spec/documentation reflects directory-based multi-pipeline hosting

**Step 2: Run the targeted tests to confirm failure**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/core_test.exs`
Expected: FAIL while legacy shortcuts remain in active runtime paths.

**Step 3: Remove or quarantine global shortcuts**

Limit global config helpers to:
- CLI/bootstrap compatibility
- legacy single-workflow mode

Do not let active orchestration, workspace, tracker, or prompt rendering depend on implicit globals.

**Step 4: Update the spec**

Revise `SPEC.md` so it describes:
- pipeline directory loading
- one orchestrator per pipeline
- isolated workspaces/logs/prompts per pipeline
- lightweight operator and agent control surfaces

**Step 5: Re-run targeted and full validation**

Run: `cd /Users/eddiearc/repo/symphony/elixir && mix test test/symphony_elixir/core_test.exs`
Expected: PASS.

Run: `cd /Users/eddiearc/repo/symphony/elixir && make all`
Expected: PASS.

**Step 6: Commit**

```bash
git add \
  elixir/lib/symphony_elixir/config.ex \
  elixir/lib/symphony_elixir/workflow_store.ex \
  elixir/lib/symphony_elixir/specs_check.ex \
  SPEC.md \
  elixir/test/symphony_elixir/core_test.exs
git commit -m "refactor: finalize multi-pipeline runtime invariants"
```
