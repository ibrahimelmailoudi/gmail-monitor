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
