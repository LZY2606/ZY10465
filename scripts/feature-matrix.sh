#!/usr/bin/env bash
# feature-matrix.sh — feature-combination and minimum-version contract gate.
#
# Runs a lean matrix of feature combinations against real-usage fixtures
# (validator/examples/*_fixture.rs), classifies failures (lockfile, msrv,
# unknown-feature, feature-pollution, compile, test) and prints one
# deterministic key=value line per combination.
#
# Offline contract: every cargo invocation uses --locked --offline. Prepare
# with `cargo fetch --locked` while online; the gate itself never touches
# the network. The shared target/ directory is reused across combinations;
# cargo's fingerprinting plus the core fixture's pollution guard keep one
# combination's features from leaking into the next.
#
# Test-only hooks (used by scripts/feature-matrix-test.sh):
#   VALIDATOR_MATRIX_INJECT_FEATURES  extra features appended to the `core`
#                                     combination to simulate a feature leak
#   VALIDATOR_MATRIX_TOOLCHAIN        force a specific toolchain for every
#                                     combination (e.g. a below-MSRV one)
set -euo pipefail
export LC_ALL=C
export CARGO_TERM_COLOR=never

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

LOG_DIR="target/feature-matrix/logs"
mkdir -p "$LOG_DIR"

MSRV=$(sed -n 's/^rust-version = "\([^"]*\)"/\1/p' Cargo.toml | head -n 1)
HOST_TARGET=$(rustc -vV | sed -n 's/^host: //p')

FORCED_TOOLCHAIN=${VALIDATOR_MATRIX_TOOLCHAIN:-}
INJECT_FEATURES=${VALIDATOR_MATRIX_INJECT_FEATURES:-}

# version_ge A B -> exit 0 if A >= B (dotted numeric compare, no GNU sort).
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

rustc_version() {
    if [[ -n $1 ]]; then
        rustc "+$1" --version | awk '{print $2}'
    else
        rustc --version | awk '{print $2}'
    fi
}

# Lowest installed stable toolchain >= MSRV, empty if none.
msrv_floor_toolchain() {
    local best="" candidate
    for candidate in $(rustup toolchain list 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | sort -u); do
        if version_ge "$candidate" "$MSRV"; then
            if [[ -z $best ]] || { [[ $best != "$candidate" ]] && version_ge "$best" "$candidate"; }; then
                best=$candidate
            fi
        fi
    done
    echo "$best"
}

classify() {
    local log=$1
    if grep -q 'feature pollution:' "$log"; then
        echo "feature-pollution"
    elif grep -qE 'does not (contain|have) (this|these) feature|feature `[^`]+` (does not exist|is unknown)|the package .+ does not (contain|have)' "$log"; then
        echo "unknown-feature"
    elif grep -qE 'is not supported by the following packages|requires rustc [0-9]|E0554|may not be used on the stable|feature `[^`]+` is required|not stabilized in this version of Cargo|rust-version' "$log"; then
        echo "msrv"
    elif grep -qE '^test result: FAILED|panicked at' "$log"; then
        echo "test"
    else
        echo "compile"
    fi
}

failing_crate() {
    local log=$1 crate
    crate=$(grep -oE 'could not compile `[^`]+`' "$log" | head -n 1 | sed 's/could not compile `//; s/`$//')
    echo "${crate:-validator}"
}

PASSED=0
FAILED=0
UNSUPPORTED=0

# run_combo <name> <toolchain|""> <label> <feature args...> -- <fixtures...>
run_combo() {
    local name=$1 toolchain=$2 label=$3
    shift 3
    local -a feature_args=()
    while [[ $1 != -- ]]; do
        feature_args+=("$1")
        shift
    done
    shift
    local -a fixtures=("$@")

    if [[ -n $FORCED_TOOLCHAIN ]]; then
        toolchain=$FORCED_TOOLCHAIN
    fi

    local -a cargo_cmd=(cargo)
    if [[ -n $toolchain ]]; then
        cargo_cmd=(cargo "+$toolchain")
    fi
    local rustc_v
    rustc_v=$(rustc_version "$toolchain")

    local log="$LOG_DIR/$name.log"
    : >"$log"

    local -a env_prefix=()
    if [[ $name == core || $name == msrv-core ]]; then
        # Arms the core fixture's pollution guard: this build is declared
        # feature-free, so any active optional feature is a leak.
        env_prefix=(env VALIDATOR_MATRIX_CORE_COMBO=1)
    fi

    local failed=0
    (
        for fixture in "${fixtures[@]}"; do
            ${env_prefix[@]+"${env_prefix[@]}"} "${cargo_cmd[@]}" build --locked --offline -p validator \
                "${feature_args[@]}" --example "$fixture" || exit 1
            ${env_prefix[@]+"${env_prefix[@]}"} "${cargo_cmd[@]}" run --locked --offline -p validator \
                "${feature_args[@]}" --example "$fixture" || exit 1
        done
        ${env_prefix[@]+"${env_prefix[@]}"} "${cargo_cmd[@]}" test --locked --offline -p validator \
            "${feature_args[@]}" --lib || exit 1
    ) >>"$log" 2>&1 || failed=1

    local fixture_list
    fixture_list=$(IFS=,; echo "${fixtures[*]}")
    if [[ $failed -eq 0 ]]; then
        echo "combo=$name rustc=$rustc_v target=$HOST_TARGET $label fixtures=$fixture_list result=pass"
        PASSED=$((PASSED + 1))
    else
        local class crate
        class=$(classify "$log")
        crate=$(failing_crate "$log")
        echo "combo=$name rustc=$rustc_v target=$HOST_TARGET $label fixtures=$fixture_list result=fail class=$class crate=$crate log=$log"
        FAILED=$((FAILED + 1))
    fi
}

# Pre-flight: the committed lockfile must satisfy --locked --offline.
if ! cargo metadata --locked --offline --format-version 1 >/dev/null 2>"$LOG_DIR/preflight.log"; then
    echo "combo=preflight rustc=$(rustc_version "") target=$HOST_TARGET features=none fixtures=none result=fail class=lockfile crate=workspace log=$LOG_DIR/preflight.log"
    echo "summary total=1 passed=0 failed=1 unsupported=0"
    exit 1
fi
echo "contract msrv=$MSRV lockfile=locked offline=1 target_dir=shared"

CORE_FEATURES=(--no-default-features)
CORE_LABEL="features=none"
if [[ -n $INJECT_FEATURES ]]; then
    CORE_FEATURES+=(--features "$INJECT_FEATURES")
    CORE_LABEL="features=none+injected:$INJECT_FEATURES"
fi

run_combo core "" "$CORE_LABEL" "${CORE_FEATURES[@]}" -- core_fixture
run_combo derive "" "features=derive" --no-default-features --features derive -- derive_fixture
run_combo card "" "features=card" --no-default-features --features card -- card_fixture
run_combo indexmap "" "features=indexmap" --no-default-features --features indexmap -- indexmap_fixture
run_combo all-stable "" "features=derive,card,indexmap" --features derive,card,indexmap -- derive_fixture card_fixture indexmap_fixture

if [[ -n $FORCED_TOOLCHAIN ]]; then
    run_combo msrv-core "$FORCED_TOOLCHAIN" "features=none" --no-default-features -- core_fixture
else
    MSRV_TOOLCHAIN=$(msrv_floor_toolchain)
    if [[ -n $MSRV_TOOLCHAIN ]]; then
        run_combo msrv-core "$MSRV_TOOLCHAIN" "features=none" --no-default-features -- core_fixture
    else
        echo "combo=msrv-core rustc=none target=$HOST_TARGET features=none fixtures=core_fixture result=unsupported reason=no-installed-toolchain>=msrv-$MSRV"
        UNSUPPORTED=$((UNSUPPORTED + 1))
    fi
fi

TOTAL=$((PASSED + FAILED + UNSUPPORTED))
echo "summary total=$TOTAL passed=$PASSED failed=$FAILED unsupported=$UNSUPPORTED"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
