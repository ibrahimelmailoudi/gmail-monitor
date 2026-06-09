import client from '../api/client'

export const getRequests   = () => client.get('/api/requests').then(r => r.data)
export const createRequest = (payload) => client.post('/api/requests', payload).then(r => r.data)
export const getThread     = (id) => client.get(`/api/requests/${id}/messages`).then(r => r.data)
export const replyRequest  = (id, body) => client.post(`/api/requests/${id}/messages`, { body }).then(r => r.data)
export const setRequestStatus = (id, status) => client.post(`/api/requests/${id}/status`, { status })

export const getRequestTypes = () => client.get('/api/requests/types').then(r => r.data)
export const deleteRequest = (id) => client.delete(`/api/requests/${id}`)
