import { useState, useEffect } from 'react'
import { Card, Table, Button, Typography, Space, Empty, Modal, Form, Input, Select, Tag, message, List, Drawer } from 'antd'
import { PlusOutlined, TeamOutlined, DeleteOutlined, UserAddOutlined, EyeOutlined, MailOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import { isStaff, rankOf, RANK } from '../roles'
import { getTeams, createTeam, deleteTeam, getTeamMembers, addTeamMember, removeTeamMember, getMemberAccounts } from '../services/teams'
import { getUsers } from '../services/admin'

const { Title, Text } = Typography

export default function TeamsPage() {
  const { user } = useApp()
  const isAdminUp = rankOf(user) >= RANK.support
  const [teams, setTeams] = useState([])
  const [users, setUsers] = useState([])
  const [active, setActive] = useState(null)     // selected team
  const [members, setMembers] = useState([])
  const [loading, setLoading] = useState(true)
  const [newTeam, setNewTeam] = useState(false)
  const [addMember, setAddMember] = useState(false)
  const [viewAccts, setViewAccts] = useState(null) // { member, accounts }
  const [form] = Form.useForm()
  const [memForm] = Form.useForm()

  const load = () => { setLoading(true); getTeams().then(setTeams).finally(() => setLoading(false)) }
  useEffect(() => { load(); if (isAdminUp || rankOf(user) >= RANK.manager) getUsers().then(setUsers).catch(() => {}) }, [])

  const openTeam = async (t) => {
    setActive(t)
    try { setMembers(await getTeamMembers(t.id)) } catch { setMembers([]) }
  }
  const submitTeam = async () => {
    const v = await form.validateFields()
    try { await createTeam(v.name, v.managerId); message.success('Team created'); setNewTeam(false); form.resetFields(); load() }
    catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }
  const removeTeam = (t) => Modal.confirm({ title: `Delete team "${t.name}"?`, okButtonProps: { danger: true },
    onOk: async () => { await deleteTeam(t.id); if (active?.id === t.id) { setActive(null); setMembers([]) } load() } })

  const submitMember = async () => {
    const v = await memForm.validateFields()
    try { await addTeamMember(active.id, v.userId, v.roleInTeam); message.success('Member added'); setAddMember(false); memForm.resetFields(); openTeam(active) }
    catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }
  const dropMember = async (m) => {
    try { await removeTeamMember(active.id, m.id); openTeam(active) }
    catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }
  const viewMemberAccounts = async (m) => {
    try { const d = await getMemberAccounts(active.id, m.id); setViewAccts({ member: m, accounts: d.accounts || [] }) }
    catch (e) { message.error(e.response?.data?.message || 'Cannot view') }
  }

  // Am I the manager of the active team (so I can add/remove members)?
  const canManageActive = isAdminUp || (active && active.manager_id === user?.id)

  const teamColumns = [
    { title: 'Team', dataIndex: 'name', render: (v) => <Space><TeamOutlined />{v}</Space> },
    { title: 'Manager', dataIndex: 'manager_username', render: (v) => v || <Text type="secondary">unassigned</Text> },
    { title: '', key: 'a', width: 160, render: (_, t) =>
      <Space>
        <Button size="small" onClick={() => openTeam(t)}>Open</Button>
        {isAdminUp && <Button size="small" danger icon={<DeleteOutlined />} onClick={() => removeTeam(t)} />}
      </Space> },
  ]

  const roleInTeamTag = (r) => r === 'team_leader' ? <Tag color="cyan">TEAM LEADER</Tag> : <Tag>MAILER</Tag>

  return (
    <>
      <Title level={4}>Teams</Title>
      <Text type="secondary">
        {isAdminUp ? 'Create teams and assign a manager. Managers add their leaders and mailers.'
          : 'Your teams. Team leaders can view (not edit) their mailers\u0027 accounts.'}
      </Text>

      <Card style={{ marginTop: 16 }}
        title={`Teams (${teams.length})`}
        extra={isAdminUp && <Button type="primary" icon={<PlusOutlined />} onClick={() => setNewTeam(true)}>New team</Button>}>
        {teams.length === 0 && !loading
          ? <Empty description="No teams yet" />
          : <Table rowKey="id" dataSource={teams} columns={teamColumns} loading={loading} pagination={false} size="small" />}
      </Card>

      {active && (
        <Card style={{ marginTop: 16 }}
          title={<Space><TeamOutlined />{active.name} - members ({members.length})</Space>}
          extra={canManageActive && <Button icon={<UserAddOutlined />} onClick={() => setAddMember(true)}>Add member</Button>}>
          {members.length === 0
            ? <Empty description="No members yet" />
            : <List dataSource={members} renderItem={(m) => (
                <List.Item actions={[
                  <Button size="small" icon={<EyeOutlined />} onClick={() => viewMemberAccounts(m)}>View accounts</Button>,
                  ...(canManageActive ? [<Button size="small" danger icon={<DeleteOutlined />} onClick={() => dropMember(m)} />] : []),
                ]}>
                  <List.Item.Meta title={<Space>{m.username} {roleInTeamTag(m.role_in_team)}</Space>} />
                </List.Item>
              )} />}
        </Card>
      )}

      {/* Create team */}
      <Modal open={newTeam} title="New team" onCancel={() => setNewTeam(false)} onOk={submitTeam} okText="Create">
        <Form form={form} layout="vertical">
          <Form.Item name="name" label="Team name" rules={[{ required: true }]}><Input placeholder="e.g. Outreach Team A" /></Form.Item>
          <Form.Item name="managerId" label="Manager">
            <Select showSearch optionFilterProp="label" placeholder="Assign a manager"
              options={users.filter(u => ['manager','admin','owner','support'].includes(u.role)).map(u => ({ value: u.id, label: `${u.username} (${u.role})` }))} />
          </Form.Item>
        </Form>
      </Modal>

      {/* Add member */}
      <Modal open={addMember} title="Add member" onCancel={() => setAddMember(false)} onOk={submitMember} okText="Add">
        <Form form={memForm} layout="vertical">
          <Form.Item name="userId" label="User" rules={[{ required: true }]}>
            <Select showSearch optionFilterProp="label" placeholder="Pick a user"
              options={users.filter(u => ['mailer','team_leader'].includes(u.role)).map(u => ({ value: u.id, label: `${u.username} (${u.role})` }))} />
          </Form.Item>
          <Form.Item name="roleInTeam" label="Role in team" rules={[{ required: true }]} initialValue="mailer">
            <Select options={[{ value: 'mailer', label: 'Mailer' }, { value: 'team_leader', label: 'Team Leader' }]} />
          </Form.Item>
        </Form>
      </Modal>

      {/* Read-only member accounts */}
      <Drawer open={!!viewAccts} width={520} onClose={() => setViewAccts(null)}
        title={viewAccts ? `${viewAccts.member.username}'s accounts (read-only)` : ''}>
        {viewAccts?.accounts?.length
          ? <List dataSource={viewAccts.accounts} renderItem={(a) => (
              <List.Item>
                <List.Item.Meta avatar={<MailOutlined />} title={a.email}
                  description={<Space><Tag color={a.active ? 'green' : 'default'}>{a.active ? 'Live' : 'Paused'}</Tag>
                    <Tag color={a.scope === 'global' ? 'purple' : 'blue'}>{a.scope || 'personal'}</Tag></Space>} />
              </List.Item>
            )} />
          : <Empty description="No accounts" />}
      </Drawer>
    </>
  )
}
