// What the page does beyond reading and downloading, which need none of this: the light/dark switch (theme.js
// applied the choice before the first paint), the install line's Copy button, a line for a visitor who isn't on
// a Mac, the dot under the dock's tile for where you are, views rising in once, and the film's play button.
;(() => {
  'use strict'
  const root = document.documentElement

  const toggles = document.querySelectorAll('[data-toggle-theme]')
  const showTheme = () => {
    const dark = root.dataset.theme === 'dark'
    for (const button of toggles) {
      button.hidden = false
      button.setAttribute('aria-pressed', String(dark))
      button.setAttribute('aria-label', dark ? 'Switch to light appearance' : 'Switch to dark appearance')
    }
  }
  for (const button of toggles) {
    button.addEventListener('click', () => {
      root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark'
      try {
        localStorage.setItem('petal-theme', root.dataset.theme)
      } catch {}
      showTheme()
    })
  }
  showTheme()

  if (navigator.clipboard) {
    for (const button of document.querySelectorAll('[data-copy]')) {
      button.hidden = false
      button.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(button.parentElement.querySelector('code').textContent)
          button.textContent = 'Copied'
          setTimeout(() => (button.textContent = 'Copy'), 1400)
        } catch {}
      })
    }
  }

  // An iPad says it is a Mac; it is the one with a touch screen.
  const platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || ''
  const onMac = /mac/i.test(platform) && !(navigator.maxTouchPoints > 1)
  if (!onMac) for (const line of document.querySelectorAll('[data-not-mac]')) line.hidden = false

  // The dot under a tile, as under a running app: the last part of the page whose top has passed mid-screen.
  const tiles = [...document.querySelectorAll('.dock a[href^="#"]')]
  const parts = tiles.map((tile) => document.querySelector(tile.getAttribute('href')))
  const mark = () => {
    const line = window.innerHeight * 0.5
    let current = 0
    parts.forEach((part, i) => {
      if (part.getBoundingClientRect().top <= line) current = i
    })
    tiles.forEach((tile, i) => {
      if (i === current) tile.setAttribute('aria-current', 'true')
      else tile.removeAttribute('aria-current')
    })
  }
  let frame = 0
  const onScroll = () => {
    if (frame) return
    frame = requestAnimationFrame(() => {
      frame = 0
      mark()
    })
  }
  mark()
  document.addEventListener('scroll', onScroll, { passive: true })
  window.addEventListener('resize', onScroll)

  if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const seen = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue
          entry.target.classList.add('seen')
          seen.unobserve(entry.target)
        }
      },
      { rootMargin: '0px 0px -8% 0px' },
    )
    root.classList.add('rises')
    for (const view of document.querySelectorAll('.reveal')) seen.observe(view)
  }

  // The film plays only when asked. Until then its poster carries one large button; after, the browser's own controls.
  for (const button of document.querySelectorAll('[data-play]')) {
    const video = button.parentElement.querySelector('video')
    video.controls = false
    button.hidden = false
    button.addEventListener('click', () => {
      video.controls = true
      button.hidden = true
      video.play().catch(() => {})
      video.focus()
    })
  }
})()
