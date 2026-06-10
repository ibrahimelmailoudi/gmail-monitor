import client from '../api/client'

export const fetchAccounts = () => client.get('/api/accounts').then(r => r.data)
export const toggleAccount = (id) => client.post(`/api/accounts/${id}/toggle`)
export const removeAccount = (id) => client.delete(`/api/accounts/${id}`)

export const startGoogleAuth = (socketId) =>
  client.get('/api/auth/google/start', { params: { socketId } }).then(r => r.data)

// Normal user: send ispId (host/port hidden). Admin: may send host/port directly.
export const addImapAccount = (payload) =>
  client.post('/api/accounts/imap', payload).then(r => r.data)

// Enabled ISP presets for the picker (available to all logged-in users)
export const fetchIsps = () => client.get('/api/accounts/isps').then(r => r.data)

export const extractEmails = (accountId, count = 50, includeSource = false, categories = []) =>
  client.post(`/api/accounts/${accountId}/extract`, { count, includeSource, categories }).then(r => r.data)

export const refreshAccount = (id) =>
  client.post(`/api/accounts/${id}/refresh`).then(r => r.data)

export const searchUsers = (q) =>
  client.get('/api/accounts/users/search', { params: { q } }).then(r => r.data)
export const shareAccount = (id, userId) =>
  client.post(`/api/accounts/${id}/share`, { userId })

export const gmailEnabled = () =>
  client.get('/api/accounts/gmail-enabled').then(r => r.data.enabled)

export const startAll = () => client.post('/api/accounts/start-all')
export const pauseAll = () => client.post('/api/accounts/pause-all')

export const setPriority = (id, priority) =>
  client.post(`/api/accounts/${id}/priority`, { priority })

export const resumeAll = () => client.post('/api/accounts/resume')

// Storage (persistent saved emails)
export const getSavedEmails    = () => client.get('/api/accounts/saved').then(r => r.data)
export const saveEmailsToStore = (emails) => client.post('/api/accounts/saved', { emails })
export const deleteSavedEmail  = (id) => client.delete(`/api/accounts/saved/${id}`)
export const clearSavedEmails  = () => client.delete('/api/accounts/saved')

export const getUiSettings = () => client.get('/api/accounts/ui-settings').then(r => r.data)
