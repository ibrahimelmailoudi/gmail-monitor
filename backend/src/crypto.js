import crypto from 'crypto'
import { config } from './config.js'

const KEY = Buffer.from(config.encryptionKey, 'hex')

// Encrypts an object -> compact string "iv:tag:ciphertext" (all hex/base64)
export function encrypt(obj) {
  if (KEY.length !== 32) throw new Error('ENCRYPTION_KEY must be 64 hex chars (32 bytes)')
  const iv = crypto.randomBytes(12)
  const cipher = crypto.createCipheriv('aes-256-gcm', KEY, iv)
  const data = Buffer.concat([cipher.update(JSON.stringify(obj), 'utf8'), cipher.final()])
  const tag = cipher.getAuthTag()
  return [iv.toString('base64'), tag.toString('base64'), data.toString('base64')].join(':')
}

export function decrypt(blob) {
  const [iv, tag, data] = blob.split(':').map(p => Buffer.from(p, 'base64'))
  const decipher = crypto.createDecipheriv('aes-256-gcm', KEY, iv)
  decipher.setAuthTag(tag)
  const out = Buffer.concat([decipher.update(data), decipher.final()])
  return JSON.parse(out.toString('utf8'))
}
