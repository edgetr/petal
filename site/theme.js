// Every page loads this in <head>: the theme chosen with the top bar's switch (or the system's)
// and the visitor's system are set before anything is drawn, so neither flashes.
;(() => {
  const root = document.documentElement
  let chosen = null
  try {
    chosen = localStorage.getItem('petal-theme')
  } catch {}
  if (chosen === 'light' || chosen === 'dark') root.dataset.theme = chosen
  root.dataset.shown = chosen ?? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
  const platform = `${navigator.userAgentData?.platform ?? ''} ${navigator.platform ?? ''} ${navigator.userAgent}`
  root.dataset.os = /win/i.test(platform) ? 'windows' : /mac|iphone|ipad/i.test(platform) ? 'mac' : 'linux'
})()

// The switch: light or dark, kept for the next visit.
document.addEventListener('DOMContentLoaded', () => {
  const root = document.documentElement
  document.getElementById('theme')?.addEventListener('click', () => {
    const next = root.dataset.shown === 'dark' ? 'light' : 'dark'
    root.dataset.theme = next
    root.dataset.shown = next
    try {
      localStorage.setItem('petal-theme', next)
    } catch {}
  })
})
