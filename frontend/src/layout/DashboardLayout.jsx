import { useState } from 'react'
import { Layout, Menu, Button, Typography, Space, Tooltip, Avatar, Dropdown } from 'antd'
import { DashboardOutlined, InboxOutlined, LogoutOutlined, MenuFoldOutlined, MenuUnfoldOutlined,
  BulbOutlined, BulbFilled, UserOutlined, SettingOutlined, ToolOutlined, AreaChartOutlined,
  DatabaseOutlined, ExportOutlined, MessageOutlined, MailOutlined, IdcardOutlined, LockOutlined, TeamOutlined } from '@ant-design/icons'
import { useNavigate, useLocation, Outlet } from 'react-router-dom'
import { useApp } from '../context/AppProvider'
import { isStaff as staffCheck, roleLabel as roleLabelOf, rankOf, RANK, canManageUsers } from '../roles'
import { logout } from '../services/auth'
import { APP_NAME } from '../branding'
import NotificationBell from '../components/NotificationBell'
import logo from '../assets/logo.png'

const { Sider, Header, Content } = Layout
const { Text } = Typography

export default function DashboardLayout() {
  const navigate = useNavigate()
  const { pathname } = useLocation()
  const { setToken, accounts, mode, toggleMode, user } = useApp()
  const [collapsed, setCollapsed] = useState(false)
  const isStaff = staffCheck(user)
  const sections = user?.sections || []
  const can = (s) => isStaff || ['monitor', 'extract'].includes(s) || sections.includes(s)

  const handleLogout = () => { logout(); setToken(null) }

  const menuChildren = [
    can('overview') && { key: '/overview', icon: <DashboardOutlined />, label: 'Deliverability' },
    { key: '/monitor', icon: <InboxOutlined />, label: 'Monitor' },
    { key: '/my-accounts', icon: <MailOutlined />, label: 'My Accounts' },
    can('extract') && { key: '/extract', icon: <ExportOutlined />, label: 'Extract' },
    { key: '/storage', icon: <DatabaseOutlined />, label: 'Storage' },
    { key: '/tools', icon: <ToolOutlined />, label: 'Tools' },
    rankOf(user) >= RANK.team_leader && { key: '/teams', icon: <TeamOutlined />, label: 'Teams' },
    { key: '/vault', icon: <LockOutlined />, label: 'Vault' },
    { key: '/requests', icon: <MessageOutlined />, label: 'Support' },
  ].filter(Boolean)

  const manageChildren = [
    can('allaccounts') && { key: '/manage/all-accounts', icon: <DatabaseOutlined />, label: 'All Accounts' },
    can('storedemails') && { key: '/manage/stored-emails', icon: <MailOutlined />, label: 'Stored Emails' },
    canManageUsers(user) && { key: '/manage/users', icon: <UserOutlined />, label: 'Users' },
    rankOf(user) >= RANK.admin && { key: '/manage/settings', icon: <SettingOutlined />, label: 'Settings' },
    can('analytics') && { key: '/manage/analytics', icon: <AreaChartOutlined />, label: 'Analytics' },
  ].filter(Boolean)

  const items = [
    { type: 'group', label: collapsed ? '' : 'WORKSPACE', children: menuChildren },
    ...(manageChildren.length ? [{ type: 'group', label: collapsed ? '' : 'MANAGE', children: manageChildren }] : []),
  ]

  const roleLabel = roleLabelOf(user?.role)
  const profileMenu = { items: [
    { key: 'who', disabled: true, label: (
      <div style={{ padding: '4px 0' }}>
        <div style={{ fontWeight: 600 }}>{user?.username || 'User'}</div>
        <div style={{ fontSize: 12, color: '#94a3b8' }}>{roleLabel}</div>
        <div style={{ fontSize: 12, color: '#2563eb', marginTop: 2 }}>
          <IdcardOutlined /> ID: {user?.code || '----'}
        </div>
      </div>) },
    { type: 'divider' },
    { key: 'logout', icon: <LogoutOutlined />, label: 'Logout', danger: true, onClick: handleLogout },
  ] }

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Sider trigger={null} collapsible collapsed={collapsed} width={248} breakpoint="lg">
        <div style={{ display: 'flex', alignItems: 'center', gap: 12,
          justifyContent: collapsed ? 'center' : 'flex-start',
          padding: collapsed ? '18px 0' : '20px 18px', borderBottom: '1px solid rgba(255,255,255,0.06)' }}>
          <img src={logo} alt="logo" width={collapsed ? 34 : 38} height={collapsed ? 34 : 38} style={{ borderRadius: 10 }} />
          {!collapsed && (
            <div style={{ lineHeight: 1.15 }}>
              <div style={{ color: '#fff', fontWeight: 800, fontSize: 16 }}>Gmass</div>
              <div style={{ color: '#60a5fa', fontWeight: 700, fontSize: 13 }}>MailScope</div>
            </div>)}
        </div>
        <Menu theme="dark" mode="inline" selectedKeys={[pathname]} items={items}
          onClick={(e) => e.key && navigate(e.key)} style={{ background: 'transparent', borderInlineEnd: 'none', paddingTop: 8 }} />
      </Sider>

      <Layout>
        <Header style={{ background: mode === 'dark' ? undefined : '#fff',
          borderBottom: '1px solid rgba(100,116,139,0.15)', display: 'flex', alignItems: 'center',
          justifyContent: 'space-between', padding: '0 18px' }}>
          <Space size="middle">
            <Button type="text" shape="circle" icon={collapsed ? <MenuUnfoldOutlined /> : <MenuFoldOutlined />}
              onClick={() => setCollapsed(c => !c)} />
            <Text type="secondary">{accounts.length} accounts monitored</Text>
          </Space>
          <Space size="middle">
            <NotificationBell />
            <Tooltip title={mode === 'dark' ? 'Light mode' : 'Dark mode'}>
              <Button type="text" shape="circle" icon={mode === 'dark' ? <BulbFilled /> : <BulbOutlined />} onClick={toggleMode} />
            </Tooltip>
            <Dropdown menu={profileMenu} placement="bottomRight" trigger={['click']}>
              <Avatar src={user?.picture} style={{ background: '#2563eb', cursor: 'pointer' }} icon={<UserOutlined />}>
                {user?.username?.[0]?.toUpperCase()}
              </Avatar>
            </Dropdown>
          </Space>
        </Header>
        <Content style={{ padding: 24 }}><Outlet /></Content>
      </Layout>
    </Layout>
  )
}
