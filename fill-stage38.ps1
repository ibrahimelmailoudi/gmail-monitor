# fill-stage38.ps1 - Extract results persist across navigation + select/save emails to new Storage section
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path frontend\src\context,frontend\src\pages,frontend\src\layout | Out-Null

Set-Content -LiteralPath 'frontend\src\context\AppProvider.jsx' -Encoding utf8 -Value @'
import { createContext, useContext, useState, useCallback, useEffect, useRef } from 'react'
import { ConfigProvider, message } from 'antd'
import { makeTheme } from '../theme'
import { useAccounts } from '../hooks/useAccounts'
import { resumeAll, pauseAll } from '../services/accounts'

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
  // Emails the user chose to save (full source). In-memory for the session.
  const [storedEmails, setStoredEmails] = useState([])
  const saveEmails = useCallback((emails) => {
    setStoredEmails(prev => {
      const seen = new Set(prev.map(e => e.message_id || `${e.from_email}|${e.subject}`))
      const add = emails.filter(e => !seen.has(e.message_id || `${e.from_email}|${e.subject}`))
      return [...add, ...prev]
    })
  }, [])
  const removeStored = useCallback((id) =>
    setStoredEmails(prev => prev.filter(e => (e.message_id || `${e.from_email}|${e.subject}`) !== id)), [])
  const clearStored = useCallback(() => setStoredEmails([]), [])

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
        storedEmails, saveEmails, removeStored, clearStored,
        ...accountState }}>
        {contextHolder}
        {children}
      </AppContext.Provider>
    </ConfigProvider>
  )
}
'@
Write-Host 'wrote frontend\src\context\AppProvider.jsx'

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
  const saveSelected = () => {
    const chosen = rows.filter((r, i) => selectedKeys.includes(rowKeyOf(r, i)))
    if (!chosen.length) return message.warning('Select at least one email')
    if (!withSource && chosen.some(r => !r.source)) {
      message.warning('Tip: enable "Include full source" and re-extract to save the raw source too')
    }
    saveEmails(chosen)
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

  const keyOf = (e, i) => e.message_id || `${e.from_email}|${e.subject}|${i}`

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
          onClick={() => removeStored(r.message_id || `${r.from_email}|${r.subject}`)} />
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

Set-Content -LiteralPath 'frontend\src\App.jsx' -Encoding utf8 -Value @'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AppProvider, useApp } from './context/AppProvider'
import DashboardLayout from './layout/DashboardLayout'
import DashboardPage from './pages/DashboardPage'
import AccountsPage from './pages/AccountsPage'
import MyAccountsPage from './pages/MyAccountsPage'
import StoragePage from './pages/StoragePage'
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
  DatabaseOutlined, ExportOutlined, MessageOutlined, MailOutlined, IdcardOutlined } from '@ant-design/icons'
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
Write-Host "STAGE 38 written. Restart frontend (npm run dev), hard-refresh."
