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
