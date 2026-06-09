import { useState, useEffect, useRef, useCallback } from 'react'
import { getSharedSocket } from './useRealtime'
import * as accountsApi from '../services/accounts'

const MAX_EMAILS_PER_ACCOUNT = 40

// A content fingerprint that identifies the SAME email across the live socket
// path and the refresh path, even if ids/Message-IDs/timestamps differ.
// Deliberately NO time component: the same email captured a few seconds apart
// (e.g. live vs refresh) must produce the SAME fingerprint.
function fingerprint(e) {
  const subj = (e.sender?.subject || e.subject || '').trim().toLowerCase()
  const from = (e.sender?.email || e.from_email || '').trim().toLowerCase()
  const ip = (e.ip || '').trim()
  return `${from}|${subj}|${ip}`
}

// Dedup a list by fingerprint, preferring the entry with a REAL placement
// (so 'unknown' never wins over 'primary'/'promotions'/etc.) and keeping flags.
function dedupeByContent(list) {
  const byFp = new Map()
  for (const e of list) {
    const fp = fingerprint(e)
    const prev = byFp.get(fp)
    if (!prev) { byFp.set(fp, e); continue }
    // merge: keep the better (non-unknown) category, keep earliest id for stability
    const better = (prev.category && prev.category !== 'unknown') ? prev.category
                 : (e.category && e.category !== 'unknown') ? e.category
                 : (prev.category || e.category)
    byFp.set(fp, { ...prev, category: better })
  }
  return Array.from(byFp.values())
}

// Sort emails newest-first by date/time, dedupe by content, keep only the latest 40.
function capAndSort(emails) {
  const ts = (e) => new Date(e.time || e.date || 0).getTime() || 0
  const deduped = dedupeByContent(emails)
  return deduped.sort((a, b) => ts(b) - ts(a)).slice(0, MAX_EMAILS_PER_ACCOUNT)
}

// Owns account state, live socket updates, and the "new email" highlight set.
export function useAccounts(token, notify) {
  const [accounts, setAccounts] = useState([])
  const [loading, setLoading] = useState(true)
  const [newEmailIds, setNewEmailIds] = useState(new Set())
  const socketRef = useRef(null)
  // accounts that already had their first refresh fill (so we don't flag the
  // initial batch as "NEW" - only genuinely new arrivals after that)
  const filledOnce = useRef(new Set())

  const markNew = useCallback((id) => {
    setNewEmailIds(prev => new Set([...prev, id]))
    // keep the "NEW" badge + border + animation visible for 30 seconds
    setTimeout(() => setNewEmailIds(prev => {
      const s = new Set(prev); s.delete(id); return s
    }), 30000)
  }, [])

  // Initial load - robust against transient failures (was sometimes needing 2-3 refreshes)
  useEffect(() => {
    if (!token) return
    let cancelled = false
    setLoading(true)
    const load = (attempt = 1) => {
      accountsApi.fetchAccounts()
        .then(data => {
          if (cancelled) return
          setAccounts(Array.isArray(data) ? data : [])
          setLoading(false)
        })
        .catch(() => {
          if (cancelled) return
          if (attempt < 3) {
            setTimeout(() => load(attempt + 1), 600 * attempt) // backoff retry
          } else {
            setLoading(false)
            notify?.('Failed to load accounts', 'error')
          }
        })
    }
    load()
    return () => { cancelled = true }
  }, [token]) // eslint-disable-line react-hooks/exhaustive-deps

  // Live updates (uses the ONE shared socket, so events reach every page)
  useEffect(() => {
    if (!token) return
    const socket = getSharedSocket()
    socketRef.current = socket

    const onAdded = (acc) => {
      setAccounts(prev => [...prev.filter(a => a.id !== acc.id), acc])
      notify?.(`Account connected: ${acc.email}`)
    }
    const onUpdate = ({ id, active }) =>
      setAccounts(prev => prev.map(a => a.id === id ? { ...a, active } : a))
    const onRemoved = ({ id }) =>
      setAccounts(prev => prev.filter(a => a.id !== id))
    const onNewEmail = ({ accountId, email }) => {
      setAccounts(prev => prev.map(a => {
        if (a.id !== accountId) return a
        // capAndSort dedupes by content, so even if this email also comes via
        // refresh it will collapse into one card.
        return { ...a, emails: capAndSort([email, ...(a.emails || [])]) }
      }))
      markNew(email.id)
    }
    const onAllToggled = ({ active }) =>
      setAccounts(prev => prev.map(a => ({ ...a, active })))

    socket.on('account_added', onAdded)
    socket.on('account_update', onUpdate)
    socket.on('account_removed', onRemoved)
    socket.on('new_email', onNewEmail)
    socket.on('all_toggled', onAllToggled)

    return () => {
      socket.off('account_added', onAdded)
      socket.off('account_update', onUpdate)
      socket.off('account_removed', onRemoved)
      socket.off('new_email', onNewEmail)
      socket.off('all_toggled', onAllToggled)
    }
  }, [token, notify, markNew])

  const toggle = (id) => {
    // optimistic: flip immediately so the UI feels instant
    setAccounts(prev => prev.map(a => a.id === id ? { ...a, active: !a.active } : a))
    accountsApi.toggleAccount(id).catch(() => {
      setAccounts(prev => prev.map(a => a.id === id ? { ...a, active: !a.active } : a)) // revert
      notify?.('Failed', 'error')
    })
  }
  const remove = (id) => accountsApi.removeAccount(id).catch(() => notify?.('Failed', 'error'))

  // Merge emails returned by a refresh into the account. Dedup is by content
  // fingerprint (handled in capAndSort), so the same email from live + refresh
  // collapses into one card and never duplicates.
  const mergeEmails = (accountId, emails) => {
    setAccounts(prev => {
      const next = prev.map(a => {
        if (a.id !== accountId) return a
        const normId = (mid) => (mid || '').replace(/[<>]/g, '').trim().toLowerCase()
        const mapped = emails.map((e) => ({ id: normId(e.message_id) || `r-${accountId}-${e.subject}-${e.date}`, ...e,
          sender: { name: e.from_name, email: e.from_email, subject: e.subject, domain: e.domain },
          auth: { spf: e.spf, dkim: e.dkim, dmarc: e.dmarc }, time: e.date, category: e.category,
          preview: e.body_text }))

        // figure out which fingerprints are genuinely new (for the NEW badge)
        const existingFps = new Set((a.emails || []).map(fingerprint))
        const freshFps = mapped.filter(e => !existingFps.has(fingerprint(e)))

        if (filledOnce.current.has(accountId)) {
          setTimeout(() => freshFps.forEach(e => markNew(e.id)), 0)
        } else {
          filledOnce.current.add(accountId)
        }

        // combine then dedupe-by-content (newer 'unknown' won't override a real category)
        return { ...a, emails: capAndSort([...mapped, ...(a.emails || [])]) }
      })
      return next
    })
  }

  return { accounts, loading, newEmailIds, toggle, remove, mergeEmails, socketId: socketRef.current?.id }
}
