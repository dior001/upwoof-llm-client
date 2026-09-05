# Architecture Decision Records

Durable record of decisions that shape this codebase — the **History** role in
[`../README.md`](../README.md). An ADR answers "why is it like this?" for someone who arrives
in six months and is tempted to undo it.

## When to write one

Write an ADR when a choice is **costly to reverse and non-obvious**: a datastore, a framework,
a boundary between services, a security posture, an approach deliberately rejected. Also when
something is **removed on purpose** — undocumented removals get recreated.

Do not write one for routine work. A commit message covers "fixed the N+1 query"; an ADR
covers "we accept N+1 here because the alternative breaks tenant isolation."

## How

1. Copy [`template.md`](template.md) to `NNNN-short-title.md`, `NNNN` being the next number.
2. Fill it in — the **Consequences** section is the part future readers need most.
3. Add a row to the index below.
4. Never rewrite an accepted ADR. Supersede it with a new one and mark the old one
   `superseded by ADR-NNNN`; the wrong turn is part of the record.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| _none yet_ | | | |
