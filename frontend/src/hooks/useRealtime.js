import { useEffect } from 'react'
import { createSocket } from '../api/socket'

let shared = null
export function getSharedSocket() {
  if (!shared) shared = createSocket()
  return shared
}

// Call on logout so the next login creates a socket with the fresh token.
export function resetSharedSocket() {
  try { shared?.disconnect() } catch { /* ignore */ }
  shared = null
}

// Subscribe to a socket event; handler cleaned up on unmount.
export function useSocketEvent(event, handler) {
  useEffect(() => {
    const s = getSharedSocket()
    s.on(event, handler)
    return () => s.off(event, handler)
  }, [event, handler])
}
