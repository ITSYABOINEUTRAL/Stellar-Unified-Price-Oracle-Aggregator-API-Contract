#!/usr/bin/env bash
# mutation-gate.sh — cargo-mutants security gate (#412).
#
# Runs mutation testing in two classes:
#   critical  — auth, aggregation math, bounds, finality, upgrade.
#               Any surviving (missed) or timed-out mutant fails the gate.
#   general   — the rest of the contract. Fails below GENERAL_THRESHOLD %.
#
# Usage:
#   ./scripts/mutation-gate.sh critical|general|all
#
# Environment:
#   GENERAL_THRESHOLD  minimum kill rate for general modules (default 80)
#   MUTANTS_ARGS       extra cargo-mutants args, e.g. "--in-diff pr.diff" or
#                      "--shard 0/4" to bound CI duration
#
# Reports (score per class + survivor list) go to stdout and, in CI,
# $GITHUB_STEP_SUMMARY. Survivors are left in mutants-<class>/mutants.out/missed.txt.

set -euo pipefail

SRC="contracts/price-oracle/src"
SECURITY_CRITICAL=(admin.rs rbac.rs multisig.rs storage.rs finality.rs migration.rs)
GENERAL_THRESHOLD="${GENERAL_THRESHOLD:-80}"
CLASS="${1:-all}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
status=0

run_class() {
  local class="$1"; shift
  local out="mutants-${class}"
  # cargo-mutants exits 2 when mutants are missed; the gate decides below.
  # shellcheck disable=SC2086
  cargo mutants --no-shuffle -o "$out" "$@" ${MUTANTS_ARGS:-} || true

  local json="$out/mutants.out/outcomes.json"
  if [[ ! -f "$json" ]]; then
    echo "::error::cargo-mutants produced no outcomes for $class"
    status=1
    return
  fi

  local caught missed timeout unviable score
  caught=$(jq '.caught' "$json")
  missed=$(jq '.missed' "$json")
  timeout=$(jq '.timeout' "$json")
  unviable=$(jq '.unviable' "$json")
  score=$(awk -v c="$caught" -v m="$missed" -v t="$timeout" \
    'BEGIN { v = c + m + t; printf "%.1f", v ? 100 * c / v : 100 }')

  {
    echo "### Mutation score — $class: ${score}%"
    echo ""
    echo "| caught | missed | timeout | unviable |"
    echo "|---|---|---|---|"
    echo "| $caught | $missed | $timeout | $unviable |"
    echo ""
    if [[ -s "$out/mutants.out/missed.txt" ]]; then
      echo "<details><summary>Survivors ($class)</summary>"
      echo ""
      echo '```'
      cat "$out/mutants.out/missed.txt"
      echo '```'
      echo "</details>"
    fi
  } | tee -a "$SUMMARY"

  if [[ "$class" == critical ]]; then
    if (( missed > 0 || timeout > 0 )); then
      echo "::error::$((missed + timeout)) security-critical mutant(s) survived"
      status=1
    fi
  elif awk -v s="$score" -v t="$GENERAL_THRESHOLD" 'BEGIN { exit !(s < t) }'; then
    echo "::error::general mutation score ${score}% is below ${GENERAL_THRESHOLD}%"
    status=1
  fi
}

critical_args=()
general_args=()
for f in "${SECURITY_CRITICAL[@]}"; do
  critical_args+=(--file "$SRC/$f")
  general_args+=(--exclude "$SRC/$f")
done

case "$CLASS" in
  critical) run_class critical "${critical_args[@]}" ;;
  general)  run_class general "${general_args[@]}" ;;
  all)      run_class critical "${critical_args[@]}"
            run_class general "${general_args[@]}" ;;
  *) echo "usage: $0 critical|general|all" >&2; exit 64 ;;
esac

exit "$status"
