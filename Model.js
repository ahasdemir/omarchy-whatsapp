.pragma library

// Formatting helpers shared by BarWidget.qml and Panel.qml. Kept free of QML
// types so both can import it as a plain library.

function badgeText(count) {
  var n = Math.max(0, count | 0)
  if (n === 0) return ""
  return n > 99 ? "99+" : String(n)
}

function truncate(text, limit) {
  var value = String(text === undefined || text === null ? "" : text)
  var max = limit || 60
  if (value.length <= max) return value
  return value.slice(0, max - 1) + "\u2026"
}

// Collapse newlines so a multi-line message still occupies one preview row.
function oneLine(text) {
  return String(text === undefined || text === null ? "" : text).replace(/\s*\n+\s*/g, " \u00b7 ").trim()
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
}

// WhatsApp's own scheme: time today, "Yesterday", weekday this week, date beyond.
function chatTimestamp(seconds) {
  if (!seconds) return ""
  var date = new Date(seconds * 1000)
  var now = new Date()
  var today = startOfDay(now)
  var stamp = startOfDay(date)
  var dayMs = 86400000

  if (stamp === today) return Qt.formatTime(date, "HH:mm")
  if (stamp === today - dayMs) return "Yesterday"
  if (today - stamp < 6 * dayMs) return Qt.formatDateTime(date, "ddd")
  if (date.getFullYear() === now.getFullYear()) return Qt.formatDateTime(date, "d MMM")
  return Qt.formatDateTime(date, "d MMM yyyy")
}

function messageTimestamp(seconds) {
  if (!seconds) return ""
  return Qt.formatTime(new Date(seconds * 1000), "HH:mm")
}

// Day separators inside a conversation.
function dayLabel(seconds) {
  if (!seconds) return ""
  var date = new Date(seconds * 1000)
  var today = startOfDay(new Date())
  var stamp = startOfDay(date)
  if (stamp === today) return "Today"
  if (stamp === today - 86400000) return "Yesterday"
  return Qt.formatDateTime(date, "ddd d MMM")
}

function sameDay(a, b) {
  if (!a || !b) return false
  return startOfDay(new Date(a * 1000)) === startOfDay(new Date(b * 1000))
}

function chatTitle(chat) {
  if (!chat) return ""
  return chat.name || prettyJid(chat.jid)
}

function prettyJid(jid) {
  if (!jid) return ""
  var user = String(jid).split("@")[0].split(":")[0]
  if (!user) return String(jid)
  return /^\d{6,}$/.test(user) ? "+" + user : user
}

// The preview line under a chat name: "You: ..." for outgoing, "Name: ..." in
// groups, bare text in a one-to-one chat.
function chatPreview(chat) {
  if (!chat) return ""
  var text = oneLine(chat.lastText)
  if (!text) return "No messages yet"
  if (chat.lastFromMe) return "You: " + text
  if (chat.isGroup && chat.lastSender) return chat.lastSender + ": " + text
  return text
}

// Baileys status enum: 1 pending, 2 server ack, 3 delivered, 4 read, 5 played.
function statusGlyph(status) {
  switch (status | 0) {
    case 0:
    case 1: return "\uf017"     // clock
    case 2: return "\uf00c"     // check
    case 3: return "\uf560"     // double check
    case 4:
    case 5: return "\uf560"
    default: return ""
  }
}

function statusIsRead(status) {
  return (status | 0) >= 4
}

function connectionLabel(state, needsLogin, daemonOnline, pairingStopped) {
  if (!daemonOnline) return "Daemon offline"
  if (pairingStopped) return "QR paused"
  if (needsLogin) return "Not linked"
  switch (state) {
    case "open": return "Connected"
    case "connecting": return "Connecting\u2026"
    case "qr": return "Waiting for scan"
    case "close": return "Reconnecting\u2026"
    case "idle": return "Idle"
    default: return state ? String(state) : "Unknown"
  }
}

function isReady(state, needsLogin, daemonOnline) {
  return daemonOnline === true && needsLogin !== true && state === "open"
}
