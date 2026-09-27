#!/usr/bin/env bash
# feature-matrix-test.sh — negative tests for the feature-matrix gate.
#
# Each scenario constructs a boundary violation and asserts that the gate
# rejects it with the documented failure class:
#   leak-injection   a `card` feature leak into the core combination must be
#                    caught as `feature-pollution`
#   unknown-feature  the removed `unic` feature must be rejected as
#                    `unknown-feature` (explicitly unsupported combination)
#   below-msrv       a toolchain older than the workspace MSRV must be
#                    rejected as `msrv`
#   lockfile-drift   a missing/stale Cargo.lock must be rejected as
#                    `lockfile`
#
# The script is sequential and deterministic (no background jobs, no
# retries), restores Cargo.lock via trap, and only writes logs under
# target/feature-matrix/logs/.
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

LOG_DIR="target/feature-matrix/logs"
mkdir -p "$LOG_DIR"

MSRV=$(sed -n 's/^rust-version = "\([^"]*\)"/\1/p' Cargo.toml | head -n 1)
FAILED=0
UNSUPPORTED=0

version_ge() {
    local IFS=.
    local -a left=($1) right=($2)
    local i l r
    for i in 0 1 2; do
        l=${left[i]:-0}
        r=${right[i]:-0}
        ((10#$l > 10#$r)) && return 0
        ((10#$l < 10#$r)) && return 1
    done
    return 0
}

# expect_gate_failure <name> <expected class> [env VAR=VAL ...]
expect_gate_failure() {
    local name=$1 expected_class=$2
    shift 2
    local log="$LOG_DIR/negtest-$name.log"
    local status=0
    env "$@" bash scripts/feature-matrix.sh >"$log" 2>&1 || status=$?
    if [[ $status -eq 0 ]]; then
        echo "negtest=$name result=fail reason=gate-unexpectedly-passed log=$log"
        FAILED=$((FAILED + 1))
    elif grep -q "class=$expected_class" "$log"; then
        echo "negtest=$name result=pass class=$expected_class"
    else
        echo "negtest=$name result=fail reason=missing-class-$expected_class log=$log"
        FAILED=$((FAILED + 1))
    fi
}

# 1. A constructed feature leak must be caught by the core fixture guard.
expect_gate_failure leak-injection feature-pollution VALIDATOR_MATRIX_INJECT_FEATURES=card

# 2. The `unic` feature was removed upstream; the combination is explicitly
#    unsupported and must be classified as unknown-feature.
expect_gate_failure unknown-feature unknown-feature VALIDATOR_MATRIX_INJECT_FEATURES=unic

# 3. A below-MSRV toolchain must be classified as an msrv violation.
BELOW_MSRV=""
for candidate in $(rustup toolchain list 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | sort -u); do
    if ! version_ge "$candidate" "$MSRV"; then
        BELOW_MSRV=$candidate
        break
    fi
done
if [[ -n $BELOW_MSRV ]]; then
    expect_gate_failure below-msrv msrv VALIDATOR_MATRIX_TOOLCHAIN="$BELOW_MSRV"
else
    echo "negtest=below-msrv result=unsupported reason=no-installed-toolchain<msrv-$MSRV"
    UNSUPPORTED=$((UNSUPPORTED + 1))
fi

# 4. A missing lockfile must be classified as a lockfile violation.
mv Cargo.lock Cargo.lock.matrix-test-bak
restore_lock() {
    if [[ -f Cargo.lock.matrix-test-bak ]]; then
        mv Cargo.lock.matrix-test-bak Cargo.lock
    fi
}
trap restore_lock EXIT
expect_gate_failure lockfile-drift lockfile
restore_lock
trap - EXIT

TOTAL=$((4))
PASSED=$((TOTAL - FAILED - UNSUPPORTED))
echo "summary total=$TOTAL passed=$PASSED failed=$FAILED unsupported=$UNSUPPORTED"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
