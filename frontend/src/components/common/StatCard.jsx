import { Card, Statistic } from 'antd'

export default function StatCard({ title, value, prefix, contentStyle }) {
  return (
    <Card>
      <Statistic title={title} value={value} prefix={prefix} styles={{ content: contentStyle }} />
    </Card>
  )
}