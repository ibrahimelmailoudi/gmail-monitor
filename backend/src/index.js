import express from 'express'
import cors from 'cors'
import session from 'express-session'
import { createServer } from 'http'
import { Server } from 'socket.io'
import dotenv from 'dotenv'
import { google } from 'googleapis'
import { v4 as uuidv4 } from 'uuid'
import jwt from 'jsonwebtoken'
import compression from 'compression'
import helmet from 'helmet'

dotenv.config()

const app = express()
const httpServer = createServer(app)
const io = new Server(httpServer, {
  cors: { origin: process.env.FRONTEND_URL, methods: ['GET','POST'], credentials: true },
  maxHttpBufferSize: 1e6,
  pingInterval: 25000,
  pingTimeout: 60000,
  transports: ['websocket', 'polling']
})

app.use(helmet())
app.use(compression())
app.use(cors({ origin: process.env.FRONTEND_URL, credentials: true }))
app.use(express.json({ limit: '50mb' }))
app.use(session({
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, httpOnly: true, maxAge: 86400000 }
}))

const users = new Map()
const accounts = new Map()
const pendingAuth = new Map()
const emailCache = new Map()
const accountStats = new Map()
const processingQueue = new Map()
const pollSchedules = new Map()

// ============================================================
// UTILITY FUNCTIONS
// ============================================================

function createUser(email) {
  const userId = uuidv4()
  const user = {
    id: userId,
    email,
    createdAt: Date.now(),
    accounts: [],
    settings: { theme: 'dark', notifications: true }
  }
  users.set(userId, user)
  return user
}

function createToken(userId) {
  return jwt.sign({ userId }, process.env.JWT_SECRET, { expiresIn: '30d' })
}

function verifyToken(token) {
  try {
    return jwt.verify(token, process.env.JWT_SECRET)
  } catch (err) {
    return null
  }
}

function authMiddleware(req, res, next) {
  const token = req.headers.authorization?.replace('Bearer ', '')
  if (!token) return res.status(401).json({ error: 'No token' })
  const decoded = verifyToken(token)
  if (!decoded) return res.status(401).json({ error: 'Invalid token' })
  req.userId = decoded.userId
  next()
}

function makeOAuth2Client() {
  return new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET,
    process.env.REDIRECT_URI
  )
}

function classifyCategory(labelIds = []) {
  if (labelIds?.includes('SPAM')) return 'spam'
  if (labelIds?.includes('CATEGORY_PROMOTIONS')) return 'promotions'
  if (labelIds?.includes('CATEGORY_SOCIAL')) return 'social'
  if (labelIds?.includes('CATEGORY_UPDATES')) return 'updates'
  if (labelIds?.includes('INBOX')) return 'primary'
  return 'other'
}

function extractMetadata(headers = []) {
  const get = (n) => headers.find(h => h.name?.toLowerCase() === n.toLowerCase())?.value || ''
  const fromRaw = get('From')
  const fromMatch = fromRaw.match(/^(.*?)\s*<(.+)>$/) || []
  const senderName = fromMatch[1]?.trim() || fromRaw
  const senderEmail = fromMatch[2]?.trim() || fromRaw
  const domain = senderEmail.split('@')[1] || ''
  
  const received = get('Received') || ''
  const ipMatch = received.match(/\[(\d{1,3}(?:\.\d{1,3}){3})\]/)
  const ip = ipMatch ? ipMatch[1] : null

  return { senderName, senderEmail, domain, ip }
}

function generateEmailHash(email) {
  return `${email.accountId}_${email.sender.email}_${email.sender.subject}_${email.time}`
}

function sanitizeAccount(a) {
  return {
    id: a.id,
    email: a.email,
    picture: a.picture,
    active: a.active,
    emails: a.emails.slice(0, 50),
    type: a.type,
    addedAt: a.addedAt,
    stats: accountStats.get(a.id) || { total: a.emails.length, lastSync: Date.now() }
  }
}

// ============================================================
// EMAIL FETCHING
// ============================================================

async function fetchEmailsGoogle(account) {
  try {
    if (processingQueue.has(account.id)) return
    processingQueue.set(account.id, true)

    const auth = makeOAuth2Client()
    auth.setCredentials(account.tokens)
    const gmail = google.gmail({ version: 'v1', auth })

    const lastChecked = account.lastChecked || new Date(Date.now() - 3600000)
    const query = `after:${Math.floor(lastChecked.getTime()/1000)}`

    const listRes = await gmail.users.messages.list({
      userId: 'me',
      q: query,
      maxResults: 20,
      fields: 'messages(id,internalDate)'
    })

    const messages = listRes.data.messages || []
    const newEmails = []

    for (const msg of messages) {
      try {
        const detail = await gmail.users.messages.get({
          userId: 'me',
          id: msg.id,
          format: 'full',
          fields: 'payload(headers,mimeType),labelIds,internalDate'
        })

        const headers = detail.data.payload?.headers || []
        const { senderName, senderEmail, domain, ip } = extractMetadata(headers)
        const get = (n) => headers.find(h => h.name?.toLowerCase() === n.toLowerCase())?.value || ''

        const email = {
          id: msg.id,
          category: classifyCategory(detail.data.labelIds, get('Subject'), senderEmail),
          sender: {
            name: senderName,
            email: senderEmail,
            domain,
            subject: get('Subject') || '(no subject)',
            body: ''
          },
          ip,
          time: parseInt(detail.data.internalDate),
          labels: detail.data.labelIds || [],
          accountId: account.id,
          type: 'gmail'
        }

        const hash = generateEmailHash(email)
        if (!emailCache.has(hash)) {
          emailCache.set(hash, true)
          newEmails.push(email)
        }
      } catch (err) {
        console.error('Message processing error:', err.message)
      }
    }

    account.lastChecked = new Date()
    account.emails.unshift(...newEmails)
    if (account.emails.length > 100) account.emails = account.emails.slice(0, 100)

    accountStats.set(account.id, {
      total: account.emails.length,
      lastSync: Date.now(),
      newEmails: newEmails.length
    })

    newEmails.forEach(email => {
      io.emit('new_email', { accountId: account.id, email })
    })

    return newEmails.length
  } catch (err) {
    if (err.code === 401) {
      account.active = false
      io.emit('account_update', { id: account.id, active: false, error: 'Token expired' })
    }
    console.error('Google fetch error:', err.message)
    return 0
  } finally {
    processingQueue.delete(account.id)
  }
}

function startPolling(accountId, interval = 30000) {
  if (pollSchedules.has(accountId)) return

  const schedule = setInterval(async () => {
    const account = accounts.get(accountId)
    if (!account || !account.active) {
      clearInterval(schedule)
      pollSchedules.delete(accountId)
      return
    }

    if (account.type === 'gmail') {
      await fetchEmailsGoogle(account)
    }
  }, interval)

  pollSchedules.set(accountId, schedule)
}

function stopPolling(accountId) {
  const schedule = pollSchedules.get(accountId)
  if (schedule) {
    clearInterval(schedule)
    pollSchedules.delete(accountId)
  }
}

// ============================================================
// API ROUTES
// ============================================================

app.post('/api/auth/register', (req, res) => {
  const { email } = req.body
  if (!email) return res.status(400).json({ error: 'Email required' })

  const existing = [...users.values()].find(u => u.email === email)
  if (existing) {
    const token = createToken(existing.id)
    return res.json({ user: existing, token })
  }

  const user = createUser(email)
  const token = createToken(user.id)
  res.json({ user, token })
})

app.get('/api/auth/me', authMiddleware, (req, res) => {
  const user = users.get(req.userId)
  res.json(user || { error: 'User not found' })
})

app.get('/api/auth/google/start', authMiddleware, (req, res) => {
  const { socketId } = req.query
  const state = uuidv4()
  pendingAuth.set(state, { socketId, userId: req.userId, type: 'gmail' })

  const auth = makeOAuth2Client()
  const url = auth.generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent',
    scope: ['https://www.googleapis.com/auth/gmail.readonly',
            'https://www.googleapis.com/auth/userinfo.email'],
    state
  })
  res.json({ url })
})

app.get('/api/auth/google/callback', async (req, res) => {
  const { code, state } = req.query
  try {
    const pendingData = pendingAuth.get(state)
    const userId = pendingData?.userId
    const user = users.get(userId)

    if (!user) return res.send('<html><body style="background:#0f0f0f;color:#ef4444"><h2>Error: User not found</h2></body></html>')

    const auth = makeOAuth2Client()
    const { tokens } = await auth.getToken(code)
    auth.setCredentials(tokens)

    const oauth2 = google.oauth2({ version: 'v2', auth })
    const { data } = await oauth2.userinfo.get()

    const accountId = uuidv4()
    const account = {
      id: accountId,
      userId,
      email: data.email,
      picture: data.picture,
      tokens,
      active: true,
      emails: [],
      type: 'gmail',
      lastChecked: new Date(),
      addedAt: Date.now()
    }

    accounts.set(accountId, account)
    user.accounts.push(accountId)
    accountStats.set(accountId, { total: 0, lastSync: Date.now() })

    startPolling(accountId, 30000)
    await fetchEmailsGoogle(account)

    const socketId = pendingData?.socketId
    if (socketId) {
      io.to(socketId).emit('account_added', sanitizeAccount(account))
      pendingAuth.delete(state)
    }

    res.send(`<html><body style="font-family:sans-serif;text-align:center;padding:60px;background:#0f0f0f;color:#fff">
      <h2 style="color:#10b981">Account Connected!</h2>
      <p>Email: ${data.email}</p>
      <script>setTimeout(()=>window.close(),3000)</script>
    </body></html>`)
  } catch(err) {
    console.error('OAuth error:', err)
    res.send('<html><body style="background:#0f0f0f;color:#ef4444"><h2>Error: Auth failed</h2></body></html>')
  }
})

app.get('/api/accounts', authMiddleware, (req, res) => {
  const user = users.get(req.userId)
  const userAccounts = (user?.accounts || []).map(id => accounts.get(id)).filter(Boolean).map(sanitizeAccount)
  res.json(userAccounts)
})

app.post('/api/accounts/:id/toggle', authMiddleware, (req, res) => {
  const acc = accounts.get(req.params.id)
  if (!acc || acc.userId !== req.userId) return res.status(404).json({ error: 'Not found' })

  acc.active = !acc.active
  if (acc.active) startPolling(acc.id, 30000)
  else stopPolling(acc.id)

  io.emit('account_update', { id: acc.id, active: acc.active })
  res.json({ active: acc.active })
})

app.delete('/api/accounts/:id', authMiddleware, (req, res) => {
  const acc = accounts.get(req.params.id)
  if (!acc || acc.userId !== req.userId) return res.status(404).json({ error: 'Not found' })

  const user = users.get(req.userId)
  user.accounts = user.accounts.filter(id => id !== req.params.id)
  stopPolling(req.params.id)
  accounts.delete(req.params.id)
  accountStats.delete(req.params.id)

  io.emit('account_removed', { id: req.params.id })
  res.json({ ok: true })
})

app.post('/api/accounts/start-all', authMiddleware, (req, res) => {
  const user = users.get(req.userId)
  (user?.accounts || []).forEach(id => {
    const acc = accounts.get(id)
    if (acc) {
      acc.active = true
      startPolling(id, 30000)
    }
  })
  io.emit('all_toggled', { active: true })
  res.json({ ok: true })
})

app.post('/api/accounts/stop-all', authMiddleware, (req, res) => {
  const user = users.get(req.userId)
  (user?.accounts || []).forEach(id => {
    const acc = accounts.get(id)
    if (acc) {
      acc.active = false
      stopPolling(id)
    }
  })
  io.emit('all_toggled', { active: false })
  res.json({ ok: true })
})

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', accounts: accounts.size, users: users.size, timestamp: Date.now() })
})

io.on('connection', socket => {
  console.log('Client connected:', socket.id)
})

const PORT = process.env.PORT || 4000
httpServer.listen(PORT, () => {
  console.log(`\n🚀 Backend Server Running`)
  console.log(`📍 http://localhost:${PORT}`)
  console.log(`🔗 WebSocket: ws://localhost:${PORT}`)
  console.log(`📊 Health: http://localhost:${PORT}/api/health\n`)
})
