import { google } from 'googleapis'
import { config } from './config.js'
import { readCredentials } from './store.js'
import { categoryFromLabels, extractIp, parseAuth, buildEmail } from './parser.js'

export function oauthClient() {
  return new google.auth.OAuth2(
    config.google.clientId,
    config.google.clientSecret,
    config.google.redirectUri
  )
}

// Prefer admin-entered DB config; fall back to env. Use in OAuth start/callback.
export async function oauthClientFromSettings() {
  const { getSetting } = await import('./store.js')
  const id = (await getSetting('gmail_client_id', '')) || config.google.clientId
  const secret = (await getSetting('gmail_client_secret', '')) || config.google.clientSecret
  const redirect = (await getSetting('gmail_redirect_uri', '')) || config.google.redirectUri
  return new google.auth.OAuth2(id, secret, redirect)
}

function clientForAccount(account) {
  const creds = readCredentials(account)
  const client = oauthClient()
  client.setCredentials({ refresh_token: creds.refresh_token, access_token: creds.access_token })
  return client
}

const header = (payload, name) =>
  payload?.headers?.find(h => h.name.toLowerCase() === name.toLowerCase())?.value || ''

// Parse a "From" header into name + address
function parseFrom(value) {
  const m = value.match(/^\s*"?([^"<]*)"?\s*<([^>]+)>/)
  if (m) return { name: m[1].trim(), address: m[2].trim() }
  return { name: '', address: value.trim() }
}

// Starts a polling loop. Returns a stop() function.
export function startGmailWatcher(account, emit) {
  let lastTs = Date.now() - 2 * 60 * 1000 // back-fill last 2 minutes, then go live
  let timer = null
  let stopped = false

  const gmail = google.gmail({ version: 'v1', auth: clientForAccount(account) })

  async function poll() {
    if (stopped) return
    try {
      const afterSec = Math.floor(lastTs / 1000)
      const { data } = await gmail.users.messages.list({
        userId: 'me',
        q: `after:${afterSec}`,
        maxResults: 15,
      })
      const ids = (data.messages || []).map(m => m.id)
      for (const id of ids.reverse()) {
        const { data: msg } = await gmail.users.messages.get({
          userId: 'me', id, format: 'metadata',
          metadataHeaders: ['From', 'Subject', 'Received', 'Date', 'Authentication-Results'],
        })
        const ts = Number(msg.internalDate) || Date.now()
        if (ts <= lastTs) continue
        const from = parseFrom(header(msg.payload, 'From'))
        const received = msg.payload.headers.filter(h => h.name === 'Received').map(h => h.value)
        const authHdr = msg.payload.headers.filter(h => h.name === 'Authentication-Results').map(h => h.value)
        const email = buildEmail({
          name: from.name,
          address: from.address,
          subject: header(msg.payload, 'Subject'),
          dateMs: ts,
          ip: extractIp(received),
          category: categoryFromLabels(msg.labelIds),
          auth: parseAuth(authHdr),
          preview: msg.snippet || '',
        })
        lastTs = Math.max(lastTs, ts)
        await emit(account.id, email)
      }
    } catch (err) {
      console.error(`[gmail ${account.email}]`, err.message)
    } finally {
      if (!stopped) timer = setTimeout(poll, config.gmailPollMs)
    }
  }

  poll()
  return () => { stopped = true; if (timer) clearTimeout(timer) }
}

// Exchange OAuth code -> tokens + profile
export async function exchangeCode(code) {
  const client = oauthClient()
  const { tokens } = await client.getToken(code)
  client.setCredentials(tokens)
  const oauth2 = google.oauth2({ version: 'v2', auth: client })
  const { data: profile } = await oauth2.userinfo.get()
  return { tokens, profile }
}
