# XCTest isolation and execution policy

`script/test_suite.sh` runs a small, explicit allowlist concurrently, then runs every other
XCTest serially. New tests remain serial unless the allowlist is deliberately changed.

## CI shards

CI runs the suite as three shards on three machines at once: `script/test_suite.sh editor`
(Preview editing and writing assistance), `workspace` (the sidebar, file operations, documents and
their viewers) and `app` (everything else, with `MonknotTests`, the repository contracts, the
release builds and the smoke executables). A `MonknotAppTests` class belongs to `editor` or
`workspace` by the start of its name, as the runner's filters list; every other class runs in
`app`, so a new class is never left out. `script/test_suite.sh` with no shard runs everything.

A run that prints nothing for 300 seconds (`MONKNOT_TEST_STALL_SECONDS`) has hung: the runner
prints the test process's stacks and stops it, so CI fails in minutes and names the stuck test.
Test output is unbuffered (`NSUnbufferedIO`) so the log shows the test that was running.

Wall-clock budgets (`MarkdownVisualEditorTests`' keystroke costs) are four times larger when `CI`
is set, since a shared runner is several times slower than a Mac at a desk.

## Parallel allowlist

The following `MonknotAppTests` suites can run concurrently:

- `HostedFlowCorpusTests`
- `ProseCompletionEditorTests`
- `SentenceRepairCoordinatorTests`

Each test owns its coordinator, text view, and window. Pasteboard-driven corpus tests use a
UUID-named pasteboard, and hosted views are dismantled before the test exits. These suites do
not use `UserDefaults.standard`, fixed filesystem paths, shared WebKit/PDF runtimes, PTYs, or
the general pasteboard. SwiftPM runs each parallel XCTest method in a separate process, which
also keeps the suites' AppKit object graphs process-local. The tests are long enough to recover
the cost of launching those processes.

The default is two workers. Set `MONKNOT_TEST_WORKERS=1` to run the complete suite serially.
Higher worker counts are useful only for benchmarking and must not become the default without
repeating the isolation audit and full-suite stress runs.

## Serial groups

- `MonknotTests` and `RepositoryContractTests` are generally isolated, but their tests are too
  short for process-level parallelism. Parallel execution increases their wall time.
- Workspace split, settings, migration, and Sparkle tests touch persisted or standard defaults.
- Workspace store, watcher, and file-operation tests coordinate asynchronous filesystem state.
- AppKit focus/window tests, general pasteboard tests, PDFKit tests, and WebKit tests use
  platform-global or lifecycle-sensitive resources.
- Menu and popover suites (`MonknotContextMenuTests`, `MonknotPopUpMenuTests`,
  `MonknotPopoverTests`, the sidebar suites) share `MonknotContextMenuController.shared`,
  `MonknotPopoverController.shared`, their event monitors and the app's activation; each closes
  both controllers before it starts.
- Terminal tests create PTYs, processes, dispatch sources, and file descriptors.
- All other `MonknotAppTests` stay serial until they have both an isolation audit and a measured
  end-to-end benefit.

Do not replace the allowlist with whole-suite `--parallel`. Process isolation does not isolate
persisted user-default domains, filesystem paths, OS focus, subprocess resources, or other
machine-wide state.
