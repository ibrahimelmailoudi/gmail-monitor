import { useState, useEffect } from 'react'
import { Card, Table, Button, Typography, Space, Empty, Modal, Tag, message, Segmented, Input, AutoComplete, List, Form } from 'antd'
import { DownloadOutlined, DeleteOutlined, EyeOutlined, ClearOutlined, SearchOutlined, ShareAltOutlined, InboxOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import { searchUsers } from '../services/accounts'
import { sendPacket, getPackets, importPacket, deletePacket } from '../services/accounts'

const { Title, Text } = Typography

const CAT_COLORS = { primary: '#16a34a', spam: '#dc2626', promotions: '#db2777', social: '#4f46e5', updates: '#ea580c', forums: '#0891b2', inbox: '#16a34a' }

// User's saved emails (kept in memory for the session). Each can be downloaded
// as its full raw source (.eml), or all selected exported together.
export default function StoragePage() {
  const { storedEmails, removeStored, clearStored, reloadStored } = useApp()
  const [view, setView] = useState(null)
  const [selected, setSelected] = useState([])
  const [shareOpen, setShareOpen] = useState(false)
  const [pick, setPick] = useState(null)       // chosen recipient id
  const [pickLabel, setPickLabel] = useState('') // what shows in the box (the name)
  const [options, setOptions] = useState([])
  const [packetName, setPacketName] = useState('')
  const [packets, setPackets] = useState([])

  const loadPackets = () => getPackets().then(setPackets).catch(() => setPackets([]))
  useEffect(() => { loadPackets() }, [])

  const onSearchUser = async (text) => {
    setPickLabel(text); setPick(null)
    if (!text || text.length < 2) return setOptions([])
    try {
      const res = await searchUsers(text)
      // value carries the id, but we show a friendly label; we resolve the name on select
      setOptions((res || []).map(u => ({ value: String(u.id), label: `${u.username} (#${u.code})`, name: u.username })))
    } catch { setOptions([]) }
  }
  const onSelectUser = (id, option) => {
    setPick(id)
    setPickLabel(option?.label || option?.name || id)
  }
  const doShare = async () => {
    const chosen = storedEmails.filter((e, i) => selected.includes(keyOf(e, i)))
    if (!chosen.length) return message.warning('Select emails first')
    if (!pick) return message.warning('Pick a recipient')
    try {
      await sendPacket(packetName || 'Shared emails', pick, chosen)
      message.success('Shared')
      setShareOpen(false); setPick(null); setPickLabel(''); setPacketName(''); setSelected([])
    } catch (e) { message.error(e.response?.data?.message || 'Share failed') }
  }
  const doImport = async (p) => {
    try { const r = await importPacket(p.id); message.success(`Imported ${r.imported} email(s)`); reloadStored?.() }
    catch (e) { message.error(e.response?.data?.message || 'Import failed') }
  }
  const dropPacket = async (p) => {
    try { await deletePacket(p.id); loadPackets() } catch { /* ignore */ }
  }

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
            <Button icon={<ShareAltOutlined />} type="primary" ghost disabled={!selected.length}
              onClick={() => setShareOpen(true)}>
              Share selected ({selected.length})
            </Button>
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

      {/* Received packets (emails shared with me) */}
      <Card style={{ marginTop: 16 }} title={<Space><InboxOutlined />Received packets ({packets.length})</Space>}>
        {packets.length === 0
          ? <Empty description="No shared packets" />
          : <List dataSource={packets} renderItem={(p) => (
              <List.Item actions={[
                <Button size="small" type="primary" ghost onClick={() => doImport(p)}>Import to Storage</Button>,
                <Button size="small" danger onClick={() => dropPacket(p)}>Dismiss</Button>,
              ]}>
                <List.Item.Meta
                  title={<Space>{p.name} <Tag>{p.count} emails</Tag></Space>}
                  description={<Text type="secondary" style={{ fontSize: 12 }}>
                    from {p.from_username || 'someone'} - {new Date(p.created_at).toLocaleString()}</Text>} />
              </List.Item>
            )} />}
      </Card>

      {/* Share modal */}
      <Modal open={shareOpen} title={`Share ${selected.length} email(s)`} onCancel={() => setShareOpen(false)}
        onOk={doShare} okText="Share">
        <Form layout="vertical">
          <Form.Item label="Packet name (you can rename it)">
            <Input placeholder="e.g. Inbox hits - April" value={packetName}
              onChange={(e) => setPacketName(e.target.value)} />
          </Form.Item>
          <Form.Item label="Send to (search by name or 4-digit code)">
            <AutoComplete style={{ width: '100%' }} options={options} value={pickLabel}
              onSearch={onSearchUser} onSelect={onSelectUser}
              placeholder="Type a username or code" />
            {pick && <Text type="secondary" style={{ fontSize: 12 }}>Recipient selected</Text>}
          </Form.Item>
        </Form>
      </Modal>

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
