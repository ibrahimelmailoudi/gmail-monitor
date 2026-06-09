import { ImapFlow } from 'imapflow'
import { simpleParser } from 'mailparser'
import { google } from 'googleapis'
import { readCredentials, getIsp } from './store.js'
import { extractIp, parseAuth, domainOf, guessCategory, categoryFromImapLabels } from './parser.js'
import { oauthClient } from './gmail.js'

// Decode MIME encoded-words like =?UTF-8?B?...?= or =?UTF-8?Q?...?= in headers.
// Uses Node's built-in TextDecoder (no external dependency).
function decodeCharset(buf, charset) {
  try { return new TextDecoder(charset || 'utf-8').decode(buf) }
  catch {
    try { return new TextDecoder('utf-8').decode(buf) }
    catch { return buf.toString('latin1') }
  }
}
function decodeWord(str) {
  if (!str || str.indexOf('=?') === -1) return str || ''
  // join adjacent encoded-words separated by whitespace first
  const joined = str.replace(/\?=\s+=\?/g, '?==?')
  return joined.replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, (_, charset, enc, text) => {
    try {
      let buf
      if (enc.toUpperCase() === 'B') {
        buf = Buffer.from(text, 'base64')
      } else {
        const bytes = []
        for (let i = 0; i < text.length; i++) {
          if (text[i] === '_') bytes.push(0x20)
          else if (text[i] === '=' && i + 2 < text.length) {
            bytes.push(parseInt(text.substr(i + 1, 2), 16)); i += 2
          } else bytes.push(text.charCodeAt(i))
        }
        buf = Buffer.from(bytes)
      }
      return decodeCharset(buf, charset)
    } catch { return text }
  })
}

export async function extractFromAccount(accountRow, count = 50, includeSource = false, categories = [], sinceMs = null) {
  const creds = readCredentials(accountRow)
  // Resolve this account's ISP placement definitions (folder-based detection for
  // non-Gmail providers; Gmail still auto-detected via X-GM extensions).
  let ispPlacements = null
  if (accountRow.isp_id) {
    try { const isp = await getIsp(accountRow.isp_id); ispPlacements = isp?.placements || null } catch { /* ignore */ }
  }
  const emails = accountRow.type === 'imap'
    ? await imapExtract(accountRow, creds, count, includeSource, categories, ispPlacements)
    : await gmailExtract(accountRow, creds, count, includeSource, categories)
  if (sinceMs) {
    const cutoff = Number(sinceMs)
    return emails.filter(e => {
      const t = new Date(e.date || e.time || 0).getTime()
      return t && t >= cutoff
    })
  }
  return emails
}

// map our category -> Gmail search query
const GMAIL_CAT_QUERY = {
  spam: 'in:spam', promotions: 'category:promotions', social: 'category:social',
  updates: 'category:updates', forums: 'category:forums', primary: 'category:primary',
}

// Build a row from already-parsed header fields (fast path) or full parse.
function shapeFromHeaders(h, category, source) {
  // decode any MIME encoded-words present in text headers
  ;['from','to','subject','reply-to'].forEach(k => { if (h[k]) h[k] = decodeWord(h[k]) })
  const fromRaw = h.from || ''
  const m = fromRaw.match(/^\s*"?([^"<]*)"?\s*<([^>]+)>/)
  const name = m ? m[1].trim() : ''
  const address = m ? m[2].trim() : fromRaw.trim()
  const auth = parseAuth(h['authentication-results'] ? [h['authentication-results']] : [])
  return {
    category: category || guessCategory({ address, subject: h.subject || '', name, listUnsub: h['list-unsubscribe'] || '' }),
    from_name: name, from_email: address,
    to: h.to || '', subject: h.subject || '',
    date: h.date || '', message_id: h['message-id'] || '',
    domain: domainOf(address), ip: extractIp(h.received ? [].concat(h.received) : []),
    spf: auth.spf, dkim: auth.dkim, dmarc: auth.dmarc,
    reply_to: h['reply-to'] || '',
    return_path: (h['return-path'] || '').replace(/[<>]/g, ''),
    list_unsubscribe: h['list-unsubscribe'] || '',
    body_text: '', source,
  }
}

// ---- IMAP ----
// Gmail tabs are preset searches on hidden category labels. We use the X-GM-RAW
// extension to run Gmail's own search syntax over IMAP - this returns EXACTLY the
// same messages each tab shows. This is the authoritative way to get placement.
const GM_RAW = {
  primary: 'category:primary', promotions: 'category:promotions',
  social: 'category:social', updates: 'category:updates',
  forums: 'category:forums', spam: 'in:spam',
}

async function imapExtract(account, creds, count, includeSource, categories = [], ispPlacements = null) {
  const client = new ImapFlow({
    host: creds.host, port: creds.port || 993, secure: creds.ssl !== false,
    auth: { user: account.email, pass: creds.password }, logger: false,
    socketTimeout: 120000, greetingTimeout: 30000, connectionTimeout: 30000,
  })
  client.on('error', () => {})
  const out = []
  await client.connect()
  try {
    // Detect Gmail (X-GM extensions) and the All Mail folder.
    const isGmail = !!(client.capabilities && (client.capabilities.has?.('X-GM-EXT-1') || client.capabilities.get?.('X-GM-EXT-1')))
    let allBox = 'INBOX'
    try {
      const list = await client.list()
      const all = list.find(m => m.specialUse === '\\All')
      if (all) allBox = all.path
    } catch { /* INBOX */ }

    const fetchOpts = includeSource
      ? { uid: true, source: true, labels: true }
      : { uid: true, envelope: true, labels: true, headers: ['from', 'to', 'subject', 'date',
          'message-id', 'reply-to', 'return-path', 'list-unsubscribe', 'received', 'authentication-results'] }

    const shape = (parsed, forcedCat, labels, src) => {
      const from = parsed.from?.value?.[0] || {}
      const received = parsed.headerLines.filter(x => x.key === 'received').map(x => x.line)
      const authHdr = parsed.headerLines.filter(x => x.key === 'authentication-results').map(x => x.line)
      const auth = parseAuth(authHdr)
      const listUnsub = parsed.headerLines.find(x => x.key === 'list-unsubscribe')?.line || ''
      let category = forcedCat
      if (!category && labels && labels.size) category = categoryFromImapLabels(labels)
      if (!category) category = guessCategory({ address: from.address || '', subject: parsed.subject || '', name: from.name || '', listUnsub })
      return {
        category,
        from_name: from.name || '', from_email: from.address || '',
        to: parsed.to?.text || '', subject: parsed.subject || '',
        date: parsed.date ? parsed.date.toISOString() : '', message_id: parsed.messageId || '',
        domain: domainOf(from.address || ''), ip: extractIp(received),
        spf: auth.spf, dkim: auth.dkim, dmarc: auth.dmarc,
        reply_to: parsed.replyTo?.text || '',
        return_path: (parsed.headerLines.find(x => x.key === 'return-path')?.line || '').replace(/^return-path:\s*/i, ''),
        list_unsubscribe: listUnsub.replace(/^list-unsubscribe:\s*/i, ''),
        body_text: includeSource ? (parsed.text || '').slice(0, 5000) : '',
        source: includeSource ? (src ? src.toString('utf8') : undefined) : undefined,
      }
    }

    if (isGmail) {
      // Gmail: get exact placement. Spam lives in its own folder; the 5 tab
      // categories live in All Mail and are found via X-GM-RAW category search.
      const cats = categories.length ? categories : ['primary', 'promotions', 'social', 'updates', 'forums', 'spam']
      const tabCats = cats.filter(c => c !== 'spam')
      const wantSpam = cats.includes('spam')
      const seen = new Set()

      const fetchUids = async (uids, forcedCat) => {
        if (!uids || !uids.length) return
        // ensure ascending, then take the newest `count`
        const sorted = [...uids].sort((a, b) => a - b)
        const pick = sorted.slice(-count)
        for await (const msg of client.fetch(pick, fetchOpts, { uid: true })) {
          try {
            const key = `${forcedCat}:${msg.uid}`
            if (seen.has(key)) continue
            seen.add(key)
            const parsed = await simpleParser(includeSource ? msg.source : msg.headers)
            out.push(shape(parsed, forcedCat, msg.labels, msg.source))
          } catch { /* skip */ }
        }
      }

      // Tab categories - search inside All Mail
      if (tabCats.length) {
        const lock = await client.getMailboxLock(allBox)
        try {
          for (const cat of tabCats) {
            const raw = GM_RAW[cat]
            if (!raw) continue
            let uids = []
            try { uids = await client.search({ gmraw: raw }, { uid: true }) } catch { uids = [] }
            await fetchUids(uids, cat)
          }
        } finally { lock.release() }
      }

      // Spam - open the Spam folder directly (it is NOT inside All Mail)
      if (wantSpam) {
        let spamPath = null
        try {
          const list = await client.list()
          const junk = list.find(m => m.specialUse === '\\Junk')
          spamPath = junk?.path || '[Gmail]/Spam'
        } catch { spamPath = '[Gmail]/Spam' }
        try {
          const lock = await client.getMailboxLock(spamPath)
          try {
            const total = client.mailbox.exists || 0
            if (total > 0) {
              const n = Math.min(count, total)
              const start = Math.max(1, total - n + 1)
              for await (const msg of client.fetch(`${start}:${total}`, includeSource ? { source: true, labels: true } : { envelope: true, labels: true, headers: ['from','to','subject','date','message-id','reply-to','return-path','list-unsubscribe','received','authentication-results'] })) {
                try {
                  const parsed = await simpleParser(includeSource ? msg.source : msg.headers)
                  out.push(shape(parsed, 'spam', msg.labels, msg.source))
                } catch { /* skip */ }
              }
            }
          } finally { lock.release() }
        } catch { /* spam folder unavailable */ }
      }
    } else {
      // Non-Gmail IMAP (GMX/Outlook/Yahoo/etc.): no category tabs. They only have
      // Inbox + a Spam/Junk folder. Read Inbox -> 'inbox', and the junk folder -> 'spam'.
      const cats = categories.length ? categories : ['inbox', 'spam']
      const wantInbox = cats.includes('inbox') || cats.includes('primary') || cats.includes('focused')
      const wantSpam = cats.includes('spam') || cats.includes('junk')

      const readBox = async (path, forced) => {
        try {
          const lock = await client.getMailboxLock(path)
          try {
            const total = client.mailbox.exists || 0
            if (total > 0) {
              const n = Math.min(count, total)
              const start = Math.max(1, total - n + 1)
              for await (const msg of client.fetch(`${start}:${total}`, includeSource ? { source: true } : { envelope: true, headers: ['from','to','subject','date','message-id','reply-to','return-path','list-unsubscribe','received','authentication-results'] })) {
                try {
                  const parsed = await simpleParser(includeSource ? msg.source : msg.headers)
                  out.push(shape(parsed, forced, null, msg.source))
                } catch { /* skip */ }
              }
            }
          } finally { lock.release() }
        } catch { /* folder missing */ }
      }

      if (ispPlacements && ispPlacements.length) {
        // Use the ISP's own placement definitions (folder-based detection).
        const wanted = categories.length ? ispPlacements.filter(p => categories.includes(p.key)) : ispPlacements
        for (const p of wanted) {
          const det = p.detect || {}
          if (det.type === 'inbox') {
            await readBox('INBOX', p.key)
          } else if (det.type === 'folder' && det.path) {
            // try the configured path; if missing, fall back to special-use junk for spam
            await readBox(det.path, p.key)
            if (p.key === 'spam' && !out.some(e => e.category === 'spam')) {
              let junk = null
              try { const list = await client.list(); junk = list.find(m => m.specialUse === '\\Junk')?.path } catch { /* ignore */ }
              if (junk) await readBox(junk, 'spam')
            }
          }
        }
      } else {
        // Fallback when no ISP placements are defined: Inbox + Spam/Junk.
        const wantInbox = cats.includes('inbox') || cats.includes('primary') || cats.includes('focused')
        const wantSpam = cats.includes('spam') || cats.includes('junk')
        if (wantInbox) await readBox('INBOX', 'inbox')
        if (wantSpam) {
          let junk = null
          try { const list = await client.list(); junk = list.find(m => m.specialUse === '\\Junk')?.path } catch { /* ignore */ }
          const candidates = junk ? [junk] : ['Spam', 'Junk', 'Bulk Mail', 'Junk E-mail']
          for (const path of candidates) { await readBox(path, 'spam'); if (out.some(e => e.category === 'spam')) break }
        }
      }
    }
  } finally {
    try { await client.logout() } catch { /* ignore */ }
  }
  // sort newest-first
  let result = out.sort((a, b) => new Date(b.date || 0) - new Date(a.date || 0))
  if (categories.length) {
    // keep only requested categories; do NOT globally slice (would drop e.g. spam
    // if primary already filled `count`). Each category was already capped at `count`.
    result = result.filter(e => categories.includes(e.category))
    return result
  }
  return result.slice(0, count)
}

function categoryFromGmailLabels(labelIds = []) {
  if (labelIds.includes('SPAM')) return 'spam'
  if (labelIds.includes('CATEGORY_PROMOTIONS')) return 'promotions'
  if (labelIds.includes('CATEGORY_SOCIAL')) return 'social'
  if (labelIds.includes('CATEGORY_UPDATES')) return 'updates'
  if (labelIds.includes('CATEGORY_FORUMS')) return 'forums'
  return 'primary'
}


// ---- Gmail: metadata format is much faster than raw unless source needed ----
async function gmailExtract(account, creds, count, includeSource, categories = []) {
  const client = oauthClient()
  client.setCredentials({ refresh_token: creds.refresh_token, access_token: creds.access_token })
  const gmail = google.gmail({ version: 'v1', auth: client })

  // Build a Gmail search query from requested categories (reliable spam/promo/etc.)
  const q = categories.length
    ? categories.map(c => GMAIL_CAT_QUERY[c]).filter(Boolean).join(' OR ')
    : undefined
  const ids = []
  let pageToken
  while (ids.length < count) {
    const { data } = await gmail.users.messages.list({
      userId: 'me', maxResults: Math.min(100, count - ids.length),
      includeSpamTrash: true, q, pageToken,
    })
    ;(data.messages || []).forEach(m => ids.push(m.id))
    pageToken = data.nextPageToken
    if (!pageToken) break
  }

  const out = []
  // Run in small parallel batches to speed things up (was strictly sequential).
  const BATCH = 8
  const slice = ids.slice(0, count)
  for (let i = 0; i < slice.length; i += BATCH) {
    const chunk = slice.slice(i, i + BATCH)
    const results = await Promise.all(chunk.map(async (id) => {
      try {
        if (includeSource) {
          const { data: full } = await gmail.users.messages.get({ userId: 'me', id, format: 'raw' })
          const buf = Buffer.from(full.raw, 'base64')
          const parsed = await simpleParser(buf)
          const from = parsed.from?.value?.[0] || {}
          const received = parsed.headerLines.filter(x => x.key === 'received').map(x => x.line)
          const auth = parseAuth(parsed.headerLines.filter(x => x.key === 'authentication-results').map(x => x.line))
          return {
            category: categoryFromGmailLabels(full.labelIds),
            from_name: from.name || '', from_email: from.address || '',
            to: parsed.to?.text || '', subject: parsed.subject || '',
            date: parsed.date ? parsed.date.toISOString() : '', message_id: parsed.messageId || '',
            domain: domainOf(from.address || ''), ip: extractIp(received),
            spf: auth.spf, dkim: auth.dkim, dmarc: auth.dmarc,
            reply_to: parsed.replyTo?.text || '', return_path: '', list_unsubscribe: '',
            body_text: (parsed.text || '').slice(0, 5000), source: buf.toString('utf8'),
          }
        } else {
          const { data: msg } = await gmail.users.messages.get({
            userId: 'me', id, format: 'metadata',
            metadataHeaders: ['From', 'To', 'Subject', 'Date', 'Message-ID', 'Reply-To',
              'Return-Path', 'List-Unsubscribe', 'Received', 'Authentication-Results'],
          })
          const hv = (n) => msg.payload.headers.find(x => x.name.toLowerCase() === n)?.value || ''
          const received = msg.payload.headers.filter(x => x.name === 'Received').map(x => x.value)
          const h = {
            from: hv('from'), to: hv('to'), subject: hv('subject'), date: hv('date'),
            'message-id': hv('message-id'), 'reply-to': hv('reply-to'),
            'return-path': hv('return-path'), 'list-unsubscribe': hv('list-unsubscribe'),
            received, 'authentication-results': hv('authentication-results'),
          }
          return shapeFromHeaders(h, categoryFromGmailLabels(msg.labelIds))
        }
      } catch { return null }
    }))
    results.forEach(r => { if (r) out.push(r) })
  }
  return out
}
