import { theme } from 'antd'

const base = {
  token: {
    colorPrimary: '#2563eb',
    borderRadius: 10,
    fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
  },
}

export function makeTheme(mode) {
  if (mode === 'dark') {
    return {
      ...base,
      algorithm: theme.darkAlgorithm,
      components: { Layout: { siderBg: '#0b1120', headerBg: '#0f172a', bodyBg: '#020617' } },
    }
  }
  return {
    ...base,
    components: { Layout: { siderBg: '#0f172a', headerBg: '#ffffff', bodyBg: '#f1f5f9' } },
  }
}
