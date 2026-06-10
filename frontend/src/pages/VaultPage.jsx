import { useState, useEffect } from 'react'
import { Card, Table, Button, Typography, Space, Empty, Modal, Form, Input, message, Tooltip } from 'antd'
import { PlusOutlined, EyeOutlined, EyeInvisibleOutlined, EditOutlined, DeleteOutlined, CopyOutlined, LockOutlined } from '@ant-design/icons'
import { getVaultItems, revealVaultItem, addVaultItem, updateVaultItem, deleteVaultItem } from '../services/vault'

const { Title, Text } = Typography

// Personal Vault: securely store app passwords + notes (encrypted at rest in the DB).
export default function VaultPage() {
  const [items, setItems] = useState([])
  const [loading, setLoading] = useState(true)
  const [modal, setModal] = useState(null) // 'new' | item being edited
  const [revealed, setRevealed] = useState({}) // id -> { secret, notes }
  const [form] = Form.useForm()

  const load = () => {
    setLoading(true)
    getVaultItems().then(setItems).catch(() => setItems([])).finally(() => setLoading(false))
  }
  useEffect(load, [])

  const openNew = () => { setModal('new'); form.resetFields() }
  const openEdit = async (item) => {
    // fetch the decrypted values to prefill the form
    try {
      const full = await revealVaultItem(item.id)
      setModal(item)
      form.setFieldsValue({ label: full.label, account_email: full.account_email,
        username: full.username, secret: full.secret, notes: full.notes })
    } catch { message.error('Could not open item') }
  }
  const submit = async () => {
    const v = await form.validateFields()
    try {
      if (modal === 'new') await addVaultItem(v)
      else await updateVaultItem(modal.id, v)
      message.success('Saved'); setModal(null); load()
    } catch (e) { message.error(e.response?.data?.message || 'Save failed') }
  }
  const remove = async (id) => {
    try { await deleteVaultItem(id); message.success('Deleted'); load() }
    catch { message.error('Delete failed') }
  }
  const toggleReveal = async (item) => {
    if (revealed[item.id]) { setRevealed(p => { const n = { ...p }; delete n[item.id]; return n }); return }
    try {
      const full = await revealVaultItem(item.id)
      setRevealed(p => ({ ...p, [item.id]: { secret: full.secret, notes: full.notes } }))
    } catch { message.error('Could not reveal') }
  }
  const copy = (text) => navigator.clipboard.writeText(text || '')
    .then(() => message.success('Copied')).catch(() => message.error('Copy failed'))

  const columns = [
    { title: 'Label', dataIndex: 'label', render: (v) => <Space><LockOutlined />{v}</Space> },
    { title: 'Account', dataIndex: 'account_email', ellipsis: true, render: (v) => v || <Text type="secondary">-</Text> },
    { title: 'Username', dataIndex: 'username', render: (v) => v || <Text type="secondary">-</Text> },
    { title: 'Secret', key: 'secret', render: (_, r) => {
      const shown = revealed[r.id]
      return (
        <Space>
          <code style={{ fontSize: 12 }}>
            {!r.hasSecret ? <Text type="secondary">none</Text> : shown ? shown.secret : '********'}
          </code>
          {r.hasSecret && (
            <Tooltip title={shown ? 'Hide' : 'Reveal'}>
              <Button size="small" type="text" icon={shown ? <EyeInvisibleOutlined /> : <EyeOutlined />}
                onClick={() => toggleReveal(r)} />
            </Tooltip>
          )}
          {r.hasSecret && shown && (
            <Button size="small" type="text" icon={<CopyOutlined />} onClick={() => copy(shown.secret)} />
          )}
        </Space>
      )
    } },
    { title: 'Actions', key: 'a', width: 110, render: (_, r) =>
      <Space>
        <Button size="small" icon={<EditOutlined />} onClick={() => openEdit(r)} />
        <Button size="small" danger icon={<DeleteOutlined />}
          onClick={() => Modal.confirm({ title: `Delete "${r.label}"?`, okButtonProps: { danger: true }, onOk: () => remove(r.id) })} />
      </Space> },
  ]

  return (
    <>
      <Title level={4}>Vault</Title>
      <Text type="secondary">Securely store app passwords, tokens, and notes. Encrypted at rest - only you can see them.</Text>
      <Card style={{ marginTop: 16 }}
        title={`Saved secrets (${items.length})`}
        extra={<Button type="primary" icon={<PlusOutlined />} onClick={openNew}>New secret</Button>}>
        {items.length === 0 && !loading ? (
          <Empty description="No secrets yet. Click 'New secret' to add an app password or note." />
        ) : (
          <Table rowKey="id" dataSource={items} columns={columns} loading={loading}
            scroll={{ x: true }} size="small" pagination={{ pageSize: 20 }}
            expandable={{
              expandedRowRender: (r) => {
                const shown = revealed[r.id]
                return (
                  <div style={{ padding: '4px 8px' }}>
                    <Text strong>Notes: </Text>
                    {r.hasNotes
                      ? (shown ? <span style={{ whiteSpace: 'pre-wrap' }}>{shown.notes}</span>
                                : <Text type="secondary">hidden - click the eye to reveal</Text>)
                      : <Text type="secondary">none</Text>}
                  </div>
                )
              },
              rowExpandable: (r) => r.hasNotes,
            }} />
        )}
      </Card>

      <Modal open={!!modal} title={modal === 'new' ? 'New secret' : 'Edit secret'}
        onCancel={() => setModal(null)} onOk={submit} okText="Save">
        <Form form={form} layout="vertical">
          <Form.Item name="label" label="Label" rules={[{ required: true, message: 'Give it a name' }]}>
            <Input placeholder="e.g. Gmail app password - work" />
          </Form.Item>
          <Form.Item name="account_email" label="Account email">
            <Input placeholder="name@gmail.com" />
          </Form.Item>
          <Form.Item name="username" label="Username (optional)">
            <Input />
          </Form.Item>
          <Form.Item name="secret" label="App password / secret">
            <Input.Password placeholder="the 16-char app password or token" />
          </Form.Item>
          <Form.Item name="notes" label="Notes">
            <Input.TextArea rows={3} placeholder="anything you want to remember" />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}
