# docs/

Where this repo's documentation lives and what each file is responsible for.

Four roles, **one canonical owner each**: a fact belongs to exactly one of them and the
others link to it rather than repeating it. This layout matches the fleet standard in
`upwoof-tohora-server-tools/docs/fleet-conventions.md`.

| Role | Owns | Here |
|---|---|---|
| **Constitution** | rules agents and contributors must follow | [`../CLAUDE.md`](../CLAUDE.md) |
| **Map** | what exists and where it lives | [`../README.md`](../README.md), this file |
| **Status** | current health, blockers, the live work queue | _no owner yet_ |
| **History** | durable decisions and why they were made | [`adr/`](adr/) |

## Adding to this directory

- **A decision that shapes the code** → an ADR in [`adr/`](adr/). Not a commit message:
  record it when someone would otherwise ask "why is it like this?" in six months.
- **A diagram** → [`diagrams/`](diagrams/), as mermaid inside a `.md` file so it stays
  diffable and renders on GitHub.
- **Anything an agent must obey** → `../CLAUDE.md`, which `../AGENTS.md` symlinks to so
  every tool reads the same instructions.

Prefer extending a document that already owns the role over adding a new top-level file.
