# fill-stage39.ps1 - keyword filters emails in Monitor; user crud rules (no crud on global);
#                    My Accounts crud; top-admin secret code to delete admins + rotate code
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path backend\src\routes,frontend\src\pages,frontend\src\pages\admin,frontend\src\components\accounts,frontend\src\services | Out-Null

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
'@
Write-Host 'wrote backend\src\routes\admin.js'

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
                  onPlacementClick={(cat) => setPlacement(cat)} />
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

export default function AccountCard({ account, onToggle, onRemove, onRefresh, newEmailIds, emailFilter, onPlacementClick }) {
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

          <Text strong style={{ wordBreak: 'break-all' }}>{account.email}</Text>
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

Set-Content -LiteralPath 'frontend\src\pages\MyAccountsPage.jsx' -Encoding utf8 -Value @'
import { useState } from 'react'
import { Card, Table, Tag, Button, Typography, Space, Modal, AutoComplete, message, Empty, Popconfirm } from 'antd'
import { ShareAltOutlined, MailOutlined, DeleteOutlined, PlayCircleOutlined, PauseCircleOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import { searchUsers, shareAccount } from '../services/accounts'

const { Title, Text } = Typography

// A simple page where a normal user sees THEIR OWN accounts and can share them
// with another user by name or 4-digit ID. (No global-scope toggle here.)
export default function MyAccountsPage() {
  const { accounts, user, toggle, remove } = useApp()
  const mine = accounts.filter(a => a.ownerId === user?.id || a.owner_id === user?.id)

  const [shareFor, setShareFor] = useState(null) // account being shared
  const [options, setOptions] = useState([])
  const [pick, setPick] = useState(null)
  const [text, setText] = useState('')

  const onSearch = async (t) => {
    setText(t)
    if (!t || t.length < 2) { setOptions([]); return }
    try {
      const users = await searchUsers(t)
      setOptions(users.map(u => ({ value: u.id, label: `${u.username}  -  ID ${u.code}` })))
    } catch { setOptions([]) }
  }
  const doShare = async () => {
    if (!pick) return message.warning('Pick a user from the list')
    try {
      await shareAccount(shareFor.id, pick)
      message.success('Account shared')
      setShareFor(null); setPick(null); setText(''); setOptions([])
    } catch (e) { message.error(e.response?.data?.message || 'Share failed') }
  }

  const columns = [
    { title: 'Email', dataIndex: 'email', render: (v) => <Space><MailOutlined />{v}</Space> },
    { title: 'Status', dataIndex: 'active', render: (v) => <Tag color={v ? 'green' : 'default'}>{v ? 'Live' : 'Paused'}</Tag> },
    { title: 'Scope', dataIndex: 'scope', render: (v) => <Tag color={v === 'global' ? 'purple' : 'blue'}>{v || 'personal'}</Tag> },
    { title: 'Emails', key: 'n', render: (_, r) => (r.emails || []).length },
    { title: 'Actions', key: 'actions', render: (_, r) =>
      <Space>
        <Button size="small" icon={r.active ? <PauseCircleOutlined /> : <PlayCircleOutlined />}
          onClick={() => toggle(r.id)}>{r.active ? 'Pause' : 'Start'}</Button>
        <Button size="small" icon={<ShareAltOutlined />} onClick={() => setShareFor(r)}>Share</Button>
        <Popconfirm title="Delete this account?" okText="Delete" okButtonProps={{ danger: true }}
          onConfirm={() => remove(r.id)}>
          <Button size="small" danger icon={<DeleteOutlined />} />
        </Popconfirm>
      </Space> },
  ]

  return (
    <>
      <Title level={4}>My Accounts</Title>
      <Text type="secondary">Your own mailboxes. You can share any of them with another user by name or ID.</Text>
      <Card style={{ marginTop: 16 }}>
        {mine.length === 0 ? <Empty description="You have no accounts yet" /> :
          <Table rowKey="id" dataSource={mine} columns={columns} pagination={false} scroll={{ x: true }} size="small" />}
      </Card>

      <Modal title={shareFor ? `Share ${shareFor.email}` : 'Share'} open={!!shareFor}
        onCancel={() => setShareFor(null)} onOk={doShare} okText="Share">
        <p style={{ color: '#64748b' }}>Type a username or their 4-digit ID, then pick the right person.</p>
        <AutoComplete style={{ width: '100%' }} options={options} value={text}
          onSearch={onSearch} onChange={setText}
          onSelect={(value, option) => { setPick(value); setText(option.label) }}
          placeholder="Start typing a name or ID..." />
      </Modal>
    </>
  )
}
'@
Write-Host 'wrote frontend\src\pages\MyAccountsPage.jsx'

Set-Content -LiteralPath 'frontend\src\pages\admin\UsersPage.jsx' -Encoding utf8 -Value @'
import { useEffect, useState } from 'react'
import { Table, Button, Modal, Form, Input, InputNumber, Select, Typography, Tag, Space, Checkbox, Badge, Popconfirm, message } from 'antd'
import { PlusOutlined, SafetyOutlined, DeleteOutlined, AppstoreOutlined } from '@ant-design/icons'
import { getUsers, createUser, updateUser, getPerms, setUserRole, deleteUser, setUserSections, getPresence } from '../../services/admin'
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

  const roleTag = (r) => r === 'admin' ? <Tag color="red">ADMIN</Tag> : r === 'support' ? <Tag color="blue">SUPPORT</Tag> : <Tag>USER</Tag>

  const columns = [
    { title: '', dataIndex: 'id', width: 30, render: (id) =>
      <Badge status={online.includes(id) ? 'success' : 'default'} title={online.includes(id) ? 'Online' : 'Offline'} /> },
    { title: 'Username', dataIndex: 'username' },
    { title: 'Role', dataIndex: 'role', render: (v) => roleTag(v) },
    { title: 'Max accts', dataIndex: 'max_accounts', width: 120, render: (v, r) =>
      <InputNumber size="small" min={0} max={9999} defaultValue={v} onBlur={(e) => setMax(r.id, Number(e.target.value))} /> },
    { title: 'Token (h)', dataIndex: 'token_hours', width: 120, render: (v, r) =>
      <InputNumber size="small" min={1} max={720} placeholder="default" defaultValue={v}
        onBlur={(e) => setTokenHours(r.id, Number(e.target.value) || null)} /> },
    { title: 'Actions', key: 'act', render: (_, r) => (
      <Space>
        <Button size="small" icon={<SafetyOutlined />} onClick={() => openRole(r)} disabled={r.id === me?.id}>Role</Button>
        <Button size="small" icon={<AppstoreOutlined />} onClick={() => openSec(r)}>Access</Button>
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
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>Add User</Button>
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
export const rotateTopAdmin = (currentCode, newCode) =>
  client.post('/api/admin/top-admin/rotate', { currentCode, newCode })
export const setUserSections = (id, sections) => client.patch(`/api/admin/users/${id}/sections`, { sections })
export const getSettings = () => client.get('/api/admin/settings').then(r => r.data)
export const saveSettings = (patch) => client.put('/api/admin/settings', patch)

export const getStoredEmails = (params) => client.get('/api/admin/emails', { params }).then(r => r.data)
export const deleteStoredEmail = (id) => client.delete(`/api/admin/emails/${id}`)
export const bulkDeleteEmails = (body) => client.post('/api/admin/emails/bulk-delete', body)
'@
Write-Host 'wrote frontend\src\services\admin.js'

Write-Host ""
Write-Host "STAGE 39 written. Restart backend + frontend, hard-refresh."
Write-Host "Top-admin code = settings top_admin_code, falls back to BOOTSTRAP_SECRET. Rotate via Users page later."
