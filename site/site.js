// The page's three small behaviours: the light/dark switch (theme.js applied the choice before the first
// paint), the side rail following the page, and the install line's Copy button.
;(() => {
  'use strict'
  const root = document.documentElement

  const toggles = document.querySelectorAll('[data-toggle-theme]')
  const showTheme = () => {
    const dark = root.dataset.theme === 'dark'
    for (const button of toggles) {
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

  const links = [...document.querySelectorAll('.rail a')]
  const sections = links.map((link) => document.querySelector(link.getAttribute('href'))).filter(Boolean)
  if (sections.length) {
    const mark = () => {
      const line = 96
      const atBottom = window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2
      let current = sections[0]
      if (atBottom) current = sections[sections.length - 1]
      else {
        for (const section of sections) {
          if (section.getBoundingClientRect().top <= line) current = section
        }
      }
      for (const link of links) {
        if (link.getAttribute('href') === `#${current.id}`) link.setAttribute('aria-current', 'true')
        else link.removeAttribute('aria-current')
      }
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
    window.addEventListener('hashchange', onScroll)
  }

  for (const button of document.querySelectorAll('[data-copy]')) {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(button.parentElement.querySelector('code').textContent)
        button.textContent = 'Copied'
        setTimeout(() => (button.textContent = 'Copy'), 1400)
      } catch {}
    })
  }
})()
