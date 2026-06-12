import client from '../api/client'

export const getTeams       = () => client.get('/api/teams').then(r => r.data)
export const createTeam     = (name, managerId) => client.post('/api/teams', { name, managerId }).then(r => r.data)
export const updateTeam     = (id, payload) => client.put(`/api/teams/${id}`, payload)
export const deleteTeam     = (id) => client.delete(`/api/teams/${id}`)
export const getTeamMembers = (id) => client.get(`/api/teams/${id}/members`).then(r => r.data)
export const addTeamMember  = (id, userId, roleInTeam) => client.post(`/api/teams/${id}/members`, { userId, roleInTeam })
export const removeTeamMember = (id, userId) => client.delete(`/api/teams/${id}/members/${userId}`)
export const getMemberAccounts = (id, userId) => client.get(`/api/teams/${id}/members/${userId}/accounts`).then(r => r.data)
