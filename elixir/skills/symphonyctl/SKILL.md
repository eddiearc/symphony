---
name: symphonyctl
description: Use when working in Symphony Elixir and you need to start the local service, scaffold a new pipeline, create a Linear issue for a requirement, or monitor a Linear issue until completion with notifications.
---

# Symphonyctl

## Overview
`symphonyctl` is a repo-local CLI helper for the Symphony Elixir project. It wraps the standard `make run` / `mix pipeline.scaffold` workflow, adds lightweight Linear issue creation, and can monitor issue status changes until completion.

## Working Directory
`symphonyctl` runs from the elixir subdirectory of the symphony repo:
```bash
cd ~/repo/symphony/elixir
./skills/symphonyctl/syctl <command>
```

## Commands

### start — Launch Symphony service
```bash
cd ~/repo/symphony/elixir
./skills/symphonyctl/syctl start
```
- Checks if port 4000 is already in use before launching
- Reads `~/.zshrc` / `~/.zprofile` for `LINEAR_API_KEY` and injects it into the subprocess environment
- Pipelines with `enabled: true` in their `pipeline.yaml` are loaded on startup
- If a pipeline fails to load (e.g. missing Linear token), the service fails to start

### pipeline create — Scaffold a new pipeline
```bash
cd ~/repo/symphony/elixir
./skills/symphonyctl/syctl pipeline create <id> \
  --project-slug <slug> \
  --repo <repo-path> \
  --workspace-root <workspace-root>
```
- Creates `pipelines/<id>/pipeline.yaml` and `pipelines/<id>/WORKFLOW.md` from the pipeline scaffold template
- Run with `--help` to see full usage

### issue create — Create a Linear issue
```bash
cd ~/repo/symphony/elixir
./skills/symphonyctl/syctl issue create \
  --title "Issue title" \
  [--description "Description"] \
  [--project-slug <slug>] \
  [--team-id <team-id>]
```

### monitor — Poll until issue is done
```bash
cd ~/repo/symphony/elixir
./skills/symphonyctl/syctl monitor --issue-id ISSUE-123 [--poll-interval-ms 15000]
```

## Configuration
- Default config path: `~/.symphonyctl/config.yaml`
- Example template: `./skills/symphonyctl/config.example.yaml`
- Defaults:
  - port `4000`
  - start command `make run`
  - pipelines root `<repo>/pipelines`
  - workspace root `<repo>/workspaces`
  - Linear endpoint `https://api.linear.app/graphql`

## Notifications
- Always prints a local status message to stdout
- Optionally sends Telegram notifications when `notify.telegram.enabled` is true and bot/chat credentials are configured

## Notes
- `start` checks whether the target port is already in use before launching
- `pipeline create` requires `project-slug`, `repo`, and `workspace-root`
- `monitor` keeps polling until the issue reaches a terminal state such as `Done` or `Closed`
- `start` auto-injects `LINEAR_API_KEY` from `~/.zshrc` / `~/.zprofile` into the subprocess — ensure `LINEAR_API_KEY` is exported in your shell config, otherwise pipelines will fail to load with `:missing_linear_api_token`
