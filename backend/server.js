import express from 'express'
import http from 'http'
import cors from 'cors'
import jwt from 'jsonwebtoken'
import { Server } from 'socket.io'
import { config } from './src/config.js'
import { initMonitor, startForUser, scheduleStopForUser } from './src/monitor.js'
import { touchUser, purgeOldEmails, purgeResolvedRequests } from './src/store.js'
import { auth } from './src/auth-middleware.js'
import { isStaff, canManageUsers } from './src/permissions.js'
import authRoutes from './src/routes/auth.js'
import accountRoutes from './src/routes/accounts.js'
import adminRoutes from './src/routes/admin.js'
import toolsRoutes from './src/routes/tools.js'
import requestRoutes from './src/routes/requests.js'
import vaultRoutes from './src/routes/vault.js'
import teamRoutes from './src/routes/teams.js'

const app = express()

// Never let a transient DB/network error crash the whole backend.
process.on('unhandledRejection', (err) => {
  console.error('[unhandledRejection]', err?.message || err)
})
process.on('uncaughtException', (err) => {
  console.error('[uncaughtException]', err?.message || err)
})

// CORS: allow the configured frontend, plus any *.vercel.app preview URL.
// FRONTEND_URL can be a comma-separated list of allowed origins.
const allowedOrigins = (config.frontendUrl || '').split(',').map(s => s.trim()).filter(Boolean)
const corsCheck = (origin, cb) => {
  // allow same-origin / curl (no origin), the configured origins, and vercel previews
  if (!origin || allowedOrigins.includes(origin) || /\.vercel\.app$/.test(new URL(origin).hostname)) {
    return cb(null, true)
  }
  cb(null, true) // be permissive for a temporary demo; tighten later if needed
}

app.use(cors({ origin: corsCheck, credentials: true }))
app.use(express.json({ limit: '25mb' }))

// Request logger: prints every request + its response status to the terminal.
// For 4xx/5xx it also prints the JSON message the server sent back, so failures
// like a 400 are immediately visible instead of silent.
app.use((req, res, next) => {
  const start = Date.now()
  const origJson = res.json.bind(res)
  let payload
  res.json = (body) => { payload = body; return origJson(body) }
  res.on('finish', () => {
    const ms = Date.now() - start
    const base = `${req.method} ${req.originalUrl} -> ${res.statusCode} (${ms}ms)`
    if (res.statusCode >= 400) {
      const msg = payload && payload.message ? ` :: ${payload.message}` : ''
      console.error('[REQ]', base + msg)
    } else {
      console.log('[REQ]', base)
    }
  })
  next()
})

// live presence: userId -> set of socket ids
const online = new Map()

app.get('/api/health', (_req, res) => res.json({ ok: true }))
app.get('/api/presence', auth, (req, res) => {
  if (!canManageUsers(req.user)) return res.status(403).json({ message: 'Not allowed' })
  res.json({ onlineNow: online.size, onlineIds: [...online.keys()] })
})

app.use('/api/auth', authRoutes)
app.use('/api/accounts', accountRoutes)
app.use('/api/admin', adminRoutes)
app.use('/api/tools', toolsRoutes)
app.use('/api/requests', requestRoutes)
app.use('/api/vault', vaultRoutes)
app.use('/api/teams', teamRoutes)

const server = http.createServer(app)
const io = new Server(server, { cors: { origin: corsCheck, credentials: true } })

io.on('connection', (socket) => {
  const token = socket.handshake.auth?.token
  try {
    const payload = jwt.verify(token, config.jwtSecret)
    socket.userId = payload.id
    socket.join(`user:${payload.id}`)
    if (payload.is_admin || payload.role === 'support') socket.join('staff')
    if (!online.has(payload.id)) online.set(payload.id, new Set())
    online.get(payload.id).add(socket.id)
    touchUser(payload.id).catch(() => {})
    startForUser(payload.id).catch(() => {})  // start watchers when user opens app
  } catch { /* anonymous */ }

  socket.on('disconnect', () => {
    const set = online.get(socket.userId)
    if (set) {
      set.delete(socket.id)
      if (!set.size) {
        online.delete(socket.userId)
        scheduleStopForUser(socket.userId)  // auto-pause ~10 min after going offline
      }
    }
  })
})

initMonitor(io)

// purge emails older than 24h, now and hourly
purgeOldEmails().catch(() => {})
setInterval(() => { purgeOldEmails().catch(() => {}); purgeResolvedRequests().catch(() => {}) }, 60 * 60 * 1000)

server.listen(config.port, () => console.log(`Backend running on http://localhost:${config.port}`))
