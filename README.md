# WhatsApp for Omarchy

WhatsApp in the Omarchy Quattro bar: unread badge, desktop notifications you can
click, inline reply without leaving the bar, and one keystroke to the full
WhatsApp Web client when you need media, calls, or search.

```
┌──────────────────────────────┐
│ WhatsApp        Connected  ⏻ │
│ ──────────────────────────── │
│ Aditi             14:32  ②   │
│ you around?                  │
│ Family group      13:05      │
│ Mum: dinner at 8             │
│ ──────────────────────────── │
│ Reply…                     ➤ │
└──────────────────────────────┘
```

## How it works

Two pieces, on purpose:

| Piece | Job |
|-------|-----|
| **Bridge daemon** (Node + [Baileys](https://github.com/WhiskeySockets/Baileys)) | Holds one linked-device session, receives messages, sends notifications, sends your replies |
| **Bar plugin** (QML) | Unread badge, chat list, conversation view, reply box |

They talk NDJSON over a unix socket in `$XDG_RUNTIME_DIR` — no localhost port,
no auth token, no browser running in the background just to get a notification.
The daemon is the fan-out point, so bars on several monitors stay in sync and a
notification click reaches whichever panel is on screen.

The **full client** is separate on purpose too: the bar panel is for reading and
replying, and the WhatsApp Web app window handles everything heavier. WhatsApp
allows up to four linked devices, so the bridge and the web app can be linked at
the same time.

## Install

```sh
git clone https://github.com/ricky/omarchy-whatsapp.git
cd omarchy-whatsapp
./install.sh
```

`install.sh` copies the plugin to `~/.config/omarchy/plugins/io.github.ricky.whatsapp/`,
installs the daemon's dependencies, sets up the `omarchy-whatsapp` user service,
and adds the widget to your bar.

Via the plugin manager instead (the installer never runs plugin code, so the
setup step is manual afterwards):

```sh
omarchy plugin add https://github.com/ricky/omarchy-whatsapp.git --enable --yes
~/.config/omarchy/plugins/io.github.ricky.whatsapp/install.sh
```

Requirements: Omarchy 4 (Quattro) and Node.js 20+. If Node lives in a version
manager (mise, proto, fnm, volta, nvm) the installer finds it and pins the
absolute path into the service unit.

## Link your account

Click the WhatsApp icon in the bar and scan the QR code, or:

```sh
omarchy-whatsapp login                 # QR in the terminal
omarchy-whatsapp login --pair 919812345678   # 8-digit code instead
```

On your phone: **Settings → Linked devices → Link a device**.

## Use it

| Action | How |
|--------|-----|
| Open the panel | Click the bar icon |
| Move through chats | `j` / `k` or arrow keys |
| Open a chat | `Enter` |
| Reply | Type, then `Enter` |
| Back to the chat list | `Escape` |
| Close the panel | `Escape` from the list |
| Full WhatsApp Web | Right-click the icon, or the ⧉ button in the panel |
| Open a chat from a notification | Click the notification |

Opening a chat marks it read on every device. Messages arriving while a
conversation is open are marked read immediately.

## CLI

```sh
omarchy-whatsapp status                          # connection, account, unread
omarchy-whatsapp send 919812345678@s.whatsapp.net "on my way"
omarchy-whatsapp chats 10                        # recent chats as JSON
omarchy-whatsapp focus 919812345678@s.whatsapp.net   # open the panel on a chat
omarchy-whatsapp open                            # full web client
omarchy-whatsapp restart | logs | logout
```

`install.sh` links these into `~/.local/bin`. `omarchy-whatsapp-ctl -h` lists the
raw daemon commands.

## Settings

Per-widget settings live inline on the bar entry in `~/.config/omarchy/shell.json`
and hot-reload on save:

```json
{ "id": "io.github.ricky.whatsapp", "showUnreadCount": true, "chatLimit": 40 }
```

| Key | Default | Meaning |
|-----|---------|---------|
| `socketPath` | `""` | Daemon socket; blank uses `$XDG_RUNTIME_DIR/omarchy-whatsapp.sock` |
| `autostartDaemon` | `true` | Start the daemon if the socket is missing |
| `showUnreadCount` | `true` | Show the count next to the icon |
| `hideWhenEmpty` | `false` | Hide the widget entirely when nothing is unread |
| `chatLimit` | `40` | Chats listed in the panel |
| `messageLimit` | `60` | Messages loaded per conversation |
| `webAppUrl` | `https://web.whatsapp.com` | Full client URL |
| `webAppPattern` | `web.whatsapp.com` | Window pattern used to focus the full client |

Move the widget:

```sh
omarchy bar move io.github.ricky.whatsapp --section right
```

## What it stores, and where

| Path | Contents |
|------|----------|
| `~/.local/state/omarchy-whatsapp/auth/` | Linked-device credentials and Signal keys (`0700`) |
| `~/.local/state/omarchy-whatsapp/store.json` | Recent chats and up to 200 messages per chat (`0600`) |
| `$XDG_RUNTIME_DIR/omarchy-whatsapp.sock` | Control socket (`0600`, cleared on logout) |

Nothing leaves your machine except traffic to WhatsApp itself. Media is never
downloaded — photos and voice notes show as `📷 Photo`, `🎤 Voice message`, and
so on. Open the full client for the real thing.

`omarchy-whatsapp logout` unlinks the device and deletes all three.

## Things worth knowing before you install

- **Baileys is an unofficial WhatsApp Web client.** It is not endorsed by
  WhatsApp, and using it carries some risk to your account. It is the same
  mechanism every WhatsApp bridge on Linux uses, but the risk is yours.
- **The version is pinned deliberately.** `baileys@6.7.24`. npm's `latest`
  (6.17.16) is deprecated for a message-spoofing zero-day
  ([GHSA-qvv5-jq5g-4cgg](https://github.com/WhiskeySockets/Baileys/security/advisories/GHSA-qvv5-jq5g-4cgg));
  do not bump it without checking that advisory.
- **Plugins run unsandboxed inside `omarchy-shell`.** This one keeps its network
  and protocol work in a separate process for exactly that reason — the QML side
  only parses JSON from a socket it owns — but you should still read the code
  before enabling it.
- **The daemon stays "offline" to WhatsApp** (`markOnlineOnConnect: false`) so
  your phone keeps its own notifications working.
- **Read receipts are sent** when you open a chat, the same as opening it on your
  phone.

## Troubleshooting

**Icon is dim / "Daemon offline"**

```sh
systemctl --user status omarchy-whatsapp
journalctl --user -u omarchy-whatsapp -n 50
```

**"no Node.js >= 20 found"** — install `nodejs`, or point the service at your
interpreter: `systemctl --user edit omarchy-whatsapp` and add
`Environment=OMARCHY_WHATSAPP_NODE=/path/to/node`.

**Widget not in the bar**

```sh
omarchy plugin list --json | jq '.[] | select(.id == "io.github.ricky.whatsapp")'
omarchy-shell shell rescanPlugins
qs log -p "$OMARCHY_PATH/shell" --tail 100
```

**Stuck on "Reconnecting…"** — `omarchy-whatsapp ctl reconnect`, then re-link
with `omarchy-whatsapp login` if the phone dropped the device.

## Remove

```sh
./install.sh --uninstall          # or, if installed via the plugin manager:
omarchy plugin remove io.github.ricky.whatsapp
rm -rf ~/.local/state/omarchy-whatsapp   # credentials and cache
```

## License

MIT. See [LICENSE](LICENSE).
