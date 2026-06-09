import { ImapFlow } from 'imapflow'
import { simpleParser } from 'mailparser'
import { readCredentials } from './store.js'
import { extractIp, parseAuth, buildEmail, guessCategory, categoryFromImapLabels } from './parser.js'

// Crash-proof, leak-free IMAP watcher.
// Uses imapflow's built-in IDLE (it keeps itself in IDLE and emits 'exists').
// We do NOT manually loop idle() (that caused a busy-spin / memory blowup).
export function startImapWatcher(account, emit) {
  const creds = readCredentials(account)
  let client = null
  let stopped = false
  let lastSeen = 0
  let backoff = 5000
  let processing = false
  let pollTimer = null
  const MAX_BACKOFF = 5 * 60 * 1000

  async function processNew() {
    if (processing || !client?.usable) return
    processing = true
    let lock
    try {
      lock = await client.getMailboxLock('INBOX')
      const total = client.mailbox.exists || 0
      if (total > lastSeen) {
        const start = lastSeen + 1
        for await (const msg of client.fetch(`${start}:${total}`, { source: true, labels: true })) {
          try {
            const parsed = await simpleParser(msg.source)
            const from = parsed.from?.value?.[0] || {}
            const received = parsed.headerLines.filter(h => h.key === 'received').map(h => h.line)
            const authHdr = parsed.headerLines.filter(h => h.key === 'authentication-results').map(h => h.line)
            const listUnsub = parsed.headerLines.find(h => h.key === 'list-unsubscribe')?.line || ''
            // Placement priority:
            // 1) real Gmail labels (X-GM-LABELS) - exact category if present
            // 2) message is in INBOX with no category label -> it's Primary by definition
            // 3) only then fall back to a header guess
            let category = null
            if (msg.labels && msg.labels.size) {
              category = categoryFromImapLabels(msg.labels)
              // categoryFromImapLabels returns 'unknown' when labels exist but carry
              // no category - for an INBOX message that means Primary.
              if (category === 'unknown') category = 'primary'
            }
            if (!category) category = guessCategory({ address: from.address, subject: parsed.subject, name: from.name, listUnsub })
            await emit(account.id, buildEmail({
              name: from.name, address: from.address, subject: parsed.subject,
              dateMs: parsed.date ? parsed.date.getTime() : Date.now(),
              ip: extractIp(received),
              category,
              auth: parseAuth(authHdr),
              preview: (parsed.text || '').replace(/\s+/g, ' ').trim().slice(0, 200),
            }))
          } catch { /* skip one bad message */ }
          if (msg.seq > lastSeen) lastSeen = msg.seq
        }
      }
    } catch (e) {
      console.error(`[imap ${account.email}] process:`, e.code || e.message)
    } finally {
      if (lock) lock.release()
      processing = false
    }
  }

  function cleanup() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
    if (!client) return
    const c = client
    client = null
    try { c.removeAllListeners() } catch { /* ignore */ }
    try { c.close() } catch { /* ignore */ }
  }
  async function session() {
    client = new ImapFlow({
      host: creds.host, port: creds.port || 993, secure: creds.ssl !== false,
      auth: { user: account.email, pass: creds.password },
      logger: false,
      emitLogs: false,
      socketTimeout: 30 * 60 * 1000,   // 30 min; IDLE keeps it alive anyway
      greetingTimeout: 30 * 1000,
      connectionTimeout: 30 * 1000,
    })

    // Swallow errors so a drop never crashes the process; trigger reconnect.
    client.on('error', (e) => {
      console.error(`[imap ${account.email}]`, e.code || e.message)
    })
    client.on('close', () => {
      // connection closed; if not stopped, schedule a reconnect
      if (!stopped) scheduleReconnect()
    })
    // New message(s) arrived while in IDLE
    client.on('exists', () => { processNew().catch(() => {}) })

    await client.connect()
    await client.mailboxOpen('INBOX', { readOnly: true })
    const total = client.mailbox.exists || 0
    // Back-fill: include messages received in the last ~2 minutes, then go live.
    // We look back a small window of recent messages and keep those newer than the cutoff.
    lastSeen = total
    try {
      const LOOKBACK = 15 // check up to the last 15 messages for the 2-min window
      const cutoff = Date.now() - 2 * 60 * 1000
      if (total > 0) {
        const start = Math.max(1, total - LOOKBACK + 1)
        const recent = []
        for await (const msg of client.fetch(`${start}:${total}`, { envelope: true })) {
          const when = msg.envelope?.date ? new Date(msg.envelope.date).getTime() : 0
          if (when >= cutoff) recent.push(msg.seq)
        }
        if (recent.length) lastSeen = Math.min(...recent) - 1 // so processNew emits them
      }
    } catch { /* if backfill probe fails, just go live from now */ }
    backoff = 5000

    // emit the backfilled window immediately, then rely on IDLE for new mail
    await processNew()

    // Safety-net poll every 30s in case an IDLE 'exists' event is missed
    // (some servers/networks drop notifications). This guarantees new mail shows
    // live without the user clicking refresh.
    if (pollTimer) clearInterval(pollTimer)
    pollTimer = setInterval(() => { processNew().catch(() => {}) }, 30 * 1000)

    // Enter IDLE ONCE. imapflow keeps the connection in IDLE and re-arms it
    // internally, emitting 'exists' on new mail. This call resolves only when
    // IDLE ends (e.g. connection closes) - no busy loop, no timer leak.
    await client.idle()
  }

  let reconnectTimer = null
  function scheduleReconnect() {
    if (stopped || reconnectTimer) return
    cleanup()
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null
      run().catch(() => {})
    }, backoff)
    backoff = Math.min(backoff * 2, MAX_BACKOFF)
  }

  async function run() {
    if (stopped) return
    try {
      await session()
      // idle() returned (connection ended) -> reconnect unless stopped
      if (!stopped) scheduleReconnect()
    } catch (err) {
      console.error(`[imap ${account.email}] retry in ${backoff / 1000}s:`, err.code || err.message)
      if (!stopped) scheduleReconnect()
    }
  }

  run().catch(err => console.error(`[imap ${account.email}] fatal:`, err.message))

  // stop function
  return async () => {
    stopped = true
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null }
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
    try { await client?.logout() } catch { /* ignore */ }
    cleanup()
  }
}

export async function verifyImap({ email, password, host, port, ssl }) {
  const client = new ImapFlow({
    host, port: port || 993, secure: ssl !== false,
    auth: { user: email, pass: password }, logger: false,
    greetingTimeout: 20000, connectionTimeout: 20000,
  })
  client.on('error', () => {})
  try {
    await client.connect()
    await client.logout()
  } finally {
    try { client.removeAllListeners() } catch { /* ignore */ }
    try { client.close() } catch { /* ignore */ }
  }
}
