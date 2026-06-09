import client from '../api/client'

export const dnsLookup  = (domain) => client.get('/api/tools/dns', { params: { domain } }).then(r => r.data)
export const dkimLookup = (domain, selector) =>
  client.get('/api/tools/dkim', { params: { domain, selector } }).then(r => r.data)
