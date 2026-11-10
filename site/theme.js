// Loaded in <head>, before anything is drawn, so neither flashes: light or dark (the visitor's choice,
// else their system's), and which system they're on, for the download buttons.
;(() => {
  const root = document.documentElement
  let chosen = null
  try {
    chosen = localStorage.getItem('petal-theme')
  } catch {}
  root.dataset.theme =
    chosen === 'light' || chosen === 'dark' ? chosen : matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
  const platform = `${navigator.userAgentData?.platform ?? ''} ${navigator.platform ?? ''} ${navigator.userAgent}`
  root.dataset.os = /mac|iphone|ipad/i.test(platform) ? 'mac' : /linux|x11/i.test(platform) && !/android/i.test(platform) ? 'linux' : 'other'
})()
