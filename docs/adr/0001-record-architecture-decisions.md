# ADR-0001: Record architecture decisions

- Status: Accepted
- Date: 2026-10-25

## Context

The platform will evolve across many phases and technologies. Without a durable record, the reasoning behind choices is lost, and later contributors cannot tell whether a constraint is deliberate or accidental.

## Decision

We record architecturally significant decisions as Architecture Decision Records (ADRs), following the format described by Michael Nygard. Records live in `docs/adr`, are numbered sequentially, use the shared template, and are reviewed through pull requests. Accepted records are not edited except for status changes; a reversal is a new ADR that supersedes the earlier one.

## Consequences

- Decisions and their trade-offs are discoverable and reviewable alongside the code.
- Contributors take on a small documentation cost for significant changes.
- The history of why the platform looks the way it does is preserved.

## Alternatives considered

- Wiki pages: drift from the code and lack review history.
- No formal record: cheapest now, costly when context is lost.
