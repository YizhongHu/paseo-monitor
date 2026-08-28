#!/bin/sh
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT

for version_arg in --version version; do
    version_output="$($PMT_BIN "$version_arg")" || fail "$version_arg failed"
    assert_eq "$version_output" 'paseo-monitor v1.3.0' "$version_arg output"
done
help_output="$($PMT_BIN --help)" || fail "help failed"
printf '%s\n' "$help_output" | grep -q 'version | --version' || fail "help omits version command"
echo PASS: version commands report v1.3.0
