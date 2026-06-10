import { Router } from 'express'
import bcrypt from 'bcryptjs'
import { auth } from '../auth-middleware.js'
import { isStaff, can, staffOnly, requirePerm, PERMS } from '../permissions.js'
import bcryptPlaceholder from 'bcryptjs'
import {
  listUsers, createUser, updateUser, listIsps, addIsp, stats,
  grantAccess, revokeAccess, listAllAccountsAdmin, setAccountScope,
  listResetRequests, resolveResetRequest, listNotifications, countUnread, markAllRead,
  getUserByUsername, getUserById, deleteUser, setUserSections, listRequestTypes, addRequestType,
  getSetting, setSetting, trimNotifications, updateIsp, deleteIsp,
  listStoredEmails, deleteEmail, deleteEmailsBulk, listAccessUserIds,
} from '../store.js'
import { emitToUser } from '../monitor.js'
import { config } from '../config.js'

const router = Router()
router.use(auth, staffOnly)

// The "top admin" is whoever knows the secret code. The code is stored in settings
// (rotatable at runtime); if unset there, it falls back to the env BOOTSTRAP_SECRET.
async function verifyTopAdminCode(code) {
  if (!code) return false
  const stored = await getSetting('top_admin_code', null)
  const expected = stored || config.bootstrapSecret || ''
  return expected.length > 0 && String(code) === String(expected)
}

// ----- users -----
router.get('/users', async (_req, res) => res.json(await listUsers()))

router.post('/users', requirePerm('manage_users'), async (req, res) => {
  const { username, password, is_admin = false, max_accounts = 5 } = req.body || {}
  if (!username || !password) return res.status(400).json({ message: 'username and password required' })
  try {
    const passwordHash = await bcrypt.hash(password, 10)
    const user = await createUser({ username, passwordHash, isAdmin: is_admin, maxAccounts: max_accounts })
    res.json({ id: user.id, username: user.username, is_admin: user.is_admin, max_accounts: user.max_accounts })
  } catch (e) {
    res.status(400).json({ message: e.message.includes('duplicate') ? 'Username taken' : e.message })
  }
})

router.patch('/users/:id', requirePerm('manage_users'), async (req, res) => {
  const patch = {}
  if ('is_admin' in req.body) patch.is_admin = req.body.is_admin
  if ('max_accounts' in req.body) patch.max_accounts = req.body.max_accounts
  if (req.body.password) patch.password_hash = await bcrypt.hash(req.body.password, 10)
  res.json(await updateUser(req.params.id, patch))
})

// ----- roles & permissions -----
router.get('/perms', (_req, res) => res.json({ perms: PERMS }))
router.patch('/users/:id/role', requirePerm('manage_users'), async (req, res) => {
  const { role, permissions } = req.body || {}
  if (!['user','support','admin'].includes(role)) return res.status(400).json({ message: 'bad role' })
  const { setUserRole } = await import('../store.js')
  res.json(await setUserRole(req.params.id, role, permissions || {}))
})

// ----- delete user / sections / token hours -----
// Deleting a regular user: any manage_users admin can do it freely.
// Deleting an ADMIN: requires the top-admin secret code (proves top-admin authority).
router.delete('/users/:id', requirePerm('manage_users'), async (req, res) => {
  if (req.params.id === req.user.id) return res.status(400).json({ message: 'Cannot delete yourself' })
  const target = await getUserById(req.params.id)
  if (!target) return res.status(404).json({ message: 'Not found' })
  if (target.role === 'admin') {
    const code = req.body?.topAdminCode || req.headers['x-top-admin-code'] || ''
    const ok = await verifyTopAdminCode(code)
    if (!ok) return res.status(403).json({ message: 'Deleting an admin requires the top-admin secret code' })
  }
  await deleteUser(req.params.id); res.json({ ok: true })
})

// Rotate the top-admin secret code. Requires the CURRENT code (so only the current
// top admin can hand off the role by setting a new code).
router.post('/top-admin/rotate', requirePerm('manage_users'), async (req, res) => {
  const { currentCode, newCode } = req.body || {}
  if (!newCode || newCode.length < 6) return res.status(400).json({ message: 'New code must be at least 6 characters' })
  const ok = await verifyTopAdminCode(currentCode || '')
  if (!ok) return res.status(403).json({ message: 'Current top-admin code is incorrect' })
  await setSetting('top_admin_code', String(newCode))
  res.json({ ok: true })
})
router.patch('/users/:id/sections', requirePerm('manage_users'), async (req, res) => {
  const { sections = [] } = req.body || {}
  res.json(await setUserSections(req.params.id, sections))
})

// ----- request types (manage) -----
router.get('/request-types', async (_req, res) => res.json(await listRequestTypes()))
router.post('/request-types', requirePerm('manage_users'), async (req, res) => {
  const { key, label } = req.body || {}
  if (!key || !label) return res.status(400).json({ message: 'key and label required' })
  try { res.json(await addRequestType(key, label)) }
  catch (e) { res.status(400).json({ message: e.message.includes('duplicate') ? 'Key exists' : e.message }) }
})

// ----- app settings (token lifetime, etc.) -----
router.get('/settings', async (_req, res) => res.json({
  token_hours: Number(await getSetting('token_hours', 48)),
  store_emails: String(await getSetting('store_emails', false)) === 'true',
  gmail_api_enabled: String(await getSetting('gmail_api_enabled', false)) === 'true',
  gmail_client_id: await getSetting('gmail_client_id', ''),
  gmail_redirect_uri: await getSetting('gmail_redirect_uri', ''),
  // client secret intentionally not returned
}))
router.put('/settings', requirePerm('manage_isps'), async (req, res) => {
  if (req.body.token_hours != null) await setSetting('token_hours', Number(req.body.token_hours))
  if (req.body.store_emails != null) await setSetting('store_emails', !!req.body.store_emails)
  if (req.body.gmail_api_enabled != null) await setSetting('gmail_api_enabled', !!req.body.gmail_api_enabled)
  if (req.body.gmail_client_id != null) await setSetting('gmail_client_id', String(req.body.gmail_client_id))
  if (req.body.gmail_client_secret) await setSetting('gmail_client_secret', String(req.body.gmail_client_secret))
  if (req.body.gmail_redirect_uri != null) await setSetting('gmail_redirect_uri', String(req.body.gmail_redirect_uri))
  res.json({ ok: true })
})

// ----- stored emails (CRUD) -----
router.get('/emails', async (req, res) =>
  res.json(await listStoredEmails({ accountId: req.query.accountId, category: req.query.category, limit: req.query.limit })))
router.delete('/emails/:id', requirePerm('delete_accounts'), async (req, res) => {
  await deleteEmail(req.params.id); res.json({ ok: true })
})
router.post('/emails/bulk-delete', requirePerm('delete_accounts'), async (req, res) => {
  await deleteEmailsBulk({ accountId: req.body.accountId, category: req.body.category }); res.json({ ok: true })
})

// ----- access grants (global account -> user) -----
router.post('/access', requirePerm('share_accounts'), async (req, res) => {
  const { accountId, userId } = req.body || {}
  await grantAccess(accountId, userId)
  res.json({ ok: true })
})
router.delete('/access', requirePerm('share_accounts'), async (req, res) => {
  const { accountId, userId } = req.body || {}
  await revokeAccess(accountId, userId)
  res.json({ ok: true })
})

// ----- ISPs -----
router.get('/isps', async (_req, res) => res.json(await listIsps()))
router.post('/isps', requirePerm('manage_isps'), async (req, res) => {
  const { name, host, port = 993, ssl = true, placements = [] } = req.body || {}
  if (!name || !host) return res.status(400).json({ message: 'name and host required' })
  res.json(await addIsp({ name, host, port, ssl, placements }))
})
router.patch('/isps/:id', requirePerm('manage_isps'), async (req, res) => {
  res.json(await updateIsp(req.params.id, req.body || {}))
})
router.delete('/isps/:id', requirePerm('manage_isps'), async (req, res) => {
  await deleteIsp(req.params.id); res.json({ ok: true })
})

// ----- all accounts (admin view) -----
router.get('/accounts', async (_req, res) => res.json(await listAllAccountsAdmin()))

router.patch('/accounts/:id/scope', requirePerm('share_accounts'), async (req, res) => {
  const { scope } = req.body || {}
  if (!['global', 'personal'].includes(scope)) return res.status(400).json({ message: 'bad scope' })
  // capture who currently has access (to notify them if we revoke)
  let granted = []
  if (scope === 'personal') {
    try { granted = await listAccessUserIds(req.params.id) } catch { granted = [] }
  }
  const result = await setAccountScope(req.params.id, scope)
  if (scope === 'personal') {
    // tell each previously-granted user (except owner) to drop it from their list
    granted.forEach(uid => emitToUser(uid, 'account_removed', { id: req.params.id }))
  }
  res.json(result)
})

// ----- notifications -----
router.get('/notifications', async (_req, res) =>
  res.json({ items: await listNotifications(), unread: await countUnread() }))
router.post('/notifications/read', async (_req, res) => { await markAllRead(); await trimNotifications(); res.json({ ok: true }) })

// ----- password reset requests -----
router.get('/reset-requests', async (_req, res) => res.json(await listResetRequests()))
router.post('/reset-requests/:id/set-password', requirePerm('set_passwords'), async (req, res) => {
  const { username, password } = req.body || {}
  if (!username || !password) return res.status(400).json({ message: 'username and password required' })
  const user = await getUserByUsername(username)
  if (!user) return res.status(404).json({ message: 'User not found' })
  const password_hash = await bcryptPlaceholder.hash(password, 10)
  await updateUser(user.id, { password_hash })
  await resolveResetRequest(req.params.id)
  res.json({ ok: true })
})

// ----- analytics -----
router.get('/stats', async (_req, res) => res.json(await stats()))

export default router
