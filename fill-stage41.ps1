# fill-stage41.ps1 - Storage now persists in the DATABASE (survives refresh/logout)
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path backend\db,backend\src\routes,frontend\src\context,frontend\src\pages,frontend\src\services | Out-Null

Set-Content -LiteralPath 'backend\db\migration-stage41.sql' -Encoding utf8 -Value @'
-- Stage 41: user-saved emails (Storage section) - persistent, per user.
-- Separate from the live `emails` buffer (which is purged after 24h).
create table if not exists saved_emails (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  message_id text,
  from_name text,
  from_email text,
  subject text,
  ip text,
  category text,
  spf text,
  dkim text,
  dmarc text,
  body_text text,
  source text,                 -- full raw source when captured
  saved_at timestamptz not null default now()
);
create index if not exists idx_saved_emails_user on saved_emails(user_id, saved_at desc);
'@
Write-Host 'wrote backend\db\migration-stage41.sql'

Set-Content -LiteralPath 'backend\src\store.js' -Encoding utf8 -Value @'
import { q } from './db.js'
import { encrypt, decrypt } from './crypto.js'
import { MAX_EMAILS } from './config.js'

// ---------------- users ----------------
export async function getUserByUsername(username) {
  const { rows } = await q('select * from users where username = $1', [username])
  return rows[0] || null
}
export async function getUserById(id) {
  const { rows } = await q('select * from users where id = $1', [id])
  return rows[0] || null
}
export async function createUser({ username, passwordHash, isAdmin = false, maxAccounts = 5 }) {
  const { rows } = await q(
    `insert into users (username, password_hash, is_admin, max_accounts)
     values ($1,$2,$3,$4) returning *`,
    [username, passwordHash, isAdmin, maxAccounts])
  return rows[0]
}
export async function listUsers() {
  const { rows } = await q(
    'select id, username, code, is_admin, role, permissions, sections, max_accounts, token_hours, last_seen, picture, created_at from users order by created_at')
  return rows
}
export async function updateUser(id, patch) {
  const cols = [], vals = []
  let i = 1
  for (const [k, v] of Object.entries(patch)) { cols.push(`${k} = $${i++}`); vals.push(v) }
  if (!cols.length) return getUserById(id)
  vals.push(id)
  const { rows } = await q(
    `update users set ${cols.join(', ')} where id = $${i}
     returning id, username, is_admin, max_accounts, picture`, vals)
  return rows[0]
}
export async function countUsers() {
  const { rows } = await q('select count(*)::int as n from users')
  return rows[0].n
}

// ---------------- ISPs ----------------
export async function listIsps(onlyEnabled = false) {
  const { rows } = await q(
    `select * from isps ${onlyEnabled ? 'where enabled = true' : ''} order by name`)
  return rows
}
export async function addIsp({ name, host, port = 993, ssl = true, placements = [] }) {
  const { rows } = await q(
    'insert into isps (name, host, port, ssl, placements) values ($1,$2,$3,$4,$5) returning *',
    [name, host, port, ssl, JSON.stringify(placements)])
  return rows[0]
}
export async function getIsp(id) {
  const { rows } = await q('select * from isps where id = $1', [id])
  return rows[0] || null
}

// ---------------- accounts ----------------
function publicAccount(a) {
  return { id: a.id, ownerId: a.owner_id, type: a.type, email: a.email,
    picture: a.picture, active: a.active, scope: a.scope, priority: a.priority, created_at: a.created_at }
}

export async function listAccountsForUser(user) {
  let rows
  if (user.is_admin) {
    ;({ rows } = await q('select * from accounts order by created_at'))
  } else {
    ;({ rows } = await q(
      `select distinct a.* from accounts a
       left join account_access g on g.account_id = a.id
       where a.owner_id = $1 or g.user_id = $1
       order by a.created_at`, [user.id]))
  }
  // Do NOT load old/stored emails into the dashboard. Each session starts empty;
  // only emails that arrive live (via socket) while the app is open are shown.
  return rows.map(a => ({ ...publicAccount(a), emails: [] }))
}

async function withEmails(accounts) {
  const out = []
  for (const a of accounts) {
    const { rows: emails } = await q(
      'select * from emails where account_id = $1 order by received_at desc limit $2',
      [a.id, MAX_EMAILS])
    out.push({ ...publicAccount(a), emails: emails.map(rowToEmail) })
  }
  return out
}

export async function getAccountRow(id) {
  const { rows } = await q('select * from accounts where id = $1', [id])
  return rows[0] || null
}
export async function findAccountByEmail(email, ownerId) {
  const { rows } = await q(
    'select * from accounts where owner_id = $1 and lower(email) = lower($2)', [ownerId, email])
  return rows[0] || null
}
export async function countAccountsForOwner(ownerId) {
  const { rows } = await q('select count(*)::int as n from accounts where owner_id = $1', [ownerId])
  return rows[0].n
}
export async function addAccount(acc) {
  const { rows } = await q(
    `insert into accounts (owner_id, type, email, picture, active, scope, credentials, isp_id)
     values ($1,$2,$3,$4,$5,$6,$7,$8) returning *`,
    [acc.ownerId, acc.type, acc.email, acc.picture || null,
     acc.active !== false, acc.scope || 'personal', encrypt(acc.credentials || {}), acc.ispId || null])
  return publicAccount(rows[0])
}
export function readCredentials(accountRow) {
  return decrypt(accountRow.credentials)
}
export async function updateAccount(id, patch) {
  const cols = [], vals = []
  let i = 1
  for (const [k, v] of Object.entries(patch)) { cols.push(`${k} = $${i++}`); vals.push(v) }
  if (!cols.length) return publicAccount(await getAccountRow(id))
  vals.push(id)
  const { rows } = await q(`update accounts set ${cols.join(', ')} where id = $${i} returning *`, vals)
  return rows[0] ? publicAccount(rows[0]) : null
}
export async function removeAccount(id) {
  await q('delete from accounts where id = $1', [id])
  return true
}
export async function allActiveAccounts() {
  const { rows } = await q('select * from accounts where active = true')
  return rows
}

export async function grantAccess(accountId, userId) {
  await q(`insert into account_access (account_id, user_id) values ($1,$2)
           on conflict do nothing`, [accountId, userId])
}
export async function revokeAccess(accountId, userId) {
  await q('delete from account_access where account_id = $1 and user_id = $2', [accountId, userId])
}

// ---------------- emails ----------------
function rowToEmail(r) {
  return {
    id: r.id, category: r.category, time: r.received_at, ip: r.ip, preview: r.preview,
    auth: { spf: r.spf, dkim: r.dkim, dmarc: r.dmarc },
    sender: { name: r.sender_name, email: r.sender_email, subject: r.subject, domain: r.domain },
  }
}
export async function pushEmail(accountId, email) {
  try {
    const { rows } = await q(
      `insert into emails
       (account_id, category, received_at, sender_name, sender_email, subject, domain, ip, spf, dkim, dmarc, preview)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) returning *`,
      [accountId, email.category, email.time, email.sender.name, email.sender.email,
       email.sender.subject, email.sender.domain, email.ip,
       email.auth?.spf, email.auth?.dkim, email.auth?.dmarc, email.preview || null])
    return rowToEmail(rows[0])
  } catch (e) { console.error('pushEmail:', e.message); return null }
}

// ---------------- stats ----------------
export async function stats() {
  const [u, a, m, byType, byCat, act, auth] = await Promise.all([
    q('select count(*)::int as n from users'),
    q('select count(*)::int as n from accounts'),
    q('select count(*)::int as n from emails'),
    q('select type, count(*)::int as n from accounts group by type'),
    q('select category, count(*)::int as n from emails group by category'),
    q('select count(*)::int as n from accounts where active = true'),
    q(`select
        count(*) filter (where spf ilike 'pass')::int as spf_pass,
        count(*) filter (where dkim ilike 'pass')::int as dkim_pass,
        count(*) filter (where dmarc ilike 'pass')::int as dmarc_pass,
        count(*)::int as total from emails`),
  ])
  const providers = byType.rows.reduce((map, r) => { map[r.type] = r.n; return map }, {})
  const categories = byCat.rows.reduce((map, r) => { map[r.category] = r.n; return map }, {})
  const inbox = categories.primary || 0
  const spam = categories.spam || 0
  const total = m.rows[0].n
  const aur = auth.rows[0]
  const rate = (x) => aur.total ? Math.round((x / aur.total) * 100) : 0
  return {
    users: u.rows[0].n, accounts: a.rows[0].n, emails: total,
    activeAccounts: act.rows[0].n, providers, categories,
    spam, inbox,
    inboxRate: total ? Math.round((inbox / total) * 100) : 0,
    spamRate: total ? Math.round((spam / total) * 100) : 0,
    spfPass: rate(aur.spf_pass), dkimPass: rate(aur.dkim_pass), dmarcPass: rate(aur.dmarc_pass),
    activeToday: await activeTodayCount(),
  }
}

// ---------------- admin: all accounts with owner + grants ----------------
export async function listAllAccountsAdmin() {
  const { rows } = await q(`
    select a.id, a.email, a.type, a.scope, a.active, a.created_at,
           u.username as owner_username, a.owner_id,
           coalesce(json_agg(json_build_object('user_id', ac.user_id, 'username', gu.username))
                    filter (where ac.user_id is not null), '[]') as grants
    from accounts a
    join users u on u.id = a.owner_id
    left join account_access ac on ac.account_id = a.id
    left join users gu on gu.id = ac.user_id
    group by a.id, u.username
    order by a.created_at`)
  return rows
}

export async function listAccessUserIds(accountId) {
  const { rows } = await q('select user_id from account_access where account_id = $1', [accountId])
  return rows.map(r => r.user_id)
}

export async function setAccountScope(id, scope) {
  const { rows } = await q('update accounts set scope = $1 where id = $2 returning id, scope', [scope, id])
  // Turning OFF global: revoke all grants so previously-granted users lose access.
  if (scope === 'personal') {
    await q('delete from account_access where account_id = $1', [id])
  }
  return rows[0] || null
}

// ---------------- reset requests + notifications ----------------
export async function createResetRequest(username) {
  const { rows } = await q(
    'insert into reset_requests (username) values ($1) returning *', [username])
  await q('insert into notifications (type, message, ref_id) values ($1,$2,$3)',
    ['reset_request', `Password reset requested by "${username}"`, rows[0].id])
  return rows[0]
}
export async function listResetRequests() {
  const { rows } = await q('select * from reset_requests order by created_at desc limit 100')
  return rows
}
export async function resolveResetRequest(id) {
  await q('update reset_requests set status = $1, resolved_at = now() where id = $2', ['resolved', id])
}
export async function listNotifications() {
  const { rows } = await q('select * from notifications order by created_at desc limit 10')
  return rows
}
export async function countUnread() {
  const { rows } = await q('select count(*)::int as n from notifications where read = false')
  return rows[0].n
}
export async function markAllRead() {
  await q('update notifications set read = true where read = false')
}

// ---------------- email extraction (custom fields) ----------------
// Returns rows for an account with only the requested columns.
const FIELD_MAP = {
  from_name: 'sender_name', from_email: 'sender_email', subject: 'subject',
  domain: 'domain', ip: 'ip', spf: 'spf', dkim: 'dkim', dmarc: 'dmarc',
  category: 'category', received_at: 'received_at', preview: 'preview',
}
export async function extractEmails(accountId, fields, limit = 500) {
  const cols = fields.filter(f => FIELD_MAP[f]).map(f => `${FIELD_MAP[f]} as ${f}`)
  if (!cols.length) cols.push('id')
  const { rows } = await q(
    `select ${cols.join(', ')} from emails where account_id = $1 order by received_at desc limit $2`,
    [accountId, Math.min(Number(limit) || 500, 2000)])
  return rows
}
export async function getOwnedOrGrantedAccount(accountId, user) {
  if (user.is_admin) return getAccountRow(accountId)
  const { rows } = await q(
    `select a.* from accounts a
     left join account_access g on g.account_id = a.id
     where a.id = $1 and (a.owner_id = $2 or g.user_id = $2) limit 1`,
    [accountId, user.id])
  return rows[0] || null
}

// ---------------- presence ----------------
export async function touchUser(id) {
  await q('update users set last_seen = now() where id = $1', [id])
}
export async function activeTodayCount() {
  const { rows } = await q("select count(*)::int as n from users where last_seen > now() - interval '24 hours'")
  return rows[0].n
}

// ---------------- roles / permissions ----------------
export async function setUserRole(id, role, permissions) {
  const patch = { role, is_admin: role === 'admin' }
  if (permissions) patch.permissions = permissions
  return updateUser(id, patch)
}

// ---------------- requests + messages ----------------
export async function createRequest({ userId, type = 'message', subject, body }) {
  const { rows } = await q(
    'insert into requests (user_id, type, subject) values ($1,$2,$3) returning *',
    [userId, type, subject || null])
  const reqId = rows[0].id
  if (body) {
    await q('insert into request_messages (request_id, sender_id, sender_role, body) values ($1,$2,$3,$4)',
      [reqId, userId, 'user', body])
  }
  await q('insert into notifications (type, message, ref_id) values ($1,$2,$3)',
    ['request', `New ${type} request${subject ? ': ' + subject : ''}`, reqId])
  return rows[0]
}
export async function listRequestsForUser(user) {
  const staff = user.role === 'admin' || user.role === 'support'
  const { rows } = staff
    ? await q(`select r.*, u.username from requests r join users u on u.id = r.user_id order by r.created_at desc`)
    : await q(`select r.*, u.username from requests r join users u on u.id = r.user_id
               where r.user_id = $1 order by r.created_at desc`, [user.id])
  return rows
}
export async function getRequestThread(id) {
  const { rows } = await q(`select m.*, u.username from request_messages m
    left join users u on u.id = m.sender_id where m.request_id = $1 order by m.created_at`, [id])
  return rows
}
export async function addRequestMessage(requestId, sender, body) {
  const { rows } = await q(
    'insert into request_messages (request_id, sender_id, sender_role, body) values ($1,$2,$3,$4) returning *',
    [requestId, sender.id, sender.role, body])
  return rows[0]
}
export async function setRequestStatus(id, status) {
  await q('update requests set status = $1, resolved_at = case when $1 = \'resolved\' then now() else null end where id = $2',
    [status, id])
}
export async function deleteRequest(id) {
  await q('delete from request_messages where request_id = $1', [id])
  await q('delete from requests where id = $1', [id])
}

export async function getRequest(id) {
  const { rows } = await q('select * from requests where id = $1', [id])
  return rows[0] || null
}

// ---------------- email retention ----------------
export async function purgeOldEmails() {
  await q("delete from emails where received_at < now() - interval '24 hours'")
}

// ---------------- settings (key/value) ----------------
export async function getSetting(key, fallback = null) {
  const { rows } = await q('select value from settings where key = $1', [key])
  return rows.length ? rows[0].value : fallback
}
export async function setSetting(key, value) {
  await q(`insert into settings (key, value) values ($1, $2::jsonb)
           on conflict (key) do update set value = $2::jsonb`, [key, JSON.stringify(value)])
}

// ---------------- request types ----------------
export async function listRequestTypes() {
  const { rows } = await q('select * from request_types order by label')
  return rows
}
export async function addRequestType(key, label) {
  const { rows } = await q('insert into request_types (key, label) values ($1,$2) returning *', [key, label])
  return rows[0]
}

// ---------------- users: delete, sections, token hours ----------------
export async function deleteUser(id) {
  await q('delete from users where id = $1', [id])
}
export async function setUserSections(id, sections) {
  const { rows } = await q('update users set sections = $1::jsonb where id = $2 returning *', [JSON.stringify(sections), id])
  return rows[0]
}

// ---------------- request auto-delete on resolve (after 24h) ----------------
export async function purgeResolvedRequests() {
  await q("delete from requests where status = 'resolved' and resolved_at < now() - interval '24 hours'")
}

// ---------------- notifications: keep dropdown light ----------------
export async function trimNotifications() {
  // delete READ notifications older than 5h; keep table from growing
  await q("delete from notifications where read = true and created_at < now() - interval '5 hours'")
}

export async function updateIsp(id, patch) {
  const cols=[], vals=[]; let i=1
  for (const [k,v] of Object.entries(patch)) {
    cols.push(`${k} = $${i++}`)
    // placements is JSONB - serialize objects/arrays
    vals.push(k === 'placements' ? JSON.stringify(v) : v)
  }
  if (!cols.length) return getIsp(id)
  vals.push(id)
  const { rows } = await q(`update isps set ${cols.join(', ')} where id = $${i} returning *`, vals)
  return rows[0]
}
export async function deleteIsp(id) { await q('delete from isps where id = $1', [id]) }

// Accounts a user is responsible for watching: owned + granted-global
export async function accountsForOwner(userId) {
  const { rows } = await q(`
    select distinct a.* from accounts a
    left join account_access g on g.account_id = a.id
    where a.owner_id = $1 or g.user_id = $1
    order by a.priority desc, a.created_at asc`, [userId])
  return rows.map(rowToAccountMeta)
}
function rowToAccountMeta(r) {
  return { id: r.id, owner_id: r.owner_id, type: r.type, email: r.email,
    active: r.active, scope: r.scope, priority: r.priority, credentials: r.credentials }
}

// ---------------- stored emails admin (CRUD) ----------------
export async function listStoredEmails({ accountId, category, limit = 200 } = {}) {
  const where = [], vals = []; let i = 1
  if (accountId) { where.push(`e.account_id = $${i++}`); vals.push(accountId) }
  if (category) { where.push(`e.category = $${i++}`); vals.push(category) }
  vals.push(Math.min(Number(limit) || 200, 1000))
  const { rows } = await q(`
    select e.*, a.email as account_email from emails e
    join accounts a on a.id = e.account_id
    ${where.length ? 'where ' + where.join(' and ') : ''}
    order by e.received_at desc limit $${i}`, vals)
  return rows
}
export async function deleteEmail(id) { await q('delete from emails where id = $1', [id]) }
export async function deleteEmailsBulk({ accountId, category } = {}) {
  const where = [], vals = []; let i = 1
  if (accountId) { where.push(`account_id = $${i++}`); vals.push(accountId) }
  if (category) { where.push(`category = $${i++}`); vals.push(category) }
  await q(`delete from emails ${where.length ? 'where ' + where.join(' and ') : ''}`, vals)
}

// ---------------- user code + search (share-by-name) ----------------
export async function ensureUserCode(id) {
  const { rows } = await q('select code from users where id = $1', [id])
  if (rows[0]?.code) return rows[0].code
  let code
  for (;;) {
    code = String(Math.floor(Math.random() * 10000)).padStart(4, '0')
    const dup = await q('select 1 from users where code = $1', [code])
    if (!dup.rows.length) break
  }
  await q('update users set code = $1 where id = $2', [code, id])
  return code
}
// search users by name prefix or exact 4-digit code; returns minimal info only
export async function searchUsers(term, excludeId) {
  const t = (term || '').trim()
  if (!t) return []
  const { rows } = await q(`
    select id, username, code from users
    where (username ilike $1 or code = $2) and id <> $3
    order by username limit 8`, [`${t}%`, t, excludeId || '00000000-0000-0000-0000-000000000000'])
  return rows
}

// Set active flag on ALL of a user's accounts (for Start All / Pause All)
export async function setAllActiveForUser(userId, active) {
  await q('update accounts set active = $1 where owner_id = $2', [!!active, userId])
}

// Mark an account as priority (checked/fetched before others) or not
export async function setAccountPriority(accountId, priority) {
  await q('update accounts set priority = $1 where id = $2', [!!priority, accountId])
}

// ---------------- saved emails (Storage section, persistent per user) ----------------
export async function saveEmailsForUser(userId, emails) {
  if (!Array.isArray(emails) || !emails.length) return 0
  let saved = 0
  for (const e of emails) {
    // skip if this user already saved the same message (by message_id when present)
    if (e.message_id) {
      const { rows } = await q(
        'select 1 from saved_emails where user_id = $1 and message_id = $2 limit 1',
        [userId, e.message_id])
      if (rows.length) continue
    }
    await q(
      `insert into saved_emails
       (user_id, message_id, from_name, from_email, subject, ip, category, spf, dkim, dmarc, body_text, source)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [userId, e.message_id || null, e.from_name || null, e.from_email || null,
       e.subject || null, e.ip || null, e.category || null, e.spf || null,
       e.dkim || null, e.dmarc || null, e.body_text || null, e.source || null])
    saved++
  }
  return saved
}

export async function listSavedEmails(userId) {
  const { rows } = await q(
    'select * from saved_emails where user_id = $1 order by saved_at desc', [userId])
  return rows
}

export async function deleteSavedEmail(userId, id) {
  await q('delete from saved_emails where id = $1 and user_id = $2', [id, userId])
}

export async function clearSavedEmails(userId) {
  await q('delete from saved_emails where user_id = $1', [userId])
}
'@
Write-Host 'wrote backend\src\store.js'

Set-Content -LiteralPath 'backend\src\routes\accounts.js' -Encoding utf8 -Value @'
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
'@
Write-Host 'wrote backend\src\routes\accounts.js'

Set-Content -LiteralPath 'frontend\src\context\AppProvider.jsx' -Encoding utf8 -Value @'
import { createContext, useContext, useState, useCallback, useEffect, useRef } from 'react'
import { ConfigProvider, message } from 'antd'
import { makeTheme } from '../theme'
import { useAccounts } from '../hooks/useAccounts'
import { resumeAll, pauseAll } from '../services/accounts'
import * as accountsApi from '../services/accounts'

const AppContext = createContext(null)
export const useApp = () => useContext(AppContext)

export function AppProvider({ children }) {
  const [token, setToken] = useState(localStorage.getItem('token'))
  const user = (() => { try { return JSON.parse(localStorage.getItem('user')) } catch { return null } })()
  const [mode, setMode] = useState(localStorage.getItem('mode') || 'light')
  const [messageApi, contextHolder] = message.useMessage()

  // Extract page results - kept here (not in the page) so navigating away and back
  // does NOT wipe the extracted emails. Lives in memory for the session.
  const [extractResults, setExtractResults] = useState([])
  const [extractMeta, setExtractMeta] = useState({ accountId: null, withSource: false })
  // Saved emails now PERSIST in the database (survive refresh/logout), unlike the
  // in-memory extract results.
  const [storedEmails, setStoredEmails] = useState([])
  const reloadStored = useCallback(async () => {
    try { setStoredEmails(await accountsApi.getSavedEmails()) } catch { /* ignore */ }
  }, [])
  const saveEmails = useCallback(async (emails) => {
    try {
      await accountsApi.saveEmailsToStore(emails)
      await reloadStored()
    } catch { messageApi.open({ type: 'error', content: 'Could not save to Storage' }) }
  }, [reloadStored, messageApi])
  const removeStored = useCallback(async (id) => {
    try { await accountsApi.deleteSavedEmail(id); await reloadStored() } catch { /* ignore */ }
  }, [reloadStored])
  const clearStored = useCallback(async () => {
    try { await accountsApi.clearSavedEmails(); setStoredEmails([]) } catch { /* ignore */ }
  }, [])

  const notify = useCallback((msg, type = 'success') =>
    messageApi.open({ type: type === 'error' ? 'error' : 'success', content: msg }), [messageApi])

  const toggleMode = useCallback(() => {
    setMode(prev => {
      const next = prev === 'dark' ? 'light' : 'dark'
      localStorage.setItem('mode', next)
      return next
    })
  }, [])

  // Inactivity auto-pause: if the tab is hidden for 10 min, pause all watchers.
  // Resume when the user comes back. Also pause on page close.
  const hideTimer = useRef(null)
  const resumeTimer = useRef(null)
  // Load persisted saved-emails from the DB once logged in.
  useEffect(() => { if (token) reloadStored() }, [token, reloadStored])

  useEffect(() => {
    if (!token) return
    const IDLE = 10 * 60 * 1000
    const onVisibility = () => {
      if (document.hidden) {
        if (resumeTimer.current) { clearTimeout(resumeTimer.current); resumeTimer.current = null }
        hideTimer.current = setTimeout(() => { pauseAll().catch(() => {}) }, IDLE)
      } else {
        if (hideTimer.current) { clearTimeout(hideTimer.current); hideTimer.current = null }
        // debounce: only resume once things settle (prevents rapid start-all spam)
        if (resumeTimer.current) clearTimeout(resumeTimer.current)
        resumeTimer.current = setTimeout(() => { resumeAll().catch(() => {}) }, 1500)
      }
    }
    const onClose = () => { try { navigator.sendBeacon?.('/api/accounts/pause-all') } catch { /* ignore */ } }
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('pagehide', onClose)
    return () => {
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('pagehide', onClose)
      if (hideTimer.current) clearTimeout(hideTimer.current)
      if (resumeTimer.current) clearTimeout(resumeTimer.current)
    }
  }, [token])

  const accountState = useAccounts(token, notify)

  return (
    <ConfigProvider theme={makeTheme(mode)}>
      <AppContext.Provider value={{ token, setToken, user, mode, toggleMode, notify,
        extractResults, setExtractResults, extractMeta, setExtractMeta,
        storedEmails, saveEmails, removeStored, clearStored, reloadStored,
        ...accountState }}>
        {contextHolder}
        {children}
      </AppContext.Provider>
    </ConfigProvider>
  )
}
'@
Write-Host 'wrote frontend\src\context\AppProvider.jsx'

Set-Content -LiteralPath 'frontend\src\pages\StoragePage.jsx' -Encoding utf8 -Value @'
import { useState } from 'react'
import { Card, Table, Button, Typography, Space, Empty, Modal, Tag, message } from 'antd'
import { DownloadOutlined, DeleteOutlined, EyeOutlined, ClearOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'

const { Title, Text } = Typography

const CAT_COLORS = { primary: '#16a34a', spam: '#dc2626', promotions: '#db2777', social: '#4f46e5', updates: '#ea580c', forums: '#0891b2', inbox: '#16a34a' }

// User's saved emails (kept in memory for the session). Each can be downloaded
// as its full raw source (.eml), or all selected exported together.
export default function StoragePage() {
  const { storedEmails, removeStored, clearStored } = useApp()
  const [view, setView] = useState(null)
  const [selected, setSelected] = useState([])

  const keyOf = (e, i) => e.id || e.message_id || `${e.from_email}|${e.subject}|${i}`

  const downloadOne = (e) => {
    const content = e.source || buildFallback(e)
    const blob = new Blob([content], { type: 'message/rfc822' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `${(e.subject || 'email').replace(/[^a-z0-9]+/gi, '_').slice(0, 40)}.eml`
    a.click()
    URL.revokeObjectURL(url)
  }
  const downloadSelected = () => {
    const chosen = storedEmails.filter((e, i) => selected.includes(keyOf(e, i)))
    if (!chosen.length) return message.warning('Select emails first')
    chosen.forEach(downloadOne)
  }
  // when full source wasn't captured, build a readable fallback from parsed fields
  const buildFallback = (e) =>
    `From: ${e.from_name || ''} <${e.from_email || ''}>\nSubject: ${e.subject || ''}\nDate: ${e.date || ''}\n` +
    `IP: ${e.ip || ''}\nSPF: ${e.spf || 'n/a'}  DKIM: ${e.dkim || 'n/a'}  DMARC: ${e.dmarc || 'n/a'}\n` +
    `Placement: ${e.category || ''}\n\n${e.body_text || '(full source not captured - re-extract with "Include full source")'}`

  const columns = [
    { title: 'Placement', dataIndex: 'category', width: 120, render: (v) =>
      <Tag color={CAT_COLORS[v] || 'default'} style={{ color: '#fff' }}>{v || 'n/a'}</Tag> },
    { title: 'From', dataIndex: 'from_email', ellipsis: true,
      render: (v, r) => <span>{r.from_name ? `${r.from_name} ` : ''}<Text type="secondary">{v}</Text></span> },
    { title: 'Subject', dataIndex: 'subject', ellipsis: true },
    { title: 'IP', dataIndex: 'ip', width: 130 },
    { title: 'Source', key: 'src', width: 80, render: (_, r) =>
      <Tag color={r.source ? 'green' : 'default'}>{r.source ? 'full' : 'partial'}</Tag> },
    { title: 'Actions', key: 'a', width: 150, render: (_, r) =>
      <Space>
        <Button size="small" icon={<EyeOutlined />} onClick={() => setView(r)} />
        <Button size="small" icon={<DownloadOutlined />} onClick={() => downloadOne(r)} />
        <Button size="small" danger icon={<DeleteOutlined />}
          onClick={() => removeStored(r.id)} />
      </Space> },
  ]

  return (
    <>
      <Title level={4}>Storage</Title>
      <Text type="secondary">Emails you saved from Extract. Download any as its full raw source (.eml).</Text>
      <Card style={{ marginTop: 16 }}
        title={`Saved emails (${storedEmails.length})`}
        extra={
          <Space>
            <Button icon={<DownloadOutlined />} disabled={!selected.length} onClick={downloadSelected}>
              Download selected ({selected.length})
            </Button>
            <Button icon={<ClearOutlined />} danger disabled={!storedEmails.length}
              onClick={() => Modal.confirm({ title: 'Clear all saved emails?', onOk: clearStored })}>
              Clear all
            </Button>
          </Space>}>
        {storedEmails.length === 0 ? (
          <Empty description="No saved emails yet. Go to Extract, select emails, and click 'Save selected'." />
        ) : (
          <Table rowKey={(e, i) => keyOf(e, i)} dataSource={storedEmails} columns={columns}
            rowSelection={{ selectedRowKeys: selected, onChange: setSelected }}
            scroll={{ x: true }} size="small" pagination={{ pageSize: 20 }} />
        )}
      </Card>

      <Modal open={!!view} title={view?.subject || 'Email source'} width={820} footer={null}
        onCancel={() => setView(null)}>
        <pre style={{ maxHeight: 460, overflow: 'auto', background: '#0f172a', color: '#e2e8f0',
          padding: 14, borderRadius: 8, fontSize: 12, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
          {view?.source || buildFallback(view || {})}
        </pre>
      </Modal>
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\StoragePage.jsx'

Set-Content -LiteralPath 'frontend\src\pages\ExtractPage.jsx' -Encoding utf8 -Value @'
import { useState, useEffect } from 'react'
import { Card, Select, Checkbox, Button, Table, Space, Typography, InputNumber, message, Switch, Modal, Input, Dropdown } from 'antd'
import { DownloadOutlined, EyeOutlined, CopyOutlined, SearchOutlined, DownOutlined, SaveOutlined } from '@ant-design/icons'
import * as XLSX from 'xlsx'
import { useApp } from '../context/AppProvider'
import { extractEmails, fetchIsps } from '../services/accounts'

const { Title, Paragraph, Text } = Typography

// All standard fields the user can choose to show as columns
const FIELDS = [
  { key: 'category', label: 'Placement' },
  { key: 'from_name', label: 'From name' },
  { key: 'from_email', label: 'From email' },
  { key: 'to', label: 'To' },
  { key: 'subject', label: 'Subject' },
  { key: 'date', label: 'Date' },
  { key: 'domain', label: 'Domain' },
  { key: 'ip', label: 'IP' },
  { key: 'spf', label: 'SPF' },
  { key: 'dkim', label: 'DKIM' },
  { key: 'dmarc', label: 'DMARC' },
  { key: 'message_id', label: 'Message-ID' },
  { key: 'reply_to', label: 'Reply-To' },
  { key: 'return_path', label: 'Return-Path' },
  { key: 'list_unsubscribe', label: 'List-Unsubscribe' },
  { key: 'body_text', label: 'Body text' },
]

const CAT_COLORS = { primary: '#16a34a', spam: '#dc2626', promotions: '#db2777', social: '#4f46e5', updates: '#ea580c', forums: '#0891b2' }

// colored label for SPF/DKIM/DMARC
function authLabel(v) {
  const s = (v || '').toString().toLowerCase()
  if (!s) return <span style={{ background: '#94a3b8', color: '#fff', padding: '1px 8px', borderRadius: 5, fontSize: 12 }}>not found</span>
  if (s === 'pass') return <span style={{ background: '#16a34a', color: '#fff', padding: '1px 8px', borderRadius: 5, fontSize: 12 }}>PASS</span>
  if (['fail', 'softfail', 'permerror', 'temperror', 'none'].includes(s))
    return <span style={{ background: '#dc2626', color: '#fff', padding: '1px 8px', borderRadius: 5, fontSize: 12 }}>{s.toUpperCase()}</span>
  return <span style={{ background: '#64748b', color: '#fff', padding: '1px 8px', borderRadius: 5, fontSize: 12 }}>{s.toUpperCase()}</span>
}

export default function ExtractPage() {
  const { accounts, extractResults, setExtractResults, extractMeta, setExtractMeta, saveEmails, notify } = useApp()
  const [accountId, setAccountId] = useState(extractMeta.accountId || null)
  const [count, setCount] = useState(50)
  const [fields, setFields] = useState(['category', 'from_name', 'subject', 'spf', 'dkim', 'dmarc'])
  const [withSource, setWithSource] = useState(extractMeta.withSource || false)
  const [placements, setPlacements] = useState([])  // filter by category (multi)
  const [colFilters, setColFilters] = useState({}) // per-column text filters
  const [keyword, setKeyword] = useState('')        // global keyword search
  const [isps, setIsps] = useState([])              // ISP defs (for per-ISP placements)
  const rows = extractResults                       // results live in app state (persist across navigation)
  const setRows = setExtractResults
  const [busy, setBusy] = useState(false)
  const [view, setView] = useState(null) // full source modal
  const [selectedKeys, setSelectedKeys] = useState([]) // selected table rows

  useEffect(() => { fetchIsps().then(setIsps).catch(() => setIsps([])) }, [])

  // The placement options for the chosen account come from ITS ISP definition.
  const selectedAccount = accounts.find(a => a.id === accountId)
  const ispForAccount = selectedAccount && isps.find(i =>
    i.id === selectedAccount.isp_id || i.name?.toLowerCase() === (selectedAccount.email || '').split('@')[1]?.split('.')[0])
  const placementOptions = (ispForAccount?.placements || []).map(p => ({ value: p.key, label: p.label }))
  useEffect(() => { setPlacements([]) }, [accountId])
  const [dragCol, setDragCol] = useState(null) // column key being dragged

  const run = async () => {
    if (!accountId) return message.warning('Choose an account')
    setBusy(true)
    try {
      const data = await extractEmails(accountId, count, withSource, placements)
      setRows(data.emails || [])
      setExtractMeta({ accountId, withSource })
      setSelectedKeys([])
      if (!data.emails?.length) message.info('No emails found')
    } catch (e) { message.error(e.response?.data?.message || 'Extract failed') }
    finally { setBusy(false) }
  }

  // Save the selected rows (with full source) into Storage.
  const rowKeyOf = (r, i) => r.message_id || `${r.from_email}|${r.subject}|${i}`
  const saveSelected = async () => {
    const chosen = rows.filter((r, i) => selectedKeys.includes(rowKeyOf(r, i)))
    if (!chosen.length) return message.warning('Select at least one email')
    if (!withSource && chosen.some(r => !r.source)) {
      message.warning('Tip: enable "Include full source" and re-extract to save the raw source too')
    }
    await saveEmails(chosen)
    notify?.(`Saved ${chosen.length} email(s) to Storage`)
    setSelectedKeys([])
  }

  const AUTH = ['spf', 'dkim', 'dmarc']

  // Reorder columns by dragging one field key onto another
  const moveColumn = (fromKey, toKey) => {
    if (!fromKey || fromKey === toKey) return
    setFields(prev => {
      const arr = [...prev]
      const from = arr.indexOf(fromKey)
      const to = arr.indexOf(toKey)
      if (from === -1 || to === -1) return prev
      arr.splice(to, 0, arr.splice(from, 1)[0])
      return arr
    })
  }

  // A draggable header cell - drag one column header onto another to reorder
  const DragHeader = ({ colKey, children }) => (
    <div draggable
      onDragStart={(e) => { setDragCol(colKey); e.dataTransfer.effectAllowed = 'move' }}
      onDragOver={(e) => e.preventDefault()}
      onDrop={() => { moveColumn(dragCol, colKey); setDragCol(null) }}
      style={{ cursor: 'grab', userSelect: 'none' }}
      title="Drag to reorder this column">
      {children}
    </div>
  )

  // Columns follow the ORDER you pick fields in (so you control column position).
  const columns = [
    ...fields.map(f => ({
      title: <DragHeader colKey={f}>{FIELDS.find(x => x.key === f)?.label || f}</DragHeader>,
      dataIndex: f, ellipsis: true,
      sorter: (a, b) => String(a[f] ?? '').localeCompare(String(b[f] ?? '')),
      // per-column search box for text fields (IP, email, domain, subject, etc.)
      filterDropdown: AUTH.includes(f) || f === 'category' ? undefined : ({ confirm }) => (
        <div style={{ padding: 8 }}>
          <input autoFocus placeholder={`Filter ${f}`} value={colFilters[f] || ''}
            onChange={(e) => setColFilters(prev => ({ ...prev, [f]: e.target.value }))}
            onKeyDown={(e) => e.key === 'Enter' && confirm()}
            style={{ width: 160, padding: 4 }} />
        </div>
      ),
      render: (v) => {
        if (f === 'date' && v) return new Date(v).toLocaleString()
        if (f === 'category') {
          const c = CAT_COLORS[v] || '#94a3b8'
          return <span style={{ background: c, color: '#fff', padding: '1px 8px', borderRadius: 5, fontSize: 12 }}>{v || 'primary'}</span>
        }
        if (AUTH.includes(f)) return authLabel(v)
        return v ?? ''
      },
    })),
    ...(withSource ? [{
      title: 'Source', key: 'src', width: 90, render: (_, r) =>
        <Button size="small" icon={<EyeOutlined />} onClick={() => setView(r)}>View</Button>
    }] : []),
  ]

  const filteredRows = rows.filter(r => {
    if (placements.length && !placements.includes(r.category)) return false
    // per-column text filters
    for (const [k, val] of Object.entries(colFilters)) {
      if (val && !String(r[k] ?? '').toLowerCase().includes(val.toLowerCase())) return false
    }
    // global keyword search across all visible fields
    if (keyword.trim()) {
      const kw = keyword.toLowerCase()
      const hit = fields.some(f => String(r[f] ?? '').toLowerCase().includes(kw))
      if (!hit) return false
    }
    return true
  })

  // Copy helpers - copy a column's values (deduped), joined by the chosen separator.
  const [sepChoice, setSepChoice] = useState('\n')
  const SEPARATORS = [
    { value: '\n', label: 'New line' },
    { value: ', ', label: 'Comma' },
    { value: '; ', label: 'Semicolon' },
    { value: ' | ', label: 'Pipe' },
    { value: '\t', label: 'Tab' },
    { value: ' ', label: 'Space' },
  ]
  const copyValues = (extractor, label) => {
    const vals = []
    const seen = new Set()
    filteredRows.forEach(r => {
      const v = extractor(r)
      if (v && !seen.has(v)) { seen.add(v); vals.push(v) }
    })
    if (!vals.length) return message.warning(`No ${label} to copy`)
    navigator.clipboard.writeText(vals.join(sepChoice))
      .then(() => message.success(`Copied ${vals.length} ${label}`))
      .catch(() => message.error('Copy failed'))
  }
  const copyMenu = {
    items: [
      { key: 'ips', label: 'IPs' },
      { key: 'domains', label: 'Domains' },
      { key: 'ip_domain', label: 'IP + Domain' },
      { key: 'emails', label: 'From emails' },
      { key: 'subjects', label: 'Subjects' },
      { key: 'from_names', label: 'From names' },
    ],
    onClick: ({ key }) => {
      if (key === 'ips') copyValues(r => r.ip, 'IPs')
      else if (key === 'domains') copyValues(r => r.domain, 'domains')
      else if (key === 'ip_domain') copyValues(r => (r.ip || r.domain) ? `${r.ip || ''}\t${r.domain || ''}`.trim() : '', 'IP+domain rows')
      else if (key === 'emails') copyValues(r => r.from_email, 'emails')
      else if (key === 'subjects') copyValues(r => r.subject, 'subjects')
      else if (key === 'from_names') copyValues(r => r.from_name, 'names')
    },
  }

  const dataForExport = () => filteredRows.map(r => {
    const o = {}; fields.forEach(f => { o[f] = r[f] }); return o
  })

  const exportFile = (type) => {
    if (!rows.length) return message.warning('Nothing to export')
    const ws = XLSX.utils.json_to_sheet(dataForExport())
    const wb = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(wb, ws, 'emails')
    const acc = accounts.find(a => a.id === accountId)
    const name = `extract_${acc?.email || 'account'}`
    if (type === 'csv') XLSX.writeFile(wb, `${name}.csv`, { bookType: 'csv' })
    else XLSX.writeFile(wb, `${name}.xlsx`)
  }

  const copySource = () => {
    navigator.clipboard.writeText(view.source || '').then(() => message.success('Copied'))
  }
  const downloadSource = () => {
    const blob = new Blob([view.source || ''], { type: 'text/plain' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url; a.download = `${(view.subject || 'email').slice(0, 40)}.eml`; a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <>
      <Title level={4}>Extract Emails</Title>
      <Paragraph type="secondary">Pulls emails <b>live from the mailbox</b> (nothing stored). Pick fields to show; columns appear only for what you select.</Paragraph>

      <Card style={{ marginBottom: 16 }}>
        <Space direction="vertical" style={{ width: '100%' }} size="middle">
          <Space wrap>
            <Select style={{ width: 320 }} placeholder="Select account" value={accountId} onChange={setAccountId}
              options={accounts.map(a => ({ value: a.id, label: a.email }))} />
            <span>How many:</span>
            <InputNumber min={1} max={200} value={count} onChange={setCount} />
            <Space><Text>Include full source</Text><Switch checked={withSource} onChange={setWithSource} /></Space>
            <Button type="primary" loading={busy} onClick={run}>Extract</Button>
          </Space>
          <div>
            <Paragraph style={{ marginBottom: 6 }} strong>Columns to show:</Paragraph>
            <Select mode="multiple" allowClear style={{ width: '100%' }} value={fields} onChange={setFields}
              placeholder="Pick columns (order = column position)..."
              options={FIELDS.map(f => ({ label: f.label, value: f.key }))} />
          </div>
          <div>
            <Paragraph style={{ marginBottom: 6 }} strong>Filter by placement:</Paragraph>
            <Select mode="multiple" allowClear style={{ width: '100%' }} value={placements} onChange={setPlacements}
              placeholder={ispForAccount ? `Placements for ${ispForAccount.name}` : 'All placements'}
              options={placementOptions.length ? placementOptions : [
                { value: 'primary', label: 'Primary Inbox' },
                { value: 'promotions', label: 'Promotions' },
                { value: 'social', label: 'Social' },
                { value: 'updates', label: 'Updates / Notifications' },
                { value: 'forums', label: 'Forums' },
                { value: 'spam', label: 'Spam' },
              ]} />
          </div>
        </Space>
      </Card>

      {rows.length > 0 && (
        <Card
          title={`${filteredRows.length} emails`}
          extra={
            <Space wrap>
              <Button icon={<SaveOutlined />} type="primary" ghost
                disabled={!selectedKeys.length} onClick={saveSelected}>
                Save selected ({selectedKeys.length})
              </Button>
              <Select size="small" value={sepChoice} onChange={setSepChoice} style={{ width: 120 }}
                options={SEPARATORS} title="Separator for copy" />
              <Dropdown menu={copyMenu} trigger={['click']}>
                <Button icon={<CopyOutlined />}>Copy <DownOutlined /></Button>
              </Dropdown>
              <Button icon={<DownloadOutlined />} onClick={() => exportFile('csv')}>CSV</Button>
              <Button icon={<DownloadOutlined />} type="primary" onClick={() => exportFile('xlsx')}>Excel</Button>
            </Space>}>
          <Input allowClear prefix={<SearchOutlined />} placeholder="Search keyword across all columns..."
            value={keyword} onChange={(e) => setKeyword(e.target.value)}
            style={{ marginBottom: 12, maxWidth: 360 }} />
          <Table rowKey={(r, i) => rowKeyOf(r, i)} dataSource={filteredRows} columns={columns}
            rowSelection={{ selectedRowKeys: selectedKeys, onChange: setSelectedKeys }}
            scroll={{ x: true }} size="small" pagination={{ pageSize: 25 }} />
        </Card>
      )}

      <Modal open={!!view} title={view?.subject || 'Email source'} width={820}
        onCancel={() => setView(null)}
        footer={[
          <Button key="copy" icon={<CopyOutlined />} onClick={copySource}>Copy</Button>,
          <Button key="dl" icon={<DownloadOutlined />} onClick={downloadSource}>Download .eml</Button>,
          <Button key="close" type="primary" onClick={() => setView(null)}>Close</Button>,
        ]}>
        <pre style={{ maxHeight: 480, overflow: 'auto', background: '#0f172a', color: '#e2e8f0',
          padding: 14, borderRadius: 8, fontSize: 12, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
          {view?.source || '(no source)'}
        </pre>
      </Modal>
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\ExtractPage.jsx'

Set-Content -LiteralPath 'frontend\src\services\accounts.js' -Encoding utf8 -Value @'
import client from '../api/client'

export const fetchAccounts = () => client.get('/api/accounts').then(r => r.data)
export const toggleAccount = (id) => client.post(`/api/accounts/${id}/toggle`)
export const removeAccount = (id) => client.delete(`/api/accounts/${id}`)

export const startGoogleAuth = (socketId) =>
  client.get('/api/auth/google/start', { params: { socketId } }).then(r => r.data)

// Normal user: send ispId (host/port hidden). Admin: may send host/port directly.
export const addImapAccount = (payload) =>
  client.post('/api/accounts/imap', payload).then(r => r.data)

// Enabled ISP presets for the picker (available to all logged-in users)
export const fetchIsps = () => client.get('/api/accounts/isps').then(r => r.data)

export const extractEmails = (accountId, count = 50, includeSource = false, categories = []) =>
  client.post(`/api/accounts/${accountId}/extract`, { count, includeSource, categories }).then(r => r.data)

export const refreshAccount = (id) =>
  client.post(`/api/accounts/${id}/refresh`).then(r => r.data)

export const searchUsers = (q) =>
  client.get('/api/accounts/users/search', { params: { q } }).then(r => r.data)
export const shareAccount = (id, userId) =>
  client.post(`/api/accounts/${id}/share`, { userId })

export const gmailEnabled = () =>
  client.get('/api/accounts/gmail-enabled').then(r => r.data.enabled)

export const startAll = () => client.post('/api/accounts/start-all')
export const pauseAll = () => client.post('/api/accounts/pause-all')

export const setPriority = (id, priority) =>
  client.post(`/api/accounts/${id}/priority`, { priority })

export const resumeAll = () => client.post('/api/accounts/resume')

// Storage (persistent saved emails)
export const getSavedEmails    = () => client.get('/api/accounts/saved').then(r => r.data)
export const saveEmailsToStore = (emails) => client.post('/api/accounts/saved', { emails })
export const deleteSavedEmail  = (id) => client.delete(`/api/accounts/saved/${id}`)
export const clearSavedEmails  = () => client.delete('/api/accounts/saved')
'@
Write-Host 'wrote frontend\src\services\accounts.js'

Write-Host ""
Write-Host "STAGE 41 written."
Write-Host "1) Run backend\db\migration-stage41.sql in Supabase (creates saved_emails table)."
Write-Host "2) Restart backend + frontend, hard-refresh."
Write-Host "Saved emails now persist in the DB - survive refresh and logout."
