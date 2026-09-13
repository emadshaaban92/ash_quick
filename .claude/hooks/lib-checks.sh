#!/usr/bin/env bash
#
# Stop hook: CI-equivalent quality gate for the library.
#
#   mix format --check-formatted
#   mix spark.formatter --check --extensions AshQuick,AshQuick.Nav.Dsl
#   mix compile --warnings-as-errors
#   mix credo
#   mix sobelow
#   mix test
#
# These mirror the `test` and `quality` jobs in .github/workflows/ci.yml, so a
# green gate here is a green CI run.
#
# The spark.formatter check is here and not only in CI because .formatter.exs is
# *exported* to consuming apps: a DSL entity added without regenerating it makes
# every host format that entity with parens. It is generated, never hand-edited.
#
# Fingerprint-gated (see _common.sh): if no source file has changed since the
# last passing run, the gate skips entirely — so pure Q&A / "thinking" turns
# don't trigger the suite. Only a real change re-runs it.
#
# Every check runs even if an earlier one fails, so a single turn surfaces every
# problem. On any failure the hook exits 2: the collected output goes back to
# Claude and it keeps working until the gate is green. The loop terminates
# naturally once all checks pass.

set -uo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Fail open: if the shared helper is missing, let the turn finish rather than
# hard-erroring under `set -u`.
COMMON="$REPO_DIR/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
source "$COMMON"

# Skip when nothing the library cares about has changed since the last green run.
fp="$(fingerprint_library)"
gate_unchanged library "$fp" && exit 0

failures=""

# run <label> <cmd...> — execute a check in the library root, capturing output.
run() {
  local label="$1"
  shift
  local out
  if ! out="$(cd "$REPO_DIR" && "$@" 2>&1)"; then
    failures+=$'\n'"### ${label} failed:"$'\n'"${out}"$'\n'
  fi
}

run "mix format --check-formatted"     mix format --check-formatted
run "mix spark.formatter --check"      mix spark.formatter --check --extensions AshQuick,AshQuick.Nav.Dsl
run "mix compile --warnings-as-errors" mix compile --warnings-as-errors
run "mix credo"                        mix credo
run "mix sobelow"                      mix sobelow
run "mix test"                         mix test

if [ -n "$failures" ]; then
  echo "Stop gate failed — fix these before finishing:${failures}" >&2
  exit 2
fi

# All green — remember this fingerprint so unchanged turns skip the gate.
gate_passed library "$fp"
