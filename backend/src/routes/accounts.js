import { Router } from 'express'
import { auth } from '../auth-middleware.js'
import {
  listAccountsForUser, getAccountRow, addAccount, removeAccount, findAccountByEmail,
  saveEmailsForUser, listSavedEmails, deleteSavedEmail, clearSavedEmails,
  countAccountsForOwner, getIsp,
} from '../store.js'
import { startAccount, stopAccount, toggleAccount, emitAdded, emitRemoved, startForUser, startAllForUser, stopAllForUser } from '../monitor.js'
import { verifyImap } from '../imap.js'
import { listIsps, getOwnedOrGrantedAccount, searchUsers, grantAccess } from '../store.js'
import { providerOf, placementsFor } from '../placements.js'
import { extractFromAccount } from '../extractor.js'

const router = Router()
router.use(auth)

// List accounts visible to this user (own + granted globals; admins see all)
router.get('/', async (req, res) => {
  res.json(await listAccountsForUser(req.user))
})

// Add IMAP account. Normal users pass ispId (host/port hidden); admins may pass host/port directly.
router.post('/imap', async (req, res) => {
  let { email, password, host, port, ssl, ispId } = req.body || {}

  // Resolve ISP preset if provided (this is what normal users use)
  if (ispId) {
    const isp = await getIsp(ispId)
    if (!isp || !isp.enabled) return res.status(400).json({ message: 'Unknown ISP' })
    host = isp.host; port = isp.port; ssl = isp.ssl
  }
  if (!email || !password || !host) return res.status(400).json({ message: 'email, password and host are required' })

  // Enforce per-user account limit (admins exempt)
  if (!req.user.is_admin) {
    const count = await countAccountsForOwner(req.user.id)
    if (count >= req.user.max_accounts)
      return res.status(403).json({ message: `Account limit reached (${req.user.max_accounts})` })
  }
  if (await findAccountByEmail(email, req.user.id))
    return res.status(409).json({ message: 'This account is already connected' })

  try { await verifyImap({ email, password, host, port, ssl }) }
  catch (err) { return res.status(400).json({ message: 'IMAP login failed: ' + err.message }) }

  const account = await addAccount({
    ownerId: req.user.id, type: 'imap', email, active: true, scope: 'personal',
    credentials: { password, host, port: Number(port) || 993, ssl: ssl !== false },
    ispId: ispId || null,
  })
  startAccount(await getAccountRow(account.id))
  emitAdded(req.user.id, account)
  res.json(account)
})

router.post('/:id/toggle', async (req, res) => {
  const row = await getAccountRow(req.params.id)
  if (!row) return res.status(404).json({ message: 'Not found' })
  // Global accounts: only staff (admin/support) can pause/resume.
  // Personal accounts: only the owner (or staff).
  const staff = req.user.role === 'admin' || req.user.role === 'support'
  if (row.scope === 'global') {
    if (!staff) return res.status(403).json({ message: 'Only staff can pause a global account' })
  } else if (row.owner_id !== req.user.id && !staff) {
    return res.status(404).json({ message: 'Not found' })
  }
  res.json(await toggleAccount(row))
})

// Manual refresh: pull newest emails right now (so user can check without waiting)
router.post('/:id/refresh', async (req, res) => {
  const account = await getOwnedOrGrantedAccount(req.params.id, req.user)
  if (!account) return res.status(404).json({ message: 'Not found' })
  // gated by permission unless owner/staff
  const staff = req.user.role === 'admin' || req.user.role === 'support'
  const isOwner = account.owner_id === req.user.id
  if (!staff && !isOwner && !req.user.permissions?.refresh_accounts)
    return res.status(403).json({ message: 'Missing permission: refresh_accounts' })
  try {
    // Live refresh should only bring in RECENT mail (last 5 minutes), not old emails.
    const fiveMinAgo = Date.now() - 5 * 60 * 1000
    const emails = await extractFromAccount(account, 40, false, [], fiveMinAgo)
    res.json({ account: { id: account.id, email: account.email }, emails })
  } catch (e) {
    res.status(400).json({ message: 'Refresh failed: ' + e.message })
  }
})

router.delete('/:id', async (req, res) => {
  const row = await getAccountRow(req.params.id)
  if (!row || (row.owner_id !== req.user.id && !req.user.is_admin))
    return res.status(404).json({ message: 'Not found' })
  await stopAccount(row.id)
  await removeAccount(row.id)
  emitRemoved(row.owner_id, row.id)
  res.json({ ok: true })
})

// Whether Gmail API option is enabled (admin-controlled)
router.get('/gmail-enabled', async (_req, res) => {
  const { getSetting } = await import('../store.js')
  res.json({ enabled: String(await getSetting('gmail_api_enabled', false)) === 'true' })
})

// UI settings any logged-in user may read (non-sensitive display toggles)
router.get('/ui-settings', async (_req, res) => {
  const { getSetting } = await import('../store.js')
  res.json({ show_owner_name: String(await getSetting('show_owner_name', false)) === 'true' })
})

// Enabled ISP presets for the Add-Account picker (any logged-in user)
router.get('/isps', async (_req, res) => {
  const isps = await listIsps(true)
  // normal users don't need host/port exposed; send id + name + ssl only
  res.json(isps.map(i => ({ id: i.id, name: i.name, ssl: i.ssl, placements: i.placements || [] })))
})

// What placements (categories) this account supports, based on its provider
router.get('/:id/placements', async (req, res) => {
  const account = await getOwnedOrGrantedAccount(req.params.id, req.user)
  if (!account) return res.status(404).json({ message: 'Not found' })
  let host = ''
  try { host = account.credentials?.host || '' } catch { host = '' }
  const provider = providerOf({ host, ispName: account.email })
  res.json({ provider, placements: placementsFor(provider) })
})

// LIVE extract: pull N emails straight from the mailbox (not from DB)
router.post('/:id/extract', async (req, res) => {
  const account = await getOwnedOrGrantedAccount(req.params.id, req.user)
  if (!account) return res.status(404).json({ message: 'Not found' })
  const { count = 50, includeSource = false, categories = [] } = req.body || {}
  try {
    const emails = await extractFromAccount(account, Math.min(Number(count) || 50, 200), !!includeSource, categories)
    res.json({ account: { id: account.id, email: account.email }, emails })
  } catch (e) {
    res.status(400).json({ message: 'Extract failed: ' + e.message })
  }
})

// search users to share with (by name prefix or 4-digit code) - minimal info
router.get('/users/search', async (req, res) => {
  const rows = await searchUsers(req.query.q, req.user.id)
  res.json(rows.map(u => ({ id: u.id, username: u.username, code: u.code })))
})

// share one of MY accounts with another user (owner or staff only)
router.post('/:id/share', async (req, res) => {
  const account = await getAccountRow(req.params.id)
  if (!account) return res.status(404).json({ message: 'Not found' })
  const staff = req.user.role === 'admin' || req.user.role === 'support'
  if (account.owner_id !== req.user.id && !staff)
    return res.status(403).json({ message: 'Only the owner can share this account' })
  const { userId } = req.body || {}
  if (!userId) return res.status(400).json({ message: 'userId required' })
  await grantAccess(account.id, userId)
  res.json({ ok: true })
})

// Start ALL of my accounts (explicit Start All button) - activates everything
router.post('/start-all', async (req, res) => {
  await startAllForUser(req.user.id)
  res.json({ ok: true })
})

// Resume monitoring after returning to the tab - ONLY restarts accounts that were
// already active; does NOT re-activate ones the user paused on purpose.
router.post('/resume', async (req, res) => {
  await startForUser(req.user.id)
  res.json({ ok: true })
})

// Pause ALL of my accounts (called on inactivity / closing the tab)
router.post('/pause-all', async (req, res) => {
  await stopAllForUser(req.user.id)
  res.json({ ok: true })
})

// Mark an account as priority (checked/fetched before others) - owner or staff
router.post('/:id/priority', async (req, res) => {
  const account = await getAccountRow(req.params.id)
  if (!account) return res.status(404).json({ message: 'Not found' })
  const staff = req.user.role === 'admin' || req.user.role === 'support'
  if (account.owner_id !== req.user.id && !staff)
    return res.status(403).json({ message: 'Only the owner can change priority' })
  const { setAccountPriority } = await import('../store.js')
  await setAccountPriority(account.id, !!req.body.priority)
  res.json({ ok: true, priority: !!req.body.priority })
})

// ----- Storage: user-saved emails (persistent) -----
router.get('/saved', async (req, res) => {
  res.json(await listSavedEmails(req.user.id))
})
router.post('/saved', async (req, res) => {
  const emails = Array.isArray(req.body?.emails) ? req.body.emails : []
  const n = await saveEmailsForUser(req.user.id, emails)
  res.json({ ok: true, saved: n })
})
router.delete('/saved/:id', async (req, res) => {
  await deleteSavedEmail(req.user.id, req.params.id)
  res.json({ ok: true })
})
router.delete('/saved', async (req, res) => {
  await clearSavedEmails(req.user.id)
  res.json({ ok: true })
})

export default router
