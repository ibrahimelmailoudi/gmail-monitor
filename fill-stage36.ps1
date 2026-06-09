# fill-stage36.ps1 - deploy prep: flexible CORS (Vercel previews) + Dockerfile for SnapDeploy
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path backend | Out-Null

Set-Content -LiteralPath 'backend\server.js' -Encoding utf8 -Value @'
import express from 'express'
import http from 'http'
import cors from 'cors'
import jwt from 'jsonwebtoken'
import { Server } from 'socket.io'
import { config } from './src/config.js'
import { initMonitor, startForUser, scheduleStopForUser } from './src/monitor.js'
import { touchUser, purgeOldEmails, purgeResolvedRequests } from './src/store.js'
import { auth } from './src/auth-middleware.js'
import { isStaff } from './src/permissions.js'
import authRoutes from './src/routes/auth.js'
import accountRoutes from './src/routes/accounts.js'
import adminRoutes from './src/routes/admin.js'
import toolsRoutes from './src/routes/tools.js'
import requestRoutes from './src/routes/requests.js'

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
app.use(express.json())

// live presence: userId -> set of socket ids
const online = new Map()

app.get('/api/health', (_req, res) => res.json({ ok: true }))
app.get('/api/presence', auth, (req, res) => {
  if (!isStaff(req.user)) return res.status(403).json({ message: 'Staff only' })
  res.json({ onlineNow: online.size, onlineIds: [...online.keys()] })
})

app.use('/api/auth', authRoutes)
app.use('/api/accounts', accountRoutes)
app.use('/api/admin', adminRoutes)
app.use('/api/tools', toolsRoutes)
app.use('/api/requests', requestRoutes)

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
'@
Write-Host 'wrote backend\server.js'

Set-Content -LiteralPath 'backend\Dockerfile' -Encoding utf8 -Value @'
# Backend Dockerfile for SnapDeploy (Node + Express + Socket.io + IMAP watchers)
FROM node:20-alpine

WORKDIR /app

# install deps first (better layer caching)
COPY package*.json ./
RUN npm install --omit=dev

# copy the rest of the backend
COPY . .

# SnapDeploy provides PORT via env; our config reads process.env.PORT
EXPOSE 4000

CMD ["npm", "start"]
'@
Write-Host 'wrote backend\Dockerfile'

Set-Content -LiteralPath 'backend\.dockerignore' -Encoding utf8 -Value @'
node_modules
npm-debug.log
.env
.git
.gitignore
*.md
'@
Write-Host 'wrote backend\.dockerignore'

Write-Host ""
Write-Host "STAGE 36 written. Commit + push to GitHub, then deploy (see steps)."
