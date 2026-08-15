import { chmodSync, readdirSync, rmSync, writeFileSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import makeWASocket, {
  Browsers,
  DisconnectReason,
  fetchLatestBaileysVersion,
  jidNormalizedUser,
  makeCacheableSignalKeyStore,
  useMultiFileAuthState
} from 'baileys'
import QRCode from 'qrcode'

import { authDir, ensureDirs, qrPngFileFor, qrTxtFile, socketPath, stateDir } from './lib/paths.js'
import { logger, waLogger } from './lib/logger.js'
import { Store } from './lib/store.js'
import { Notifier } from './lib/notify.js'
import { Bus } from './lib/server.js'
import { isGroupJid, isIgnorableChat, isSilent, messageText, messageType, prettyJid } from './lib/message.js'

const RECONNECT_BASE_MS = 2000
const RECONNECT_MAX_MS = 60000
// WhatsApp hands out a batch of ~6 QR refs and then closes the socket with 408.
// That is the normal rhythm of pairing, not a failure, so the next batch is one
// quick reconnect away rather than an exponential backoff.
const PAIRING_RETRY_MS = 1500
// 515 means "handshake done, reconnect now" and arrives right after a successful
// scan. Waiting here would stall the login the user just completed.
const RESTART_RETRY_MS = 250
// Pairing does not run forever. Without this the daemon regenerates a QR every
// 20s for as long as it is enabled, hammering WhatsApp's pairing endpoint for an
// account that may never be linked.
const PAIRING_WINDOW_MS = Math.max(
  15000,
  Number(process.env.OMARCHY_WHATSAPP_PAIRING_WINDOW_MS) || 5 * 60 * 1000
)
const MAX_QR_PER_PAIRING = 32
const PRINT_QR = process.env.OMARCHY_WHATSAPP_PRINT_QR === '1'

// Messages predating this run are backlog, not news: they were already
// notified by the phone, so replaying them as toasts on every daemon start
// would be noise.
const startedAt = Math.floor(Date.now() / 1000)

const store = new Store()
const notifier = new Notifier()
const bus = new Bus(socketPath)

let sock = null
let connection = 'connecting'
let qrVersion = 0
let hasQr = false
let currentQrPng = ''
// Pairing window bookkeeping, plus the live creds so a 401 can be told apart
// from "this pairing attempt was rejected".
let pairingStartedAt = 0
let qrCount = 0
let pairingStopped = false
let creds = null
let needsLogin = false
let lastError = ''
let reconnectAttempts = 0
let reconnectTimer = null
let connecting = false
let stopping = false
const groupNames = new Map()

// Baileys timestamps arrive as number | Long | string depending on where in the
// protocol they came from.
function toTs(value) {
  if (value === null || value === undefined) return 0
  if (typeof value === 'number') return Math.floor(value)
  if (typeof value === 'string') return Math.floor(Number(value) || 0)
  if (typeof value.toNumber === 'function') return Math.floor(value.toNumber())
  if (typeof value.low === 'number') return Math.floor(value.low)
  return 0
}

function state() {
  return {
    t: 'state',
    connection,
    needsLogin,
    hasQr,
    qrVersion,
    qrPng: hasQr ? currentQrPng : '',
    pairingStopped,
    linked: !!creds?.registered,
    me: store.me,
    unread: store.totalUnread(),
    lastError,
    daemonPid: process.pid
  }
}

function snapshot() {
  return { ...state(), t: 'state', chats: store.chatList(60) }
}

function pushState() {
  bus.broadcast(state())
}

function pushChats(limit = 60) {
  bus.broadcast({ t: 'chats', chats: store.chatList(limit), unread: store.totalUnread() })
}

function senderNameFor(chatJid, message) {
  if (message.key?.fromMe) return store.me?.name || 'You'
  const participant = message.key?.participant || message.participant
  if (isGroupJid(chatJid) && participant) {
    return store.names.get(jidNormalizedUser(participant))
      || message.pushName
      || prettyJid(participant)
  }
  return store.names.get(chatJid) || message.pushName || prettyJid(chatJid)
}

// Convert a raw Baileys message into the flat shape the panel renders and the
// store persists.
function flatten(chatJid, message) {
  const ts = toTs(message.messageTimestamp)
  return {
    id: message.key?.id || `${ts}-${Math.random().toString(36).slice(2, 8)}`,
    ts,
    fromMe: !!message.key?.fromMe,
    text: messageText(message.message),
    type: messageType(message.message),
    senderName: senderNameFor(chatJid, message),
    senderJid: message.key?.participant ? jidNormalizedUser(message.key.participant) : '',
    status: typeof message.status === 'number' ? message.status : 0,
    key: {
      remoteJid: message.key?.remoteJid || chatJid,
      id: message.key?.id || '',
      fromMe: !!message.key?.fromMe,
      participant: message.key?.participant || undefined
    }
  }
}

async function resolveGroupName(jid) {
  if (!isGroupJid(jid) || groupNames.has(jid) || !sock) return
  groupNames.set(jid, true)
  try {
    const metadata = await sock.groupMetadata(jid)
    if (metadata?.subject) {
      store.rememberName(jid, metadata.subject)
      pushChats()
    }
  } catch (err) {
    logger.debug({ err, jid }, 'group metadata lookup failed')
  }
}

function ingest(chatJid, raw, { live }) {
  if (isIgnorableChat(chatJid)) return null
  if (isSilent(raw.message)) return null

  const message = flatten(chatJid, raw)
  if (!message.ts) message.ts = Math.floor(Date.now() / 1000)

  store.upsertMessage(chatJid, message)
  const chat = store.touchChat(chatJid, message)
  if (!chat.isGroup) store.rememberName(chatJid, raw.pushName || store.names.get(chatJid) || '')
  resolveGroupName(chatJid)

  if (live && !message.fromMe) {
    store.bumpUnread(chatJid)
    if (message.ts >= startedAt) {
      const title = chat.isGroup ? (chat.name || 'Group') : (message.senderName || chat.name)
      const body = chat.isGroup ? `${message.senderName}: ${message.text}` : message.text
      notifier.queue({ jid: chatJid, title, body, muted: !!chat.muted })
    }
  }

  return message
}

function applyChatMetadata(rawChats) {
  for (const raw of rawChats || []) {
    const jid = raw?.id
    if (!jid || isIgnorableChat(jid)) continue
    const chat = store.chat(jid)
    if (raw.name) {
      store.rememberName(jid, raw.name)
      chat.name = raw.name
      chat.nameLocked = true
    }
    if (typeof raw.unreadCount === 'number') chat.unread = Math.max(0, raw.unreadCount)
    if (raw.conversationTimestamp !== undefined) {
      const ts = toTs(raw.conversationTimestamp)
      if (ts > (chat.lastTs || 0)) chat.lastTs = ts
    }
    if (raw.archived !== undefined) chat.archived = !!raw.archived
    if (raw.pinned !== undefined) chat.pinned = !!raw.pinned
    if (raw.muteEndTime !== undefined) {
      const until = toTs(raw.muteEndTime)
      chat.muted = until > Math.floor(Date.now() / 1000)
    }
  }
  store.markDirty()
}

function applyContacts(contacts) {
  for (const contact of contacts || []) {
    if (!contact?.id) continue
    const name = contact.name || contact.verifiedName || contact.notify
    if (name) store.rememberName(jidNormalizedUser(contact.id), name)
  }
}

// Open a pairing window. Every QR the daemon shows is counted against it, so an
// unlinked account cannot keep the pairing endpoint busy indefinitely.
function startPairing(reason) {
  pairingStopped = false
  pairingStartedAt = Date.now()
  qrCount = 0
  logger.info({ reason }, 'pairing: window open')
}

// Stop refreshing and drop the QR rather than leave an expired code on screen
// pretending to be scannable. The panel's "Show QR code" button and
// `omarchy-whatsapp login` both reopen the window.
function stopPairing() {
  pairingStopped = true
  clearQr()
  connection = 'idle'
  needsLogin = true
  logger.info({ qrCount }, 'pairing: no scan within the window, pausing QR refresh')
  pushState()
  try {
    sock?.end(new Error('pairing paused'))
  } catch {
    // Already closed.
  }
}

async function writeQr(qr) {
  if (pairingStopped) return
  if (pairingStartedAt === 0) startPairing('first qr')

  qrCount += 1
  if (qrCount > MAX_QR_PER_PAIRING || Date.now() - pairingStartedAt > PAIRING_WINDOW_MS) {
    stopPairing()
    return
  }

  const version = qrVersion + 1
  const target = qrPngFileFor(version)
  try {
    await QRCode.toFile(target, qr, { margin: 2, width: 512, color: { dark: '#000000ff', light: '#ffffffff' } })
    // A readable QR is a linkable account, so keep it owner-only even though
    // the state directory is already 0700.
    chmodSync(target, 0o600)
    const terminal = await QRCode.toString(qr, { type: 'terminal', small: true })
    writeFileSync(qrTxtFile, terminal, { mode: 0o600 })
    if (PRINT_QR) process.stdout.write(`\n${terminal}\n`)

    const previous = currentQrPng
    currentQrPng = target
    hasQr = true
    qrVersion = version
    connection = 'qr'
    needsLogin = true
    pushState()
    if (previous && previous !== target) removeFile(previous)
    logger.info('login: scan the QR from the WhatsApp bar panel or run `omarchy-whatsapp login`')
  } catch (err) {
    logger.error({ err }, 'login: could not render QR')
  }
}

function removeFile(path) {
  try {
    unlinkSync(path)
  } catch {
    // Nothing to clear.
  }
}

function clearQr() {
  hasQr = false
  if (currentQrPng) removeFile(currentQrPng)
  currentQrPng = ''
  removeFile(qrTxtFile)
}

// `delayOverride` covers the disconnects that are part of normal operation
// (QR batch ended, post-pair restart). Those must not consume the backoff
// budget reserved for genuine network trouble.
function scheduleReconnect(delayOverride, options) {
  if (stopping || pairingStopped || reconnectTimer) return
  const countsAsFailure = !options || options.countsAsFailure !== false
  const delay = delayOverride !== undefined
    ? delayOverride
    : Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * 2 ** Math.min(reconnectAttempts, 5))
  if (countsAsFailure) reconnectAttempts += 1
  logger.info({ delay, reason: options?.reason || 'failure' }, 'connection: reconnecting')
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    connect().catch((err) => {
      logger.error({ err }, 'connection: reconnect failed')
      scheduleReconnect()
    })
  }, delay)
  reconnectTimer.unref?.()
}

async function connect() {
  if (connecting || stopping) return
  connecting = true
  connection = 'connecting'
  lastError = ''
  pushState()

  try {
    const { state: authState, saveCreds } = await useMultiFileAuthState(authDir)
    creds = authState.creds
    const { version } = await fetchLatestBaileysVersion().catch(() => ({ version: undefined }))

    sock = makeWASocket({
      version,
      auth: {
        creds: authState.creds,
        keys: makeCacheableSignalKeyStore(authState.keys, waLogger)
      },
      logger: waLogger,
      // The phone keeps pushing its own notifications while this device stays
      // "offline", so the user never loses phone alerts by linking Omarchy.
      markOnlineOnConnect: false,
      browser: Browsers.ubuntu('Omarchy'),
      syncFullHistory: false,
      generateHighQualityLinkPreview: false,
      // Link previews and media thumbnails are never rendered here.
      shouldSyncHistoryMessage: () => true
    })

    sock.ev.on('creds.update', saveCreds)

    sock.ev.on('connection.update', (update) => {
      const { connection: next, lastDisconnect, qr } = update
      if (qr) writeQr(qr)

      if (next === 'open') {
        connection = 'open'
        needsLogin = false
        pairingStopped = false
        pairingStartedAt = 0
        qrCount = 0
        reconnectAttempts = 0
        lastError = ''
        clearQr()
        const user = sock.user
        store.me = user
          ? { id: jidNormalizedUser(user.id), name: user.name || user.verifiedName || prettyJid(user.id) }
          : null
        store.markDirty()
        logger.info({ me: store.me?.id }, 'connection: open')
        pushState()
        pushChats()
        return
      }

      if (next === 'close') {
        const statusCode = lastDisconnect?.error?.output?.statusCode
        lastError = lastDisconnect?.error?.message || ''
        connection = 'close'
        connecting = false

        if (statusCode === DisconnectReason.loggedOut) {
          // 401 means two very different things. If this device was actually
          // paired, the phone unlinked it and the credentials are dead. If it
          // was never paired, the server merely rejected this pairing attempt —
          // wiping there would throw away the chat cache for nothing.
          if (creds?.registered) {
            logger.warn('connection: device unlinked from the phone, clearing credentials')
            wipeAuth()
            needsLogin = true
            startPairing('device unlinked')
            pushState()
            connect().catch((err) => logger.error({ err }, 'connection: relogin failed'))
          } else {
            logger.warn('connection: pairing attempt rejected, retrying')
            needsLogin = true
            pushState()
            scheduleReconnect(PAIRING_RETRY_MS, { reason: 'pairing rejected', countsAsFailure: false })
          }
          return
        }

        if (pairingStopped) {
          // Stay 'idle' rather than 'close': nothing is retrying, so reporting a
          // closed connection would read as a fault instead of a paused pairing.
          connection = 'idle'
          pushState()
          return
        }

        // Both of these are routine, not faults.
        if (statusCode === DisconnectReason.restartRequired) {
          logger.info('connection: restart required, reconnecting immediately')
          pushState()
          scheduleReconnect(RESTART_RETRY_MS, { reason: 'restart required', countsAsFailure: false })
          return
        }

        if (needsLogin && statusCode === DisconnectReason.timedOut) {
          // Baileys uses 408 for both "QR refs ended" and "connection lost";
          // while unlinked and mid-pairing it is always the former.
          logger.info('connection: QR batch ended, requesting a fresh one')
          pushState()
          scheduleReconnect(PAIRING_RETRY_MS, { reason: 'qr batch ended', countsAsFailure: false })
          return
        }

        logger.warn({ statusCode, lastError }, 'connection: closed')
        pushState()
        scheduleReconnect()
      }
    })

    sock.ev.on('messaging-history.set', ({ chats, contacts, messages, isLatest }) => {
      applyContacts(contacts)
      applyChatMetadata(chats)
      for (const raw of messages || []) {
        const jid = raw?.key?.remoteJid
        if (jid) ingest(jid, raw, { live: false })
      }
      logger.info({ chats: chats?.length || 0, messages: messages?.length || 0, isLatest }, 'history sync')
      pushChats()
      pushState()
    })

    sock.ev.on('chats.upsert', (chats) => {
      applyChatMetadata(chats)
      pushChats()
    })

    sock.ev.on('chats.update', (updates) => {
      applyChatMetadata(updates)
      pushChats()
      pushState()
    })

    sock.ev.on('chats.delete', (jids) => {
      for (const jid of jids || []) {
        store.chats.delete(jid)
        store.messages.delete(jid)
      }
      store.markDirty()
      pushChats()
      pushState()
    })

    sock.ev.on('contacts.upsert', (contacts) => {
      applyContacts(contacts)
      pushChats()
    })

    sock.ev.on('contacts.update', (contacts) => {
      applyContacts(contacts)
      pushChats()
    })

    sock.ev.on('groups.update', (updates) => {
      for (const update of updates || []) {
        if (update?.id && update.subject) store.rememberName(update.id, update.subject)
      }
      pushChats()
    })

    sock.ev.on('messages.upsert', ({ messages, type }) => {
      const live = type === 'notify'
      for (const raw of messages || []) {
        const jid = raw?.key?.remoteJid
        if (!jid) continue
        const message = ingest(jid, raw, { live })
        if (!message) continue
        bus.broadcast({
          t: 'message',
          jid,
          message,
          chat: store.chat(jid),
          unread: store.totalUnread()
        })
      }
      pushChats()
      pushState()
    })

    sock.ev.on('messages.update', (updates) => {
      for (const update of updates || []) {
        const jid = update?.key?.remoteJid
        const id = update?.key?.id
        if (!jid || !id) continue
        const list = store.messages.get(jid)
        if (!list) continue
        const found = list.find((m) => m.id === id)
        if (!found) continue
        const status = update.update?.status
        if (typeof status === 'number') {
          found.status = status
          store.markDirty()
          bus.broadcast({ t: 'messageStatus', jid, id, status })
        }
      }
    })

    connecting = false
  } catch (err) {
    connecting = false
    lastError = String(err?.message || err)
    logger.error({ err }, 'connection: setup failed')
    pushState()
    scheduleReconnect()
  }
}

function wipeAuth() {
  try {
    rmSync(authDir, { recursive: true, force: true })
  } catch (err) {
    logger.warn({ err }, 'auth: wipe failed')
  }
  ensureDirs()
  store.clear()
  groupNames.clear()
}

// Mark a chat read on this device and across the account, then drop any toast
// still waiting in the coalesce window.
async function markRead(jid) {
  notifier.cancel(jid)
  store.setUnread(jid, 0)
  pushChats()
  pushState()
  if (!sock || connection !== 'open') return

  const list = store.messages.get(jid) || []
  const unreadKeys = list.filter((m) => !m.fromMe).slice(-20).map((m) => m.key).filter((k) => k?.id)
  if (unreadKeys.length) {
    try {
      await sock.readMessages(unreadKeys)
    } catch (err) {
      logger.debug({ err, jid }, 'read receipts failed')
    }
  }

  const newest = list[list.length - 1]
  if (newest?.key?.id) {
    try {
      await sock.chatModify(
        { markRead: true, lastMessages: [{ key: newest.key, messageTimestamp: newest.ts }] },
        jid
      )
    } catch (err) {
      logger.debug({ err, jid }, 'chatModify markRead failed')
    }
  }
}

async function handleCommand(payload, reply) {
  const { t, id } = payload
  switch (t) {
    case 'hello':
      reply(snapshot())
      return

    case 'ping':
      reply({ t: 'pong', id })
      return

    case 'chats':
      reply({ t: 'chats', chats: store.chatList(payload.limit || 60), unread: store.totalUnread() })
      return

    case 'messages':
      if (!payload.jid) throw new Error('messages: jid required')
      reply({
        t: 'messages',
        jid: payload.jid,
        chat: store.chat(payload.jid),
        messages: store.messageList(payload.jid, payload.limit || 60)
      })
      return

    case 'send': {
      const jid = payload.jid
      const text = String(payload.text || '')
      if (!jid) throw new Error('send: jid required')
      if (!text.trim()) throw new Error('send: empty message')
      if (!sock || connection !== 'open') throw new Error('send: not connected to WhatsApp')

      const options = {}
      if (payload.quoted) {
        const list = store.messages.get(jid) || []
        const quoted = list.find((m) => m.id === payload.quoted)
        // Baileys needs the original envelope to quote; the flattened copy only
        // keeps the key, which is enough for a reply stanza.
        if (quoted?.key) options.quoted = { key: quoted.key, message: { conversation: quoted.text } }
      }

      const sent = await sock.sendMessage(jid, { text }, options)
      if (sent) {
        const message = ingest(jid, sent, { live: false })
        if (message) {
          bus.broadcast({ t: 'message', jid, message, chat: store.chat(jid), unread: store.totalUnread() })
          pushChats()
        }
      }
      reply({ t: 'ack', id, ok: true, jid })
      return
    }

    case 'read':
      if (!payload.jid) throw new Error('read: jid required')
      await markRead(payload.jid)
      reply({ t: 'ack', id, ok: true, jid: payload.jid })
      return

    case 'typing': {
      if (!payload.jid || !sock || connection !== 'open') {
        reply({ t: 'ack', id, ok: false })
        return
      }
      const presence = payload.state === 'paused' ? 'paused' : 'composing'
      try {
        await sock.sendPresenceUpdate(presence, payload.jid)
      } catch (err) {
        logger.debug({ err }, 'presence update failed')
      }
      reply({ t: 'ack', id, ok: true })
      return
    }

    // Notification clicks land here: the daemon is already the fan-out point to
    // every bar panel, so it tells them which chat to open.
    case 'focus':
      if (!payload.jid) throw new Error('focus: jid required')
      bus.broadcast({ t: 'focus', jid: payload.jid })
      reply({ t: 'ack', id, ok: true, jid: payload.jid })
      return

    case 'pair': {
      const phone = String(payload.phone || '').replace(/[^\d]/g, '')
      if (!phone) throw new Error('pair: phone number required')
      if (!sock) throw new Error('pair: socket not ready')
      const code = await sock.requestPairingCode(phone)
      reply({ t: 'pairCode', id, code })
      return
    }

    case 'reconnect':
      reconnectAttempts = 0
      startPairing('manual reconnect')
      try {
        sock?.end(new Error('manual reconnect'))
      } catch {
        // Socket was already dead.
      }
      connecting = false
      await connect()
      reply({ t: 'ack', id, ok: true })
      return

    case 'logout':
      try {
        await sock?.logout()
      } catch (err) {
        logger.debug({ err }, 'logout call failed, clearing local state anyway')
      }
      wipeAuth()
      needsLogin = true
      startPairing('logout')
      connection = 'close'
      pushState()
      pushChats()
      connecting = false
      await connect()
      reply({ t: 'ack', id, ok: true })
      return

    default:
      reply({ t: 'error', for: String(t || ''), id, message: `unknown command: ${t}` })
  }
}

function shutdown(signal) {
  if (stopping) return
  stopping = true
  logger.info({ signal }, 'shutting down')
  notifier.cancelAll()
  store.persist()
  bus.close()
  try {
    sock?.end(new Error('shutdown'))
  } catch {
    // Already closed.
  }
  setTimeout(() => process.exit(0), 200).unref?.()
}

// A killed daemon leaves versioned QR images behind. They are useless to the
// next run and each one can link the account, so clear them at startup.
function purgeStaleQrFiles() {
  try {
    for (const name of readdirSync(stateDir)) {
      if (/^qr\.\d+\.png$/.test(name)) removeFile(join(stateDir, name))
    }
  } catch (err) {
    logger.debug({ err }, 'startup: could not purge stale QR files')
  }
}

async function main() {
  ensureDirs()
  purgeStaleQrFiles()
  store.load()

  bus.snapshot = snapshot
  bus.onCommand = handleCommand
  try {
    await bus.listen()
  } catch (err) {
    if (err.code === 'EALREADYRUNNING') {
      logger.error(err.message)
      process.exit(3)
    }
    throw err
  }

  startPairing('daemon start')

  // The window is otherwise only tested when the next QR arrives, and WhatsApp's
  // first ref lives for a minute, so the pause would land late.
  const pairingWatchdog = setInterval(() => {
    if (stopping || pairingStopped) return
    if (!needsLogin || connection === 'open') return
    if (pairingStartedAt === 0) return
    if (Date.now() - pairingStartedAt > PAIRING_WINDOW_MS) stopPairing()
  }, 5000)
  pairingWatchdog.unref?.()

  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => shutdown(signal))
  process.on('uncaughtException', (err) => logger.error({ err }, 'uncaught exception'))
  process.on('unhandledRejection', (err) => logger.error({ err }, 'unhandled rejection'))

  await connect()
}

main().catch((err) => {
  logger.error({ err }, 'daemon failed to start')
  process.exit(1)
})
