import { useState } from 'react'
import { Form, Input, Button, Modal, message } from 'antd'
import { UserOutlined, LockOutlined, SendOutlined } from '@ant-design/icons'
import { login, forgotPassword } from '../services/auth'
import { useApp } from '../context/AppProvider'
import { APP_NAME, APP_TAGLINE, SUPPORT_TELEGRAM } from '../branding'
import logo from '../assets/logo.png'

export default function LoginPage() {
  const { setToken, notify } = useApp()
  const [busy, setBusy] = useState(false)
  const [forgotOpen, setForgotOpen] = useState(false)
  const [forgotUser, setForgotUser] = useState('')

  const onFinish = async ({ username, password }) => {
    setBusy(true)
    try {
      const token = await login(username, password)
      setToken(token)
    } catch (err) {
      notify(err.response?.data?.message || 'Sign in failed. Check your credentials.', 'error')
    } finally { setBusy(false) }
  }

  const sendForgot = async () => {
    if (!forgotUser) return message.warning('Enter your username')
    try {
      await forgotPassword(forgotUser)
      message.success('Request sent to the administrator. You will be contacted shortly.')
      setForgotOpen(false); setForgotUser('')
    } catch { message.error('Could not send request') }
  }

  return (
    <div style={styles.wrap}>
      <style>{css}</style>

      <div style={styles.left}>
        <div style={styles.mesh} />
        <div style={styles.brandInner} className="ms-fade">
          <img src={logo} alt={APP_NAME} width={300} height={300} style={{ borderRadius: 16 }} />
          <h1 style={styles.brandName}>{APP_NAME}</h1>
          <p style={styles.brandTag}>{APP_TAGLINE}</p>
          <ul style={styles.points}>
            <li>Monitor inbox placement across all your mailboxes in real time</li>
            <li>Instant SPF, DKIM and DMARC verification on every message</li>
            <li>Unified dashboard for Gmail API and IMAP accounts</li>
            <li>Export and analyze deliverability data on demand</li>
          </ul>
          <div style={styles.support}>
            Need help? <a href={SUPPORT_TELEGRAM} target="_blank" rel="noreferrer" style={styles.tg}>
              <SendOutlined /> Contact support on Telegram
            </a>
          </div>
        </div>
      </div>

      <div style={styles.right}>
        <div style={styles.card} className="ms-rise">
          <h2 style={styles.title}>Welcome back</h2>
          <p style={styles.sub}>Sign in to access your dashboard</p>
          <Form layout="vertical" onFinish={onFinish} requiredMark={false}>
            <Form.Item name="username" label="Username" rules={[{ required: true, message: 'Enter your username' }]}>
              <Input size="large" prefix={<UserOutlined />} placeholder="username" autoFocus />
            </Form.Item>
            <Form.Item name="password" label="Password" rules={[{ required: true, message: 'Enter your password' }]}>
              <Input.Password size="large" prefix={<LockOutlined />} placeholder="password" />
            </Form.Item>
            <Button type="primary" htmlType="submit" size="large" block loading={busy}
              style={{ height: 46, fontWeight: 600, marginTop: 4 }}>Sign In</Button>
          </Form>
          <div style={styles.row}>
            <a onClick={() => setForgotOpen(true)} style={styles.link}>Forgot password?</a>
            <a href={SUPPORT_TELEGRAM} target="_blank" rel="noreferrer" style={styles.link}>Support</a>
          </div>
          <p style={styles.foot}>© 2026 {APP_NAME}. All rights reserved.</p>
        </div>
      </div>

      <Modal title="Request password reset" open={forgotOpen} onCancel={() => setForgotOpen(false)}
        onOk={sendForgot} okText="Send request">
        <p style={{ color: '#64748b' }}>Enter your username. An administrator will be notified and will reset your password, then contact you.</p>
        <Input prefix={<UserOutlined />} placeholder="username" value={forgotUser}
          onChange={(e) => setForgotUser(e.target.value)} onPressEnter={sendForgot} />
      </Modal>
    </div>
  )
}

const styles = {
  wrap: { minHeight: '100vh', display: 'flex', fontFamily: "'Inter', system-ui, sans-serif" },
  left: { flex: 1.1, position: 'relative', overflow: 'hidden', display: 'flex',
    alignItems: 'center', justifyContent: 'center', background: '#0b1120' },
  mesh: { position: 'absolute', inset: 0,
    background: 'radial-gradient(circle at 20% 20%, #2563eb55, transparent 45%),' +
      'radial-gradient(circle at 80% 30%, #7c3aed44, transparent 45%),' +
      'radial-gradient(circle at 50% 80%, #0ea5e944, transparent 50%)' },
  brandInner: { position: 'relative', color: '#fff', maxWidth: 440, padding: 48,  textAlign: 'center' },
  brandName: { position: 'absolute', top:'49%',right:'17%',fontSize: 39, fontWeight: 800, margin: '0px 0 6px', letterSpacing: '-0.6px' },
  brandTag: { color: '#94a3b8', fontSize: 15, margin: '0px 0 0px' },
  points: { listStyle: 'none', padding: 0, marginTop: 28, color: '#cbd5e1', lineHeight: 2, fontSize: 14 },
  support: { marginTop: 28, color: '#94a3b8', fontSize: 14 },
  tg: { color: '#38bdf8', textDecoration: 'none', fontWeight: 600 },
  right: { flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#f8fafc' },
  card: { width: 384, background: '#fff', borderRadius: 18, padding: 40,
    boxShadow: '0 20px 60px rgba(2,6,23,0.12)', border: '1px solid #eef2f7' },
  title: { fontSize: 26, fontWeight: 800, margin: 0, color: '#0f172a' },
  sub: { color: '#64748b', marginTop: 4, marginBottom: 24 },
  row: { display: 'flex', justifyContent: 'space-between', marginTop: 16 },
  link: { color: '#2563eb', cursor: 'pointer', fontSize: 13, fontWeight: 500 },
  foot: { textAlign: 'center', color: '#94a3b8', fontSize: 12, marginTop: 18 },
}

const css = `
.ms-fade { animation: msFade .8s ease both; }
.ms-rise { animation: msRise .6s cubic-bezier(.2,.8,.2,1) both; }
@keyframes msFade { from { opacity: 0; transform: translateY(10px) } to { opacity: 1; transform: none } }
@keyframes msRise { from { opacity: 0; transform: translateY(24px) } to { opacity: 1; transform: none } }
`
