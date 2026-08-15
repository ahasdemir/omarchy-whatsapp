import { getContentType, normalizeMessageContent, isJidGroup, isJidStatusBroadcast } from 'baileys'

// Glyphs stand in for media we do not download. They read the same in the bar
// panel and in a notification body.
const MEDIA_LABELS = {
  imageMessage: 'Photo',
  videoMessage: 'Video',
  audioMessage: 'Audio',
  documentMessage: 'Document',
  documentWithCaptionMessage: 'Document',
  stickerMessage: 'Sticker',
  contactMessage: 'Contact',
  contactsArrayMessage: 'Contacts',
  locationMessage: 'Location',
  liveLocationMessage: 'Live location',
  pollCreationMessage: 'Poll',
  pollCreationMessageV2: 'Poll',
  pollCreationMessageV3: 'Poll',
  productMessage: 'Product',
  paymentInviteMessage: 'Payment request',
  eventMessage: 'Event',
  ptvMessage: 'Video note'
}

// Nerd Font glyphs, not Unicode emoji: the bar and panel render in the shell's
// monospace font, which has the Nerd Font patch but no color emoji, so emoji
// land as tofu boxes.
const MEDIA_ICONS = {
  imageMessage: '\uf03e',
  videoMessage: '\uf03d',
  audioMessage: '\uf001',
  documentMessage: '\uf15c',
  documentWithCaptionMessage: '\uf15c',
  stickerMessage: '\uf118',
  contactMessage: '\uf007',
  contactsArrayMessage: '\uf0c0',
  locationMessage: '\uf041',
  liveLocationMessage: '\uf041',
  pollCreationMessage: '\uf080',
  pollCreationMessageV2: '\uf080',
  pollCreationMessageV3: '\uf080',
  productMessage: '\uf07a',
  paymentInviteMessage: '\uf155',
  eventMessage: '\uf073',
  ptvMessage: '\uf03d'
}

const VOICE_ICON = '\uf130'

// Message kinds that carry no user-visible content: keys rotating, receipts,
// history sync notifications, and app-state fanout.
const SILENT_TYPES = new Set([
  'protocolMessage',
  'senderKeyDistributionMessage',
  'messageContextInfo',
  'deviceSentMessage',
  'reactionMessage',
  'pollUpdateMessage',
  'keepInChatMessage',
  'stickerSyncRmrMessage',
  'encReactionMessage'
])

export function messageType(message) {
  const content = normalizeMessageContent(message)
  if (!content) return ''
  return getContentType(content) || ''
}

// Flatten a Baileys message into the single preview line the panel and the
// notification both want. Media becomes "<icon> Photo" or "<icon> caption".
export function messageText(message) {
  const content = normalizeMessageContent(message)
  if (!content) return ''

  if (typeof content.conversation === 'string' && content.conversation) return content.conversation
  if (content.extendedTextMessage?.text) return content.extendedTextMessage.text

  const type = getContentType(content)
  if (!type) return ''

  if (type === 'reactionMessage') {
    const emoji = content.reactionMessage?.text || ''
    return emoji ? `Reacted ${emoji}` : 'Removed a reaction'
  }

  if (type === 'documentWithCaptionMessage') {
    const inner = content.documentWithCaptionMessage?.message?.documentMessage
    const caption = inner?.caption || inner?.title || inner?.fileName
    return prefixed('documentMessage', caption)
  }

  const node = content[type]
  if (node && typeof node === 'object') {
    const caption = node.caption || node.title || node.fileName || node.displayName || node.name
    if (typeof caption === 'string' && caption) return prefixed(type, caption)
    if (type === 'audioMessage' && node.ptt) return `${VOICE_ICON} Voice message`
    if (type === 'pollCreationMessage' || type === 'pollCreationMessageV2' || type === 'pollCreationMessageV3') {
      return prefixed(type, node.name)
    }
  }

  if (MEDIA_LABELS[type]) return prefixed(type, '')
  if (SILENT_TYPES.has(type)) return ''
  return ''
}

function prefixed(type, text) {
  const icon = MEDIA_ICONS[type] || ''
  const label = text || MEDIA_LABELS[type] || ''
  if (!label) return icon
  return icon ? `${icon} ${label}` : label
}

// True when the message is bookkeeping the user never sees, so it must not
// bump a chat's preview line, unread count, or fire a notification.
export function isSilent(message) {
  const content = normalizeMessageContent(message)
  if (!content) return true
  const type = getContentType(content)
  if (!type) return true
  if (SILENT_TYPES.has(type)) return true
  return messageText(message) === ''
}

export function isGroupJid(jid) {
  return isJidGroup(jid) === true
}

// Status updates and newsletter/channel traffic are noise for a bar widget.
export function isIgnorableChat(jid) {
  if (!jid) return true
  if (isJidStatusBroadcast(jid)) return true
  if (jid.endsWith('@newsletter')) return true
  if (jid === 'status@broadcast') return true
  return false
}

// `1234567890@s.whatsapp.net` -> `+1234567890`, so an unknown sender still
// shows something dialable instead of a raw jid.
export function prettyJid(jid) {
  if (!jid) return ''
  const user = String(jid).split('@')[0].split(':')[0]
  if (!user) return String(jid)
  if (isGroupJid(jid)) return 'Group'
  return /^\d{6,}$/.test(user) ? `+${user}` : user
}
