import { useState } from 'react'
import { Card, Tabs, Input, Button, Typography, Space, Tag, Descriptions, Alert, Empty, message, Collapse, Tree } from 'antd'
import { SearchOutlined, GlobalOutlined, SafetyCertificateOutlined, MailOutlined, ApartmentOutlined, BranchesOutlined } from '@ant-design/icons'
import { dnsLookup, dkimLookup, recordsLookup, ptrLookup, spfTree } from '../services/tools'

const { Title, Text } = Typography
const mono = { fontFamily: 'monospace', fontSize: 12, wordBreak: 'break-all' }

// Colored status dot + label - green good / red bad / orange warn / grey neutral
function Status({ level, children }) {
  const color = { good: '#16a34a', bad: '#dc2626', warn: '#ea580c', info: '#2563eb', none: '#94a3b8' }[level] || '#94a3b8'
  return (
    <Space size={6}>
      <span style={{ width: 9, height: 9, borderRadius: '50%', background: color, display: 'inline-block', flex: '0 0 auto' }} />
      <span>{children}</span>
    </Space>
  )
}

// Highlight matches of `q` inside a string
function hl(text, q) {
  if (!q) return text
  const i = text.toLowerCase().indexOf(q.toLowerCase())
  if (i < 0) return text
  return <>{text.slice(0, i)}<mark style={{ background: '#fde047' }}>{text.slice(i, i + q.length)}</mark>{text.slice(i + q.length)}</>
}

function AuthTab() {
  const [domain, setDomain] = useState('')
  const [data, setData] = useState(null)
  const [busy, setBusy] = useState(false)
  const [q, setQ] = useState('')
  const run = async () => {
    if (!domain.trim()) return message.warning('Enter a domain')
    setBusy(true)
    try { setData(await dnsLookup(domain.trim())) }
    catch (e) { message.error(e.response?.data?.message || 'Lookup failed') }
    finally { setBusy(false) }
  }
  const healthLevel = data?.health === 'poor' ? 'bad' : data?.health === 'fair' ? 'warn' : 'good'
  const match = (s) => !q || (s || '').toLowerCase().includes(q.toLowerCase())
  return (
    <>
      <Space.Compact style={{ width: '100%', maxWidth: 480 }}>
        <Input placeholder="example.com" value={domain} onChange={(e) => setDomain(e.target.value)}
          onPressEnter={run} prefix={<GlobalOutlined />} />
        <Button type="primary" icon={<SearchOutlined />} loading={busy} onClick={run}>Check</Button>
      </Space.Compact>
      {data && (
        <div style={{ marginTop: 16 }}>
          <Alert style={{ marginBottom: 12 }}
            type={data.health === 'poor' ? 'error' : data.health === 'fair' ? 'warning' : 'success'}
            message={<Status level={healthLevel}><b>Deliverability: {(data.health || 'good').toUpperCase()}</b></Status>}
            description={data.issues?.length
              ? <ul style={{ margin: '6px 0 0', paddingLeft: 8, listStyle: 'none' }}>
                  {data.issues.map((it, i) => <li key={i} style={{ fontSize: 13, marginBottom: 4 }}>
                    <Status level={it.level === 'error' ? 'bad' : it.level === 'warn' ? 'warn' : 'info'}>{it.text}</Status>
                  </li>)}
                </ul>
              : <Status level="good">SPF, DMARC and MX look healthy.</Status>} />

          <Input allowClear prefix={<SearchOutlined />} placeholder="Filter results..." value={q}
            onChange={(e) => setQ(e.target.value)} style={{ maxWidth: 300, marginBottom: 12 }} />

          <Descriptions bordered column={1} size="small">
            {match('spf') || match(data.spf) ? (
              <Descriptions.Item label={<Status level={data.spf ? 'good' : 'bad'}>SPF</Status>}>
                {data.spf ? <span style={mono}>{hl(data.spf, q)}</span> : <Tag color="red">not found</Tag>}
              </Descriptions.Item>) : null}
            {match('dmarc') || match(data.dmarc) ? (
              <Descriptions.Item label={<Status level={data.dmarc ? 'good' : 'bad'}>DMARC</Status>}>
                {data.dmarc ? <span style={mono}>{hl(data.dmarc, q)}</span> : <Tag color="red">not found</Tag>}
              </Descriptions.Item>) : null}
            {match('mx') ? (
              <Descriptions.Item label={<Status level={data.mx?.length ? 'good' : 'bad'}>MX</Status>}>
                {data.mx?.length
                  ? <div style={mono}>{data.mx.map((m, i) => <div key={i}>{m.priority} {hl(m.exchange, q)}</div>)}</div>
                  : <Tag color="red">none</Tag>}
              </Descriptions.Item>) : null}
          </Descriptions>
        </div>
      )}
    </>
  )
}

// Recursive SPF include tree
function SpfTreeTab() {
  const [domain, setDomain] = useState('')
  const [tree, setTree] = useState(null)
  const [busy, setBusy] = useState(false)
  const [q, setQ] = useState('')
  const run = async () => {
    if (!domain.trim()) return message.warning('Enter a domain')
    setBusy(true)
    try { setTree(await spfTree(domain.trim())) }
    catch (e) { message.error(e.response?.data?.message || 'Lookup failed') }
    finally { setBusy(false) }
  }
  // build Ant Tree data from the recursive node
  const toNode = (n, key) => {
    const ipCount = (n.ip4?.length || 0) + (n.ip6?.length || 0)
    const children = []
    ;(n.includes || []).forEach((c, i) => children.push(toNode(c, `${key}-${i}`)))
    ;(n.ip4 || []).forEach((ip, i) => children.push({ key: `${key}-ip4-${i}`, title: <Status level="info"><span style={mono}>ip4: {hl(ip, q)}</span></Status> }))
    ;(n.ip6 || []).forEach((ip, i) => children.push({ key: `${key}-ip6-${i}`, title: <Status level="info"><span style={mono}>ip6: {hl(ip, q)}</span></Status> }))
    return {
      key,
      title: (
        <Status level={n.spf ? 'good' : n.truncated ? 'warn' : 'bad'}>
          <b>{hl(n.domain, q)}</b>{' '}
          {n.truncated ? <Tag color="orange">already shown</Tag>
            : n.spf ? <Text type="secondary" style={{ fontSize: 11 }}>{(n.includes?.length || 0)} includes, {ipCount} IPs</Text>
            : <Tag color="red">no SPF</Tag>}
        </Status>
      ),
      children: children.length ? children : undefined,
    }
  }
  return (
    <>
      <Space.Compact style={{ width: '100%', maxWidth: 480 }}>
        <Input placeholder="example.com" value={domain} onChange={(e) => setDomain(e.target.value)}
          onPressEnter={run} prefix={<GlobalOutlined />} />
        <Button type="primary" icon={<SearchOutlined />} loading={busy} onClick={run}>Expand SPF</Button>
      </Space.Compact>
      <Text type="secondary" style={{ display: 'block', marginTop: 8, fontSize: 12 }}>
        Shows the full SPF tree - every include: and what IT includes too, plus the IPs each authorizes.
      </Text>
      {tree && (
        <div style={{ marginTop: 12 }}>
          <Input allowClear prefix={<SearchOutlined />} placeholder="Search a domain or IP in the tree..." value={q}
            onChange={(e) => setQ(e.target.value)} style={{ maxWidth: 320, marginBottom: 12 }} />
          <Tree treeData={[toNode(tree, '0')]} defaultExpandAll showLine
            selectable={false} style={{ background: 'transparent' }} />
        </div>
      )}
    </>
  )
}

function DkimTab() {
  const [domain, setDomain] = useState('')
  const [selector, setSelector] = useState('')
  const [data, setData] = useState(null)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    if (!domain.trim()) return message.warning('Enter a domain')
    setBusy(true)
    try { setData(await dkimLookup(domain.trim(), selector.trim())) }
    catch (e) { message.error(e.response?.data?.message || 'Lookup failed') }
    finally { setBusy(false) }
  }
  return (
    <>
      <Space wrap>
        <Input placeholder="example.com" value={domain} onChange={(e) => setDomain(e.target.value)} style={{ width: 220 }} prefix={<GlobalOutlined />} />
        <Input placeholder="selector (optional)" value={selector} onChange={(e) => setSelector(e.target.value)} style={{ width: 240 }} />
        <Button type="primary" icon={<SearchOutlined />} loading={busy} onClick={run}>Check DKIM</Button>
      </Space>
      <Text type="secondary" style={{ display: 'block', marginTop: 8, fontSize: 12 }}>
        Leave selector empty to try common ones. The exact selector is the s= value in a message DKIM-Signature header.
      </Text>
      {data && (
        <Alert style={{ marginTop: 8 }} type={data.dkim ? 'success' : 'warning'}
          message={<Status level={data.dkim ? 'good' : 'warn'}>{data.dkim ? `DKIM found (selector: ${data.selector})` : 'No DKIM record found'}</Status>}
          description={data.dkim ? <span style={mono}>{data.dkim}</span> : data.note} />
      )}
    </>
  )
}

function RecordsTab() {
  const [domain, setDomain] = useState('')
  const [data, setData] = useState(null)
  const [busy, setBusy] = useState(false)
  const [q, setQ] = useState('')
  const run = async () => {
    if (!domain.trim()) return message.warning('Enter a domain')
    setBusy(true)
    try { setData(await recordsLookup(domain.trim())) }
    catch (e) { message.error(e.response?.data?.message || 'Lookup failed') }
    finally { setBusy(false) }
  }
  const filtered = (arr) => !q ? arr : (arr || []).filter(x => String(x).toLowerCase().includes(q.toLowerCase()))
  const block = (label, arr) => {
    const list = filtered(arr)
    return (
      <Descriptions.Item label={<Status level={arr?.length ? 'good' : 'none'}>{label}</Status>}>
        {list?.length ? <div style={mono}>{list.map((x, i) => <div key={i}>{hl(String(x), q)}</div>)}</div>
          : <Tag>{arr?.length ? 'no match' : 'none'}</Tag>}
      </Descriptions.Item>
    )
  }
  const txtBlock = (arr) => {
    const list = filtered(arr)
    return (
      <Descriptions.Item label={<Status level={arr?.length ? 'good' : 'none'}>TXT</Status>}>
        {!list?.length ? <Tag>{arr?.length ? 'no match' : 'none'}</Tag> : (
          <Collapse size="small" ghost items={list.map((t, i) => {
            const includes = (t.match(/include:[^\s]+/g) || [])
            const isSpf = t.toLowerCase().startsWith('v=spf1')
            return {
              key: String(i),
              label: <span style={mono}>{hl(t.slice(0, 60), q)}{t.length > 60 ? '...' : ''}</span>,
              children: (
                <div>
                  <div style={{ ...mono, marginBottom: includes.length ? 8 : 0 }}>{hl(t, q)}</div>
                  {isSpf && includes.length > 0 && (
                    <div>
                      <Text strong style={{ fontSize: 12 }}>Includes ({includes.length}):</Text>
                      <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>
                        {includes.map((inc, k) => <li key={k} style={mono}>
                          <Status level="info">{hl(inc.replace('include:', ''), q)}</Status></li>)}
                      </ul>
                    </div>
                  )}
                </div>
              ),
            }
          })} />
        )}
      </Descriptions.Item>
    )
  }
  return (
    <>
      <Space.Compact style={{ width: '100%', maxWidth: 480 }}>
        <Input placeholder="example.com" value={domain} onChange={(e) => setDomain(e.target.value)} onPressEnter={run} prefix={<GlobalOutlined />} />
        <Button type="primary" icon={<SearchOutlined />} loading={busy} onClick={run}>Lookup</Button>
      </Space.Compact>
      {data && (
        <div style={{ marginTop: 16 }}>
          <Input allowClear prefix={<SearchOutlined />} placeholder="Search records..." value={q}
            onChange={(e) => setQ(e.target.value)} style={{ maxWidth: 300, marginBottom: 12 }} />
          <Descriptions bordered column={1} size="small">
            {block('A', data.a)}
            {block('AAAA', data.aaaa)}
            {block('NS', data.ns)}
            {txtBlock(data.txt)}
            {block('CNAME', data.cname)}
          </Descriptions>
        </div>
      )}
    </>
  )
}

function PtrTab() {
  const [ip, setIp] = useState('')
  const [data, setData] = useState(null)
  const [busy, setBusy] = useState(false)
  const run = async () => {
    if (!ip.trim()) return message.warning('Enter an IP or domain')
    setBusy(true)
    try { setData(await ptrLookup(ip.trim())) }
    catch (e) { message.error(e.response?.data?.message || 'Lookup failed') }
    finally { setBusy(false) }
  }
  return (
    <>
      <Space.Compact style={{ width: '100%', maxWidth: 480 }}>
        <Input placeholder="209.85.220.41  or  example.com" value={ip} onChange={(e) => setIp(e.target.value)} onPressEnter={run} />
        <Button type="primary" icon={<SearchOutlined />} loading={busy} onClick={run}>Reverse lookup</Button>
      </Space.Compact>
      {data && (
        <Alert style={{ marginTop: 12 }} type={data.ptr?.length ? 'success' : 'warning'}
          message={<Status level={data.ptr?.length ? 'good' : 'warn'}>{data.ptr?.length ? `PTR for ${data.ip}` : 'No PTR record'}</Status>}
          description={data.ptr?.length
            ? <span style={mono}>{data.ptr.join(', ')}{data.resolvedFrom ? ` (resolved from ${data.resolvedFrom})` : ''}</span>
            : data.error} />
      )}
    </>
  )
}

export default function ToolsPage() {
  return (
    <>
      <Title level={4}>Tools</Title>
      <Text type="secondary">DNS and deliverability checks - verify SPF, DKIM, DMARC, MX and other records for any domain.</Text>
      <Card style={{ marginTop: 16 }}>
        <Tabs items={[
          { key: 'auth', label: <span><SafetyCertificateOutlined /> SPF / DMARC / MX</span>, children: <AuthTab /> },
          { key: 'spftree', label: <span><BranchesOutlined /> SPF Tree</span>, children: <SpfTreeTab /> },
          { key: 'dkim', label: <span><MailOutlined /> DKIM</span>, children: <DkimTab /> },
          { key: 'records', label: <span><ApartmentOutlined /> Records (A/NS/TXT)</span>, children: <RecordsTab /> },
          { key: 'ptr', label: <span><GlobalOutlined /> Reverse IP</span>, children: <PtrTab /> },
        ]} />
      </Card>
    </>
  )
}
