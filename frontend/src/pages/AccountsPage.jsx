import { useState, useMemo, useEffect, useRef } from 'react'
import { Input, Button, Space, Spin, Empty, Typography, Select, Segmented, Card, Statistic, Row, Col } from 'antd'
import { PlusOutlined, SearchOutlined, MailOutlined, HolderOutlined, PlayCircleOutlined, PauseCircleOutlined, CopyOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import { isStaff as staffCheck } from '../roles'
import AccountCard from '../components/accounts/AccountCard'
import AddAccountModal from '../components/accounts/AddAccountModal'
import { startAll, pauseAll, refreshAccount, fetchIsps } from '../services/accounts'
import { message } from 'antd'

const { Title, Text } = Typography

export default function AccountsPage() {
  const { accounts, loading, newEmailIds, toggle, remove, mergeEmails, user } = useApp()
  const isStaff = staffCheck(user)
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
