import { homedir } from 'node:os'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'

const home = homedir()

function envDir(name, fallback) {
  const value = process.env[name]
  return value && value.startsWith('/') ? value : fallback
}

// State lives under XDG_STATE_HOME so credentials survive reboots but stay out
// of the config tree the plugin installer overwrites.
export const stateDir = envDir(
  'OMARCHY_WHATSAPP_STATE',
  join(envDir('XDG_STATE_HOME', join(home, '.local', 'state')), 'omarchy-whatsapp')
)

export const authDir = join(stateDir, 'auth')
export const storeFile = join(stateDir, 'store.json')
export const qrTxtFile = join(stateDir, 'qr.txt')
export const pidFile = join(stateDir, 'daemon.pid')
export const mediaDir = envDir(
  'OMARCHY_WHATSAPP_MEDIA',
  join(envDir('XDG_CACHE_HOME', join(home, '.cache')), 'omarchy-whatsapp', 'media')
)

// The QR is rewritten every ~20s while pairing. A versioned filename means the
// panel's Image source URL actually changes, so it refetches without any
// imperative cache-busting on the QML side.
export function qrPngFileFor(version) {
  return join(stateDir, `qr.${version}.png`)
}

// The socket goes in the runtime dir: tmpfs, 0700, and cleared on logout, so a
// stale socket never outlives the session that owned it.
export const socketPath = process.env.OMARCHY_WHATSAPP_SOCKET
  || join(envDir('XDG_RUNTIME_DIR', join('/run/user', String(process.getuid()))), 'omarchy-whatsapp.sock')

export function ensureDirs() {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 })
  mkdirSync(authDir, { recursive: true, mode: 0o700 })
  mkdirSync(mediaDir, { recursive: true, mode: 0o700 })
}
