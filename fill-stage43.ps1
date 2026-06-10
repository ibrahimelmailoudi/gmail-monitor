# fill-stage43.ps1 - flag-based top admin: current top admin transfers role code-free; code still works as fallback
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path backend\db,backend\src\routes,frontend\src\services,frontend\src\pages\admin | Out-Null

Set-Content -LiteralPath 'backend\db\migration-stage43.sql' -Encoding utf8 -Value @'
-- Stage 43: flag-based top admin (one admin is the top admin; can transfer the role).
alter table users add column if not exists is_top_admin boolean not null default false;
-- ensure at most one top admin via a partial unique index
create unique index if not exists uniq_one_top_admin on users(is_top_admin) where is_top_admin = true;
'@
Write-Host 'wrote backend\db\migration-stage43.sql'

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

// ---------------- top admin (flag-based, transferable) ----------------
export async function isUserTopAdmin(userId) {
  const { rows } = await q('select is_top_admin from users where id = $1', [userId])
  return !!rows[0]?.is_top_admin
}
export async function anyTopAdminExists() {
  const { rows } = await q('select 1 from users where is_top_admin = true limit 1')
  return rows.length > 0
}
// Transfer top-admin to targetUserId (must be an admin). Clears the old flag first
// so the partial-unique index is satisfied.
export async function setTopAdmin(targetUserId) {
  const { rows } = await q('select role from users where id = $1', [targetUserId])
  if (!rows[0]) throw new Error('User not found')
  if (rows[0].role !== 'admin') throw new Error('Top admin must be an admin')
  await q('update users set is_top_admin = false where is_top_admin = true')
  await q('update users set is_top_admin = true where id = $1', [targetUserId])
}
'@
Write-Host 'wrote backend\src\store.js'

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
  isUserTopAdmin, setTopAdmin, anyTopAdminExists,
} from '../store.js'
import { emitToUser } from '../monitor.js'
import { config } from '../config.js'

const router = Router()
router.use(auth, staffOnly)

// Top-admin authority can be proven two ways:
//  1) the caller IS the flagged top admin (is_top_admin), or
//  2) the caller supplies the correct secret code (bootstrap/fallback).
async function verifyTopAdminCode(code) {
  if (!code) return false
  const stored = await getSetting('top_admin_code', null)
  const expected = stored || config.bootstrapSecret || ''
  return expected.length > 0 && String(code) === String(expected)
}
async function isTopAdminAuthorized(req, code) {
  if (await isUserTopAdmin(req.user.id)) return true
  return verifyTopAdminCode(code)
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
    const ok = await isTopAdminAuthorized(req, code)
    if (!ok) return res.status(403).json({ message: 'Deleting an admin requires top-admin authority (be the top admin, or enter the secret code)' })
  }
  await deleteUser(req.params.id); res.json({ ok: true })
})

// Claim top-admin using the secret code. Use this to set the INITIAL top admin
// (when none is flagged yet) or to recover. The caller must be an admin.
router.post('/top-admin/claim', requirePerm('manage_users'), async (req, res) => {
  if (req.user.role !== 'admin') return res.status(403).json({ message: 'Only an admin can be top admin' })
  const ok = await verifyTopAdminCode(req.body?.code || '')
  if (!ok) return res.status(403).json({ message: 'Incorrect secret code' })
  await setTopAdmin(req.user.id)
  res.json({ ok: true, message: 'You are now the top admin' })
})

// Transfer top-admin to another admin. Allowed if the caller is the current top
// admin (NO code needed), or supplies the secret code as a fallback.
router.post('/top-admin/transfer', requirePerm('manage_users'), async (req, res) => {
  const { targetUserId, code } = req.body || {}
  if (!targetUserId) return res.status(400).json({ message: 'targetUserId required' })
  const ok = await isTopAdminAuthorized(req, code || '')
  if (!ok) return res.status(403).json({ message: 'Only the current top admin (or the secret code) can transfer the role' })
  try { await setTopAdmin(targetUserId); res.json({ ok: true }) }
  catch (e) { res.status(400).json({ message: e.message }) }
})

// Who is the current top admin (id only) - any staff can read.
router.get('/top-admin', async (_req, res) => {
  const { anyTopAdminExists } = await import('../store.js')
  const exists = await anyTopAdminExists()
  res.json({ exists })
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

Set-Content -LiteralPath 'backend\src\routes\auth.js' -Encoding utf8 -Value @'
import { Router } from 'express'
import bcrypt from 'bcryptjs'
import { config } from '../config.js'
import { signToken, auth } from '../auth-middleware.js'
import {
  getUserByUsername, createUser, countUsers, getAccountRow,
  addAccount, findAccountByEmail, createResetRequest, getSetting, ensureUserCode,
} from '../store.js'
import { oauthClient, exchangeCode } from '../gmail.js'
import { startAccount, emitAdded } from '../monitor.js'

const router = Router()

const publicUser = (u) => ({ id: u.id, username: u.username, code: u.code, is_admin: u.is_admin,
  role: u.role, permissions: u.permissions || {}, sections: u.sections || [], max_accounts: u.max_accounts,
  picture: u.picture, is_top_admin: !!u.is_top_admin })

// Login (username + password)
router.post('/login', async (req, res) => {
  const { username, password } = req.body || {}
  if (!username || !password) return res.status(400).json({ message: 'username and password required' })
  const user = await getUserByUsername(username)
  if (!user || !(await bcrypt.compare(password, user.password_hash)))
    return res.status(401).json({ message: 'Invalid username or password' })
  if (!user.code) user.code = await ensureUserCode(user.id)
  const globalHours = Number(await getSetting('token_hours', 48)) || 48
  const hours = user.token_hours || globalHours
  res.json({ token: signToken(user, hours), user: publicUser(user) })
})

// Forgot password: user submits username -> creates an admin notification.
router.post('/forgot', async (req, res) => {
  const { username } = req.body || {}
  if (!username) return res.status(400).json({ message: 'username required' })
  await createResetRequest(username)
  res.json({ ok: true })
})

// Bootstrap: create the very FIRST user as admin (only works while DB has no users).
// Protect with BOOTSTRAP_SECRET from .env.
router.post('/bootstrap', async (req, res) => {
  const { username, password, secret } = req.body || {}
  if ((await countUsers()) > 0) return res.status(403).json({ message: 'Already initialized' })
  if (!config.bootstrapSecret || secret !== config.bootstrapSecret)
    return res.status(401).json({ message: 'Invalid bootstrap secret' })
  if (!username || !password) return res.status(400).json({ message: 'username and password required' })
  const passwordHash = await bcrypt.hash(password, 10)
  const user = await createUser({ username, passwordHash, isAdmin: true, maxAccounts: 999 })
  res.json({ token: signToken(user), user: publicUser(user) })
})

// Google OAuth start
router.get('/google/start', auth, (req, res) => {
  const state = Buffer.from(JSON.stringify({ userId: req.user.id, socketId: req.query.socketId || null }))
    .toString('base64url')
  const url = oauthClient().generateAuthUrl({
    access_type: 'offline', prompt: 'consent',
    scope: [
      'https://www.googleapis.com/auth/gmail.readonly',
      'https://www.googleapis.com/auth/userinfo.email',
      'https://www.googleapis.com/auth/userinfo.profile',
    ],
    state,
  })
  res.json({ url })
})

// Google OAuth callback
router.get('/google/callback', async (req, res) => {
  try {
    const { code, state } = req.query
    const { userId } = JSON.parse(Buffer.from(state, 'base64url').toString())
    const { tokens, profile } = await exchangeCode(code)

    if (await findAccountByEmail(profile.email, userId)) {
      return res.send(closeHtml('This account is already connected.'))
    }
    const account = await addAccount({
      ownerId: userId, type: 'gmail', email: profile.email, picture: profile.picture || null,
      active: true, scope: 'personal',
      credentials: { refresh_token: tokens.refresh_token, access_token: tokens.access_token },
    })
    startAccount(await getAccountRow(account.id))
    emitAdded(userId, account)
    res.send(closeHtml('Account connected.'))
  } catch (err) {
    console.error('oauth callback:', err.message)
    res.status(500).send('OAuth failed: ' + err.message)
  }
})

const closeHtml = (msg) =>
  `<html><body style="font-family:sans-serif;background:#0f172a;color:#fff;text-align:center;padding-top:60px">${msg} You can close this window.<script>window.close()</script></body></html>`

export default router
'@
Write-Host 'wrote backend\src\routes\auth.js'

Set-Content -LiteralPath 'frontend\src\services\admin.js' -Encoding utf8 -Value @'
import client from '../api/client'

export const getUsers   = () => client.get('/api/admin/users').then(r => r.data)
export const createUser  = (payload) => client.post('/api/admin/users', payload).then(r => r.data)
export const updateUser  = (id, patch) => client.patch(`/api/admin/users/${id}`, patch).then(r => r.data)

export const getStats    = () => client.get('/api/admin/stats').then(r => r.data)

export const getIspsAdmin = () => client.get('/api/admin/isps').then(r => r.data)
export const addIsp       = (payload) => client.post('/api/admin/isps', payload).then(r => r.data)

export const grantAccess  = (accountId, userId) => client.post('/api/admin/access', { accountId, userId })
export const revokeAccess = (accountId, userId) => client.delete('/api/admin/access', { data: { accountId, userId } })

export const getAllAccounts = () => client.get('/api/admin/accounts').then(r => r.data)
export const setAccountScope = (id, scope) => client.patch(`/api/admin/accounts/${id}/scope`, { scope })

export const getNotifications = () => client.get('/api/admin/notifications').then(r => r.data)
export const markNotificationsRead = () => client.post('/api/admin/notifications/read')
export const getResetRequests = () => client.get('/api/admin/reset-requests').then(r => r.data)
export const setUserPassword = (reqId, username, password) =>
  client.post(`/api/admin/reset-requests/${reqId}/set-password`, { username, password })

export const getPerms = () => client.get('/api/admin/perms').then(r => r.data)
export const setUserRole = (id, role, permissions) =>
  client.patch(`/api/admin/users/${id}/role`, { role, permissions })
export const getPresence = () => client.get('/api/presence').then(r => r.data)

export const updateIsp = (id, patch) => client.patch(`/api/admin/isps/${id}`, patch)
export const deleteIsp = (id) => client.delete(`/api/admin/isps/${id}`)
export const deleteUser = (id, topAdminCode) =>
  client.delete(`/api/admin/users/${id}`, topAdminCode ? { data: { topAdminCode } } : undefined)
export const claimTopAdmin = (code) => client.post('/api/admin/top-admin/claim', { code })
export const transferTopAdmin = (targetUserId, code) =>
  client.post('/api/admin/top-admin/transfer', { targetUserId, code })
export const setUserSections = (id, sections) => client.patch(`/api/admin/users/${id}/sections`, { sections })
export const getSettings = () => client.get('/api/admin/settings').then(r => r.data)
export const saveSettings = (patch) => client.put('/api/admin/settings', patch)

export const getStoredEmails = (params) => client.get('/api/admin/emails', { params }).then(r => r.data)
export const deleteStoredEmail = (id) => client.delete(`/api/admin/emails/${id}`)
export const bulkDeleteEmails = (body) => client.post('/api/admin/emails/bulk-delete', body)
'@
Write-Host 'wrote frontend\src\services\admin.js'

Set-Content -LiteralPath 'frontend\src\pages\admin\UsersPage.jsx' -Encoding utf8 -Value @'
import { useEffect, useState } from 'react'
import { Table, Button, Modal, Form, Input, InputNumber, Select, Typography, Tag, Space, Checkbox, Badge, Popconfirm, message, Tooltip } from 'antd'
import { PlusOutlined, SafetyOutlined, DeleteOutlined, AppstoreOutlined, CrownOutlined } from '@ant-design/icons'
import { getUsers, createUser, updateUser, getPerms, setUserRole, deleteUser, setUserSections, getPresence, claimTopAdmin, transferTopAdmin } from '../../services/admin'
import { useApp } from '../../context/AppProvider'
import { SECTIONS } from '../../sections'

const { Title } = Typography
const PERM_LABELS = {
  manage_users: 'Manage users', manage_isps: 'Manage ISPs/settings',
  delete_accounts: 'Delete any account', share_accounts: 'Share / global accounts',
  resolve_requests: 'Resolve requests', set_passwords: 'Set passwords',
  refresh_accounts: 'Refresh accounts',
}

export default function UsersPage() {
  const { user: me } = useApp()
  const [users, setUsers] = useState([])
  const [perms, setPerms] = useState([])
  const [online, setOnline] = useState([])
  const [loading, setLoading] = useState(true)
  const [open, setOpen] = useState(false)
  const [roleModal, setRoleModal] = useState(null)
  const [secModal, setSecModal] = useState(null)
  const [form] = Form.useForm(); const [roleForm] = Form.useForm(); const [secForm] = Form.useForm()

  const load = () => getUsers().then(setUsers).finally(() => setLoading(false))
  const loadPresence = () => getPresence().then(d => setOnline(d.onlineIds || [])).catch(() => {})
  useEffect(() => {
    load(); getPerms().then(d => setPerms(d.perms)).catch(() => {})
    loadPresence(); const t = setInterval(loadPresence, 15000); return () => clearInterval(t)
  }, [])

  const onCreate = async (vals) => {
    try { await createUser(vals); message.success('User created'); setOpen(false); form.resetFields(); load() }
    catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }
  const remove = async (u) => {
    // Deleting an admin needs the top-admin secret code.
    if (u.role === 'admin') {
      let code = ''
      Modal.confirm({
        title: `Delete admin "${u.username}"`,
        content: (
          <div>
            <p>Deleting an admin requires the top-admin secret code.</p>
            <Input.Password placeholder="Top-admin secret code" onChange={(e) => { code = e.target.value }} />
          </div>
        ),
        okText: 'Delete admin', okButtonProps: { danger: true },
        onOk: async () => {
          try { await deleteUser(u.id, code); message.success('Admin deleted'); load() }
          catch (e) { message.error(e.response?.data?.message || 'Delete failed'); throw e }
        },
      })
      return
    }
    try { await deleteUser(u.id); message.success('User deleted'); load() }
    catch (e) { message.error(e.response?.data?.message || 'Delete failed') }
  }
  const setMax = async (id, max_accounts) => { await updateUser(id, { max_accounts }); load() }
  const setTokenHours = async (id, token_hours) => { await updateUser(id, { token_hours: token_hours || null }); load() }

  const openRole = (u) => { setRoleModal(u); roleForm.setFieldsValue({ role: u.role || 'user',
    permissions: Object.keys(u.permissions || {}).filter(k => u.permissions[k]) }) }
  const saveRole = async (vals) => {
    const p = {}; (vals.permissions || []).forEach(x => { p[x] = true })
    try { await setUserRole(roleModal.id, vals.role, vals.role === 'support' ? p : {}); message.success('Role updated'); setRoleModal(null); load() }
    catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }
  const openSec = (u) => { setSecModal(u); secForm.setFieldsValue({ sections: u.sections || [] }) }
  const saveSec = async (vals) => { await setUserSections(secModal.id, vals.sections || []); message.success('Access updated'); setSecModal(null); load() }

  const roleTag = (r, row) => (
    <Space size={4}>
      {r === 'admin' ? <Tag color="red">ADMIN</Tag> : r === 'support' ? <Tag color="blue">SUPPORT</Tag> : <Tag>USER</Tag>}
      {row?.is_top_admin && <Tag color="gold" icon={<CrownOutlined />}>TOP</Tag>}
    </Space>
  )
  // Transfer top-admin to another admin. Code-free if I'm the top admin; else prompt for code.
  const makeTopAdmin = (u) => {
    const doTransfer = async (code) => {
      try { await transferTopAdmin(u.id, code); message.success(`${u.username} is now the top admin`); load() }
      catch (e) { message.error(e.response?.data?.message || 'Transfer failed'); throw e }
    }
    if (me?.is_top_admin) {
      Modal.confirm({ title: `Make "${u.username}" the top admin?`,
        content: 'You will hand over top-admin authority to this admin.',
        okText: 'Transfer', onOk: () => doTransfer() })
    } else {
      let code = ''
      Modal.confirm({ title: `Make "${u.username}" the top admin`,
        content: (<div><p>Enter the top-admin secret code to authorize this.</p>
          <Input.Password placeholder="Secret code" onChange={(e) => { code = e.target.value }} /></div>),
        okText: 'Transfer', onOk: () => doTransfer(code) })
    }
  }
  // Claim top-admin for myself using the secret code (initial setup / recovery).
  const claimTop = () => {
    let code = ''
    Modal.confirm({ title: 'Claim top-admin role',
      content: (<div><p>Enter the secret code to become the top admin.</p>
        <Input.Password placeholder="Secret code" onChange={(e) => { code = e.target.value }} /></div>),
      okText: 'Claim', onOk: async () => {
        try { await claimTopAdmin(code); message.success('You are now the top admin'); load() }
        catch (e) { message.error(e.response?.data?.message || 'Claim failed'); throw e }
      } })
  }

  const columns = [
    { title: '', dataIndex: 'id', width: 30, render: (id) =>
      <Badge status={online.includes(id) ? 'success' : 'default'} title={online.includes(id) ? 'Online' : 'Offline'} /> },
    { title: 'Username', dataIndex: 'username' },
    { title: 'Role', dataIndex: 'role', render: (v, row) => roleTag(v, row) },
    { title: 'Max accts', dataIndex: 'max_accounts', width: 120, render: (v, r) =>
      <InputNumber size="small" min={0} max={9999} defaultValue={v} onBlur={(e) => setMax(r.id, Number(e.target.value))} /> },
    { title: 'Token (h)', dataIndex: 'token_hours', width: 120, render: (v, r) =>
      <InputNumber size="small" min={1} max={720} placeholder="default" defaultValue={v}
        onBlur={(e) => setTokenHours(r.id, Number(e.target.value) || null)} /> },
    { title: 'Actions', key: 'act', render: (_, r) => (
      <Space>
        <Button size="small" icon={<SafetyOutlined />} onClick={() => openRole(r)} disabled={r.id === me?.id}>Role</Button>
        <Button size="small" icon={<AppstoreOutlined />} onClick={() => openSec(r)}>Access</Button>
        {r.role === 'admin' && !r.is_top_admin && (
          <Tooltip title="Make this admin the top admin">
            <Button size="small" icon={<CrownOutlined />} onClick={() => makeTopAdmin(r)} />
          </Tooltip>
        )}
        {r.role === 'admin' ? (
          <Button size="small" danger icon={<DeleteOutlined />} disabled={r.id === me?.id}
            onClick={() => remove(r)} />
        ) : (
          <Popconfirm title="Delete this user?" onConfirm={() => remove(r)} disabled={r.id === me?.id}>
            <Button size="small" danger icon={<DeleteOutlined />} disabled={r.id === me?.id} />
          </Popconfirm>
        )}
      </Space>) },
  ]

  return (
    <>
      <Space style={{ width: '100%', justifyContent: 'space-between', marginBottom: 16 }}>
        <Title level={4} style={{ margin: 0 }}>Users</Title>
        <Space>
          {me?.role === 'admin' && !me?.is_top_admin && (
            <Button icon={<CrownOutlined />} onClick={claimTop}>Claim top admin</Button>
          )}
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>Add User</Button>
        </Space>
      </Space>
      <Table rowKey="id" loading={loading} dataSource={users} columns={columns} pagination={false} />

      <Modal title="Add User" open={open} onCancel={() => setOpen(false)} onOk={() => form.submit()} okText="Create">
        <Form form={form} layout="vertical" onFinish={onCreate} initialValues={{ max_accounts: 5 }}>
          <Form.Item name="username" label="Username" rules={[{ required: true }]}><Input /></Form.Item>
          <Form.Item name="password" label="Password" rules={[{ required: true }]}><Input.Password /></Form.Item>
          <Form.Item name="max_accounts" label="Max accounts"><InputNumber min={0} max={9999} style={{ width: '100%' }} /></Form.Item>
        </Form>
      </Modal>

      <Modal title={`Role - ${roleModal?.username || ''}`} open={!!roleModal} onCancel={() => setRoleModal(null)}
        onOk={() => roleForm.submit()} okText="Save">
        <Form form={roleForm} layout="vertical" onFinish={saveRole}>
          <Form.Item name="role" label="Role">
            <Select options={[{ value: 'user', label: 'User' }, { value: 'support', label: 'Support' }, { value: 'admin', label: 'Admin (full access)' }]} />
          </Form.Item>
          <Form.Item noStyle shouldUpdate={(p, c) => p.role !== c.role}>
            {({ getFieldValue }) => getFieldValue('role') === 'support' && (
              <Form.Item name="permissions" label="Permissions">
                <Checkbox.Group options={perms.map(p => ({ label: PERM_LABELS[p] || p, value: p }))} />
              </Form.Item>)}
          </Form.Item>
        </Form>
      </Modal>

      <Modal title={`Section access - ${secModal?.username || ''}`} open={!!secModal} onCancel={() => setSecModal(null)}
        onOk={() => secForm.submit()} okText="Save">
        <p style={{ color: '#64748b' }}>Grant this user access to extra dashboard sections.</p>
        <Form form={secForm} onFinish={saveSec}>
          <Form.Item name="sections">
            <Checkbox.Group options={SECTIONS.map(s => ({ label: s.label, value: s.key }))} />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\admin\UsersPage.jsx'

Write-Host ""
Write-Host "STAGE 43 written."
Write-Host "1) Run backend\db\migration-stage43.sql in Supabase (adds is_top_admin)."
Write-Host "2) Restart backend + frontend, hard-refresh."
Write-Host "First: in Users, click Claim top admin and enter the secret code (= BOOTSTRAP_SECRET). Then you can transfer code-free."
