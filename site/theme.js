// Loaded in <head>, before anything is drawn, so it never flashes: light or dark (the visitor's choice,
// else their system's).
;(() => {
  const root = document.documentElement
  let chosen = null
  try {
    chosen = localStorage.getItem('petal-theme')
  } catch {}
  root.dataset.theme =
    chosen === 'light' || chosen === 'dark' ? chosen : matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
})()
