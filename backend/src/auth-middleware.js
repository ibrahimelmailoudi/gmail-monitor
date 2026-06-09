import jwt from 'jsonwebtoken'
import { config } from './config.js'
import { getUserById } from './store.js'

export const signToken = (user, hours) =>
  jwt.sign({ id: user.id, username: user.username, is_admin: user.is_admin, role: user.role },
    config.jwtSecret, { expiresIn: `${hours || 48}h` })

export async function auth(req, res, next) {
  const header = req.headers.authorization || ''
  const token = header.startsWith('Bearer ') ? header.slice(7) : null
  if (!token) return res.status(401).json({ message: 'Missing token' })
  try {
    const payload = jwt.verify(token, config.jwtSecret)
    const user = await getUserById(payload.id)
    if (!user) return res.status(401).json({ message: 'Unknown user' })
    req.user = user
    next()
  } catch {
    res.status(401).json({ message: 'Invalid token' })
  }
}

export function adminOnly(req, res, next) {
  if (!req.user?.is_admin) return res.status(403).json({ message: 'Admin only' })
  next()
}
