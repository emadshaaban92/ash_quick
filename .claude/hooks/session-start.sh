#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# The cloud Setup script installs the mise-managed toolchain (Erlang/OTP,
# Elixir, hex, rebar). This hook does the per-session work that isn't
# snapshotted: activate the toolchain and build the library.
#
# There is no database step: this package has no Repo and its suite runs Ash
# resources on the ETS data layer.

set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

log() { echo "[session-start] $*"; }

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$REPO_DIR"

# mise-managed toolchain on PATH.
#   HEX_CACERTS_PATH: the egress gateway terminates TLS with its own CA and Hex
#     ignores SSL_CERT_FILE, so point it at the system trust store or deps.get
#     fails unknown_ca.
#   ELIXIR_ERL_OPTIONS=+fnu: the container locale is C; force UTF-8 filename
#     handling or the BEAM warns it may malfunction.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="/etc/ssl/certs/ca-certificates.crt"
export ELIXIR_ERL_OPTIONS="+fnu"

mise trust "$REPO_DIR"
mise install

# Bridge the toolchain (PATH, MIX_HOME) + Hex/BEAM env into the agent session.
{
  mise env -s bash
  echo "export HEX_CACERTS_PATH=\"$HEX_CACERTS_PATH\""
  echo "export ELIXIR_ERL_OPTIONS=\"$ELIXIR_ERL_OPTIONS\""
} >> "$CLAUDE_ENV_FILE"

log "Fetching + compiling deps..."
mix deps.get
mix compile

# Compile the :test build too, so the first Stop-hook gate isn't a cold build.
log "Warming the test build..."
MIX_ENV=test mix compile

log "Done. Run the suite with: mix test"
