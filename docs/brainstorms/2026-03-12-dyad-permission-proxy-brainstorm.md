# Brainstorm: Dyad - Claude Code Permission Proxy

**Date:** 2026-03-12
**Status:** Draft

## What We're Building

A shell-based wrapper tool ("dyad") that runs two Claude Code instances as a pair:

1. **Worker** — the Claude Code instance executing the user's original task
2. **Supervisor** — a second Claude Code instance that intercepts and judges the worker's permission prompts

The supervisor uses a two-layer approval strategy:
- **Layer 1: Rule-based filtering** — configurable rules that auto-approve or auto-deny known patterns (e.g., allow file edits in the project directory, block network requests)
- **Layer 2: AI-judged approval** — when rules don't cover a prompt, the supervisor Claude Code instance reasons about whether to approve
- **Escape hatch: Approve-all mode** — an optional flag to blindly accept everything (like a smarter `--dangerously-skip-permissions`)

When the supervisor denies an operation, it prints a visible warning in the terminal so the user can intervene manually.

## Why This Approach

The current options for uninterrupted Claude Code sessions are unsatisfying:
- **Manually accepting prompts** interrupts flow and requires babysitting
- **`--dangerously-skip-permissions`** removes all safety guardrails
- **Allowlist settings** require knowing every command pattern in advance

Dyad provides a middle ground: autonomous operation with intelligent oversight. The "dyad" (pair) model keeps a human-compatible safety layer while removing the human bottleneck.

## Key Decisions

1. **Personal tool** — built for the author's own workflow, not a distributable product
2. **Shell script implementation** — minimal dependencies, uses `expect`-style CLI wrapping
3. **Supervisor is a full Claude Code CLI instance** — not a lightweight API call; gives the supervisor access to full reasoning and tool capabilities
4. **Approach: `expect`-style wrapper** — the script spawns the worker Claude Code, watches stdout for permission prompt patterns, and routes them through the rule engine and supervisor
5. **Denial flow: deny + terminal warning** — denied operations send 'no' back to the worker and print a visible warning in the dyad terminal
6. **Rule config: JSON/YAML** — structured config file with sections for file access patterns, command allowlists, network controls
7. **Audit logging** — log all decisions (approvals and denials) with timestamp, prompt text, decision, and reason
8. **Progressive supervisor context** — v1 sends only the permission prompt text + original task description to the supervisor. Full session history is a future enhancement if the supervisor makes poor decisions without it.
9. **Prototype-first** — the first step is prototyping `expect`-based capture of Claude Code's permission prompts to validate the approach before building anything else

## Architecture Sketch

```
User runs: dyad "implement feature X"
                |
                v
    +------------------------+
    |   dyad.sh (wrapper)    |
    |                        |
    |  spawns worker claude  |----> Worker Claude Code
    |  monitors stdout       |        |
    |                        |        | permission prompt detected
    |                        |<-------+
    |  Layer 1: Rule check   |
    |    match? -> auto y/n  |
    |    no match? -> L2     |
    |                        |
    |  Layer 2: Supervisor   |----> claude --print "Should I approve: <prompt>?"
    |    approve/deny        |        |
    |                        |<-------+
    |  send y/n to worker    |----> Worker stdin
    |  if denied: warn       |----> terminal warning banner
    |  log decision          |----> audit log file
    +------------------------+
```

## Resolved Questions

1. **Rule configuration format** — JSON/YAML config file with structured sections for different rule types.
2. **Supervisor context** — Progressive: v1 uses prompt + original task only. Full session history is a future enhancement.
3. **Audit trail** — Log all decisions with timestamps, prompt text, decision, and reason.
4. **Notification mechanism** — Terminal output (visible warning/banner). No macOS notifications.
5. **Feasibility validation** — Prototype `expect`-based prompt capture first before building the full tool.

## Open Questions

1. **Session history access (future)** — If v1's limited context proves insufficient, how to capture and forward the worker's full conversation history? Determine if Claude Code exposes session state or if it must be captured from terminal output.
2. **`expect` availability** — Is `expect` pre-installed on macOS, or is a pure-bash alternative needed?
