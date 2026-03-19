# Symphonyctl

`symphonyctl` is a repo-local CLI helper for `symphony/elixir`. It handles four common tasks:

- Start Symphony on a local port and skip duplicate launches.
- Scaffold a new pipeline with `mix pipeline.scaffold`.
- Create a Linear issue for a new requirement.
- Poll a Linear issue until it reaches a terminal state, with optional Telegram reminders.

## Layout

```text
skills/symphonyctl/
  SKILL.md
  README.md
  config.example.yaml
  syctl
  lib/symphonyctl/
    cli.ex
    config.ex
    issue.ex
    monitor.ex
    notifier.ex
    pipeline.ex
    start.ex
```

## Usage

Start Symphony on the default port:

```bash
./skills/symphonyctl/syctl start
```

Start on a different port:

```bash
./skills/symphonyctl/syctl start --port 4100
```

Create a pipeline:

```bash
./skills/symphonyctl/syctl pipeline create delivery \
  --project-slug delivery \
  --repo /absolute/path/to/source-repo \
  --workspace-root /absolute/path/to/workspaces
```

Create a Linear issue:

```bash
./skills/symphonyctl/syctl issue create \
  --title "Implement orchestration skill" \
  --description "Need a CLI wrapper around Symphony workflow setup."
```

Monitor an issue:

```bash
./skills/symphonyctl/syctl monitor --issue-id DEL-123
```

## Configuration

The CLI reads `~/.symphonyctl/config.yaml` by default. You can also pass `--config /path/to/config.yaml`.

See [`config.example.yaml`](/Users/arc/.openclaw/workspace/symphony/elixir/skills/symphonyctl/config.example.yaml) for the supported fields.

Key settings:

- `project_root`: Symphony Elixir repo root
- `pipelines_root`: root passed to `mix pipeline.scaffold` and `start`
- `workspace_root`: default workspace path for new pipelines
- `port`: dashboard port used by `start`
- `start.command`: defaults to `make run`
- `linear.project_slug`: default project slug for issue creation
- `linear.api_token_env`: env var name for the Linear API key
- `notify.telegram.*`: Telegram reminder settings

## Implementation Notes

- `start` launches Symphony in the background via `nohup ... &` and writes stdout/stderr to the configured log file.
- `pipeline create` shells out to `mix pipeline.scaffold` inside the repo root.
- `issue create` resolves the Linear project by slug, grabs its first team, and then runs `issueCreate`.
- `monitor` polls Linear until the issue enters a configured terminal state.
