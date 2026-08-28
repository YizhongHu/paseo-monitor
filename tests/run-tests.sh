#!/bin/sh
# Run every per-behaviour test in a deterministic lexical order.
set -u
self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
passed=0
failed=0
for test_file in "$self_dir"/t-*.sh; do
    [ -f "$test_file" ] || continue
    if sh "$test_file"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done
printf 'Test summary: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
