import pino from 'pino'

// stderr only: systemd captures it into the journal, and stdout stays free for
// the QR fallback that `omarchy-whatsapp login` prints.
export const logger = pino(
  { level: process.env.OMARCHY_WHATSAPP_LOG_LEVEL || 'info' },
  pino.destination(2)
)

// Baileys is extremely chatty at info level; give it its own quieter child.
export const waLogger = logger.child({ mod: 'baileys' })
waLogger.level = process.env.OMARCHY_WHATSAPP_WA_LOG_LEVEL || 'error'
