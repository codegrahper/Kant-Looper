# quick-parallel-stability - Planning Draft

- intent: clear
- review_required: false
- status: awaiting-approval
- pending_action: write `.omo/plans/quick-parallel-stability.md`

## Components

1. `full-retirement` — remove HPRAR `--full`; make `--quick` the default; reject `--full` clearly.
2. `parallel-hardening` — keep explicit `--parallel --chain`, validate results and prevent unsafe concurrent outcomes from being promoted.
3. `quick-chain` — add explicit `--quick --chain` for the fixed implement → review → repair sequence in one isolated worktree.
4. `verification` — test-first automated coverage plus three consecutive live successes recorded as evidence.

## Decisions

- `--full` is removed, and unspecified mode runs `--quick`.
- A discontinued `--full` invocation fails with a migration message; it is not silently aliased.
- `--parallel` does not auto-retry as quick. Its alternative is explicit `--quick --chain tool:model,...`.
- Quick-chain roles are fixed in order: implement, review, repair. The chain must provide exactly three agents.
- Tests are written before the matching implementation, then existing regression tests and live tests run.

## Findings

- `scripts/kant-loop.sh` currently defaults to `full`, routes `_run_mode` through `run_full_mode`, and documents it in both help blocks.
- `run_parallel_mode` launches all adapters into one worktree and currently checks exit status before changed-file verification and gates.
- `run_quick_mode` has a single-agent adapter call with fallback, verdict validation, changed-file validation, gates, safety check, and optional commit.
- Existing scenario coverage is dry-run only for quick/parallel/full in `scripts/tests/run-scenarios.sh`; it does not prove live adapter behavior three times.

## Approval Brief

Implement a narrow migration: delete the HPRAR runner and all `--full` paths; make quick the default; add a three-stage explicit quick chain that preserves quick-mode safety checks across the shared isolated worktree; harden parallel result validation and document that it is only for independent slices. Add test-first CLI and mocked-adapter regression coverage, update user-facing docs, then execute and record three consecutive live OpenCode-led runs that prove quick-chain success. No automatic parallel-to-quick retry, no new automatic model routing, no MCP changes, and no automatic push or merge.
