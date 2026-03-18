---
name: symphonyctl
description: Use when working in Symphony Elixir and you need to start the local service, scaffold a new pipeline, create a Linear issue for a requirement, or monitor a Linear issue until completion with notifications.
---

# Symphonyctl

## Overview
`symphonyctl` is a repo-local CLI helper for the Symphony Elixir project. It wraps the standard `make run` / `mix pipeline.scaffold` workflow, adds lightweight Linear issue creation, and can monitor issue status changes until completion.

## Commands
- `./skills/symphonyctl/syctl start`
- `./skills/symphonyctl/syctl pipeline create <id> --project-slug <slug> --repo <path> --workspace-root <path>`
- `./skills/symphonyctl/syctl issue create --title <title> [--description <text>] [--project-slug <slug>]`
- `./skills/symphonyctl/syctl monitor --issue-id <identifier>`

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
- `start` checks whether the target port is already in use before launching Symphony
- `pipeline create` requires `project-slug`, `repo`, and `workspace-root`
- `monitor` keeps polling until the issue reaches a terminal state such as `Done` or `Closed`
