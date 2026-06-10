import client from '../api/client'

export const getUsers   = () => client.get('/api/admin/users').then(r => r.data)
export const createUser  = (payload) => client.post('/api/admin/users', payload).then(r => r.data)
export const updateUser  = (id, patch) => client.patch(`/api/admin/users/${id}`, patch).then(r => r.data)

export const getStats    = () => client.get('/api/admin/stats').then(r => r.data)

export const getIspsAdmin = () => client.get('/api/admin/isps').then(r => r.data)
export const addIsp       = (payload) => client.post('/api/admin/isps', payload).then(r => r.data)

export const grantAccess  = (accountId, userId) => client.post('/api/admin/access', { accountId, userId })
export const revokeAccess = (accountId, userId) => client.delete('/api/admin/access', { data: { accountId, userId } })

export const getAllAccounts = () => client.get('/api/admin/accounts').then(r => r.data)
export const setAccountScope = (id, scope) => client.patch(`/api/admin/accounts/${id}/scope`, { scope })

export const getNotifications = () => client.get('/api/admin/notifications').then(r => r.data)
export const markNotificationsRead = () => client.post('/api/admin/notifications/read')
export const getResetRequests = () => client.get('/api/admin/reset-requests').then(r => r.data)
export const setUserPassword = (reqId, username, password) =>
  client.post(`/api/admin/reset-requests/${reqId}/set-password`, { username, password })

export const getPerms = () => client.get('/api/admin/perms').then(r => r.data)
export const setUserRole = (id, role, permissions) =>
  client.patch(`/api/admin/users/${id}/role`, { role, permissions })
export const getPresence = () => client.get('/api/presence').then(r => r.data)

export const updateIsp = (id, patch) => client.patch(`/api/admin/isps/${id}`, patch)
export const deleteIsp = (id) => client.delete(`/api/admin/isps/${id}`)
export const deleteUser = (id, topAdminCode) =>
  client.delete(`/api/admin/users/${id}`, topAdminCode ? { data: { topAdminCode } } : undefined)
export const claimTopAdmin = (code) => client.post('/api/admin/top-admin/claim', { code })
export const transferTopAdmin = (targetUserId, code) =>
  client.post('/api/admin/top-admin/transfer', { targetUserId, code })
export const setUserSections = (id, sections) => client.patch(`/api/admin/users/${id}/sections`, { sections })
export const getSettings = () => client.get('/api/admin/settings').then(r => r.data)
export const saveSettings = (patch) => client.put('/api/admin/settings', patch)

export const getStoredEmails = (params) => client.get('/api/admin/emails', { params }).then(r => r.data)
export const deleteStoredEmail = (id) => client.delete(`/api/admin/emails/${id}`)
export const bulkDeleteEmails = (body) => client.post('/api/admin/emails/bulk-delete', body)
