#!/usr/bin/env bash

set -euo pipefail

# SwiftPM parallelizes XCTest at test-method granularity by launching separate
# test processes. Keep the allowlist narrow: these suites use per-test editor
# state, UUID-named pasteboards, and explicit window teardown, and they are long
# enough for process-level parallelism to improve wall time.
readonly parallel_filter='^MonknotAppTests\.(HostedFlowCorpusTests|ProseCompletionEditorTests|SentenceRepairCoordinatorTests)/'
readonly worker_count="${MONKNOT_TEST_WORKERS:-2}"

if [[ ! "$worker_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "MONKNOT_TEST_WORKERS must be a positive integer; received: $worker_count" >&2
    exit 2
fi

if (( worker_count == 1 )); then
    echo "Running the complete XCTest suite serially"
    exec swift test --no-parallel
fi

echo "Running isolated editor-flow tests with $worker_count workers"
swift test \
    --parallel \
    --num-workers "$worker_count" \
    --filter "$parallel_filter"

echo "Running all remaining XCTest tests serially"
swift test \
    --skip-build \
    --no-parallel \
    --skip "$parallel_filter"
