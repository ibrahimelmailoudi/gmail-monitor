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
