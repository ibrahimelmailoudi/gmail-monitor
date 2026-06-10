import client from '../api/client'

export const getVaultItems  = () => client.get('/api/vault').then(r => r.data)
export const revealVaultItem = (id) => client.get(`/api/vault/${id}/reveal`).then(r => r.data)
export const addVaultItem    = (payload) => client.post('/api/vault', payload)
export const updateVaultItem = (id, payload) => client.put(`/api/vault/${id}`, payload)
export const deleteVaultItem = (id) => client.delete(`/api/vault/${id}`)
