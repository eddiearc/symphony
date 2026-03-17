# Dashboard End-to-End Testing

This document captures practical lessons from debugging and validating Symphony's dashboard config flows, especially browser-driven regressions such as `thread sandbox`.

## Scope

Use this guide when validating:

- dashboard-only interactions under `/panel/config`
- structured form state synchronization
- save/reload flows that write `pipeline.yaml` and `WORKFLOW.md`
- browser-visible regressions where LiveView unit tests are not enough

## Isolation Requirements

Dashboard E2E runs must be isolated from the operator's real Symphony setup.

Required isolation conditions:

- use a temporary `PIPELINE_ROOT`
- use a temporary port
- keep all pipeline fixtures under a temporary directory
- delete the temporary directory after the run
- stop the temporary Symphony instance after the run

Never point browser-driven tests at the default home directory pipeline root:

- do not use `~/.symphony/pipelines`
- do not mutate the operator's real pipeline files during validation

## Recommended Launch Pattern

Create a temporary test root:

```bash
TEST_ROOT="$(mktemp -d /tmp/symphony-dashboard-e2e.XXXXXX)"
PIPELINES_ROOT="$TEST_ROOT/pipelines"
PIPELINE_DIR="$PIPELINES_ROOT/default"
PORT="4101"
mkdir -p "$PIPELINE_DIR"
```

Seed the temporary pipeline with minimal fixture files:

- `pipeline.yaml`
- `WORKFLOW.md`

Start Symphony against the isolated pipeline root:

```bash
make run PIPELINE_ROOT="$PIPELINES_ROOT" PORT="$PORT"
```

For the permanent Playwright harness in this repo, use:

```bash
make e2e-dashboard-setup
make e2e-dashboard
```

Use a second shell or a browser driver to hit:

```text
http://127.0.0.1:$PORT/panel/config
```

When finished:

```bash
rm -rf "$TEST_ROOT"
```

## Validation Strategy

Prefer a layered approach:

1. LiveView integration tests for form state and save semantics.
2. Browser E2E for real DOM behavior, event wiring, and modal/save flows.

LiveView tests are fast and should lock the server-side contract.
Browser E2E should lock the user-visible path.

## Recommended Workflow

Use the browser tools in two stages instead of treating them as substitutes for each other.

1. Use `agent-browser` first to explore the path.
2. Once the path is stable, translate it into a Playwright spec.
3. Keep the long-term regression in Playwright, not in ad hoc browser-driving notes.

In practice:

- use `agent-browser` to confirm the real click path, visible labels, modal sequence, and any surprising LiveView timing
- use those findings to choose stable selectors and assertions
- then codify the path in Playwright with isolated startup and file-system assertions
- keep the supporting LiveView tests for server-side state semantics

## Tool Choice

### Playwright

Preferred for repo-owned, repeatable E2E coverage.

Why:

- mature browser automation
- stable selectors and assertions
- easy screenshot and trace capture
- good fit for CI and local reruns
- better long-term maintainability than ad hoc browser driving

Use Playwright when:

- the flow should become a permanent regression test
- the interaction spans multiple DOM updates
- you need reliable assertions on checked state, modal transitions, and saved file content

### agent-browser

Useful for ad hoc local debugging and one-off reproduction.

Use `agent-browser` when:

- triaging a regression quickly
- confirming a fix before investing in permanent test code
- inspecting live DOM state during debugging

Typical role split:

- `agent-browser` explores and de-risks the path
- Playwright preserves the path as a permanent regression

Do not treat `agent-browser` as the final long-term E2E harness for this repo unless there is a specific reason.

## Proven Regression Cases

These cases have already produced real bugs and should be kept as a quick regression checklist.

### Thread Sandbox Default State

Given a pipeline config with no explicit `codex.thread_sandbox`:

- open `/panel/config`
- switch to the `Codex` tab
- assert `Workspace Write` is selected in the structured form

Expected result:

- the UI treats omitted config as the effective default
- the control must not look like an unselected or broken field

### Thread Sandbox Escalation

Starting from the default/omitted state:

- select `Danger Full Access`
- save through the review modal
- verify the saved `pipeline.yaml`

Expected result:

- `thread_sandbox: "danger-full-access"`
- `turn_sandbox_policy.type: "dangerFullAccess"`

### Thread Sandbox De-escalation

Starting from `danger-full-access`:

- switch back to `Workspace Write`
- save through the review modal
- verify the saved `pipeline.yaml`

Expected result:

- `thread_sandbox: "workspace-write"` or the chosen canonical persisted form
- no stale `dangerFullAccess` turn policy remains

If the product intentionally persists the default as omission instead of `"workspace-write"`, the test should assert that exact canonical form and the UI must still render `Workspace Write` as selected on reload.

### YAML/Structured Consistency

For each state transition above:

- switch from structured view to YAML view before saving, or after selection
- confirm the editor body reflects the selected sandbox state

Expected result:

- structured controls and YAML body stay in sync
- save modal change summary reflects the same transition

## Implementation Notes

When adding permanent dashboard browser E2E tests:

- keep fixture creation local to the test
- assert both UI state and file-system state
- use explicit selectors for the `Codex` tab, sandbox controls, save button, and modal confirm button
- verify reload behavior after save, not just pre-save in-memory state
- keep the test focused on one user path per case

## Suggested Permanent E2E Coverage

If this repo gains Playwright coverage, start with:

- `config-thread-sandbox-default.spec`
- `config-thread-sandbox-danger.spec`
- `config-thread-sandbox-workspace-write-roundtrip.spec`

Current repo location:

- `test/e2e_playwright/specs/config-thread-sandbox.spec.js`

Each test should:

- create an isolated pipeline root
- start Symphony on an isolated port
- drive the dashboard in a real browser
- assert saved file contents
- shut down and clean up
