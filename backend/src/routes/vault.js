import { Router } from 'express'
import { auth } from '../auth-middleware.js'
import {
  listVaultItems, getVaultItem, addVaultItem, updateVaultItem, deleteVaultItem,
} from '../store.js'

const router = Router()
router.use(auth)

// list items (secrets hidden by default - only labels/usernames shown)
router.get('/', async (req, res) => {
  res.json(await listVaultItems(req.user.id, false))
})

// reveal a single item's secret + notes (explicit action)
router.get('/:id/reveal', async (req, res) => {
  const item = await getVaultItem(req.user.id, req.params.id)
  if (!item) return res.status(404).json({ message: 'Not found' })
  res.json(item)
})

router.post('/', async (req, res) => {
  const { label, account_email, username, secret, notes } = req.body || {}
  if (!label) return res.status(400).json({ message: 'Label is required' })
  const row = await addVaultItem(req.user.id, { label, account_email, username, secret, notes })
  res.json({ ok: true, id: row.id })
})

router.put('/:id', async (req, res) => {
  const { label, account_email, username, secret, notes } = req.body || {}
  await updateVaultItem(req.user.id, req.params.id, { label, account_email, username, secret, notes })
  res.json({ ok: true })
})

router.delete('/:id', async (req, res) => {
  await deleteVaultItem(req.user.id, req.params.id)
  res.json({ ok: true })
})

export default router
