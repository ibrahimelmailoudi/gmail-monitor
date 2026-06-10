import { createContext, useContext, useState, useCallback, useEffect, useRef } from 'react'
import { ConfigProvider, message } from 'antd'
import { makeTheme } from '../theme'
import { useAccounts } from '../hooks/useAccounts'
import { resumeAll, pauseAll } from '../services/accounts'
import * as accountsApi from '../services/accounts'

const AppContext = createContext(null)
export const useApp = () => useContext(AppContext)

export function AppProvider({ children }) {
  const [token, setToken] = useState(localStorage.getItem('token'))
  const user = (() => { try { return JSON.parse(localStorage.getItem('user')) } catch { return null } })()
  const [mode, setMode] = useState(localStorage.getItem('mode') || 'light')
  const [messageApi, contextHolder] = message.useMessage()

  // Extract page results - kept here (not in the page) so navigating away and back
  // does NOT wipe the extracted emails. Lives in memory for the session.
  const [extractResults, setExtractResults] = useState([])
  const [extractMeta, setExtractMeta] = useState({ accountId: null, withSource: false })
  // Saved emails now PERSIST in the database (survive refresh/logout), unlike the
  // in-memory extract results.
  const [storedEmails, setStoredEmails] = useState([])
  const reloadStored = useCallback(async () => {
    try { setStoredEmails(await accountsApi.getSavedEmails()) } catch { /* ignore */ }
  }, [])
  const saveEmails = useCallback(async (emails) => {
    try {
      await accountsApi.saveEmailsToStore(emails)
      await reloadStored()
    } catch { messageApi.open({ type: 'error', content: 'Could not save to Storage' }) }
  }, [reloadStored, messageApi])
  const removeStored = useCallback(async (id) => {
    try { await accountsApi.deleteSavedEmail(id); await reloadStored() } catch { /* ignore */ }
  }, [reloadStored])
  const clearStored = useCallback(async () => {
    try { await accountsApi.clearSavedEmails(); setStoredEmails([]) } catch { /* ignore */ }
  }, [])

  const notify = useCallback((msg, type = 'success') =>
    messageApi.open({ type: type === 'error' ? 'error' : 'success', content: msg }), [messageApi])

  const toggleMode = useCallback(() => {
    setMode(prev => {
      const next = prev === 'dark' ? 'light' : 'dark'
      localStorage.setItem('mode', next)
      return next
    })
  }, [])

  // Inactivity auto-pause: if the tab is hidden for 10 min, pause all watchers.
  // Resume when the user comes back. Also pause on page close.
  const hideTimer = useRef(null)
  const resumeTimer = useRef(null)
  // Load persisted saved-emails from the DB once logged in.
  useEffect(() => { if (token) reloadStored() }, [token, reloadStored])

  useEffect(() => {
    if (!token) return
    const IDLE = 10 * 60 * 1000
    const onVisibility = () => {
      if (document.hidden) {
        if (resumeTimer.current) { clearTimeout(resumeTimer.current); resumeTimer.current = null }
        hideTimer.current = setTimeout(() => { pauseAll().catch(() => {}) }, IDLE)
      } else {
        if (hideTimer.current) { clearTimeout(hideTimer.current); hideTimer.current = null }
        // debounce: only resume once things settle (prevents rapid start-all spam)
        if (resumeTimer.current) clearTimeout(resumeTimer.current)
        resumeTimer.current = setTimeout(() => { resumeAll().catch(() => {}) }, 1500)
      }
    }
    const onClose = () => { try { navigator.sendBeacon?.('/api/accounts/pause-all') } catch { /* ignore */ } }
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('pagehide', onClose)
    return () => {
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('pagehide', onClose)
      if (hideTimer.current) clearTimeout(hideTimer.current)
      if (resumeTimer.current) clearTimeout(resumeTimer.current)
    }
  }, [token])

  const accountState = useAccounts(token, notify)

  return (
    <ConfigProvider theme={makeTheme(mode)}>
      <AppContext.Provider value={{ token, setToken, user, mode, toggleMode, notify,
        extractResults, setExtractResults, extractMeta, setExtractMeta,
        storedEmails, saveEmails, removeStored, clearStored, reloadStored,
        ...accountState }}>
        {contextHolder}
        {children}
      </AppContext.Provider>
    </ConfigProvider>
  )
}
