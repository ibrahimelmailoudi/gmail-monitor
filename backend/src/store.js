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
