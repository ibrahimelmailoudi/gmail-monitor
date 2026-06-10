import { useState } from 'react'
import { Card, Table, Tag, Button, Typography, Space, Modal, AutoComplete, message, Empty, Popconfirm } from 'antd'
import { ShareAltOutlined, MailOutlined, DeleteOutlined, PlayCircleOutlined, PauseCircleOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import { searchUsers, shareAccount } from '../services/accounts'

const { Title, Text } = Typography

// A simple page where a normal user sees THEIR OWN accounts and can share them
// with another user by name or 4-digit ID. (No global-scope toggle here.)
export default function MyAccountsPage() {
  const { accounts, user, toggle, remove } = useApp()
  const mine = accounts.filter(a => a.ownerId === user?.id || a.owner_id === user?.id)

  const [shareFor, setShareFor] = useState(null) // account being shared
  const [options, setOptions] = useState([])
  const [pick, setPick] = useState(null)
  const [text, setText] = useState('')

  const onSearch = async (t) => {
    setText(t)
    if (!t || t.length < 2) { setOptions([]); return }
    try {
      const users = await searchUsers(t)
      setOptions(users.map(u => ({ value: u.id, label: `${u.username}  -  ID ${u.code}` })))
    } catch { setOptions([]) }
  }
  const doShare = async () => {
    if (!pick) return message.warning('Pick a user from the list')
    try {
      await shareAccount(shareFor.id, pick)
      message.success('Account shared')
      setShareFor(null); setPick(null); setText(''); setOptions([])
    } catch (e) { message.error(e.response?.data?.message || 'Share failed') }
  }

  const columns = [
    { title: 'Email', dataIndex: 'email', render: (v) => <Space><MailOutlined />{v}</Space> },
    { title: 'Status', dataIndex: 'active', render: (v) => <Tag color={v ? 'green' : 'default'}>{v ? 'Live' : 'Paused'}</Tag> },
    { title: 'Scope', dataIndex: 'scope', render: (v) => <Tag color={v === 'global' ? 'purple' : 'blue'}>{v || 'personal'}</Tag> },
    { title: 'Emails', key: 'n', render: (_, r) => (r.emails || []).length },
    { title: 'Actions', key: 'actions', render: (_, r) =>
      <Space>
        <Button size="small" icon={r.active ? <PauseCircleOutlined /> : <PlayCircleOutlined />}
          onClick={() => toggle(r.id)}>{r.active ? 'Pause' : 'Start'}</Button>
        <Button size="small" icon={<ShareAltOutlined />} onClick={() => setShareFor(r)}>Share</Button>
        <Popconfirm title="Delete this account?" okText="Delete" okButtonProps={{ danger: true }}
          onConfirm={() => remove(r.id)}>
          <Button size="small" danger icon={<DeleteOutlined />} />
        </Popconfirm>
      </Space> },
  ]

  return (
    <>
      <Title level={4}>My Accounts</Title>
      <Text type="secondary">Your own mailboxes. You can share any of them with another user by name or ID.</Text>
      <Card style={{ marginTop: 16 }}>
        {mine.length === 0 ? <Empty description="You have no accounts yet" /> :
          <Table rowKey="id" dataSource={mine} columns={columns} pagination={false} scroll={{ x: true }} size="small" />}
      </Card>

      <Modal title={shareFor ? `Share ${shareFor.email}` : 'Share'} open={!!shareFor}
        onCancel={() => setShareFor(null)} onOk={doShare} okText="Share">
        <p style={{ color: '#64748b' }}>Type a username or their 4-digit ID, then pick the right person.</p>
        <AutoComplete style={{ width: '100%' }} options={options} value={text}
          onSearch={onSearch} onChange={setText}
          onSelect={(value, option) => { setPick(value); setText(option.label) }}
          placeholder="Start typing a name or ID..." />
      </Modal>
    </>
  )
}
