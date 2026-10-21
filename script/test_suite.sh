#!/usr/bin/env bash
#
# Runs the XCTest suite: `script/test_suite.sh` runs all of it, `script/test_suite.sh SHARD` one
# third of it, so CI can test on three machines at once.
#
#   editor     Preview editing and writing assistance, in WebKit
#   workspace  the sidebar, file operations, documents and their viewers
#   app        everything else: the window's chrome, menus, terminal, MonknotTests and the
#              repository contracts
#
# A MonknotAppTests class runs in `editor` or `workspace` when its name starts with one of their
# prefixes; every other class runs in `app`, so a new class is never left out.

set -euo pipefail

readonly editor_filter='^MonknotAppTests\.(MarkdownVisualEditor|MarkdownPreview|MarkdownEditor|Flow|EditorFlow|ProseCompletion|SentenceRepair|HostedFlowCorpus|WritingTools)'
readonly workspace_filter='^MonknotAppTests\.(Sidebar|WorkspaceStore|WorkspaceFileOperation|WorkspaceSearch|WorkspacePasteboard|WorkspaceQuickOpen|WorkspaceFileWatcher|FileOperations|UnsavedChanges|ExternalDocument|NewFileOpensTab|DocumentViewerRouting|UndoKeyRouting|PDF|ImageMarkup)'

# SwiftPM parallelizes XCTest at test-method granularity by launching separate test processes.
# Keep the allowlist narrow: these suites use per-test editor state, UUID-named pasteboards, and
# explicit window teardown, and they are long enough for process-level parallelism to improve wall
# time. Window-driven suites share the screen, the pasteboard and key focus, so they run serially.
readonly parallel_filter='^MonknotAppTests\.(HostedFlowCorpusTests|ProseCompletionEditorTests|SentenceRepairCoordinatorTests)/'
readonly worker_count="${MONKNOT_TEST_WORKERS:-2}"

# XCTest has no time limit: a test that hangs holds CI until the job's own timeout. A run that
# prints nothing for this long is stopped, after printing the test process's stacks.
readonly stall_seconds="${MONKNOT_TEST_STALL_SECONDS:-300}"

if [[ ! "$worker_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "MONKNOT_TEST_WORKERS must be a positive integer; received: $worker_count" >&2
    exit 2
fi

# Each test line reaches the log as it happens, so a stall names the test it stopped in.
export NSUnbufferedIO=YES

# The processes started by process $1, and theirs.
descendants() {
    local child
    for child in $(pgrep -P "$1" || true); do
        echo "$child"
        descendants "$child"
    done
}

# Runs a command, stopping it after `stall_seconds` without output.
watched() {
    local log
    log="$(mktemp -t monknot-tests)"
    "$@" > >(tee -a "$log") 2>&1 &
    local runner=$!
    while kill -0 "$runner" 2>/dev/null; do
        sleep 5
        if (( $(date +%s) - $(stat -f %m "$log") > stall_seconds )); then
            echo "No test output for ${stall_seconds}s: stopping the run. The test processes' stacks:" >&2
            local processes pid
            processes="$(descendants "$runner")"
            for pid in $processes; do
                if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == *xctest ]]; then
                    sample "$pid" 2 2>&1 | head -n 400 >&2 || true
                fi
            done
            kill $processes "$runner" 2>/dev/null || true
            wait "$runner" 2>/dev/null || true
            rm -f "$log"
            return 124
        fi
    done
    local status=0
    wait "$runner" || status=$?
    rm -f "$log"
    return "$status"
}

shard="${1:-all}"
case "$shard" in
    all)
        if (( worker_count == 1 )); then
            echo "Running the complete XCTest suite serially"
            watched swift test --no-parallel
            exit
        fi
        echo "Running isolated editor-flow tests with $worker_count workers"
        watched swift test --parallel --num-workers "$worker_count" --filter "$parallel_filter"
        echo "Running all remaining XCTest tests serially"
        watched swift test --skip-build --no-parallel --skip "$parallel_filter"
        ;;
    editor)
        echo "Running isolated editor-flow tests with $worker_count workers"
        watched swift test --parallel --num-workers "$worker_count" --filter "$parallel_filter"
        echo "Running the remaining editor tests serially"
        watched swift test --skip-build --no-parallel --filter "$editor_filter" --skip "$parallel_filter"
        ;;
    workspace)
        echo "Running the workspace tests serially"
        watched swift test --no-parallel --filter "$workspace_filter"
        ;;
    app)
        echo "Running the app, core and repository tests serially"
        watched swift test --no-parallel --skip "$editor_filter" --skip "$workspace_filter"
        ;;
    *)
        echo "Usage: script/test_suite.sh [editor|workspace|app]" >&2
        exit 2
        ;;
esac
