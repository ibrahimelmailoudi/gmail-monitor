import { Router } from 'express'
import dns from 'dns/promises'
import { auth } from '../auth-middleware.js'

const router = Router()
router.use(auth)

// Use explicit public DNS resolvers (Cloudflare + Google) instead of the system
// default. On some machines the system resolver refuses Node's queries
// (ECONNREFUSED) - pointing at public servers fixes that.
try {
  dns.setServers(['1.1.1.1', '8.8.8.8', '1.0.0.1', '8.8.4.4'])
} catch { /* if it fails, fall back to system default */ }

// Wrap any DNS promise so it can never hang forever (5s cap).
function withTimeout(promise, ms = 5000) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('DNS timeout')), ms)),
  ])
}

// DNS / SPF / DMARC / MX lookup
router.get('/dns', async (req, res) => {
  const domain = String(req.query.domain || '').trim().toLowerCase().replace(/^https?:\/\//, '').split('/')[0]
  if (!domain) return res.status(400).json({ message: 'domain required' })
  const out = { domain, errors: {} }

  try { out.mx = (await withTimeout(dns.resolveMx(domain))).sort((a, b) => a.priority - b.priority) }
  catch (e) { out.mx = []; out.errors.mx = e.code || e.message }

  try {
    const txt = (await withTimeout(dns.resolveTxt(domain))).map(r => r.join(''))
    out.spf = txt.find(t => t.toLowerCase().startsWith('v=spf1')) || null
  } catch (e) { out.spf = null; out.errors.spf = e.code || e.message }

  try {
    const dmarc = (await withTimeout(dns.resolveTxt(`_dmarc.${domain}`))).map(r => r.join(''))
    out.dmarc = dmarc.find(t => t.toLowerCase().startsWith('v=dmarc1')) || null
  } catch (e) { out.dmarc = null; out.errors.dmarc = e.code || e.message }

  // Deliverability health: flag common problems that hurt inbox placement.
  const issues = []
  if (!out.spf) issues.push({ level: 'error', text: 'No SPF record - mail is likely to be marked spam or rejected.' })
  else {
    if (!/[-~]all/.test(out.spf)) issues.push({ level: 'warn', text: 'SPF has no -all or ~all (no clear policy for unauthorized senders).' })
    if ((out.spf.match(/include:/g) || []).length > 10) issues.push({ level: 'warn', text: 'SPF has many includes - watch the 10 DNS-lookup limit.' })
  }
  if (!out.dmarc) issues.push({ level: 'error', text: 'No DMARC record - domain is open to spoofing; senders skip alignment checks.' })
  else {
    if (/p=none/.test(out.dmarc)) issues.push({ level: 'warn', text: 'DMARC policy is p=none (monitoring only, not enforcing).' })
    if (!/rua=/.test(out.dmarc)) issues.push({ level: 'info', text: 'DMARC has no rua= aggregate-report address.' })
  }
  if (!out.mx?.length) issues.push({ level: 'error', text: 'No MX records - this domain cannot receive mail.' })
  out.issues = issues
  out.health = issues.some(i => i.level === 'error') ? 'poor' : issues.some(i => i.level === 'warn') ? 'fair' : 'good'

  res.json(out)
})

// Expand an SPF record recursively: for the given domain, fetch its SPF, then
// resolve each include: to show what THAT domain includes too (one level deep by
// default, up to maxDepth). Useful to see the full sender tree.
router.get('/spf-tree', async (req, res) => {
  const domain = String(req.query.domain || '').trim().toLowerCase().replace(/^https?:\/\//, '').split('/')[0]
  if (!domain) return res.status(400).json({ message: 'domain required' })
  const maxDepth = Math.min(Number(req.query.depth) || 3, 5)
  const seen = new Set()

  async function getSpf(d) {
    try {
      const txt = (await withTimeout(dns.resolveTxt(d))).map(r => r.join(''))
      return txt.find(t => t.toLowerCase().startsWith('v=spf1')) || null
    } catch { return null }
  }
  async function expand(d, depth) {
    if (depth > maxDepth || seen.has(d)) return { domain: d, spf: null, includes: [], truncated: seen.has(d) }
    seen.add(d)
    const spf = await getSpf(d)
    const node = { domain: d, spf, includes: [], ip4: [], ip6: [] }
    if (!spf) return node
    node.ip4 = (spf.match(/ip4:[^\s]+/g) || []).map(s => s.replace('ip4:', ''))
    node.ip6 = (spf.match(/ip6:[^\s]+/g) || []).map(s => s.replace('ip6:', ''))
    const incs = (spf.match(/include:[^\s]+/g) || []).map(s => s.replace('include:', ''))
    for (const inc of incs) node.includes.push(await expand(inc, depth + 1))
    return node
  }
  const tree = await expand(domain, 0)
  res.json(tree)
})

// DKIM lookup - tries common selectors if none given
router.get('/dkim', async (req, res) => {
  const domain = String(req.query.domain || '').trim().toLowerCase()
  const given = String(req.query.selector || '').trim().toLowerCase()
  if (!domain) return res.status(400).json({ message: 'domain required' })
  const selectors = given ? [given] : ['google', 'default', 'selector1', 'selector2', 'k1', 'dkim', 's1']
  for (const sel of selectors) {
    try {
      const txt = (await withTimeout(dns.resolveTxt(`${sel}._domainkey.${domain}`))).map(r => r.join(''))
      if (txt[0]) return res.json({ domain, selector: sel, dkim: txt[0] })
    } catch { /* try next */ }
  }
  res.json({ domain, selector: given || selectors.join(', '), dkim: null,
    note: 'No DKIM record found. Provide the exact selector from a real message DKIM-Signature header.' })
})

// Generic records: A, AAAA, NS, full TXT, CNAME - for domain verification
router.get('/records', async (req, res) => {
  const domain = String(req.query.domain || '').trim().toLowerCase().replace(/^https?:\/\//, '').split('/')[0]
  if (!domain) return res.status(400).json({ message: 'domain required' })
  const out = { domain, errors: {} }
  try { out.a = await withTimeout(dns.resolve4(domain)) } catch (e) { out.a = []; out.errors.a = e.code }
  try { out.aaaa = await withTimeout(dns.resolve6(domain)) } catch (e) { out.aaaa = []; out.errors.aaaa = e.code }
  try { out.ns = await withTimeout(dns.resolveNs(domain)) } catch (e) { out.ns = []; out.errors.ns = e.code }
  try { out.txt = (await withTimeout(dns.resolveTxt(domain))).map(r => r.join('')) } catch (e) { out.txt = []; out.errors.txt = e.code }
  try { out.cname = await withTimeout(dns.resolveCname(domain)) } catch (e) { out.cname = []; out.errors.cname = e.code }
  res.json(out)
})

// Reverse DNS (PTR). Accepts an IP, or a domain/URL (resolves to IP first).
router.get('/ptr', async (req, res) => {
  let input = String(req.query.ip || '').trim().replace(/^https?:\/\//, '').replace(/\/.*$/, '')
  if (!input) return res.status(400).json({ message: 'ip or domain required' })
  const isIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(input) || input.includes(':')
  try {
    let ip = input
    if (!isIp) {
      // it's a domain - resolve to its first A record, then reverse that
      const addrs = await withTimeout(dns.resolve4(input))
      if (!addrs.length) return res.json({ ip: input, ptr: [], error: 'No A record to reverse' })
      ip = addrs[0]
    }
    const ptr = await withTimeout(dns.reverse(ip))
    res.json({ ip, ptr, resolvedFrom: isIp ? undefined : input })
  } catch (e) {
    res.json({ ip: input, ptr: [], error: e.code || e.message })
  }
})

export default router
