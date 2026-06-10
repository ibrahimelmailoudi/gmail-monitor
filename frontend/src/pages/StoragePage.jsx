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
