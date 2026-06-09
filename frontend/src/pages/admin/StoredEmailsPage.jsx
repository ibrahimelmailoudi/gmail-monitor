import { useEffect, useState, useCallback } from 'react'
import { Table, Select, Button, Space, Typography, Tag, Popconfirm, message } from 'antd'
import { DeleteOutlined, ReloadOutlined } from '@ant-design/icons'
import { getStoredEmails, deleteStoredEmail, bulkDeleteEmails } from '../../services/admin'
import { useApp } from '../../context/AppProvider'
import { CATEGORIES } from '../../config'

const { Title, Paragraph } = Typography

export default function StoredEmailsPage() {
  const { accounts } = useApp()
  const [rows, setRows] = useState([])
  const [loading, setLoading] = useState(true)
  const [accountId, setAccountId] = useState(null)
  const [category, setCategory] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    getStoredEmails({ accountId, category, limit: 500 })
      .then(setRows).finally(() => setLoading(false))
  }, [accountId, category])
  useEffect(() => { load() }, [load])

  const removeOne = async (id) => { await deleteStoredEmail(id); message.success('Deleted'); load() }
  const removeAll = async () => {
    await bulkDeleteEmails({ accountId, category }); message.success('Deleted'); load()
  }

  const catTag = (c) => {
    const cat = CATEGORIES[c] || CATEGORIES.other
    return <Tag color={cat.color}>{cat.name}</Tag>
  }

  const columns = [
    { title: 'Placement', dataIndex: 'category', width: 120, render: catTag },
    { title: 'Account', dataIndex: 'account_email', ellipsis: true },
    { title: 'From', dataIndex: 'sender_name', ellipsis: true, render: (v, r) => v || r.sender_email },
    { title: 'Subject', dataIndex: 'subject', ellipsis: true },
    { title: 'SPF', dataIndex: 'spf', width: 70, render: (v) => v || '-' },
    { title: 'DKIM', dataIndex: 'dkim', width: 70, render: (v) => v || '-' },
    { title: 'DMARC', dataIndex: 'dmarc', width: 80, render: (v) => v || '-' },
    { title: 'Received', dataIndex: 'received_at', width: 160, render: (v) => new Date(v).toLocaleString() },
    { title: '', key: 'act', width: 50, render: (_, r) => (
      <Popconfirm title="Delete this email?" onConfirm={() => removeOne(r.id)}>
        <Button size="small" danger icon={<DeleteOutlined />} />
      </Popconfirm>) },
  ]

  return (
    <>
      <Title level={4}>Stored Emails</Title>
      <Paragraph type="secondary">Emails saved while storage is on (auto-deleted after 24h). Filter, review, and delete.</Paragraph>

      <Space style={{ marginBottom: 16 }} wrap>
        <Select allowClear placeholder="All accounts" style={{ width: 260 }} value={accountId} onChange={setAccountId}
          options={accounts.map(a => ({ value: a.id, label: a.email }))} />
        <Select allowClear placeholder="All placements" style={{ width: 180 }} value={category} onChange={setCategory}
          options={[
            { value: 'primary', label: 'Primary' }, { value: 'promotions', label: 'Promotions' },
            { value: 'social', label: 'Social' }, { value: 'updates', label: 'Updates' },
            { value: 'spam', label: 'Spam' },
          ]} />
        <Button icon={<ReloadOutlined />} onClick={load}>Refresh</Button>
        <Popconfirm title="Delete ALL matching emails?" onConfirm={removeAll}>
          <Button danger icon={<DeleteOutlined />}>Delete all (filtered)</Button>
        </Popconfirm>
      </Space>

      <Table rowKey="id" loading={loading} dataSource={rows} columns={columns}
        size="small" pagination={{ pageSize: 25 }} scroll={{ x: true }} />
    </>
  )
}
