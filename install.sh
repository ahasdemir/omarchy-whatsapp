#!/bin/bash
# Installs omarchy-whatsapp: copies the plugin into the user plugin directory
# (when run from a source checkout), installs the daemon's dependencies, sets up
# the user service, and enables the bar widget.
#
# Safe to re-run: nothing here touches your WhatsApp credentials or chat cache.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PLUGIN_ID="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SOURCE_DIR/manifest.json" | head -1)"
PLUGINS_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_ROOT/$PLUGIN_ID"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
BIN_DIR="$HOME/.local/bin"
UNIT_NAME="omarchy-whatsapp.service"

skip_service=0
skip_enable=0

die() {
  echo "install: $*" >&2
  exit 1
}

say() { echo "==> $*"; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  --no-service   skip the systemd user service (start the daemon yourself)
  --no-enable    skip adding the widget to the bar
  --uninstall    remove the service, the widget, and the installed plugin
  -h, --help     this message

Chat history and credentials live in ~/.local/state/omarchy-whatsapp and are
never touched by install or uninstall.
EOF
}

uninstall() {
  say "Stopping the service"
  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME"
  systemctl --user daemon-reload 2>/dev/null || true

  if command -v omarchy >/dev/null 2>&1; then
    say "Removing the bar widget"
    omarchy plugin disable "$PLUGIN_ID" --yes 2>/dev/null || true
  fi

  say "Removing CLI symlinks from $BIN_DIR"
  for tool in omarchy-whatsapp omarchy-whatsapp-ctl omarchy-whatsapp-focus omarchy-whatsapp-login omarchy-whatsapp-open omarchy-whatsapp-daemon; do
    [[ -L $BIN_DIR/$tool ]] && rm -f "$BIN_DIR/$tool"
  done

  if [[ -d $PLUGIN_DIR && $PLUGIN_DIR != "$SOURCE_DIR" ]]; then
    say "Removing $PLUGIN_DIR"
    rm -rf "$PLUGIN_DIR"
  fi

  command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  say "Uninstalled. Credentials remain in ~/.local/state/omarchy-whatsapp"
  exit 0
}

while (($# > 0)); do
  case $1 in
  --no-service) skip_service=1 ;;
  --no-enable) skip_enable=1 ;;
  --uninstall) uninstall ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n $PLUGIN_ID ]] || die "could not read the plugin id from manifest.json"

# Resolve a Node runtime the same way the runtime scripts do.
source "$SOURCE_DIR/bin/_common.sh"
NODE="$(wa_node)"
say "Using Node $("$NODE" -v) at $NODE"

# ── 1. Place the plugin ─────────────────────────────────────────────────────
if [[ $SOURCE_DIR == "$PLUGIN_DIR" ]]; then
  say "Already installed at $PLUGIN_DIR (in-place setup)"
else
  say "Installing to $PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude 'node_modules' \
      --exclude '*.tmp' \
      "$SOURCE_DIR"/ "$PLUGIN_DIR"/
  else
    # tar keeps the excludes working without rsync installed.
    tar -C "$SOURCE_DIR" --exclude='.git' --exclude='node_modules' -cf - . \
      | tar -C "$PLUGIN_DIR" -xf -
  fi
fi

chmod +x "$PLUGIN_DIR"/bin/* "$PLUGIN_DIR"/daemon/ctl.js "$PLUGIN_DIR"/install.sh 2>/dev/null || true

# ── 2. Daemon dependencies ──────────────────────────────────────────────────
NPM="$(dirname "$NODE")/npm"
[[ -x $NPM ]] || NPM="$(command -v npm 2>/dev/null || true)"
[[ -n $NPM && -x $NPM ]] || die "npm not found next to $NODE and not on PATH"

say "Installing daemon dependencies"
(
  cd "$PLUGIN_DIR/daemon"
  # --no-bin-links: Omarchy rejects any symlink inside a plugin folder, and
  # npm's node_modules/.bin shims are symlinks. The daemon is started as
  # `node index.js`, so no package bin is ever needed.
  if [[ -f package-lock.json ]]; then
    PATH="$(dirname "$NODE"):$PATH" "$NPM" ci --omit=dev --no-bin-links --no-audit --no-fund
  else
    PATH="$(dirname "$NODE"):$PATH" "$NPM" install --omit=dev --no-bin-links --no-audit --no-fund
  fi
)

# Belt and braces: some packages ship symlinks of their own.
if [[ -d $PLUGIN_DIR/daemon/node_modules ]]; then
  find "$PLUGIN_DIR/daemon/node_modules" -type l -delete
fi

# ── 3. CLI on PATH ──────────────────────────────────────────────────────────
# Symlinks live outside the plugin folder on purpose: Omarchy's plugin
# validation rejects any symlink inside it.
say "Linking the CLI into $BIN_DIR"
mkdir -p "$BIN_DIR"
for tool in omarchy-whatsapp omarchy-whatsapp-ctl omarchy-whatsapp-focus omarchy-whatsapp-login omarchy-whatsapp-open omarchy-whatsapp-daemon; do
  ln -sfn "$PLUGIN_DIR/bin/$tool" "$BIN_DIR/$tool"
done
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) echo "    note: $BIN_DIR is not on your PATH; add it to use the omarchy-whatsapp commands" ;;
esac

# ── 4. User service ─────────────────────────────────────────────────────────
if ((skip_service)); then
  say "Skipping the systemd user service"
else
  say "Installing $UNIT_NAME"
  mkdir -p "$UNIT_DIR"
  sed -e "s|@PLUGIN_DIR@|$PLUGIN_DIR|g" "$PLUGIN_DIR/systemd/$UNIT_NAME" >"$UNIT_DIR/$UNIT_NAME"

  # Bake the resolved interpreter in: a systemd user unit does not inherit the
  # PATH additions that version managers install into interactive shells.
  if ! grep -q '^Environment=OMARCHY_WHATSAPP_NODE=' "$UNIT_DIR/$UNIT_NAME"; then
    sed -i "/^Environment=NODE_ENV=production/a Environment=OMARCHY_WHATSAPP_NODE=$NODE" "$UNIT_DIR/$UNIT_NAME"
  fi

  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME" >/dev/null
  systemctl --user restart "$UNIT_NAME"
  say "Service started"
fi

# ── 5. Register with the shell ──────────────────────────────────────────────
if command -v omarchy-shell >/dev/null 2>&1; then
  say "Rescanning plugins"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

if ((skip_enable)); then
  say "Skipping bar enablement"
elif command -v omarchy >/dev/null 2>&1; then
  say "Enabling the bar widget"
  omarchy plugin enable "$PLUGIN_ID" --yes 2>/dev/null \
    || omarchy plugin enable "$PLUGIN_ID" 2>/dev/null \
    || echo "    (could not enable automatically; run: omarchy plugin enable $PLUGIN_ID)"
fi

cat <<EOF

Done. Next:

  1. Link your account:   $PLUGIN_DIR/bin/omarchy-whatsapp login
     (or click the WhatsApp icon in the bar and scan the QR there)
  2. Click the icon to read and reply; right-click for the full web client.

Service:  systemctl --user status $UNIT_NAME
Logs:     journalctl --user -u $UNIT_NAME -f
EOF
