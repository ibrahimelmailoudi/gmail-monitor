import { Router } from 'express'
import { auth } from '../auth-middleware.js'
import { isStaff, can } from '../permissions.js'
import {
  createRequest, listRequestsForUser, getRequestThread, addRequestMessage,
  setRequestStatus, getRequest, listRequestTypes, deleteRequest,
} from '../store.js'
import { emitToStaff, emitToUser } from '../monitor.js'

const router = Router()
router.use(auth)

// request types (any logged-in user, for the New Request form)
router.get('/types', async (_req, res) => res.json(await listRequestTypes()))

// list (users see their own; staff see all)
router.get('/', async (req, res) => res.json(await listRequestsForUser(req.user)))

// create a new request (any user)
router.post('/', async (req, res) => {
  const { type = 'message', subject, body } = req.body || {}
  if (!body && !subject) return res.status(400).json({ message: 'subject or message required' })
  const r = await createRequest({ userId: req.user.id, type, subject, body })
  emitToStaff('request_new', { ...r, username: req.user.username })
  emitToStaff('notif', { message: `New ${type} request` })
  res.json(r)
})

// thread messages
router.get('/:id/messages', async (req, res) => {
  const r = await getRequest(req.params.id)
  if (!r) return res.status(404).json({ message: 'Not found' })
  if (!isStaff(req.user) && r.user_id !== req.user.id) return res.status(403).json({ message: 'Forbidden' })
  res.json(await getRequestThread(req.params.id))
})

// reply (owner or staff)
router.post('/:id/messages', async (req, res) => {
  const r = await getRequest(req.params.id)
  if (!r) return res.status(404).json({ message: 'Not found' })
  if (!isStaff(req.user) && r.user_id !== req.user.id) return res.status(403).json({ message: 'Forbidden' })
  const { body } = req.body || {}
  if (!body) return res.status(400).json({ message: 'message required' })
  const msg = await addRequestMessage(req.params.id, req.user, body)
  emitToStaff('request_msg', { requestId: req.params.id, msg })
  emitToUser(r.user_id, 'request_msg', { requestId: req.params.id, msg })
  res.json(msg)
})

// resolve / reopen (staff with resolve_requests)
router.post('/:id/status', async (req, res) => {
  if (!can(req.user, 'resolve_requests')) return res.status(403).json({ message: 'Missing permission' })
  const { status } = req.body || {}
  if (!['open', 'resolved'].includes(status)) return res.status(400).json({ message: 'bad status' })
  await setRequestStatus(req.params.id, status)
  const rr = await getRequest(req.params.id)
  emitToUser(rr.user_id, 'request_status', { requestId: req.params.id, status })
  emitToStaff('request_status', { requestId: req.params.id, status })
  res.json({ ok: true })
})

// Delete a request: owner can delete their own, staff can delete any
router.delete('/:id', async (req, res) => {
  const r = await getRequest(req.params.id)
  if (!r) return res.status(404).json({ message: 'Not found' })
  const staff = req.user.role === 'admin' || req.user.role === 'support'
  if (r.user_id !== req.user.id && !staff)
    return res.status(403).json({ message: 'Not allowed' })
  await deleteRequest(req.params.id)
  emitToStaff('request_deleted', { id: req.params.id })
  emitToUser(r.user_id, 'request_deleted', { id: req.params.id })
  res.json({ ok: true })
})

export default router
