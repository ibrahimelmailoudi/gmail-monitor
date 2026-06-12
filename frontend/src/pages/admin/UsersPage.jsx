import { useEffect, useState } from 'react'
import { Table, Button, Modal, Form, Input, InputNumber, Select, Typography, Tag, Space, Checkbox, Badge, Popconfirm, message, Tooltip } from 'antd'
import { PlusOutlined, SafetyOutlined, DeleteOutlined, AppstoreOutlined, CrownOutlined, EditOutlined } from '@ant-design/icons'
import { getUsers, createUser, updateUser, getPerms, setUserRole, deleteUser, setUserSections, getPresence, claimTopAdmin, transferTopAdmin, renameUserProfile, reorderUsers, topAdminExists } from '../../services/admin'
import { useApp } from '../../context/AppProvider'
import { SECTIONS, GRANTABLE_SECTIONS } from '../../sections'

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
  const [ownerExists, setOwnerExists] = useState(true)
  useEffect(() => { topAdminExists().then(d => setOwnerExists(!!d.exists)).catch(() => {}) }, [])
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
    if (u.role === 'admin' || u.role === 'owner') {
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

  const openRole = (u) => { setRoleModal(u); roleForm.setFieldsValue({ role: u.role || 'mailer',
    permissions: Object.keys(u.permissions || {}).filter(k => u.permissions[k]) }) }
  const saveRole = async (vals) => {
    const p = {}; (vals.permissions || []).forEach(x => { p[x] = true })
    try { await setUserRole(roleModal.id, vals.role, ['manager','team_leader'].includes(vals.role) ? p : {}); message.success('Role updated'); setRoleModal(null); load() }
    catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }
  const openSec = (u) => { setSecModal(u); secForm.setFieldsValue({ sections: u.sections || [] }) }
  const saveSec = async (vals) => { await setUserSections(secModal.id, vals.sections || []); message.success('Access updated'); setSecModal(null); load() }

  const roleTag = (r, row) => {
    const map = {
      owner: ['gold', 'OWNER'], admin: ['red', 'ADMIN'], support: ['volcano', 'SUPPORT'],
      manager: ['blue', 'MANAGER'], team_leader: ['cyan', 'TEAM LEADER'], mailer: ['default', 'MAILER'],
    }
    const [color, label] = map[r] || ['default', (r || 'mailer').toUpperCase()]
    return (
      <Space size={4}>
        <Tag color={color}>{label}</Tag>
        {row?.is_top_admin && <Tag color="gold" icon={<CrownOutlined />}>TOP</Tag>}
      </Space>
    )
  }
  // Transfer top-admin to another admin. Code-free if I'm the top admin; else prompt for code.
  const makeTopAdmin = (u) => {
    const doTransfer = async (code) => {
      try { await transferTopAdmin(u.id, code); message.success(`${u.username} is now the top admin`); load() }
      catch (e) { message.error(e.response?.data?.message || 'Transfer failed'); throw e }
    }
    if (me?.is_top_admin) {
      Modal.confirm({ title: `Make "${u.username}" the top admin?`,
        content: 'You will hand over top-admin authority to this admin.',
        okText: 'Transfer', onOk: () => doTransfer() })
    } else {
      let code = ''
      Modal.confirm({ title: `Make "${u.username}" the top admin`,
        content: (<div><p>Enter the top-admin secret code to authorize this.</p>
          <Input.Password placeholder="Secret code" onChange={(e) => { code = e.target.value }} /></div>),
        okText: 'Transfer', onOk: () => doTransfer(code) })
    }
  }
  // Claim top-admin for myself using the secret code (initial setup / recovery).
  // Rename a user's profile
  const renameUser = (u) => {
    let name = u.username
    Modal.confirm({
      title: `Rename "${u.username}"`,
      content: (<Input defaultValue={u.username} onChange={(e) => { name = e.target.value }} style={{ marginTop: 8 }} />),
      okText: 'Save',
      onOk: async () => {
        try { await renameUserProfile(u.id, name); message.success('Renamed'); load() }
        catch (e) { message.error(e.response?.data?.message || 'Rename failed'); throw e }
      },
    })
  }
  const claimTop = () => {
    let code = ''
    Modal.confirm({ title: 'Claim top-admin role',
      content: (<div><p>Enter the secret code to become the top admin.</p>
        <Input.Password placeholder="Secret code" onChange={(e) => { code = e.target.value }} /></div>),
      okText: 'Claim', onOk: async () => {
        try { await claimTopAdmin(code); message.success('You are now the top admin'); load() }
        catch (e) { message.error(e.response?.data?.message || 'Claim failed'); throw e }
      } })
  }

  const columns = [
    { title: '', dataIndex: 'id', width: 30, render: (id) =>
      <Badge status={online.includes(id) ? 'success' : 'default'} title={online.includes(id) ? 'Online' : 'Offline'} /> },
    { title: 'Username', dataIndex: 'username' },
    { title: 'Role', dataIndex: 'role', render: (v, row) => roleTag(v, row) },
    { title: 'Max accts', dataIndex: 'max_accounts', width: 120, render: (v, r) =>
      <InputNumber size="small" min={0} max={9999} defaultValue={v} onBlur={(e) => setMax(r.id, Number(e.target.value))} /> },
    { title: 'Token (h)', dataIndex: 'token_hours', width: 120, render: (v, r) =>
      <InputNumber size="small" min={1} max={720} placeholder="default" defaultValue={v}
        onBlur={(e) => setTokenHours(r.id, Number(e.target.value) || null)} /> },
    { title: 'Actions', key: 'act', render: (_, r) => (
      <Space>
        <Button size="small" icon={<EditOutlined />} onClick={() => renameUser(r)}>Rename</Button>
        <Button size="small" icon={<SafetyOutlined />} onClick={() => openRole(r)} disabled={r.id === me?.id}>Role</Button>
        <Button size="small" icon={<AppstoreOutlined />} onClick={() => openSec(r)}>Access</Button>
        {r.role === 'admin' && !r.is_top_admin && (
          <Tooltip title="Make this admin the top admin">
            <Button size="small" icon={<CrownOutlined />} onClick={() => makeTopAdmin(r)} />
          </Tooltip>
        )}
        {(r.role === 'admin' || r.role === 'owner') ? (
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
        <Space>
          {me?.role === 'admin' && !me?.is_top_admin && !ownerExists && (
            <Button icon={<CrownOutlined />} onClick={claimTop}>Claim top admin</Button>
          )}
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>Add User</Button>
        </Space>
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
            <Select options={[
              { value: 'mailer', label: 'Mailer (base user)' },
              { value: 'team_leader', label: 'Team Leader' },
              { value: 'manager', label: 'Manager' },
              { value: 'support', label: 'Support (all access)' },
              { value: 'admin', label: 'Admin (full access)' },
            ]} />
          </Form.Item>
          <Form.Item noStyle shouldUpdate={(p, c) => p.role !== c.role}>
            {({ getFieldValue }) => ['manager','team_leader'].includes(getFieldValue('role')) && (
              <Form.Item name="permissions" label="Permissions">
                <Checkbox.Group options={perms.map(p => ({ label: PERM_LABELS[p] || p, value: p }))} />
              </Form.Item>)}
          </Form.Item>
        </Form>
      </Modal>

      <Modal title={`Section access - ${secModal?.username || ''}`} open={!!secModal} onCancel={() => setSecModal(null)}
        onOk={() => secForm.submit()} okText="Save" width={520}>
        <p style={{ color: '#64748b' }}>Grant this user access to extra dashboard sections.</p>
        <Form form={secForm} onFinish={saveSec}>
          <Form.Item name="sections" style={{ marginBottom: 8 }}>
            <Checkbox.Group style={{ display: 'flex', flexDirection: 'column', gap: 6 }}
              options={GRANTABLE_SECTIONS.map(s => ({ label: s.label, value: s.key }))} />
          </Form.Item>
        </Form>
        <div style={{ marginTop: 12, borderTop: '1px solid #f0f0f0', paddingTop: 12 }}>
          <p style={{ color: '#94a3b8', fontSize: 12, margin: '0 0 6px' }}>Always available to everyone:</p>
          <Space size={[6, 6]} wrap>
            {SECTIONS.filter(s => s.always).map(s => <Tag key={s.key}>{s.label}</Tag>)}
          </Space>
          <p style={{ color: '#94a3b8', fontSize: 12, margin: '10px 0 6px' }}>Role-restricted (by rank, not grantable):</p>
          <Space size={[6, 6]} wrap>
            {SECTIONS.filter(s => s.role).map(s => <Tag key={s.key} color="default">{s.label} - {s.role}</Tag>)}
          </Space>
        </div>
      </Modal>
    </>
  )
}
