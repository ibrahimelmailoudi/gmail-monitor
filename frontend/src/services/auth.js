import client from '../api/client'
import { resetSharedSocket } from '../hooks/useRealtime'

// Username + password login (JWT).
export async function login(username, password) {
  const { data } = await client.post('/api/auth/login', { username, password })
  localStorage.setItem('token', data.token)
  localStorage.setItem('user', JSON.stringify(data.user))
  resetSharedSocket()  // ensure socket uses the new token
  return data.token
}

export function logout() {
  localStorage.removeItem('token')
  localStorage.removeItem('user')
  resetSharedSocket()
}

export async function forgotPassword(username) {
  return client.post('/api/auth/forgot', { username })
}
