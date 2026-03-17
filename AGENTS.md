# Symphony

This file defines repository-level guidance for work in this repo.

More specific rules may exist in subdirectories and should take precedence for files under that
subtree.

Current subdirectory-specific guidance:

- [`elixir/AGENTS.md`](./elixir/AGENTS.md) for the Elixir reference implementation, dashboard, and tests

## Repository Layout

- [`README.md`](./README.md) explains the project at the repo level
- [`SPEC.md`](./SPEC.md) is the product and behavior spec for Symphony
- [`docs/`](./docs) holds repo-level plans and supporting documents
- [`elixir/`](./elixir) contains the current reference implementation

## Working Rules

- Keep repository-level changes aligned with [`SPEC.md`](./SPEC.md) unless the change is explicitly
  intended to evolve the spec.
- Prefer narrowly scoped changes; avoid mixing repo-level docs edits with unrelated implementation work.
- When changing behavior, update the nearest relevant documentation in the same change when practical.
- Do not assume repo-level instructions automatically cover implementation details inside subprojects;
  check for a closer `AGENTS.md` first.

## Docs Guidance

Update the appropriate layer of documentation for the change:

- [`README.md`](./README.md) for project-level positioning and entry points
- [`SPEC.md`](./SPEC.md) for intended product behavior and contract
- [`docs/`](./docs) for repo-level plans and process notes
- [`elixir/README.md`](./elixir/README.md) and [`elixir/docs/`](./elixir/docs) for Elixir runtime details

## Validation

- Validate at the layer you changed.
- For work under [`elixir/`](./elixir), follow [`elixir/AGENTS.md`](./elixir/AGENTS.md) for the required checks.
