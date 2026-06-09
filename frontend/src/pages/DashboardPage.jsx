import { useEffect, useState } from 'react'
import { Row, Col, Card, Statistic, Spin, Typography, Progress, Tag, Tooltip, Empty } from 'antd'
import { InboxOutlined, WarningOutlined, SafetyOutlined, CheckCircleOutlined,
  TeamOutlined, ThunderboltOutlined } from '@ant-design/icons'
import { getStats, getPresence } from '../services/admin'
import { useApp } from '../context/AppProvider'

const { Title, Text, Paragraph } = Typography

function Gauge({ label, percent, color, hint }) {
  return (
    <Card>
      <Tooltip title={hint}>
        <div style={{ textAlign: 'center' }}>
          <Progress type="dashboard" percent={percent} strokeColor={color} size={120} />
          <div style={{ marginTop: 8, fontWeight: 600 }}>{label}</div>
        </div>
      </Tooltip>
    </Card>
  )
}

export default function DashboardPage() {
  const { accounts } = useApp()
  const [stats, setStats] = useState(null)
  const [online, setOnline] = useState(null)

  useEffect(() => {
    getStats().then(setStats).catch(() => setStats({}))
    const load = () => getPresence().then(d => setOnline(d.onlineNow)).catch(() => {})
    load(); const t = setInterval(load, 20000); return () => clearInterval(t)
  }, [])
  if (!stats) return <Spin size="large" style={{ display: 'block', margin: '80px auto' }} />

  const inboxRate = stats.inboxRate || 0
  const spamRate = stats.spamRate || 0
  // health score: weighted blend of inbox placement + auth pass rates
  const health = Math.round(
    (inboxRate * 0.4) + (stats.spfPass || 0) * 0.2 + (stats.dkimPass || 0) * 0.2 + (stats.dmarcPass || 0) * 0.2
  )
  const healthColor = health >= 80 ? '#16a34a' : health >= 50 ? '#ea580c' : '#dc2626'

  // per-account placement (from live/stored emails currently loaded)
  const perAccount = accounts.map(a => {
    const em = a.emails || []
    const inbox = em.filter(e => e.category === 'primary').length
    const spam = em.filter(e => e.category === 'spam').length
    return { email: a.email, active: a.active, total: em.length, inbox, spam,
      rate: em.length ? Math.round((inbox / em.length) * 100) : 0 }
  }).sort((x, y) => y.total - x.total)

  return (
    <>
      <Title level={4} style={{ marginBottom: 4 }}>Deliverability Overview</Title>
      <Paragraph type="secondary" style={{ marginTop: 0 }}>
        How your mail is landing across all monitored mailboxes, and whether authentication is passing.
      </Paragraph>

      {/* Health score + key rates */}
      <Row gutter={[16, 16]}>
        <Col xs={24} md={8}>
          <Card style={{ textAlign: 'center' }}>
            <Progress type="dashboard" percent={health} strokeColor={healthColor} size={160}
              format={(p) => <div><div style={{ fontSize: 30, fontWeight: 800, color: healthColor }}>{p}</div>
                <div style={{ fontSize: 12, color: '#94a3b8' }}>Health score</div></div>} />
            <div style={{ marginTop: 8 }}>
              <Tag color={healthColor === '#16a34a' ? 'green' : healthColor === '#ea580c' ? 'orange' : 'red'}>
                {health >= 80 ? 'Healthy' : health >= 50 ? 'Needs attention' : 'At risk'}
              </Tag>
            </div>
          </Card>
        </Col>
        <Col xs={24} md={16}>
          <Row gutter={[16, 16]}>
            <Col xs={12}><Card><Statistic title="Inbox placement" value={inboxRate} suffix="%"
              prefix={<InboxOutlined />} valueStyle={{ color: '#16a34a' }} /></Card></Col>
            <Col xs={12}><Card><Statistic title="Spam rate" value={spamRate} suffix="%"
              prefix={<WarningOutlined />} valueStyle={{ color: spamRate > 10 ? '#dc2626' : '#64748b' }} /></Card></Col>
            <Col xs={12}><Card><Statistic title="Online now" value={online ?? 0}
              prefix={<TeamOutlined />} suffix={`/ ${stats.activeToday || 0} today`} valueStyle={{ color: '#2563eb' }} /></Card></Col>
            <Col xs={12}><Card><Statistic title="Active accounts" value={stats.activeAccounts || 0}
              suffix={`/ ${stats.accounts || 0}`} prefix={<ThunderboltOutlined />} /></Card></Col>
          </Row>
        </Col>
      </Row>

      {/* Authentication pass rates */}
      <Title level={5} style={{ marginTop: 24 }}><SafetyOutlined /> Authentication pass rates</Title>
      <Row gutter={[16, 16]}>
        <Col xs={8}><Gauge label="SPF" percent={stats.spfPass || 0} color="#16a34a" hint="Share of emails where SPF passed" /></Col>
        <Col xs={8}><Gauge label="DKIM" percent={stats.dkimPass || 0} color="#2563eb" hint="Share of emails where DKIM passed" /></Col>
        <Col xs={8}><Gauge label="DMARC" percent={stats.dmarcPass || 0} color="#7c3aed" hint="Share of emails where DMARC passed" /></Col>
      </Row>

      {/* Per-account inbox placement */}
      <Title level={5} style={{ marginTop: 24 }}>Inbox placement per account</Title>
      <Card>
        {perAccount.length === 0 ? <Empty description="No emails yet - open Monitor and let mail arrive" /> :
          perAccount.map(a => (
            <div key={a.email} style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 10 }}>
              <Tag color={a.active ? 'green' : 'default'}>{a.active ? 'Live' : 'Paused'}</Tag>
              <Text style={{ width: 220, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.email}</Text>
              <Progress percent={a.rate} size="small" style={{ flex: 1 }}
                strokeColor={a.rate >= 80 ? '#16a34a' : a.rate >= 50 ? '#ea580c' : '#dc2626'} />
              <Text type="secondary" style={{ width: 130, textAlign: 'right', fontSize: 12 }}>
                {a.inbox} inbox / {a.spam} spam
              </Text>
            </div>
          ))}
      </Card>
    </>
  )
}
