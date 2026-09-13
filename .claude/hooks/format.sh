#!/usr/bin/env bash
#
# PostToolUse hook: auto-format the file Claude just edited with `mix format`.
#
# Runs after Edit/Write/MultiEdit. It reads the tool call's JSON from stdin,
# pulls out the target file, and (for Elixir / HEEx sources) formats it from the
# project root so .formatter.exs applies — its Spark plugin and
# locals_without_parens are what keep the DSL blocks readable.

set -euo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Make the mise-managed toolchain available in web sessions (see
# session-start.sh); these are harmless no-ops in a local checkout.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

# The edited file, from the hook's JSON payload on stdin. jq is not guaranteed
# to be installed (it isn't in every devcontainer), so fall back to python3 —
# and if neither is there, let the turn proceed unformatted rather than failing
# the hook. The Stop gate's `mix format --check-formatted` still catches it.
if command -v jq >/dev/null 2>&1; then
  file="$(jq -r '.tool_input.file_path // empty')"
elif command -v python3 >/dev/null 2>&1; then
  file="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path") or "")')"
else
  exit 0
fi

[ -n "$file" ] || exit 0

# Only format Elixir source and HEEx templates.
case "$file" in
  *.ex|*.exs|*.heex) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

cd "$REPO_DIR"
mix format "$file"
