import { useEffect, useState, useCallback } from 'react'
import { Card, List, Tag, Button, Modal, Form, Input, Select, Space, Typography, message, Empty, Popconfirm } from 'antd'
import { PlusOutlined, CheckOutlined, DeleteOutlined } from '@ant-design/icons'
import { useApp } from '../context/AppProvider'
import { isStaff as staffCheck, can as canCheck } from '../roles'
import { getRequests, createRequest, getThread, replyRequest, setRequestStatus, getRequestTypes, deleteRequest } from '../services/requests'
import { useSocketEvent } from '../hooks/useRealtime'

const { Title, Text, Paragraph } = Typography

const TYPE_LABEL = { reset: 'Password reset', access: 'Account access', problem: 'Problem report', message: 'Message' }

// Sender-rank groups for the staff requests view (highest rank first).
const RANK_GROUPS = [
  { role: 'admin', label: 'From Admins', color: 'red' },
  { role: 'support', label: 'From Support', color: 'volcano' },
  { role: 'manager', label: 'From Managers', color: 'blue' },
  { role: 'team_leader', label: 'From Team Leaders', color: 'cyan' },
  { role: 'mailer', label: 'From Mailers', color: 'default' },
]

export default function RequestsPage() {
  const { user } = useApp()
  const isStaff = staffCheck(user)
  const canResolve = canCheck(user, 'resolve_requests')

  const [requests, setRequests] = useState([])
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(null)   // selected request
  const [thread, setThread] = useState([])
  const [reply, setReply] = useState('')
  const [form] = Form.useForm()
  const [types, setTypes] = useState([])

  const load = useCallback(() => getRequests().then(setRequests).catch(() => {}), [])
  useEffect(() => { load(); getRequestTypes().then(setTypes).catch(() => {}) }, [load])

  useSocketEvent('request_new', load)
  useSocketEvent('request_status', load)
  useSocketEvent('request_msg', (p) => { load(); if (active && p.requestId === active.id) getThread(active.id).then(setThread) })

  const openThread = async (r) => {
    setActive(r)
    setThread(await getThread(r.id))
  }

  const sendReply = async () => {
    if (!reply.trim()) return
    await replyRequest(active.id, reply)
    setReply(''); setThread(await getThread(active.id))
  }

  const submitNew = async (vals) => {
    try {
      await createRequest(vals)
      message.success('Request sent')
      setOpen(false); form.resetFields(); load()
    } catch { message.error('Failed to send') }
  }

  const resolve = async (r, status) => {
    await setRequestStatus(r.id, status); load()
  }
  const doDelete = async (id) => {
    try { await deleteRequest(id); if (active?.id === id) setActive(null); load(); message.success('Request deleted') }
    catch (e) { message.error(e.response?.data?.message || 'Delete failed') }
  }

  // Single request row - shared by the grouped (staff) and flat (user) lists.
  const renderRequestItem = (r) => (
    <List.Item onClick={() => openThread(r)} style={{ cursor: 'pointer', padding: 12,
      background: active?.id === r.id ? 'rgba(37,99,235,0.06)' : undefined, borderRadius: 8 }}
      actions={[
        ...(canResolve ? [
          r.status === 'open'
            ? <Button size="small" icon={<CheckOutlined />} onClick={(e) => { e.stopPropagation(); resolve(r, 'resolved') }}>Resolve</Button>
            : <Button size="small" onClick={(e) => { e.stopPropagation(); resolve(r, 'open') }}>Reopen</Button>
        ] : []),
        <Popconfirm title="Delete this request?" onConfirm={(e) => { e?.stopPropagation?.(); doDelete(r.id) }}
          onCancel={(e) => e?.stopPropagation?.()}>
          <Button size="small" danger icon={<DeleteOutlined />} onClick={(e) => e.stopPropagation()} />
        </Popconfirm>,
      ]}>
      <List.Item.Meta
        title={<Space>
          <Tag color={r.status === 'open' ? 'orange' : 'green'}>{r.status}</Tag>
          <Text strong>{TYPE_LABEL[r.type] || r.type}</Text>
          {isStaff && <Text type="secondary">- {r.username}</Text>}
        </Space>}
        description={<Text type="secondary">{r.subject || '(no subject)'} - {new Date(r.created_at).toLocaleString()}</Text>} />
    </List.Item>
  )

  return (
    <>
      <Space style={{ width: '100%', justifyContent: 'space-between', marginBottom: 16 }}>
        <Title level={4} style={{ margin: 0 }}>{isStaff ? 'Support Requests' : 'My Requests'}</Title>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setOpen(true)}>New Request</Button>
      </Space>

      <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        <div style={{ flex: '1 1 360px' }}>
          {requests.length === 0 ? (
            <Card><Empty description="No requests" /></Card>
          ) : isStaff ? (
            // Staff: grouped by the sender's rank, highest-rank group first.
            RANK_GROUPS.map(g => {
              const items = requests.filter(r => (r.sender_role || 'mailer') === g.role)
              if (!items.length) return null
              return (
                <Card key={g.role} size="small" style={{ marginBottom: 12 }}
                  title={<Space><Tag color={g.color}>{g.label}</Tag><Text type="secondary">({items.length})</Text></Space>}
                  styles={{ body: { padding: 8 } }}>
                  <List dataSource={items} renderItem={renderRequestItem} />
                </Card>
              )
            })
          ) : (
            <Card styles={{ body: { padding: 8 } }}>
              <List dataSource={requests} renderItem={renderRequestItem} />
            </Card>
          )}
        </div>

        {active && (
          <Card style={{ flex: '1 1 380px' }} title={`${TYPE_LABEL[active.type] || active.type}: ${active.subject || ''}`}>
            <div style={{ maxHeight: 360, overflow: 'auto', marginBottom: 12 }}>
              {thread.map(m => (
                <div key={m.id} style={{ marginBottom: 10, textAlign: m.sender_role === 'user' ? 'left' : 'right' }}>
                  <div style={{ display: 'inline-block', maxWidth: '80%', padding: '8px 12px', borderRadius: 10,
                    background: m.sender_role === 'user' ? '#f1f5f9' : '#2563eb',
                    color: m.sender_role === 'user' ? '#0f172a' : '#fff', textAlign: 'left' }}>
                    <div style={{ fontSize: 11, opacity: 0.7, marginBottom: 2 }}>{m.username || m.sender_role}</div>
                    {m.body}
                  </div>
                </div>
              ))}
              {thread.length === 0 && <Text type="secondary">No messages yet.</Text>}
            </div>
            {active.status === 'resolved' ? (
              <Text type="secondary">This request is resolved and closed. It will be removed automatically.</Text>
            ) : (
              <Space.Compact style={{ width: '100%' }}>
                <Input value={reply} onChange={(e) => setReply(e.target.value)} onPressEnter={sendReply}
                  placeholder="Write a message..." />
                <Button type="primary" onClick={sendReply}>Send</Button>
              </Space.Compact>
            )}
          </Card>
        )}
      </div>

      <Modal title="New Request" open={open} onCancel={() => setOpen(false)} onOk={() => form.submit()} okText="Send">
        <Form form={form} layout="vertical" onFinish={submitNew} initialValues={{ type: 'message' }}>
          <Form.Item name="type" label="Type">
            <Select options={types.map(t => ({ value: t.key, label: t.label }))} />
          </Form.Item>
          <Form.Item name="subject" label="Subject"><Input placeholder="Short summary" /></Form.Item>
          <Form.Item name="body" label="Message" rules={[{ required: true }]}>
            <Input.TextArea rows={4} placeholder="Describe your request..." />
          </Form.Item>
        </Form>
      </Modal>
    </>
  )
}
