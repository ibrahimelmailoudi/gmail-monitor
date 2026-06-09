import { Router } from 'express'
import dns from 'dns/promises'
import { auth } from '../auth-middleware.js'

const router = Router()
router.use(auth)

// DNS / SPF / DMARC / MX lookup
router.get('/dns', async (req, res) => {
  const domain = String(req.query.domain || '').trim().toLowerCase().replace(/^https?:\/\//, '').split('/')[0]
  if (!domain) return res.status(400).json({ message: 'domain required' })
  const out = { domain, errors: {} }

  try { out.mx = (await dns.resolveMx(domain)).sort((a, b) => a.priority - b.priority) }
  catch (e) { out.mx = []; out.errors.mx = e.code || e.message }

  try {
    const txt = (await dns.resolveTxt(domain)).map(r => r.join(''))
    out.spf = txt.find(t => t.toLowerCase().startsWith('v=spf1')) || null
  } catch (e) { out.spf = null; out.errors.spf = e.code || e.message }

  try {
    const dmarc = (await dns.resolveTxt(`_dmarc.${domain}`)).map(r => r.join(''))
    out.dmarc = dmarc.find(t => t.toLowerCase().startsWith('v=dmarc1')) || null
  } catch (e) { out.dmarc = null; out.errors.dmarc = e.code || e.message }

  res.json(out)
})

// DKIM lookup - tries common selectors if none given
router.get('/dkim', async (req, res) => {
  const domain = String(req.query.domain || '').trim().toLowerCase()
  const given = String(req.query.selector || '').trim().toLowerCase()
  if (!domain) return res.status(400).json({ message: 'domain required' })
  const selectors = given ? [given] : ['google', 'default', 'selector1', 'selector2', 'k1', 'dkim', 's1']
  for (const sel of selectors) {
    try {
      const txt = (await dns.resolveTxt(`${sel}._domainkey.${domain}`)).map(r => r.join(''))
      if (txt[0]) return res.json({ domain, selector: sel, dkim: txt[0] })
    } catch { /* try next */ }
  }
  res.json({ domain, selector: given || selectors.join(', '), dkim: null,
    note: 'No DKIM record found. Provide the exact selector from a real message DKIM-Signature header.' })
})

export default router
