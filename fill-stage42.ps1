# fill-stage42.ps1 - Vault (encrypted secrets), owner-name toggle, Storage source viewer (body/text/find/highlight)
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path backend\db,backend\src\routes,frontend\src\services,frontend\src\pages,frontend\src\pages\admin,frontend\src\components\accounts,frontend\src\layout | Out-Null

Set-Content -LiteralPath 'backend\db\migration-stage42.sql' -Encoding utf8 -Value @'
-- Stage 42: personal Vault - encrypted secrets (app passwords + notes) per user.
-- The 'secret' column stores AES-256-GCM encrypted text (same crypto as account creds).
create table if not exists vault_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  label text not null,
  account_email text,
  username text,
  secret text,          -- encrypted (app password / token)
  notes text,           -- encrypted (free notes)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_vault_user on vault_items(user_id, created_at desc);
'@
Write-Host 'wrote backend\db\migration-stage42.sql'

Set-Content -LiteralPath 'backend\server.js' -Encoding utf8 -Value @'
import express from 'express'
import http from 'http'
import cors from 'cors'
import jwt from 'jsonwebtoken'
import { Server } from 'socket.io'
import { config } from './src/config.js'
import { initMonitor, startForUser, scheduleStopForUser } from './src/monitor.js'
import { touchUser, purgeOldEmails, purgeResolvedRequests } from './src/store.js'
import { auth } from './src/auth-middleware.js'
import { isStaff } from './src/permissions.js'
import authRoutes from './src/routes/auth.js'
import accountRoutes from './src/routes/accounts.js'
import adminRoutes from './src/routes/admin.js'
import toolsRoutes from './src/routes/tools.js'
import requestRoutes from './src/routes/requests.js'
import vaultRoutes from './src/routes/vault.js'

const app = express()

// Never let a transient DB/network error crash the whole backend.
process.on('unhandledRejection', (err) => {
  console.error('[unhandledRejection]', err?.message || err)
})
process.on('uncaughtException', (err) => {
  console.error('[uncaughtException]', err?.message || err)
})

// CORS: allow the configured frontend, plus any *.vercel.app preview URL.
// FRONTEND_URL can be a comma-separated list of allowed origins.
const allowedOrigins = (config.frontendUrl || '').split(',').map(s => s.trim()).filter(Boolean)
const corsCheck = (origin, cb) => {
  // allow same-origin / curl (no origin), the configured origins, and vercel previews
  if (!origin || allowedOrigins.includes(origin) || /\.vercel\.app$/.test(new URL(origin).hostname)) {
    return cb(null, true)
  }
  cb(null, true) // be permissive for a temporary demo; tighten later if needed
}

app.use(cors({ origin: corsCheck, credentials: true }))
app.use(express.json())

// Request logger: prints every request + its response status to the terminal.
// For 4xx/5xx it also prints the JSON message the server sent back, so failures
// like a 400 are immediately visible instead of silent.
app.use((req, res, next) => {
  const start = Date.now()
  const origJson = res.json.bind(res)
  let payload
  res.json = (body) => { payload = body; return origJson(body) }
  res.on('finish', () => {
    const ms = Date.now() - start
    const base = `${req.method} ${req.originalUrl} -> ${res.statusCode} (${ms}ms)`
    if (res.statusCode >= 400) {
      const msg = payload && payload.message ? ` :: ${payload.message}` : ''
      console.error('[REQ]', base + msg)
    } else {
      console.log('[REQ]', base)
    }
  })
  next()
})

// live presence: userId -> set of socket ids
const online = new Map()

app.get('/api/health', (_req, res) => res.json({ ok: true }))
app.get('/api/presence', auth, (req, res) => {
  if (!isStaff(req.user)) return res.status(403).json({ message: 'Staff only' })
  res.json({ onlineNow: online.size, onlineIds: [...online.keys()] })
})

app.use('/api/auth', authRoutes)
app.use('/api/accounts', accountRoutes)
app.use('/api/admin', adminRoutes)
app.use('/api/tools', toolsRoutes)
app.use('/api/requests', requestRoutes)
app.use('/api/vault', vaultRoutes)

const server = http.createServer(app)
const io = new Server(server, { cors: { origin: corsCheck, credentials: true } })

io.on('connection', (socket) => {
  const token = socket.handshake.auth?.token
  try {
    const payload = jwt.verify(token, config.jwtSecret)
    socket.userId = payload.id
    socket.join(`user:${payload.id}`)
    if (payload.is_admin || payload.role === 'support') socket.join('staff')
    if (!online.has(payload.id)) online.set(payload.id, new Set())
    online.get(payload.id).add(socket.id)
    touchUser(payload.id).catch(() => {})
    startForUser(payload.id).catch(() => {})  // start watchers when user opens app
  } catch { /* anonymous */ }

  socket.on('disconnect', () => {
    const set = online.get(socket.userId)
    if (set) {
      set.delete(socket.id)
      if (!set.size) {
        online.delete(socket.userId)
        scheduleStopForUser(socket.userId)  // auto-pause ~10 min after going offline
      }
    }
  })
})

initMonitor(io)

// purge emails older than 24h, now and hourly
purgeOldEmails().catch(() => {})
setInterval(() => { purgeOldEmails().catch(() => {}); purgeResolvedRequests().catch(() => {}) }, 60 * 60 * 1000)

server.listen(config.port, () => console.log(`Backend running on http://localhost:${config.port}`))
'@
Write-Host 'wrote backend\server.js'

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

// ---------------- personal Vault (encrypted secrets per user) ----------------
function vEnc(text) { return text ? encrypt({ v: text }) : null }
function vDec(blob) { try { return blob ? decrypt(blob).v : '' } catch { return '' } }

export async function listVaultItems(userId, reveal = false) {
  const { rows } = await q('select * from vault_items where user_id = $1 order by created_at desc', [userId])
  return rows.map(r => ({
    id: r.id, label: r.label, account_email: r.account_email, username: r.username,
    notes: reveal ? vDec(r.notes) : undefined,
    secret: reveal ? vDec(r.secret) : undefined,
    hasSecret: !!r.secret, hasNotes: !!r.notes,
    created_at: r.created_at, updated_at: r.updated_at,
  }))
}

export async function getVaultItem(userId, id) {
  const { rows } = await q('select * from vault_items where id = $1 and user_id = $2', [id, userId])
  if (!rows[0]) return null
  const r = rows[0]
  return { id: r.id, label: r.label, account_email: r.account_email, username: r.username,
    secret: vDec(r.secret), notes: vDec(r.notes) }
}

export async function addVaultItem(userId, { label, account_email, username, secret, notes }) {
  const { rows } = await q(
    `insert into vault_items (user_id, label, account_email, username, secret, notes)
     values ($1,$2,$3,$4,$5,$6) returning id`,
    [userId, label || 'Untitled', account_email || null, username || null, vEnc(secret), vEnc(notes)])
  return rows[0]
}

export async function updateVaultItem(userId, id, { label, account_email, username, secret, notes }) {
  await q(
    `update vault_items set label=$1, account_email=$2, username=$3, secret=$4, notes=$5, updated_at=now()
     where id=$6 and user_id=$7`,
    [label || 'Untitled', account_email || null, username || null, vEnc(secret), vEnc(notes), id, userId])
}

export async function deleteVaultItem(userId, id) {
  await q('delete from vault_items where id = $1 and user_id = $2', [id, userId])
}
'@
Write-Host 'wrote backend\src\store.js'

Set-Content -LiteralPath 'backend\src\routes\vault.js' -Encoding utf8 -Value @'
import { Router } from 'express'
import { auth } from '../auth-middleware.js'
import {
  listVaultItems, getVaultItem, addVaultItem, updateVaultItem, deleteVaultItem,
} from '../store.js'

const router = Router()
router.use(auth)

// list items (secrets hidden by default - only labels/usernames shown)
router.get('/', async (req, res) => {
  res.json(await listVaultItems(req.user.id, false))
})

// reveal a single item's secret + notes (explicit action)
router.get('/:id/reveal', async (req, res) => {
  const item = await getVaultItem(req.user.id, req.params.id)
  if (!item) return res.status(404).json({ message: 'Not found' })
  res.json(item)
})

router.post('/', async (req, res) => {
  const { label, account_email, username, secret, notes } = req.body || {}
  if (!label) return res.status(400).json({ message: 'Label is required' })
  const row = await addVaultItem(req.user.id, { label, account_email, username, secret, notes })
  res.json({ ok: true, id: row.id })
})

router.put('/:id', async (req, res) => {
  const { label, account_email, username, secret, notes } = req.body || {}
  await updateVaultItem(req.user.id, req.params.id, { label, account_email, username, secret, notes })
  res.json({ ok: true })
})

router.delete('/:id', async (req, res) => {
  await deleteVaultItem(req.user.id, req.params.id)
  res.json({ ok: true })
})

export default router
'@
Write-Host 'wrote backend\src\routes\vault.js'

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
'@
Write-Host 'wrote backend\src\routes\accounts.js'

Set-Content -LiteralPath 'backend\src\routes\admin.js' -Encoding utf8 -Value @'
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
  show_owner_name: String(await getSetting('show_owner_name', false)) === 'true',
  gmail_client_id: await getSetting('gmail_client_id', ''),
  gmail_redirect_uri: await getSetting('gmail_redirect_uri', ''),
  // client secret intentionally not returned
}))
router.put('/settings', requirePerm('manage_isps'), async (req, res) => {
  if (req.body.token_hours != null) await setSetting('token_hours', Number(req.body.token_hours))
  if (req.body.store_emails != null) await setSetting('store_emails', !!req.body.store_emails)
  if (req.body.gmail_api_enabled != null) await setSetting('gmail_api_enabled', !!req.body.gmail_api_enabled)
  if (req.body.show_owner_name != null) await setSetting('show_owner_name', !!req.body.show_owner_name)
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
'@
Write-Host 'wrote backend\src\routes\admin.js'

Set-Content -LiteralPath 'frontend\src\services\vault.js' -Encoding utf8 -Value @'
import client from '../api/client'

export const getVaultItems  = () => client.get('/api/vault').then(r => r.data)
export const revealVaultItem = (id) => client.get(`/api/vault/${id}/reveal`).then(r => r.data)
export const addVaultItem    = (payload) => client.post('/api/vault', payload)
export const updateVaultItem = (id, payload) => client.put(`/api/vault/${id}`, payload)
export const deleteVaultItem = (id) => client.delete(`/api/vault/${id}`)
'@
Write-Host 'wrote frontend\src\services\vault.js'

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

export const getUiSettings = () => client.get('/api/accounts/ui-settings').then(r => r.data)
'@
Write-Host 'wrote frontend\src\services\accounts.js'

Set-Content -LiteralPath 'frontend\src\pages\VaultPage.jsx' -Encoding utf8 -Value @'
import { useState, useEffect } from 'react'
import { Card, Table, Button, Typography, Space, Empty, Modal, Form, Input, message, Tooltip } from 'antd'
import { PlusOutlined, EyeOutlined, EyeInvisibleOutlined, EditOutlined, DeleteOutlined, CopyOutlined, LockOutlined } from '@ant-design/icons'
import { getVaultItems, revealVaultItem, addVaultItem, updateVaultItem, deleteVaultItem } from '../services/vault'

const { Title, Text } = Typography

// Personal Vault: securely store app passwords + notes (encrypted at rest in the DB).
export default function VaultPage() {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [modal, setModal] = useState(null) // 'new' | item being edited
  const [revealed, setRevealed] = useState({}) // id -> { secret, notes }
  const [form] = Form.useForm()

  const load = () => {
    setLoading(true)
    getVaultItems().then(setItems).catch(() => setItems([])).finally(() => setLoading(false))
  }
  useEffect(load, [])

  const openNew = () => { setModal('new'); form.resetFields() }
  const openEdit = async (item) => {
    // fetch the decrypted values to prefill the form
    try {
      const full = await revealVaultItem(item.id)
      setModal(item)
      form.setFieldsValue({ label: full.label, account_email: full.account_email,
        username: full.username, secret: full.secret, notes: full.notes })
    } catch { message.error('Could not open item') }
  }
  const submit = async () => {
    const v = await form.validateFields()
    try {
      if (modal === 'new') await addVaultItem(v)
      else await updateVaultItem(modal.id, v)
      message.success('Saved'); setModal(null); load()
    } catch (e) { message.error(e.response?.data?.message || 'Save failed') }
  }
  const remove = async (id) => {
    try { await deleteVaultItem(id); message.success('Deleted'); load() }
    catch { message.error('Delete failed') }
  }
  const toggleReveal = async (item) => {
    if (revealed[item.id]) { setRevealed(p => { const n = { ...p }; delete n[item.id]; return n }); return }
    try {
      const full = await revealVaultItem(item.id)
      setRevealed(p => ({ ...p, [item.id]: { secret: full.secret, notes: full.notes } }))
    } catch { message.error('Could not reveal') }
  }
  const copy = (text) => navigator.clipboard.writeText(text || '')
    .then(() => message.success('Copied')).catch(() => message.error('Copy failed'))

  const columns = [
    { title: 'Label', dataIndex: 'label', render: (v) => <Space><LockOutlined />{v}</Space> },
    { title: 'Account', dataIndex: 'account_email', ellipsis: true, render: (v) => v || <Text type="secondary">-</Text> },
    { title: 'Username', dataIndex: 'username', render: (v) => v || <Text type="secondary">-</Text> },
    { title: 'Secret', key: 'secret', render: (_, r) => {
      const shown = revealed[r.id]
      return (
        <Space>
          <code style={{ fontSize: 12 }}>
            {!r.hasSecret ? <Text type="secondary">none</Text> : shown ? shown.secret : '********'}
          </code>
          {r.hasSecret && (
            <Tooltip title={shown ? 'Hide' : 'Reveal'}>
              <Button size="small" type="text" icon={shown ? <EyeInvisibleOutlined /> : <EyeOutlined />}
                onClick={() => toggleReveal(r)} />
            </Tooltip>
          )}
          {r.hasSecret && shown && (
            <Button size="small" type="text" icon={<CopyOutlined />} onClick={() => copy(shown.secret)} />
          )}
        </Space>
      )
    } },
    { title: 'Actions', key: 'a', width: 110, render: (_, r) =>
      <Space>
        <Button size="small" icon={<EditOutlined />} onClick={() => openEdit(r)} />
        <Button size="small" danger icon={<DeleteOutlined />}
          onClick={() => Modal.confirm({ title: `Delete "${r.label}"?`, okButtonProps: { danger: true }, onOk: () => remove(r.id) })} />
      </Space> },
  ]

  return (
    <>
      <Title level={4}>Vault</Title>
      <Text type="secondary">Securely store app passwords, tokens, and notes. Encrypted at rest - only you can see them.</Text>
      <Card style={{ marginTop: 16 }}
        title={`Saved secrets (${items.length})`}
        extra={<Button type="primary" icon={<PlusOutlined />} onClick={openNew}>New secret</Button>}>
        {items.length === 0 && !loading ? (
          <Empty description="No secrets yet. Click 'New secret' to add an app password or note." />
        ) : (
          <Table rowKey="id" dataSource={items} columns={columns} loading={loading}
            scroll={{ x: true }} size="small" pagination={{ pageSize: 20 }}
            expandable={{
              expandedRowRender: (r) => {
                const shown = revealed[r.id]
                return (
                  <div style={{ padding: '4px 8px' }}>
                    <Text strong>Notes: </Text>
                    {r.hasNotes
                      ? (shown ? <span style={{ whiteSpace: 'pre-wrap' }}>{shown.notes}</span>
                                : <Text type="secondary">hidden - click the eye to reveal</Text>)
                      : <Text type="secondary">none</Text>}
                  </div>
                )
              },
              rowExpandable: (r) => r.hasNotes,
            }} />
        )}
      </Card>

      <Modal open={!!modal} title={modal === 'new' ? 'New secret' : 'Edit secret'}
        onCancel={() => setModal(null)} onOk={submit} okText="Save">
        <Form form={form} layout="vertical">
          <Form.Item name="label" label="Label" rules={[{ required: true, message: 'Give it a name' }]}>
            <Input placeholder="e.g. Gmail app password - work" />
          </Form.Item>
          <Form.Item name="account_email" label="Account email">
            <Input placeholder="name@gmail.com" />
          </Form.Item>
          <Form.Item name="username" label="Username (optional)">
            <Input />
          </Form.Item>
          <Form.Item name="secret" label="App password / secret">
            <Input.Password placeholder="the 16-char app password or token" />
          </Form.Item>
          <Form.Item name="notes" label="Notes">
            <Input.TextArea rows={3} placeholder="anything you want to remember" />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\VaultPage.jsx'

Set-Content -LiteralPath 'frontend\src\pages\StoragePage.jsx' -Encoding utf8 -Value @'
import { useState } from 'react'
import { Card, Table, Button, Typography, Space, Empty, Modal, Tag, message, Segmented, Input } from 'antd'
import { DownloadOutlined, DeleteOutlined, EyeOutlined, ClearOutlined, SearchOutlined } from '@ant-design/icons'
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

      <Modal open={!!view} title={view?.subject || 'Email source'} width={900} footer={null}
        onCancel={() => setView(null)}>
        <SourceViewer email={view} buildFallback={buildFallback} />
      </Modal>
    </>
  )
}

// Default header params to highlight in the source view
const DEFAULT_PARAMS = ['SPF', 'DKIM', 'DMARC', 'Received', 'From', 'Return-Path', 'Message-ID', 'Authentication-Results']

function SourceViewer({ email, buildFallback }) {
  const [viewMode, setViewMode] = useState('full') // full | body | text
  const [find, setFind] = useState('')
  const [params, setParams] = useState(DEFAULT_PARAMS)
  const [customParam, setCustomParam] = useState('')
  if (!email) return null

  const full = email.source || buildFallback(email)
  // body = everything after the first blank line (headers end); text = body_text
  const bodyOnly = (() => {
    const idx = full.indexOf('\n\n')
    return idx >= 0 ? full.slice(idx + 2) : full
  })()
  const textOnly = email.body_text || bodyOnly
  const content = viewMode === 'body' ? bodyOnly : viewMode === 'text' ? textOnly : full

  // Build highlighted HTML: highlight param names (yellow) + find matches (green)
  const escapeHtml = (s) => s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]))
  const escapeReg = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  let html = escapeHtml(content)
  params.filter(Boolean).forEach(p => {
    const re = new RegExp(`(${escapeReg(p)})`, 'gi')
    html = html.replace(re, '<mark style="background:#fde047;color:#111">$1</mark>')
  })
  if (find.trim()) {
    const re = new RegExp(`(${escapeReg(find.trim())})`, 'gi')
    html = html.replace(re, '<mark style="background:#34d399;color:#062">$1</mark>')
  }

  const addParam = () => {
    const p = customParam.trim()
    if (p && !params.includes(p)) setParams([...params, p])
    setCustomParam('')
  }

  return (
    <div>
      <Space wrap style={{ marginBottom: 10 }}>
        <Segmented value={viewMode} onChange={setViewMode}
          options={[{ label: 'Full source', value: 'full' }, { label: 'Body', value: 'body' }, { label: 'Text', value: 'text' }]} />
        <Input prefix={<SearchOutlined />} placeholder="Find in source..." value={find}
          onChange={(e) => setFind(e.target.value)} style={{ width: 220 }} allowClear />
        <Button size="small" icon={<DownloadOutlined />} onClick={() => {
          const blob = new Blob([full], { type: 'message/rfc822' })
          const url = URL.createObjectURL(blob); const a = document.createElement('a')
          a.href = url; a.download = `${(email.subject || 'email').replace(/[^a-z0-9]+/gi, '_').slice(0, 40)}.eml`; a.click()
          URL.revokeObjectURL(url)
        }}>Download .eml</Button>
      </Space>

      <div style={{ marginBottom: 10 }}>
        <Text type="secondary" style={{ fontSize: 12 }}>Highlighted params: </Text>
        <Space size={[4, 4]} wrap style={{ marginTop: 4 }}>
          {params.map(p => (
            <Tag key={p} closable onClose={() => setParams(params.filter(x => x !== p))}
              style={{ background: '#fde047', borderColor: '#eab308' }}>{p}</Tag>
          ))}
          <Input size="small" placeholder="add param" value={customParam} style={{ width: 120 }}
            onChange={(e) => setCustomParam(e.target.value)} onPressEnter={addParam} />
          <Button size="small" onClick={addParam}>Add</Button>
        </Space>
      </div>

      <pre style={{ maxHeight: 440, overflow: 'auto', background: '#0f172a', color: '#e2e8f0',
        padding: 14, borderRadius: 8, fontSize: 12, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}
        dangerouslySetInnerHTML={{ __html: html }} />
    </div>
  )
}
'@
Write-Host 'wrote frontend\src\pages\StoragePage.jsx'

Set-Content -LiteralPath 'frontend\src\pages\AccountsPage.jsx' -Encoding utf8 -Value @'
import { useState, useMemo, useEffect, useRef } from 'react'
import { Input, Button, Space, Spin, Empty, Typography, Select, Segmented, Card, Statistic, Row, Col } from 'antd'
import { PlusOutlined, SearchOutlined, MailOutlined, HolderOutlined, PlayCircleOutlined, PauseCircleOutlined, CopyOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import AccountCard from '../components/accounts/AccountCard'
import AddAccountModal from '../components/accounts/AddAccountModal'
import { startAll, pauseAll, refreshAccount, fetchIsps } from '../services/accounts'
import { message } from 'antd'

const { Title, Text } = Typography

export default function AccountsPage() {
  const { accounts, loading, newEmailIds, toggle, remove, mergeEmails, user } = useApp()
  const isStaff = user?.role === 'admin' || user?.role === 'support'
  const [search, setSearch] = useState('')
  const [esp, setEsp] = useState('all')
  const [placement, setPlacement] = useState('all')
  const [modalOpen, setModalOpen] = useState(false)
  const [isps, setIsps] = useState([])

  useEffect(() => { fetchIsps().then(setIsps).catch(() => setIsps([])) }, [])
  const [showOwnerName, setShowOwnerName] = useState(false)
  useEffect(() => {
    import('../services/accounts').then(m => m.getUiSettings?.().then(s => setShowOwnerName(!!s.show_owner_name)).catch(() => {}))
  }, [])

  // resolve an account's ISP name (by isp_id, else by email domain)
  const ispNameOf = (a) => {
    const byId = isps.find(i => i.id === a.isp_id)
    if (byId) return byId.name
    const domain = (a.email || '').split('@')[1]?.split('.')[0]?.toLowerCase()
    const byDomain = isps.find(i => i.name?.toLowerCase() === domain)
    return byDomain?.name || 'Other'
  }

  // per-user saved card order (account id list) in localStorage
  const orderKey = `cardOrder:${user?.id || 'anon'}`
  const [order, setOrder] = useState(() => {
    try { return JSON.parse(localStorage.getItem(orderKey)) || [] } catch { return [] }
  })
  const [dragId, setDragId] = useState(null)

  const saveOrder = (next) => { setOrder(next); localStorage.setItem(orderKey, JSON.stringify(next)) }

  // Combined "registered accounts" box state
  const [allSep, setAllSep] = useState('\n') // copy separator (default new line)

  // Auto-refresh fallback: every 30s, pull newest for each active account so live
  // mail still appears if a socket event is missed. Uses a ref so the interval is
  // created ONCE (not re-created on every email update, which caused a refresh loop).
  const accountsRef = useRef(accounts)
  accountsRef.current = accounts
  const mergeRef = useRef(mergeEmails)
  mergeRef.current = mergeEmails
  // stable signature: only the SET of account ids, so the interval resets only when
  // accounts are added/removed - not when their emails change.
  const accountIdsKey = useMemo(() => accounts.map(a => a.id).sort().join(','), [accounts])
  useEffect(() => {
    if (!accountIdsKey) return
    const t = setInterval(() => {
      accountsRef.current.forEach(a => {
        if (a.active) refreshAccount(a.id).then(d => mergeRef.current(a.id, d.emails || [])).catch(() => {})
      })
    }, 60 * 1000) // 60s fallback - the live socket + backend poll handle realtime
    return () => clearInterval(t)
  }, [accountIdsKey])

  const q = search.toLowerCase().trim()

  const visible = useMemo(() => accounts.filter(a => {
    if (esp !== 'all' && ispNameOf(a) !== esp) return false
    if (!q) return true
    return a.email.toLowerCase().includes(q) ||
      (a.emails || []).some(e =>
        (e.sender?.name || '').toLowerCase().includes(q) ||
        (e.sender?.subject || '').toLowerCase().includes(q) ||
        (e.sender?.domain || '').toLowerCase().includes(q))
  }), [accounts, q, esp])

  const totals = useMemo(() => {
    const all = visible.flatMap(a => a.emails || [])
    const by = (c) => all.filter(e => e.category === c).length
    return { total: all.length, primary: by('primary'), spam: by('spam'),
      promotions: by('promotions'), social: by('social'), updates: by('updates'),
      forums: by('forums') }
  }, [visible])

  // grand total across ALL accounts (live emails this session)
  const grandTotal = useMemo(() =>
    accounts.reduce((sum, a) => sum + (a.emails || []).length, 0), [accounts])

  // Filter the emails shown INSIDE each card: by placement AND by the keyword.
  // So typing a keyword shows only the matching emails (sender/subject/domain/ip),
  // not just the matching accounts.
  const emailFilter = (e) => {
    if (placement !== 'all' && e.category !== placement) return false
    if (q) {
      const hit =
        (e.sender?.name || '').toLowerCase().includes(q) ||
        (e.sender?.subject || '').toLowerCase().includes(q) ||
        (e.sender?.email || '').toLowerCase().includes(q) ||
        (e.sender?.domain || '').toLowerCase().includes(q) ||
        (e.ip || '').toLowerCase().includes(q)
      if (!hit) return false
    }
    return true
  }

  // The combined box lists the MONITORED ACCOUNT ADDRESSES (the mailboxes the user
  // registered), not the content of incoming mail. Respects the ISP filter and the
  // keyword search (matched against the account address).
  const allEmailValues = useMemo(() => {
    let list = visible.map(a => a.email).filter(Boolean)
    if (q) list = list.filter(addr => addr.toLowerCase().includes(q))
    // dedupe, preserve order
    const seen = new Set(); const out = []
    list.forEach(addr => { if (!seen.has(addr)) { seen.add(addr); out.push(addr) } })
    return out
  }, [visible, q])

  // apply saved per-user order: ordered ids first, then any new accounts
  const ordered = useMemo(() => {
    const byId = Object.fromEntries(visible.map(a => [a.id, a]))
    const inOrder = order.map(id => byId[id]).filter(Boolean)
    const rest = visible.filter(a => !order.includes(a.id))
    return [...inOrder, ...rest]
  }, [visible, order])

  // drag handlers (native HTML5)
  const onDrop = (targetId) => {
    if (!dragId || dragId === targetId) return
    const ids = ordered.map(a => a.id)
    const from = ids.indexOf(dragId)
    const to = ids.indexOf(targetId)
    if (from === -1 || to === -1) return
    ids.splice(to, 0, ids.splice(from, 1)[0])
    saveOrder(ids)
    setDragId(null)
  }

  if (loading) return <Spin size="large" style={{ display: 'block', margin: '80px auto' }} />

  const espOptions = [{ value: 'all', label: 'All ISPs' },
    ...isps.map(i => ({ value: i.name, label: i.name }))]

  return (
    <>
      <Space style={{ width: '100%', justifyContent: 'space-between', marginBottom: 12 }} wrap>
        <Title level={4} style={{ margin: 0 }}>Monitor</Title>
        <Space wrap>
          <Input allowClear prefix={<SearchOutlined />} placeholder="Search keyword"
            value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 240 }} />
          <Select value={esp} onChange={setEsp} options={espOptions} style={{ width: 140 }} />
          <Button icon={<PlayCircleOutlined />} onClick={async () => { await startAll(); message.success("Starting all accounts") }}>Start All</Button>
          <Button icon={<PauseCircleOutlined />} danger onClick={async () => { await pauseAll(); message.success("Pausing all accounts") }}>Pause All</Button>
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setModalOpen(true)}>Add Account</Button>
        </Space>
      </Space>

      {/* Box listing the registered account addresses (the monitored mailboxes), copyable */}
      <Card style={{ marginBottom: 16 }} styles={{ body: { padding: 16 } }}
        title={`Registered accounts (${allEmailValues.length})`}
        extra={
          <Space>
            <Select size="small" value={allSep} onChange={setAllSep} style={{ width: 120 }}
              options={[
                { value: '\n', label: 'New line' },
                { value: ', ', label: 'Comma' },
                { value: '; ', label: 'Semicolon' },
                { value: ' | ', label: 'Pipe' },
                { value: '\t', label: 'Tab' },
              ]} />
            <Button type="primary" icon={<CopyOutlined />} onClick={() => {
              if (!allEmailValues.length) return message.warning('No accounts to copy')
              navigator.clipboard.writeText(allEmailValues.join(allSep))
                .then(() => message.success(`Copied ${allEmailValues.length} accounts`))
                .catch(() => message.error('Copy failed'))
            }}>Copy</Button>
          </Space>}>
        <div style={{ maxHeight: 120, overflowY: 'auto', fontFamily: 'monospace', fontSize: 12,
          color: '#334155', background: '#f8fafc', borderRadius: 8, padding: 10, whiteSpace: 'pre-wrap' }}>
          {allEmailValues.length ? allEmailValues.join(' | ') : 'No accounts yet'}
        </div>
      </Card>

      {/* Top box: grand total live emails + placement filter */}
      <Card style={{ marginBottom: 16 }} styles={{ body: { padding: 16 } }}>
        <Row gutter={16} align="middle" wrap>
          <Col>
            <Statistic title="Total live emails (all accounts)" value={grandTotal}
              prefix={<MailOutlined />} valueStyle={{ color: '#2563eb' }} />
          </Col>
          <Col flex="auto" style={{ textAlign: 'right' }}>
            <Segmented value={placement} onChange={setPlacement}
              options={[
                { value: 'all', label: `All (${totals.total})` },
                { value: 'primary', label: `Inbox (${totals.primary})` },
                { value: 'spam', label: `Spam (${totals.spam})` },
                { value: 'promotions', label: `Promo (${totals.promotions})` },
                { value: 'social', label: `Social (${totals.social})` },
                { value: 'updates', label: `Updates (${totals.updates})` },
                { value: 'forums', label: `Forums (${totals.forums})` },
              ]} />
          </Col>
        </Row>
      </Card>

      {/* All account cards live inside this box */}
      <Card styles={{ body: { padding: 12 } }}>
        {accounts.length === 0 ? (
          <Empty description="No accounts yet">
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setModalOpen(true)}>Add Account</Button>
          </Empty>
        ) : visible.length === 0 ? (
          <Empty description="No accounts match" />
        ) : (
          ordered.map(a => (
            <div key={a.id}
              draggable={dragId === a.id}
              onDragStart={(e) => { e.dataTransfer.effectAllowed = 'move'; setDragId(a.id) }}
              onDragEnd={() => setDragId(null)}
              onDragOver={(e) => e.preventDefault()}
              onDrop={() => onDrop(a.id)}
              style={{ display: 'flex', alignItems: 'stretch', gap: 6,
                opacity: dragId === a.id ? 0.5 : 1 }}>

              {/* DRAG BUTTON - only this enables dragging */}
              <Button
                type="text"
                icon={<HolderOutlined />}
                title="Hold and drag to move this card"
                onMouseDown={() => setDragId(a.id)}
                onMouseUp={() => setDragId(null)}
                style={{ height: 'auto', cursor: 'grab', color: '#94a3b8',
                  display: 'flex', alignItems: 'center', borderRadius: 8 }}
              />

              <div style={{ flex: 1, minWidth: 0 }}>
                <AccountCard account={a} onToggle={toggle} onRemove={remove}
                  onRefresh={mergeEmails} newEmailIds={newEmailIds} emailFilter={emailFilter}
                  onPlacementClick={(cat) => setPlacement(cat)} showOwnerName={showOwnerName} />
              </div>
            </div>
          ))
        )}
      </Card>

      <AddAccountModal open={modalOpen} onClose={() => setModalOpen(false)} />
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\AccountsPage.jsx'

Set-Content -LiteralPath 'frontend\src\components\accounts\AccountCard.jsx' -Encoding utf8 -Value @'
import { useState, useMemo } from 'react'
import { Avatar, Button, Space, Popconfirm, Tag, Card, Typography, Input, Tooltip, message, Modal, AutoComplete } from 'antd'
import { MailOutlined, PlayCircleOutlined, PauseCircleOutlined, DeleteOutlined, SearchOutlined, LockOutlined, ReloadOutlined, ShareAltOutlined, StarOutlined, StarFilled } from '@ant-design/icons'
import EmailCard from '../emails/EmailCard'
import { useApp } from '../../context/AppProvider'
import { refreshAccount, searchUsers, shareAccount, setPriority } from '../../services/accounts'

const { Text } = Typography
const MAX_PER_SECTION = 40

export default function AccountCard({ account, onToggle, onRemove, onRefresh, newEmailIds, emailFilter, onPlacementClick, showOwnerName }) {
  const { user } = useApp()
  const isStaff = user?.role === 'admin' || user?.role === 'support'
  const isAdmin = !!user?.is_admin
  const [localSearch, setLocalSearch] = useState('')
  const [refreshing, setRefreshing] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [shareOptions, setShareOptions] = useState([])
  const [sharePick, setSharePick] = useState(null)
  const [shareText, setShareText] = useState('')
  const [priority, setPriorityState] = useState(!!account.priority)

  const isOwner = (account.owner_id || account.ownerId) === user?.id
  const isGlobal = account.scope === 'global'
  // Rule: normal users get NO crud on GLOBAL accounts (only staff do).
  // On personal accounts, the owner and staff have full crud.
  const canToggle = isGlobal ? isStaff : (isOwner || isStaff)
  const canDelete = isGlobal ? isStaff : (isOwner || isStaff)
  // Refresh: staff always; on personal accounts the owner; or a user explicitly
  // granted the refresh_accounts permission (but still not on global unless staff).
  const canRefresh = isStaff || (!isGlobal && isOwner) || (!isGlobal && !!user?.permissions?.refresh_accounts)
  // Share: only the owner of a personal account, or staff.
  const canShare = isGlobal ? isStaff : (isOwner || isStaff)
  // Priority: owner of a personal account, or staff.
  const canPriority = isGlobal ? isStaff : (isOwner || isStaff)

  const togglePriority = async () => {
    const next = !priority
    setPriorityState(next) // optimistic
    try { await setPriority(account.id, next) }
    catch { setPriorityState(!next); message.error('Could not change priority') }
  }

  const filtered = useMemo(() => {
    let list = account.emails || []
    if (emailFilter) list = list.filter(emailFilter)
    const q = localSearch.toLowerCase().trim()
    if (q) {
      list = list.filter(e =>
        (e.sender?.name || '').toLowerCase().includes(q) ||
        (e.sender?.subject || '').toLowerCase().includes(q) ||
        (e.sender?.domain || '').toLowerCase().includes(q) ||
        (e.ip || '').toLowerCase().includes(q))
    }
    return list
  }, [account.emails, localSearch, emailFilter])

  const total = (account.emails || []).length
  const shown = filtered.slice(0, MAX_PER_SECTION)
  const live = account.active

  const doRefresh = async () => {
    setRefreshing(true)
    try {
      const data = await refreshAccount(account.id)
      onRefresh?.(account.id, data.emails || [])
      message.success(`Refreshed ${account.email}`)
    } catch (e) {
      message.error(e.response?.data?.message || 'Refresh failed')
    } finally { setRefreshing(false) }
  }

  // share-by-name: type a name/code, system proposes matches (id shown), pick one
  const onShareSearch = async (text) => {
    setShareText(text)
    if (!text || text.length < 2) { setShareOptions([]); return }
    try {
      const users = await searchUsers(text)
      setShareOptions(users.map(u => ({
        value: u.id,
        label: `${u.username}  -  ID ${u.code}`,
      })))
    } catch { setShareOptions([]) }
  }
  const doShare = async () => {
    if (!sharePick) return message.warning('Pick a user from the list')
    try {
      await shareAccount(account.id, sharePick)
      message.success('Account shared')
      setShareOpen(false); setSharePick(null); setShareText(''); setShareOptions([])
    } catch (e) { message.error(e.response?.data?.message || 'Share failed') }
  }

  return (
    <Card styles={{ body: { padding: 14 } }} style={{ marginBottom: 14 }}>
      <div style={{ display: 'flex', gap: 16, alignItems: 'stretch' }}>
        <div style={{ width: 215, minWidth: 215, display: 'flex', flexDirection: 'column', gap: 8 }}>
          <Space align="center">
            {/* Envelope turns green when live, gray/amber when paused */}
            <Avatar shape="square"
              style={{ background: live ? '#16a34a' : '#94a3b8' }}
              icon={<MailOutlined />} />
            <Text strong style={{ color: live ? '#16a34a' : '#94a3b8' }}>
              {live ? 'Live' : 'Paused'}
            </Text>
          </Space>

          <Text strong style={{ wordBreak: 'break-all' }}>
            {showOwnerName ? (account.owner_username || account.ownerName || account.email) : account.email}
          </Text>
          <Space size={6} wrap>
            {isStaff && account.type && <Tag>{account.type.toUpperCase()}</Tag>}
            {account.scope === 'global' && <Tag color="purple">GLOBAL</Tag>}
            {priority && <Tag color="gold">PRIORITY</Tag>}
            <Tag color="blue">{total} emails</Tag>
          </Space>

          <Input size="small" allowClear prefix={<SearchOutlined />}
            placeholder="Filter this account"
            value={localSearch} onChange={(e) => setLocalSearch(e.target.value)} />

          {/* Controls: pause/resume + refresh + delete */}
          <Space style={{ marginTop: 'auto' }} wrap>
            {canToggle ? (
              <Tooltip title={live ? 'Pause' : 'Resume'}>
                <Button size="small" icon={live ? <PauseCircleOutlined /> : <PlayCircleOutlined />}
                  onClick={() => onToggle(account.id)} />
              </Tooltip>
            ) : (
              <Tooltip title="Global account - only staff can pause it">
                <Button size="small" disabled icon={live ? <PauseCircleOutlined /> : <PlayCircleOutlined />} />
              </Tooltip>
            )}
            {canRefresh && (
              <Tooltip title="Check for new emails now">
                <Button size="small" icon={<ReloadOutlined />} loading={refreshing} onClick={doRefresh} />
              </Tooltip>
            )}
            {canDelete ? (
              <Popconfirm title="Remove this account?" onConfirm={() => onRemove(account.id)}>
                <Button size="small" danger icon={<DeleteOutlined />}>Delete</Button>
              </Popconfirm>
            ) : (
              <Tooltip title="Global account  -  only the owner or staff can remove it">
                <Button size="small" disabled icon={<LockOutlined />}>Delete</Button>
              </Tooltip>
            )}
            {canShare && (
              <Tooltip title="Share this account with another user">
                <Button size="small" icon={<ShareAltOutlined />} onClick={() => setShareOpen(true)} />
              </Tooltip>
            )}
            {canPriority && (
              <Tooltip title={priority ? 'Priority - checked first. Click to unset.' : 'Set as priority (checked before other accounts)'}>
                <Button size="small"
                  icon={priority ? <StarFilled style={{ color: '#f59e0b' }} /> : <StarOutlined />}
                  onClick={togglePriority} />
              </Tooltip>
            )}
          </Space>
        </div>

        <div style={{ flex: 1, display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
          {shown.length === 0 ? (
            <div style={{ alignSelf: 'center', display: 'flex', alignItems: 'center', gap: 10,
              color: '#94a3b8', padding: '0 8px' }}>
              {localSearch ? (
                <Text type="secondary">No emails match this filter</Text>
              ) : live ? (
                <>
                  <span style={{ width: 9, height: 9, borderRadius: '50%', background: '#22c55e',
                    boxShadow: '0 0 0 0 rgba(34,197,94,0.6)', animation: 'livePulse 1.6s infinite' }} />
                  <Text type="secondary" style={{ fontWeight: 600 }}>Listening for new mail</Text>
                </>
              ) : (
                <Text type="secondary">Paused - press play to resume monitoring</Text>
              )}
            </div>
          ) : shown.map((em, i) => (
            <EmailCard key={em.id} email={em} isNew={newEmailIds.has(em.id)} index={i}
              onFilter={(text) => setLocalSearch(text)} onPlacementClick={onPlacementClick} />
          ))}
          {filtered.length > MAX_PER_SECTION && (
            <div style={{ alignSelf: 'center', minWidth: 90, color: '#94a3b8', fontSize: 12, textAlign: 'center' }}>
              +{filtered.length - MAX_PER_SECTION} more
            </div>
          )}
        </div>
      </div>

      <Modal title={`Share ${account.email}`} open={shareOpen} onCancel={() => setShareOpen(false)}
        onOk={doShare} okText="Share">
        <p style={{ color: '#64748b' }}>Type a username (or their 4-digit ID). Pick the right person from the suggestions.</p>
        <AutoComplete
          style={{ width: '100%' }}
          options={shareOptions}
          value={shareText}
          onSearch={onShareSearch}
          onChange={(v) => setShareText(v)}
          onSelect={(value, option) => { setSharePick(value); setShareText(option.label) }}
          placeholder="Start typing a name or ID..."
        />
      </Modal>
    </Card>
  )
}
'@
Write-Host 'wrote frontend\src\components\accounts\AccountCard.jsx'

Set-Content -LiteralPath 'frontend\src\pages\admin\SettingsPage.jsx' -Encoding utf8 -Value @'
import { useEffect, useState } from 'react'
import { Table, Button, Modal, Form, Input, InputNumber, Switch, Typography, Space, Tag, Popconfirm, Card, message } from 'antd'
import { PlusOutlined, DeleteOutlined, EditOutlined } from '@ant-design/icons'
import { getIspsAdmin, addIsp, updateIsp, deleteIsp, getSettings, saveSettings } from '../../services/admin'

const { Title, Paragraph } = Typography

export default function SettingsPage() {
  const [isps, setIsps] = useState([])
  const [loading, setLoading] = useState(true)
  const [open, setOpen] = useState(false)
  const [editing, setEditing] = useState(null)
  const [tokenHours, setTokenHours] = useState(48)
  const [storeEmails, setStoreEmails] = useState(false)
  const [showOwnerName, setShowOwnerName] = useState(false)
  const [gmailOn, setGmailOn] = useState(false)
  const [gmailCfg, setGmailCfg] = useState({ gmail_client_id: '', gmail_client_secret: '', gmail_redirect_uri: '' })
  const [form] = Form.useForm()

  const load = () => getIspsAdmin().then(setIsps).finally(() => setLoading(false))
  useEffect(() => { load(); getSettings().then(s => { setTokenHours(s.token_hours); setStoreEmails(s.store_emails); setGmailOn(s.gmail_api_enabled); setShowOwnerName(s.show_owner_name); setGmailCfg({ gmail_client_id: s.gmail_client_id || '', gmail_client_secret: '', gmail_redirect_uri: s.gmail_redirect_uri || '' }) }).catch(() => {}) }, [])

  const openNew = () => { setEditing(null); form.resetFields(); form.setFieldsValue({ port: 993, ssl: true, enabled: true }); setOpen(true) }
  const openEdit = (r) => { setEditing(r); form.setFieldsValue(r); setOpen(true) }

  const submit = async (vals) => {
    try {
      if (editing) await updateIsp(editing.id, vals)
      else await addIsp(vals)
      message.success('Saved'); setOpen(false); load()
    } catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }

  const remove = async (id) => { await deleteIsp(id); message.success('Deleted'); load() }
  const toggleEnabled = async (r) => { await updateIsp(r.id, { enabled: !r.enabled }); load() }

  const saveToken = async () => { await saveSettings({ token_hours: tokenHours }); message.success('Token lifetime saved') }

  const columns = [
    { title: 'Name', dataIndex: 'name' },
    { title: 'Host', dataIndex: 'host' },
    { title: 'Port', dataIndex: 'port' },
    { title: 'SSL', dataIndex: 'ssl', render: (v) => v ? <Tag color="green">SSL</Tag> : <Tag>none</Tag> },
    { title: 'Enabled', dataIndex: 'enabled', render: (v, r) => <Switch checked={v} onChange={() => toggleEnabled(r)} /> },
    { title: '', key: 'act', render: (_, r) => (
      <Space>
        <Button size="small" icon={<EditOutlined />} onClick={() => openEdit(r)} />
        <Popconfirm title="Delete this ISP?" onConfirm={() => remove(r.id)}>
          <Button size="small" danger icon={<DeleteOutlined />} />
        </Popconfirm>
      </Space>) },
  ]

  return (
    <>
      <Title level={4}>App Settings</Title>

      <Card title="Session" style={{ marginBottom: 16, maxWidth: 460 }}>
        <Space>
          <span>Auto-logout after</span>
          <InputNumber min={1} max={720} value={tokenHours} onChange={setTokenHours} addonAfter="hours" />
          <Button type="primary" onClick={saveToken}>Save</Button>
        </Space>
        <Paragraph type="secondary" style={{ marginTop: 8, marginBottom: 0 }}>
          Global default token lifetime. You can override per user on the Users page.
        </Paragraph>
      </Card>

      <Card title="Display" style={{ marginBottom: 16, maxWidth: 460 }}>
        <Space>
          <Switch checked={showOwnerName} onChange={async (v) => { setShowOwnerName(v); await saveSettings({ show_owner_name: v }); message.success(v ? "Showing owner name on cards" : "Showing account email on cards") }} />
          <span>{showOwnerName ? "Monitor cards show the OWNER NAME" : "Monitor cards show the account email"}</span>
        </Space>
        <Paragraph type="secondary" style={{ marginTop: 8, marginBottom: 0 }}>
          When on, each Monitor card shows the account owner's username instead of the full email address.
        </Paragraph>
      </Card>

      <Card title="Email storage" style={{ marginBottom: 16, maxWidth: 460 }}>
        <Space>
          <Switch checked={storeEmails} onChange={async (v) => { setStoreEmails(v); await saveSettings({ store_emails: v }); message.success(v ? "Storing emails" : "Not storing emails") }} />
          <span>{storeEmails ? "Incoming emails ARE stored (24h)" : "Incoming emails are NOT stored"}</span>
        </Space>
        <Paragraph type="secondary" style={{ marginTop: 8, marginBottom: 0 }}>
          When off, live emails show in the dashboard but are never saved. Turn on to keep them (auto-deleted after 24h) and manage them in the Stored Emails section.
        </Paragraph>
      </Card>

      <Card title="Gmail API" style={{ marginBottom: 16, maxWidth: 560 }}>
        <Space style={{ marginBottom: 12 }}>
          <Switch checked={gmailOn} onChange={async (v) => { setGmailOn(v); await saveSettings({ gmail_api_enabled: v }); message.success(v ? "Gmail API enabled" : "Gmail API disabled") }} />
          <span>{gmailOn ? "Gmail API option is available when adding accounts" : "Gmail API is disabled (only IMAP shown)"}</span>
        </Space>
        {gmailOn && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <Paragraph type="secondary" style={{ margin: 0 }}>
              OAuth credentials from Google Cloud Console. Set the redirect URI to your backend callback, e.g. http://localhost:4000/api/auth/google/callback
            </Paragraph>
            <Input placeholder="Client ID" value={gmailCfg.gmail_client_id}
              onChange={(e) => setGmailCfg({ ...gmailCfg, gmail_client_id: e.target.value })} />
            <Input.Password placeholder="Client Secret (leave blank to keep current)" value={gmailCfg.gmail_client_secret}
              onChange={(e) => setGmailCfg({ ...gmailCfg, gmail_client_secret: e.target.value })} />
            <Input placeholder="Redirect URI" value={gmailCfg.gmail_redirect_uri}
              onChange={(e) => setGmailCfg({ ...gmailCfg, gmail_redirect_uri: e.target.value })} />
            <Button type="primary" style={{ alignSelf: 'flex-start' }}
              onClick={async () => { await saveSettings(gmailCfg); message.success('Gmail config saved') }}>
              Save Gmail config
            </Button>
          </div>
        )}
      </Card>

      <Space style={{ width: '100%', justifyContent: 'space-between', marginBottom: 8 }}>
        <Title level={5} style={{ margin: 0 }}>Email Providers (ISPs)</Title>
        <Button type="primary" icon={<PlusOutlined />} onClick={openNew}>Add ISP</Button>
      </Space>
      <Paragraph type="secondary">Normal users pick a provider by name; host/port stay hidden.</Paragraph>
      <Table rowKey="id" loading={loading} dataSource={isps} columns={columns} pagination={false} />

      <Modal title={editing ? 'Edit ISP' : 'Add ISP'} open={open} onCancel={() => setOpen(false)}
        onOk={() => form.submit()} okText="Save">
        <Form form={form} layout="vertical" onFinish={submit}>
          <Form.Item name="name" label="Display name" rules={[{ required: true }]}><Input placeholder="Gmail" /></Form.Item>
          <Form.Item name="host" label="IMAP host" rules={[{ required: true }]}><Input placeholder="imap.gmail.com" /></Form.Item>
          <Form.Item name="port" label="Port"><InputNumber min={1} max={65535} style={{ width: '100%' }} /></Form.Item>
          <Form.Item name="ssl" label="SSL/TLS" valuePropName="checked"><Switch /></Form.Item>
          <Form.Item name="enabled" label="Enabled" valuePropName="checked"><Switch /></Form.Item>
        </Form>
      </Modal>
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\admin\SettingsPage.jsx'

Set-Content -LiteralPath 'frontend\src\App.jsx' -Encoding utf8 -Value @'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AppProvider, useApp } from './context/AppProvider'
import DashboardLayout from './layout/DashboardLayout'
import DashboardPage from './pages/DashboardPage'
import AccountsPage from './pages/AccountsPage'
import MyAccountsPage from './pages/MyAccountsPage'
import StoragePage from './pages/StoragePage'
import VaultPage from './pages/VaultPage'
import ExtractPage from './pages/ExtractPage'
import RequestsPage from './pages/RequestsPage'
import LoginPage from './pages/LoginPage'
import UsersPage from './pages/admin/UsersPage'
import SettingsPage from './pages/admin/SettingsPage'
import ToolsPage from './pages/admin/ToolsPage'
import AnalyticsPage from './pages/admin/AnalyticsPage'
import AllAccountsPage from './pages/admin/AllAccountsPage'
import StoredEmailsPage from './pages/admin/StoredEmailsPage'

function useCan() {
  const { user } = useApp()
  const staff = user?.role === 'admin' || user?.role === 'support'
  return (section) => staff || (user?.sections || []).includes(section)
}

function Gate({ section, children }) {
  const can = useCan()
  // overview is now grantable; if not allowed, send to the first place they can go
  return can(section) ? children : <Navigate to="/no-access" replace />
}

function FirstAllowed() {
  const can = useCan()
  // pick a landing page the user is allowed to see
  if (can('overview')) return <Navigate to="/overview" replace />
  return <Navigate to="/monitor" replace />
}

function NoAccess() {
  return <div style={{ padding: 40, textAlign: 'center', color: '#64748b' }}>
    You don't have access to this section. Ask an administrator to grant it.
  </div>
}

function Root() {
  const { token } = useApp()
  return (
    <BrowserRouter>
      <Routes>
        {/* Not logged in: every path renders the login screen */}
        {!token ? (
          <Route path="*" element={<LoginPage />} />
        ) : (
          <Route element={<DashboardLayout />}>
            <Route index element={<FirstAllowed />} />
            <Route path="overview" element={<Gate section="overview"><DashboardPage /></Gate>} />
            <Route path="monitor" element={<AccountsPage />} />
            <Route path="my-accounts" element={<MyAccountsPage />} />
            <Route path="storage" element={<StoragePage />} />
            <Route path="vault" element={<VaultPage />} />
            <Route path="requests" element={<RequestsPage />} />
            <Route path="extract" element={<Gate section="extract"><ExtractPage /></Gate>} />
            <Route path="manage/all-accounts" element={<Gate section="allaccounts"><AllAccountsPage /></Gate>} />
            <Route path="manage/stored-emails" element={<Gate section="storedemails"><StoredEmailsPage /></Gate>} />
            <Route path="manage/users" element={<Gate section="users"><UsersPage /></Gate>} />
            <Route path="manage/settings" element={<Gate section="settings"><SettingsPage /></Gate>} />
            <Route path="manage/tools" element={<Gate section="tools"><ToolsPage /></Gate>} />
            <Route path="manage/analytics" element={<Gate section="analytics"><AnalyticsPage /></Gate>} />
            <Route path="no-access" element={<NoAccess />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        )}
      </Routes>
    </BrowserRouter>
  )
}

export default function App() {
  return (
    <AppProvider>
      <Root />
    </AppProvider>
  )
}
'@
Write-Host 'wrote frontend\src\App.jsx'

Set-Content -LiteralPath 'frontend\src\layout\DashboardLayout.jsx' -Encoding utf8 -Value @'
import { useState } from 'react'
import { Layout, Menu, Button, Typography, Space, Tooltip, Avatar, Dropdown } from 'antd'
import { DashboardOutlined, InboxOutlined, LogoutOutlined, MenuFoldOutlined, MenuUnfoldOutlined,
  BulbOutlined, BulbFilled, UserOutlined, SettingOutlined, ToolOutlined, AreaChartOutlined,
  DatabaseOutlined, ExportOutlined, MessageOutlined, MailOutlined, IdcardOutlined, LockOutlined } from '@ant-design/icons'
import { useNavigate, useLocation, Outlet } from 'react-router-dom'
import { useApp } from '../context/AppProvider'
import { logout } from '../services/auth'
import { APP_NAME } from '../branding'
import NotificationBell from '../components/NotificationBell'
import logo from '../assets/logo.png'

const { Sider, Header, Content } = Layout
const { Text } = Typography

export default function DashboardLayout() {
  const navigate = useNavigate()
  const { pathname } = useLocation()
  const { setToken, accounts, mode, toggleMode, user } = useApp()
  const [collapsed, setCollapsed] = useState(false)
  const isStaff = user?.role === 'admin' || user?.role === 'support'
  const sections = user?.sections || []
  const can = (s) => isStaff || sections.includes(s)

  const handleLogout = () => { logout(); setToken(null) }

  const menuChildren = [
    can('overview') && { key: '/overview', icon: <DashboardOutlined />, label: 'Deliverability' },
    { key: '/monitor', icon: <InboxOutlined />, label: 'Monitor' },
    { key: '/my-accounts', icon: <MailOutlined />, label: 'My Accounts' },
    can('extract') && { key: '/extract', icon: <ExportOutlined />, label: 'Extract' },
    { key: '/storage', icon: <DatabaseOutlined />, label: 'Storage' },
    { key: '/vault', icon: <LockOutlined />, label: 'Vault' },
    { key: '/requests', icon: <MessageOutlined />, label: 'Support' },
  ].filter(Boolean)

  const manageChildren = [
    can('allaccounts') && { key: '/manage/all-accounts', icon: <DatabaseOutlined />, label: 'All Accounts' },
    can('storedemails') && { key: '/manage/stored-emails', icon: <MailOutlined />, label: 'Stored Emails' },
    can('users') && { key: '/manage/users', icon: <UserOutlined />, label: 'Users' },
    can('settings') && { key: '/manage/settings', icon: <SettingOutlined />, label: 'Settings' },
    can('tools') && { key: '/manage/tools', icon: <ToolOutlined />, label: 'Auth Tools' },
    can('analytics') && { key: '/manage/analytics', icon: <AreaChartOutlined />, label: 'Analytics' },
  ].filter(Boolean)

  const items = [
    { type: 'group', label: collapsed ? '' : 'WORKSPACE', children: menuChildren },
    ...(manageChildren.length ? [{ type: 'group', label: collapsed ? '' : 'MANAGE', children: manageChildren }] : []),
  ]

  const roleLabel = user?.role === 'admin' ? 'Administrator' : user?.role === 'support' ? 'Support' : 'User'
  const profileMenu = { items: [
    { key: 'who', disabled: true, label: (
      <div style={{ padding: '4px 0' }}>
        <div style={{ fontWeight: 600 }}>{user?.username || 'User'}</div>
        <div style={{ fontSize: 12, color: '#94a3b8' }}>{roleLabel}</div>
        <div style={{ fontSize: 12, color: '#2563eb', marginTop: 2 }}>
          <IdcardOutlined /> ID: {user?.code || '----'}
        </div>
      </div>) },
    { type: 'divider' },
    { key: 'logout', icon: <LogoutOutlined />, label: 'Logout', danger: true, onClick: handleLogout },
  ] }

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Sider trigger={null} collapsible collapsed={collapsed} width={248} breakpoint="lg">
        <div style={{ display: 'flex', alignItems: 'center', gap: 12,
          justifyContent: collapsed ? 'center' : 'flex-start',
          padding: collapsed ? '18px 0' : '20px 18px', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
          <img src={logo} alt="logo" width={collapsed ? 34 : 38} height={collapsed ? 34 : 38} style={{ borderRadius: 10 }} />
          {!collapsed && (
            <div style={{ lineHeight: 1.15 }}>
              <div style={{ color: '#fff', fontWeight: 800, fontSize: 16 }}>Gmass</div>
              <div style={{ color: '#60a5fa', fontWeight: 700, fontSize: 13 }}>MailScope</div>
            </div>)}
        </div>
        <Menu theme="dark" mode="inline" selectedKeys={[pathname]} items={items}
          onClick={(e) => e.key && navigate(e.key)} style={{ background: 'transparent', borderInlineEnd: 'none', paddingTop: 8 }} />
      </Sider>

      <Layout>
        <Header style={{ background: mode === 'dark' ? undefined : '#fff',
          borderBottom: '1px solid rgba(100,116,139,0.15)', display: 'flex', alignItems: 'center',
          justifyContent: 'space-between', padding: '0 18px' }}>
          <Space size="middle">
            <Button type="text" shape="circle" icon={collapsed ? <MenuUnfoldOutlined /> : <MenuFoldOutlined />}
              onClick={() => setCollapsed(c => !c)} />
            <Text type="secondary">{accounts.length} accounts monitored</Text>
          </Space>
          <Space size="middle">
            {isStaff && <NotificationBell />}
            <Tooltip title={mode === 'dark' ? 'Light mode' : 'Dark mode'}>
              <Button type="text" shape="circle" icon={mode === 'dark' ? <BulbFilled /> : <BulbOutlined />} onClick={toggleMode} />
            </Tooltip>
            <Dropdown menu={profileMenu} placement="bottomRight" trigger={['click']}>
              <Avatar src={user?.picture} style={{ background: '#2563eb', cursor: 'pointer' }} icon={<UserOutlined />}>
                {user?.username?.[0]?.toUpperCase()}
              </Avatar>
            </Dropdown>
          </Space>
        </Header>
        <Content style={{ padding: 24 }}><Outlet /></Content>
      </Layout>
    </Layout>
  )
}
'@
Write-Host 'wrote frontend\src\layout\DashboardLayout.jsx'

Write-Host ""
Write-Host "STAGE 42 written."
Write-Host "1) Run backend\db\migration-stage42.sql in Supabase (creates vault_items table)."
Write-Host "2) Restart backend + frontend, hard-refresh."
Write-Host "New: Vault section (encrypted). Admin Settings > Display toggle for owner-name. Storage source viewer upgraded."
