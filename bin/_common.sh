#!/bin/bash
# Sourced by every omarchy-whatsapp script. Resolves the plugin root, the state
# directory, and a Node runtime new enough for Baileys.

set -euo pipefail

WA_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WA_ROOT="$(dirname "$WA_BIN_DIR")"
WA_DAEMON_DIR="$WA_ROOT/daemon"
WA_STATE_DIR="${OMARCHY_WHATSAPP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-whatsapp}"
WA_SOCKET="${OMARCHY_WHATSAPP_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/omarchy-whatsapp.sock}"

export OMARCHY_WHATSAPP_STATE="$WA_STATE_DIR"
export OMARCHY_WHATSAPP_SOCKET="$WA_SOCKET"

wa_die() {
  echo "omarchy-whatsapp: $*" >&2
  exit 1
}

# Version managers (mise, proto, fnm, nvm, volta) keep node off the default
# PATH of a systemd user unit, so probe their shim directories too.
wa_resolve_node() {
  if [[ -n ${OMARCHY_WHATSAPP_NODE:-} ]]; then
    printf '%s\n' "$OMARCHY_WHATSAPP_NODE"
    return 0
  fi

  local candidates=(
    "$(command -v node 2>/dev/null || true)"
    "$HOME/.local/share/mise/shims/node"
    "$HOME/.local/share/proto/shims/node"
    "$HOME/.local/share/fnm/aliases/default/bin/node"
    "$HOME/.volta/bin/node"
    "$HOME/.bun/bin/node"
    /usr/bin/node
    /usr/local/bin/node
  )

  local candidate major
  for candidate in "${candidates[@]}"; do
    [[ -n $candidate && -x $candidate ]] || continue
    major="$("$candidate" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if ((major >= 20)); then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

wa_node() {
  local node
  node="$(wa_resolve_node)" || wa_die "no Node.js >= 20 found. Install nodejs, or set OMARCHY_WHATSAPP_NODE=/path/to/node"
  printf '%s\n' "$node"
}

wa_ensure_deps() {
  [[ -d $WA_DAEMON_DIR/node_modules/baileys ]] && return 0

  local node npm
  node="$(wa_node)"
  npm="$(dirname "$node")/npm"
  [[ -x $npm ]] || npm="$(command -v npm 2>/dev/null || true)"
  [[ -n $npm && -x $npm ]] || wa_die "npm not found; run: (cd $WA_DAEMON_DIR && npm ci)"

  echo "omarchy-whatsapp: installing daemon dependencies (first run only)..." >&2
  # --no-bin-links keeps the plugin folder free of symlinks, which Omarchy's
  # plugin validation rejects.
  (cd "$WA_DAEMON_DIR" && PATH="$(dirname "$node"):$PATH" "$npm" install --omit=dev --no-bin-links --no-audit --no-fund) \
    || wa_die "dependency install failed"
  find "$WA_DAEMON_DIR/node_modules" -type l -delete 2>/dev/null || true
}

wa_daemon_running() {
  [[ -S $WA_SOCKET ]] || return 1
  "$(wa_node)" "$WA_DAEMON_DIR/ctl.js" ping >/dev/null 2>&1
}
