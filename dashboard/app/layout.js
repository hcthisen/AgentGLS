import './globals.css'

export const metadata = {
  title: 'AgentGLS Dashboard',
  description: 'Security and health monitoring for AgentGLS',
}

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
