import { useState, useEffect, useCallback } from 'react'
import { Badge, Dropdown, Button, List, Typography, Empty, Modal, Input, message, notification } from 'antd'
import { BellOutlined } from '@ant-design/icons'
import { getResetRequests, setUserPassword } from '../services/admin'
import { getNotifications, markNotificationsRead } from '../services/accounts'
import { useSocketEvent } from '../hooks/useRealtime'

const { Text } = Typography

export default function NotificationBell() {
  const [data, setData] = useState({ items: [], unread: 0 })
  const [open, setOpen] = useState(false)
  const [resetModal, setResetModal] = useState(null) // { reqId, username }
  const [newPass, setNewPass] = useState('')

  const [api, notifHolder] = notification.useNotification()

  const load = useCallback(() => { getNotifications().then(setData).catch(() => {}) }, [])
  useEffect(() => { load() }, [load])
  // When a live event arrives: refresh the list AND show an in-interface banner.
  const onLive = useCallback((payload) => {
    load()
    api.open({
      message: 'New notification',
      description: payload?.message || 'You have a new notification',
      placement: 'topRight', duration: 5,
    })
  }, [load, api])
  useSocketEvent('notif', onLive)
  useSocketEvent('request_new', load)

  const onOpenChange = async (v) => {
    setOpen(v)
    if (v && data.unread > 0) { await markNotificationsRead(); load() }
  }

  const openReset = async (n) => {
    // find the matching reset request to get the username
    const reqs = await getResetRequests()
    const r = reqs.find(x => x.id === n.ref_id) || {}
    setResetModal({ reqId: n.ref_id, username: r.username || '' })
    setNewPass('')
  }

  const submitReset = async () => {
    try {
      await setUserPassword(resetModal.reqId, resetModal.username, newPass)
      message.success(`Password updated for ${resetModal.username}`)
      setResetModal(null); load()
    } catch (e) { message.error(e.response?.data?.message || 'Failed') }
  }

  const panel = (
    <div style={{ width: 340, maxHeight: 420, overflow: 'auto', background: 'var(--ant-color-bg-elevated, #fff)',
      borderRadius: 10, boxShadow: '0 10px 40px rgba(2,6,23,0.18)', padding: 8 }}>
      {data.items.length === 0 ? <Empty description="No notifications" style={{ padding: 24 }} /> : (
        <List size="small" dataSource={data.items} renderItem={(n) => (
          <List.Item style={{ cursor: n.type === 'reset_request' ? 'pointer' : 'default' }}
            onClick={() => n.type === 'reset_request' && openReset(n)}>
            <List.Item.Meta
              title={<Text style={{ fontSize: 13 }}>{n.message}</Text>}
              description={<Text type="secondary" style={{ fontSize: 11 }}>
                {new Date(n.created_at).toLocaleString()}{n.type === 'reset_request' ? ' - click to set new password' : ''}
              </Text>} />
          </List.Item>
        )} />
      )}
    </div>
  )

  return (
    <>
      {notifHolder}
      <Dropdown open={open} onOpenChange={onOpenChange} trigger={['click']}
        popupRender={() => panel} placement="bottomRight">
        <Badge count={data.unread} size="small">
          <Button type="text" shape="circle" icon={<BellOutlined />} />
        </Badge>
      </Dropdown>

      <Modal open={!!resetModal} title="Set new password" onCancel={() => setResetModal(null)}
        onOk={submitReset} okText="Update password">
        <p>User: <b>{resetModal?.username}</b></p>
        <Input.Password placeholder="New password" value={newPass} onChange={(e) => setNewPass(e.target.value)} />
        <p style={{ color: '#94a3b8', fontSize: 12, marginTop: 8 }}>
          After updating, contact the user to confirm they can log in.
        </p>
      </Modal>
    </>
  )
}
