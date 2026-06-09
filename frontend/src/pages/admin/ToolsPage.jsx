import { useState } from 'react'
import { Card, Input, Button, Typography, Descriptions, Tag, Space, message } from 'antd'
import { dnsLookup, dkimLookup } from '../../services/tools'

const { Title, Paragraph, Text } = Typography

export default function ToolsPage() {
  const [domain, setDomain] = useState('')
  const [selector, setSelector] = useState('google')
  const [res, setRes] = useState(null)
  const [dkim, setDkim] = useState(null)
  const [busy, setBusy] = useState(false)

  const run = async () => {
    if (!domain) return
    setBusy(true)
    try {
      setRes(await dnsLookup(domain))
      setDkim(await dkimLookup(domain, selector))
    } catch (e) { message.error('Lookup failed') }
    finally { setBusy(false) }
  }

  return (
    <>
      <Title level={4}>Tools  -  DNS / SPF / DKIM / DMARC lookup</Title>
      <Paragraph type="secondary">Checks a domain's <b>published</b> SPF/DKIM/DMARC DNS records. Note: this is the domain's policy - it is different from the per-email pass/fail you see on each mail card (that comes from the message's Authentication-Results header).</Paragraph>
      <Space.Compact style={{ width: '100%', maxWidth: 640, marginBottom: 8 }}>
        <Input placeholder="domain (e.g. example.com)" value={domain}
          onChange={(e) => setDomain(e.target.value)} onPressEnter={run} />
        <Input style={{ maxWidth: 160 }} placeholder="DKIM selector" value={selector}
          onChange={(e) => setSelector(e.target.value)} />
        <Button type="primary" loading={busy} onClick={run}>Check</Button>
      </Space.Compact>

      {res && (
        <Card style={{ marginTop: 16, maxWidth: 760 }}>
          <Descriptions column={1} bordered size="small">
            <Descriptions.Item label="Domain">{res.domain}</Descriptions.Item>
            <Descriptions.Item label="MX">
              {(res.mx || []).length ? res.mx.map(m => <Tag key={m.exchange}>{m.exchange}</Tag>) : <Text type="secondary">none</Text>}
            </Descriptions.Item>
            <Descriptions.Item label="SPF">{res.spf || <Tag color="red">missing</Tag>}</Descriptions.Item>
            <Descriptions.Item label="DMARC">{res.dmarc || <Tag color="red">missing</Tag>}</Descriptions.Item>
            <Descriptions.Item label={`DKIM (${selector})`}>{dkim?.dkim || <Tag color="red">not found</Tag>}</Descriptions.Item>
          </Descriptions>
        </Card>
      )}
    </>
  )
}
