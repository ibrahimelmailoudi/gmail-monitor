import { useEffect, useState } from 'react'
import { Row, Col, Card, Statistic, Spin, Typography } from 'antd'
import { TeamOutlined, MailOutlined, InboxOutlined, GoogleOutlined } from '@ant-design/icons'
import { getStats } from '../../services/admin'

const { Title } = Typography

export default function AnalyticsPage() {
  const [stats, setStats] = useState(null)
  useEffect(() => { getStats().then(setStats).catch(() => setStats({})) }, [])
  if (!stats) return <Spin size="large" style={{ display: 'block', margin: '80px auto' }} />

  const providers = stats.providers || {}
  return (
    <>
      <Title level={4}>Overview</Title>
      <Row gutter={[16, 16]}>
        <Col xs={24} sm={12} lg={6}><Card><Statistic title="Users" value={stats.users || 0} prefix={<TeamOutlined />} /></Card></Col>
        <Col xs={24} sm={12} lg={6}><Card><Statistic title="Accounts" value={stats.accounts || 0} prefix={<InboxOutlined />} /></Card></Col>
        <Col xs={24} sm={12} lg={6}><Card><Statistic title="Emails captured" value={stats.emails || 0} prefix={<MailOutlined />} /></Card></Col>
        <Col xs={24} sm={12} lg={6}><Card><Statistic title="Gmail accounts" value={providers.gmail || 0} prefix={<GoogleOutlined />} valueStyle={{ color: '#2563eb' }} /></Card></Col>
      </Row>

      <Title level={5} style={{ marginTop: 28 }}>Accounts by provider</Title>
      <Row gutter={[16, 16]}>
        {Object.entries(providers).length === 0 ? (
          <Col span={24}><Card>No accounts yet.</Card></Col>
        ) : Object.entries(providers).map(([type, n]) => (
          <Col xs={12} sm={8} lg={4} key={type}>
            <Card><Statistic title={type.toUpperCase()} value={n} /></Card>
          </Col>
        ))}
      </Row>
    </>
  )
}
