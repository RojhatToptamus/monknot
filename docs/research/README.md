# Research Notes

These files are historical research snapshots from earlier Monknot/Markprev implementation passes. They preserve useful reasoning, Apple API notes, risk analysis, and testing ideas, but many file paths, line numbers, target names, and completion states are intentionally stale.

Use current sources for authoritative status:

- `AGENTS.md` for the current architecture, targets, runtime flow, and test commands.
- `improvement_progress.md` for the latest completed slices and remaining blockers.
- `Package.swift`, `script/build_and_run.sh`, and the current test suite for build/test truth.

When reusing an older research item, first verify it against the current codebase. In particular, references to `Markprev*`, orphaned smoke tests, undeclared smoke targets, or missing app-layer test targets predate the current Monknot package layout and should not be treated as current facts.
