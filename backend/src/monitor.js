import { startGmailWatcher } from './gmail.js'
import { startImapWatcher } from './imap.js'
import { pushEmail, accountsForOwner, getAccountRow, updateAccount, getSetting, setAllActiveForUser } from './store.js'

let io = null
const watchers = new Map()       // accountId -> stop function
const accountOwner = new Map()   // accountId -> ownerId
const offlineTimers = new Map()  // userId -> timeout (10-min grace)
const GRACE_MS = 10 * 60 * 1000

export function initMonitor(socketServer) { io = socketServer }

function toOwner(accountId, event, payload) {
  const owner = accountOwner.get(accountId)
  if (io && owner) io.to(`user:${owner}`).emit(event, payload)
}

// On new email: stream live to the owner. Only persist if storage is ON.
async function onNewEmail(accountId, email) {
  const store = String(await getSetting('store_emails', false)) === 'true'
  let payload = email
  if (store) {
    const stored = await pushEmail(accountId, email)
    if (stored) payload = stored
  } else {
    // give it a transient id so the UI can key it without DB
    payload = { ...email, id: email.id || `live-${accountId}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}` }
  }
  toOwner(accountId, 'new_email', { accountId, email: payload })
}

function startWatcher(accountRow) {
  if (!accountRow || watchers.has(accountRow.id)) return
  accountOwner.set(accountRow.id, accountRow.owner_id)
  const stop = accountRow.type === 'imap'
    ? startImapWatcher(accountRow, onNewEmail)
    : startGmailWatcher(accountRow, onNewEmail)
  watchers.set(accountRow.id, stop)
}

async function stopWatcher(accountId) {
  const stop = watchers.get(accountId)
  if (stop) { await stop(); watchers.delete(accountId) }
}

// ---- presence-driven control ----

// Start all of a user's active accounts (called when the user connects)
export async function startForUser(userId) {
  // cancel any pending offline-stop
  const t = offlineTimers.get(userId)
  if (t) { clearTimeout(t); offlineTimers.delete(userId) }

  const accounts = await accountsForOwner(userId) // owned + granted, priority first
  // priority accounts connect immediately; others a touch later
  accounts.forEach((a, i) => {
    if (!a.active) return
    if (a.priority) startWatcher(a)
    else setTimeout(() => startWatcher(a), 300 * (i + 1))
  })
}

// Explicit "Start All" button: activate ALL accounts and start their watchers.
// accountsForOwner returns priority accounts first, so they connect first.
export async function startAllForUser(userId) {
  const t = offlineTimers.get(userId)
  if (t) { clearTimeout(t); offlineTimers.delete(userId) }
  await setAllActiveForUser(userId, true)
  const accounts = await accountsForOwner(userId) // priority desc, then oldest
  // start priority accounts immediately; stagger the rest slightly behind them
  accounts.forEach((a, i) => {
    if (a.priority) startWatcher({ ...a, active: true })
    else setTimeout(() => startWatcher({ ...a, active: true }), 300 * (i + 1))
  })
  emitToUser(userId, 'all_toggled', { active: true })
}

// Schedule a stop ~10 min after the user goes offline (unless they return)
export function scheduleStopForUser(userId) {
  if (offlineTimers.has(userId)) return
  const t = setTimeout(async () => {
    offlineTimers.delete(userId)
    try {
      const accounts = await accountsForOwner(userId)
      for (const a of accounts) await stopWatcher(a.id)
    } catch (e) {
      // DB unreachable (e.g. network blip) - don't crash; try again next cycle
      console.error('[monitor] scheduleStop failed:', e.message)
    }
  }, GRACE_MS)
  offlineTimers.set(userId, t)
}

// Manual pause/resume by the user (also flips the active flag for persistence)
export async function toggleAccount(accountRow) {
  const active = !accountRow.active
  if (active) startWatcher(await getAccountRow(accountRow.id))
  else await stopWatcher(accountRow.id)
  const updated = await updateAccount(accountRow.id, { active })
  toOwner(accountRow.id, 'account_update', { id: accountRow.id, active })
  return updated
}

export async function stopAccount(accountId) { await stopWatcher(accountId) }

// Stop ALL of a user's account watchers right now (manual pause-all / inactivity)
export async function stopAllForUser(userId) {
  const accounts = await accountsForOwner(userId)
  for (const a of accounts) await stopWatcher(a.id)
  await setAllActiveForUser(userId, false)
  emitToUser(userId, 'all_toggled', { active: false })
}
export function startAccount(accountRow) { startWatcher(accountRow) }

export const emitAdded = (ownerId, account) => io?.to(`user:${ownerId}`).emit('account_added', account)
export const emitRemoved = (ownerId, id) => io?.to(`user:${ownerId}`).emit('account_removed', { id })
export const emitToUser = (userId, event, payload) => io?.to(`user:${userId}`).emit(event, payload)
export const emitToStaff = (event, payload) => io?.to('staff').emit(event, payload)
