#!/usr/bin/env bash
# tests/run.sh — verification harness.
#
# Always runs `bash -n` (zero-dep floor). Runs shellcheck and bats only if
# they are installed; otherwise prints an actionable SKIP and still exits
# informatively. CI installs both so they run for real there.

set -uo pipefail
cd "$(dirname "$0")/.."

rc=0
SH_FILES=(install.sh lib/*.sh tests/run.sh)

echo "== bash -n (syntax, always) =="
for f in "${SH_FILES[@]}"; do
    [[ -e $f ]] || continue
    if bash -n "$f"; then
        echo "  ok    $f"
    else
        echo "  FAIL  $f"
        rc=1
    fi
done

echo
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "${SH_FILES[@]}"; then
        echo "  shellcheck clean"
    else
        echo "  shellcheck reported issues"
        rc=1
    fi
else
    echo "  SKIPPED — shellcheck not installed (install: apt-get install shellcheck)"
fi

echo
echo "== bats unit tests =="
if command -v bats >/dev/null 2>&1; then
    if bats tests/*.bats; then
        echo "  bats passed"
    else
        echo "  bats failed"
        rc=1
    fi
else
    echo "  SKIPPED — bats not installed (install: apt-get install bats)"
fi

echo
if (( rc == 0 )); then
    echo "RESULT: OK (skipped tools are informational, not failures)"
else
    echo "RESULT: FAILURES above"
fi
exit $rc
