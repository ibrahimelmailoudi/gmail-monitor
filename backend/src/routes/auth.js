import { Router } from 'express'
import bcrypt from 'bcryptjs'
import { config } from '../config.js'
import { signToken, auth } from '../auth-middleware.js'
import {
  getUserByUsername, createUser, countUsers, getAccountRow,
  addAccount, findAccountByEmail, createResetRequest, getSetting, ensureUserCode,
} from '../store.js'
import { oauthClient, exchangeCode } from '../gmail.js'
import { startAccount, emitAdded } from '../monitor.js'

const router = Router()

const publicUser = (u) => ({ id: u.id, username: u.username, code: u.code, is_admin: u.is_admin,
  role: u.role, permissions: u.permissions || {}, sections: u.sections || [], max_accounts: u.max_accounts, picture: u.picture })

// Login (username + password)
router.post('/login', async (req, res) => {
  const { username, password } = req.body || {}
  if (!username || !password) return res.status(400).json({ message: 'username and password required' })
  const user = await getUserByUsername(username)
  if (!user || !(await bcrypt.compare(password, user.password_hash)))
    return res.status(401).json({ message: 'Invalid username or password' })
  if (!user.code) user.code = await ensureUserCode(user.id)
  const globalHours = Number(await getSetting('token_hours', 48)) || 48
  const hours = user.token_hours || globalHours
  res.json({ token: signToken(user, hours), user: publicUser(user) })
})

// Forgot password: user submits username -> creates an admin notification.
router.post('/forgot', async (req, res) => {
  const { username } = req.body || {}
  if (!username) return res.status(400).json({ message: 'username required' })
  await createResetRequest(username)
  res.json({ ok: true })
})

// Bootstrap: create the very FIRST user as admin (only works while DB has no users).
// Protect with BOOTSTRAP_SECRET from .env.
router.post('/bootstrap', async (req, res) => {
  const { username, password, secret } = req.body || {}
  if ((await countUsers()) > 0) return res.status(403).json({ message: 'Already initialized' })
  if (!config.bootstrapSecret || secret !== config.bootstrapSecret)
    return res.status(401).json({ message: 'Invalid bootstrap secret' })
  if (!username || !password) return res.status(400).json({ message: 'username and password required' })
  const passwordHash = await bcrypt.hash(password, 10)
  const user = await createUser({ username, passwordHash, isAdmin: true, maxAccounts: 999 })
  res.json({ token: signToken(user), user: publicUser(user) })
})

// Google OAuth start
router.get('/google/start', auth, (req, res) => {
  const state = Buffer.from(JSON.stringify({ userId: req.user.id, socketId: req.query.socketId || null }))
    .toString('base64url')
  const url = oauthClient().generateAuthUrl({
    access_type: 'offline', prompt: 'consent',
    scope: [
      'https://www.googleapis.com/auth/gmail.readonly',
      'https://www.googleapis.com/auth/userinfo.email',
      'https://www.googleapis.com/auth/userinfo.profile',
    ],
    state,
  })
  res.json({ url })
})

// Google OAuth callback
router.get('/google/callback', async (req, res) => {
  try {
    const { code, state } = req.query
    const { userId } = JSON.parse(Buffer.from(state, 'base64url').toString())
    const { tokens, profile } = await exchangeCode(code)

    if (await findAccountByEmail(profile.email, userId)) {
      return res.send(closeHtml('This account is already connected.'))
    }
    const account = await addAccount({
      ownerId: userId, type: 'gmail', email: profile.email, picture: profile.picture || null,
      active: true, scope: 'personal',
      credentials: { refresh_token: tokens.refresh_token, access_token: tokens.access_token },
    })
    startAccount(await getAccountRow(account.id))
    emitAdded(userId, account)
    res.send(closeHtml('Account connected.'))
  } catch (err) {
    console.error('oauth callback:', err.message)
    res.status(500).send('OAuth failed: ' + err.message)
  }
})

const closeHtml = (msg) =>
  `<html><body style="font-family:sans-serif;background:#0f172a;color:#fff;text-align:center;padding-top:60px">${msg} You can close this window.<script>window.close()</script></body></html>`

export default router
