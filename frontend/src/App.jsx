import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AppProvider, useApp } from './context/AppProvider'
import DashboardLayout from './layout/DashboardLayout'
import DashboardPage from './pages/DashboardPage'
import AccountsPage from './pages/AccountsPage'
import MyAccountsPage from './pages/MyAccountsPage'
import StoragePage from './pages/StoragePage'
import { isStaff, canManageUsers, rankOf, RANK } from './roles'
import VaultPage from './pages/VaultPage'
import ExtractPage from './pages/ExtractPage'
import RequestsPage from './pages/RequestsPage'
import LoginPage from './pages/LoginPage'
import UsersPage from './pages/admin/UsersPage'
import SettingsPage from './pages/admin/SettingsPage'
import ToolsPage from './pages/ToolsPage'
import TeamsPage from './pages/TeamsPage'
import AnalyticsPage from './pages/admin/AnalyticsPage'
import AllAccountsPage from './pages/admin/AllAccountsPage'
import StoredEmailsPage from './pages/admin/StoredEmailsPage'

function useCan() {
  const { user } = useApp()
  const staff = isStaff(user)
  // monitor + extract are granted to everyone by default
  const DEFAULT_SECTIONS = ['monitor', 'extract']
  return (section) => staff || DEFAULT_SECTIONS.includes(section) || (user?.sections || []).includes(section)
}

function Gate({ section, children }) {
  const can = useCan()
  // overview is now grantable; if not allowed, send to the first place they can go
  return can(section) ? children : <Navigate to="/no-access" replace />
}

// Only owner/admin/support may manage users (managers/leaders cannot).
function ManageUsersGate({ children }) {
  const { user } = useApp()
  return canManageUsers(user) ? children : <Navigate to="/no-access" replace />
}

// Gate a route by minimum role rank (e.g. min="admin" => admin or owner).
function RoleGate({ min, children }) {
  const { user } = useApp()
  return rankOf(user) >= RANK[min] ? children : <Navigate to="/no-access" replace />
}

function FirstAllowed() {
  const can = useCan()
  // pick a landing page the user is allowed to see
  if (can('overview')) return <Navigate to="/overview" replace />
  return <Navigate to="/monitor" replace />
}

function NoAccess() {
  return <div style={{ padding: 40, textAlign: 'center', color: '#64748b' }}>
    You don't have access to this section. Ask an administrator to grant it.
  </div>
}

function Root() {
  const { token } = useApp()
  return (
    <BrowserRouter>
      <Routes>
        {/* Not logged in: every path renders the login screen */}
        {!token ? (
          <Route path="*" element={<LoginPage />} />
        ) : (
          <Route element={<DashboardLayout />}>
            <Route index element={<FirstAllowed />} />
            <Route path="overview" element={<Gate section="overview"><DashboardPage /></Gate>} />
            <Route path="monitor" element={<AccountsPage />} />
            <Route path="my-accounts" element={<MyAccountsPage />} />
            <Route path="storage" element={<StoragePage />} />
            <Route path="vault" element={<VaultPage />} />
            <Route path="requests" element={<RequestsPage />} />
            <Route path="extract" element={<Gate section="extract"><ExtractPage /></Gate>} />
            <Route path="manage/all-accounts" element={<Gate section="allaccounts"><AllAccountsPage /></Gate>} />
            <Route path="manage/stored-emails" element={<Gate section="storedemails"><StoredEmailsPage /></Gate>} />
            <Route path="manage/users" element={<ManageUsersGate><UsersPage /></ManageUsersGate>} />
            <Route path="manage/settings" element={<RoleGate min="admin"><SettingsPage /></RoleGate>} />
            <Route path="tools" element={<ToolsPage />} />
            <Route path="teams" element={<RoleGate min="team_leader"><TeamsPage /></RoleGate>} />
            <Route path="manage/analytics" element={<Gate section="analytics"><AnalyticsPage /></Gate>} />
            <Route path="no-access" element={<NoAccess />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        )}
      </Routes>
    </BrowserRouter>
  )
}

export default function App() {
  return (
    <AppProvider>
      <Root />
    </AppProvider>
  )
}
