import { readFileSync, writeFileSync, renameSync } from 'node:fs'
import { storeFile } from './paths.js'
import { logger } from './logger.js'
import { isGroupJid, prettyJid } from './message.js'

const MAX_MESSAGES_PER_CHAT = 200
const MAX_CHATS = 300
const PERSIST_DEBOUNCE_MS = 2000

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
      this.me = data.me || null
      logger.info({ chats: this.chats.size }, 'store: snapshot loaded')
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
      version: 1,
      me: this.me,
      chats,
      messages,
      names: Object.fromEntries(this.names)
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
    if (!jid || !name) return
    const clean = String(name).trim()
    if (!clean) return
    if (this.names.get(jid) === clean) return
    this.names.set(jid, clean)
    const chat = this.chats.get(jid)
    if (chat && !chat.nameLocked) {
      chat.name = clean
      this.markDirty()
    }
  }

  displayName(jid) {
    return this.names.get(jid) || prettyJid(jid)
  }

  chat(jid) {
    let chat = this.chats.get(jid)
    if (!chat) {
      chat = {
        jid,
        name: this.displayName(jid),
        isGroup: isGroupJid(jid),
        unread: 0,
        muted: false,
        archived: false,
        pinned: false,
        lastTs: 0,
        lastText: '',
        lastFromMe: false,
        lastSender: ''
      }
      this.chats.set(jid, chat)
      this.markDirty()
    }
    return chat
  }

  // Insert or replace a message, keeping each chat's list sorted by timestamp
  // so out-of-order delivery (history sync racing live traffic) still renders
  // in the right order.
  upsertMessage(jid, message) {
    const list = this.messages.get(jid) || []
    const existing = list.findIndex((m) => m.id === message.id)
    if (existing !== -1) {
      list[existing] = { ...list[existing], ...message }
    } else {
      list.push(message)
      list.sort((a, b) => a.ts - b.ts)
      if (list.length > MAX_MESSAGES_PER_CHAT) list.splice(0, list.length - MAX_MESSAGES_PER_CHAT)
    }
    this.messages.set(jid, list)
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
    const list = this.messages.get(jid) || []
    return list.slice(-Math.max(1, limit))
  }

  clear() {
    this.chats.clear()
    this.messages.clear()
    this.names.clear()
    this.me = null
    this._dirty = true
    this.persist()
  }
}
