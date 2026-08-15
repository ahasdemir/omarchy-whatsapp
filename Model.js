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

function isPhotoPlaceholder(text) {
  return /^[\uf03e\uf118]?\s*(Photo|Sticker)?$/i.test(String(text || "").trim())
}

function chatTitle(chat) {
  if (!chat) return ""
  return chat.name || prettyJid(chat.jid)
}

function prettyJid(jid) {
  if (!jid) return ""
  var parts = String(jid).split("@")
  var user = parts[0].split(":")[0]
  var server = parts.length > 1 ? parts[1] : ""
  if (!user) return String(jid)
  if (server === "g.us") return "Group"
  if (server === "lid") return user
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
// Two nf-fa-check glyphs, not nf-fa-check-double: that codepoint is a copy
// icon in a lot of Nerd Fonts, so "delivered" was rendering as one tick.
function statusGlyph(status) {
  switch (status | 0) {
    case 0:
    case 1: return "\uf017"
    case 2: return "\uf00c"
    case 3:
    case 4:
    case 5: return "\uf00c\uf00c"
    default: return ""
  }
}

function statusIsRead(status) {
  return (status | 0) >= 4
}

function connectionLabel(state, needsLogin, daemonOnline, pairingStopped) {
  if (needsLogin) {
    if (state === "qr") return "Scan QR"
    if (pairingStopped) return "Not linked"
    if (state === "connecting") return "Starting login\u2026"
    return "Not linked"
  }
  if (!daemonOnline) return "Offline"
  if (state === "open") return "Connected"
  return "Connected"
}

function isReady(state, needsLogin, daemonOnline) {
  return needsLogin !== true && (state === "open" || daemonOnline === true)
}
