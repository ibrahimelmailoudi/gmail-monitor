import { useEffect, useState, useCallback } from 'react'
import { Table, Tag, Switch, Select, Typography, Space, message } from 'antd'
import { getAllAccounts, setAccountScope, getUsers, grantAccess, revokeAccess } from '../../services/admin'

const { Title, Paragraph } = Typography

export default function AllAccountsPage() {
  const [accounts, setAccounts] = useState([])
  const [users, setUsers] = useState([])
  const [loading, setLoading] = useState(true)

  const load = useCallback(() => {
    Promise.all([getAllAccounts(), getUsers()])
      .then(([a, u]) => { setAccounts(a); setUsers(u) })
      .finally(() => setLoading(false))
  }, [])
  useEffect(() => { load() }, [load])

  const toggleScope = async (row, checked) => {
    await setAccountScope(row.id, checked ? 'global' : 'personal')
    message.success(`${row.email} is now ${checked ? 'global' : 'personal'}`)
    load()
  }

  // Which users currently have access (besides the owner)
  const grantedIds = (row) => (row.grants || []).map(g => g.user_id)

  const updateGrants = async (row, selectedUserIds) => {
    const current = grantedIds(row)
    const toAdd = selectedUserIds.filter(id => !current.includes(id))
    const toRemove = current.filter(id => !selectedUserIds.includes(id))
    await Promise.all([
      ...toAdd.map(id => grantAccess(row.id, id)),
      ...toRemove.map(id => revokeAccess(row.id, id)),
    ])
    message.success('Access updated')
    load()
  }

  const columns = [
    { title: 'Account', dataIndex: 'email',
      render: (v, r) => <Space direction="vertical" size={0}>
        <span style={{ fontWeight: 600 }}>{v}</span>
        <Tag>{(r.type || '').toUpperCase()}</Tag>
      </Space> },
    { title: 'Owner', dataIndex: 'owner_username' },
    { title: 'Scope', dataIndex: 'scope', render: (v, r) =>
      <Space>
        <Switch checked={v === 'global'} checkedChildren="Global" unCheckedChildren="Personal"
          onChange={(c) => toggleScope(r, c)} />
      </Space> },
    { title: 'Shared with', key: 'grants', width: 320, render: (_, r) =>
      r.scope === 'global' ? (
        <Select mode="multiple" allowClear style={{ width: '100%' }} placeholder="Grant users access..."
          value={grantedIds(r)}
          onChange={(ids) => updateGrants(r, ids)}
          options={users
            .filter(u => u.id !== r.owner_id)   // owner already has access
            .map(u => ({ value: u.id, label: u.username }))} />
      ) : <span style={{ color: '#94a3b8' }}> -  personal  - </span> },
    { title: 'Status', dataIndex: 'active', render: (v) =>
      v ? <Tag color="green">Live</Tag> : <Tag>Stopped</Tag> },
  ]

  return (
    <>
      <Title level={4}>All Accounts</Title>
      <Paragraph type="secondary">
        Every connected account across all users. Mark an account <b>Global</b> to share it,
        then choose which users can see it. Owners always keep access.
      </Paragraph>
      <Table rowKey="id" loading={loading} dataSource={accounts} columns={columns} pagination={false} />
    </>
  )
}
