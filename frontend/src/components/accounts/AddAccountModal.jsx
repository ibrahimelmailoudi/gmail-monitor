import { useState, useEffect } from 'react'
import { Modal, Segmented, Form, Input, InputNumber, Switch, Button, Select, Typography, Space } from 'antd'
import { SafetyCertificateOutlined, KeyOutlined } from '@ant-design/icons'
import { useApp } from '../../context/AppProvider'
import { startGoogleAuth, addImapAccount, fetchIsps, gmailEnabled } from '../../services/accounts'

const { Text } = Typography

export default function AddAccountModal({ open, onClose }) {
  const { notify, socketId, user } = useApp()
  const isAdmin = !!user?.is_admin
  const [method, setMethod] = useState('IMAP')
  const [busy, setBusy] = useState(false)
  const [isps, setIsps] = useState([])
  const [gmailOn, setGmailOn] = useState(false)
  const [form] = Form.useForm()

  useEffect(() => {
    if (open) {
      fetchIsps()
        .then(list => setIsps(Array.isArray(list) ? list : []))
        .catch(() => { setIsps([]); notify?.('Could not load providers - check your connection', 'error') })
      gmailEnabled().then(en => { setGmailOn(en); setMethod(en ? 'Gmail API' : 'IMAP') }).catch(() => setGmailOn(false))
    }
  }, [open])

  const connectGmail = async () => {
    setBusy(true)
    try {
      const { url } = await startGoogleAuth(socketId)
      window.open(url, '_blank', 'width=500,height=600')
      onClose()
    } catch { notify('Failed to start Google auth', 'error') }
    finally { setBusy(false) }
  }

  const connectImap = async (values) => {
    setBusy(true)
    try {
      // Normal user sends ispId only; admin may send host/port directly.
      await addImapAccount(values)
      notify('IMAP account added')
      form.resetFields(); onClose()
    } catch (err) {
      notify(err.response?.data?.message || 'Failed to add account', 'error')
    } finally { setBusy(false) }
  }

  return (
    <Modal title="Add Account" open={open} onCancel={onClose} footer={null} destroyOnClose>
      {/* Method toggle only for admins, or when Gmail API is enabled.
          Normal users never see "IMAP"/"Gmail API" - they just pick a provider. */}
      {(isAdmin || gmailOn) && (
        <Segmented block value={method} onChange={setMethod}
          options={[
            ...(gmailOn ? [{ label: 'Gmail API', value: 'Gmail API', icon: <SafetyCertificateOutlined /> }] : []),
            { label: isAdmin ? 'IMAP' : 'Email & Password', value: 'IMAP', icon: <KeyOutlined /> },
          ]} style={{ margin: '8px 0 20px' }} />
      )}

      {method === 'Gmail API' && gmailOn ? (
        <Space direction="vertical" style={{ width: '100%' }}>
          <Text type="secondary">You'll be redirected to Google to grant access with your own consent.</Text>
          <Button type="primary" block loading={busy} icon={<SafetyCertificateOutlined />} onClick={connectGmail}>
            Connect with Google
          </Button>
        </Space>
      ) : (
        <Form form={form} layout="vertical" onFinish={connectImap}
          initialValues={{ ssl: true, port: 993 }}>
          {/* Normal users pick the provider FIRST (by name) */}
          {!isAdmin && (
            <Form.Item name="ispId" label="Email provider" rules={[{ required: true, message: 'Choose your email provider' }]}
              extra={isps.length === 0 ? 'No providers available yet - ask an admin to add/enable them in Settings.' : undefined}>
              <Select placeholder="Select your provider"
                notFoundContent="No providers"
                options={isps.map(i => ({ value: i.id, label: i.name }))} />
            </Form.Item>
          )}

          <Form.Item name="email" label="Email" rules={[{ required: true, type: 'email' }]}>
            <Input placeholder="you@example.com" />
          </Form.Item>
          <Form.Item name="password" label="App password" rules={[{ required: true }]}>
            <Input.Password placeholder="App-specific password" />
          </Form.Item>

          {/* Admins: full control over host/port, or also pick a preset */}
          {isAdmin && (
            <>
              <Form.Item name="ispId" label="Provider preset (optional)">
                <Select allowClear placeholder="Use a preset, or fill host/port below"
                  options={isps.map(i => ({ value: i.id, label: i.name }))} />
              </Form.Item>
              <Space>
                <Form.Item name="host" label="IMAP host"><Input placeholder="imap.gmail.com" /></Form.Item>
                <Form.Item name="port" label="Port"><InputNumber min={1} max={65535} /></Form.Item>
                <Form.Item name="ssl" label="SSL" valuePropName="checked"><Switch /></Form.Item>
              </Space>
            </>
          )}

          <Button type="primary" htmlType="submit" block loading={busy}>Add Account</Button>
          <Text type="secondary" style={{ fontSize: 12, display: 'block', marginTop: 8 }}>
            For Gmail use an App Password, not your normal password.
          </Text>
        </Form>
      )}
    </Modal>
  )
}
