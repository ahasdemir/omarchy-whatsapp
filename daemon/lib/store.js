import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs'
import { storeFile } from './paths.js'
import { logger } from './logger.js'
import { isGroupJid, prettyJid } from './message.js'

const MAX_MESSAGES_PER_CHAT = 200
const MAX_CHATS = 300
const PERSIST_DEBOUNCE_MS = 2000

export function normalizeJid(jid) {
  if (!jid) return ''
  const [user, server] = String(jid).split('@')
  if (!user) return String(jid)
  const bare = user.split(':')[0]
  return server ? `${bare}@${server}` : bare
}

export function isPlaceholderName(name) {
  if (!name) return true
  const value = String(name).trim()
  if (!value || value === 'Group' || value === 'Unknown') return true
  if (/^[+]?[\d\s-]{6,}$/.test(value)) return true
  return false
}

// In-memory chat/message state with a JSON snapshot on disk. Baileys ships no
// store since v6, and the panel needs something to render the instant it
// connects — before (or without) a fresh history sync.
export class Store {
  constructor() {
    /** @type {Map<string, object>} */
    this.chats = new Map()
    /** @type {Map<string, object[]>} */
    this.messages = new Map()
    /** @type {Map<string, string>} */
    this.names = new Map()
    /** @type {Map<string, string>} */
    this.aliases = new Map()
    this.me = null
    this._persistTimer = null
    this._dirty = false
  }

  load() {
    let raw
    try {
      raw = readFileSync(storeFile, 'utf8')
    } catch (err) {
      if (err.code !== 'ENOENT') logger.warn({ err }, 'store: unreadable snapshot, starting empty')
      return
    }
    try {
      const data = JSON.parse(raw)
      for (const chat of data.chats || []) if (chat?.jid) this.chats.set(chat.jid, chat)
      for (const [jid, list] of Object.entries(data.messages || {})) {
        if (Array.isArray(list)) this.messages.set(jid, list.slice(-MAX_MESSAGES_PER_CHAT))
      }
      for (const [jid, name] of Object.entries(data.names || {})) this.names.set(jid, name)
      for (const [from, to] of Object.entries(data.aliases || {})) this.aliases.set(from, to)
      this.me = data.me || null
      for (const list of this.messages.values()) {
        for (const message of list) {
          if (message.imagePath && !existsSync(message.imagePath)) message.imagePath = ''
        }
      }
      this.applyNamesToChats()
      for (const chat of this.chats.values()) {
        if (String(chat.jid).endsWith('@lid') && isPlaceholderName(chat.name)) {
          chat.name = prettyJid(chat.jid)
        }
      }
      logger.info({ chats: this.chats.size, names: this.names.size }, 'store: snapshot loaded')
    } catch (err) {
      logger.warn({ err }, 'store: corrupt snapshot, starting empty')
    }
  }

  markDirty() {
    this._dirty = true
    if (this._persistTimer) return
    this._persistTimer = setTimeout(() => {
      this._persistTimer = null
      this.persist()
    }, PERSIST_DEBOUNCE_MS)
    this._persistTimer.unref?.()
  }

  persist() {
    if (!this._dirty) return
    this._dirty = false
    const chats = this.sortedChats().slice(0, MAX_CHATS)
    const messages = {}
    for (const chat of chats) {
      const list = this.messages.get(chat.jid)
      if (list?.length) messages[chat.jid] = list.slice(-MAX_MESSAGES_PER_CHAT)
    }
    const payload = {
      version: 2,
      me: this.me,
      chats,
      messages,
      names: Object.fromEntries(this.names),
      aliases: Object.fromEntries(this.aliases)
    }
    const tmp = `${storeFile}.tmp`
    try {
      // Write-then-rename: a crash mid-write leaves the previous snapshot
      // intact instead of a half-written file the next start cannot parse.
      writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 })
      renameSync(tmp, storeFile)
    } catch (err) {
      logger.warn({ err }, 'store: snapshot write failed')
    }
  }

  rememberName(jid, name) {
    if (!jid || !name) return false
    const key = normalizeJid(jid)
    const clean = String(name).trim().replace(/[\u200e\u200f\u202a-\u202e]/g, '')
    if (!key || !clean) return false

    const existing = this.names.get(key)
    if (existing === clean) {
      this._applyName(key, clean)
      return false
    }
    if (existing && !isPlaceholderName(existing) && isPlaceholderName(clean)) return false

    this.names.set(key, clean)
    const aliased = this.aliases.get(key)
    if (aliased && (isPlaceholderName(this.names.get(aliased)) || !this.names.get(aliased))) {
      this.names.set(aliased, clean)
    }
    this._applyName(key, clean)
    if (aliased) this._applyName(aliased, clean)
    this.markDirty()
    return true
  }

  alias(a, b) {
    const left = normalizeJid(a)
    const right = normalizeJid(b)
    if (!left || !right || left === right) return false
    if (this.aliases.get(left) === right && this.aliases.get(right) === left) return false
    this.aliases.set(left, right)
    this.aliases.set(right, left)
    const name = this.lookupName(left) || this.lookupName(right)
    if (name) {
      this.rememberName(left, name)
      this.rememberName(right, name)
    }
    this.markDirty()
    return true
  }

  lookupName(jid) {
    const key = normalizeJid(jid)
    if (!key) return ''
    return this.names.get(key) || this.names.get(this.aliases.get(key) || '') || ''
  }

  displayName(jid) {
    return this.lookupName(jid) || prettyJid(jid)
  }

  _applyName(jid, name) {
    const chat = this.chats.get(jid)
    if (!chat) return
    if (chat.nameLocked && !isPlaceholderName(chat.name)) return
    if (chat.name === name) return
    chat.name = name
    if (!isPlaceholderName(name)) chat.nameLocked = false
  }

  applyNamesToChats() {
    let changed = false
    for (const chat of this.chats.values()) {
      const resolved = this.lookupName(chat.jid)
      if (!resolved) continue
      if (chat.name === resolved) continue
      if (chat.nameLocked && !isPlaceholderName(chat.name)) continue
      chat.name = resolved
      changed = true
    }
    if (changed) this.markDirty()
    return changed
  }

  chat(jid) {
    const key = normalizeJid(jid) || jid
    let chat = this.chats.get(key)
    if (!chat) {
      chat = {
        jid: key,
        name: this.displayName(key),
        isGroup: isGroupJid(key),
        unread: 0,
        muted: false,
        archived: false,
        pinned: false,
        lastTs: 0,
        lastText: '',
        lastFromMe: false,
        lastSender: ''
      }
      this.chats.set(key, chat)
      this.markDirty()
    } else if (isPlaceholderName(chat.name)) {
      const resolved = this.lookupName(key)
      if (resolved && resolved !== chat.name) chat.name = resolved
    }
    return chat
  }

  // Insert or replace a message, keeping each chat's list sorted by timestamp
  // so out-of-order delivery (history sync racing live traffic) still renders
  // in the right order.
  upsertMessage(jid, message) {
    const key = normalizeJid(jid) || jid
    const list = this.messages.get(key) || this.messages.get(jid) || []
    const existing = list.findIndex((m) => m.id === message.id)
    if (existing !== -1) {
      list[existing] = { ...list[existing], ...message }
    } else {
      list.push(message)
      list.sort((a, b) => a.ts - b.ts)
      if (list.length > MAX_MESSAGES_PER_CHAT) list.splice(0, list.length - MAX_MESSAGES_PER_CHAT)
    }
    this.messages.set(key, list)
    this.markDirty()
    return list
  }

  // A chat's preview line only moves forward in time, so a late history-sync
  // message can never overwrite the newest one the user just received.
  touchChat(jid, message) {
    const chat = this.chat(jid)
    if (message.ts >= (chat.lastTs || 0)) {
      chat.lastTs = message.ts
      chat.lastText = message.text
      chat.lastFromMe = !!message.fromMe
      chat.lastSender = message.senderName || ''
    }
    this.markDirty()
    return chat
  }

  setUnread(jid, count) {
    const chat = this.chat(jid)
    const next = Math.max(0, count | 0)
    if (chat.unread === next) return chat
    chat.unread = next
    this.markDirty()
    return chat
  }

  bumpUnread(jid) {
    const chat = this.chat(jid)
    chat.unread = (chat.unread || 0) + 1
    this.markDirty()
    return chat
  }

  totalUnread() {
    let total = 0
    for (const chat of this.chats.values()) {
      if (chat.muted) continue
      total += Math.max(0, chat.unread || 0)
    }
    return total
  }

  sortedChats() {
    return [...this.chats.values()]
      .filter((chat) => chat.lastTs > 0 || chat.unread > 0)
      .sort((a, b) => {
        if (!!b.pinned !== !!a.pinned) return b.pinned ? 1 : -1
        return (b.lastTs || 0) - (a.lastTs || 0)
      })
  }

  chatList(limit = 40) {
    return this.sortedChats().slice(0, Math.max(1, limit))
  }

  messageList(jid, limit = 60) {
    const list = this.messages.get(normalizeJid(jid) || jid) || this.messages.get(jid) || []
    return list.slice(-Math.max(1, limit))
  }

  findMessage(jid, id) {
    if (!id) return null
    const keys = [jid, normalizeJid(jid), this.aliases.get(normalizeJid(jid) || jid)].filter(Boolean)
    for (const key of keys) {
      const list = this.messages.get(key)
      const found = list?.find((m) => m.id === id)
      if (found) return found
    }
    for (const list of this.messages.values()) {
      const found = list.find((m) => m.id === id)
      if (found) return found
    }
    return null
  }

  clear() {
    this.chats.clear()
    this.messages.clear()
    this.names.clear()
    this.aliases.clear()
    this.me = null
    this._dirty = true
    this.persist()
  }
}
