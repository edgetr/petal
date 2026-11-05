// The homepage: sections rise in, the side rail follows the page, the install
// line copies, and the dock sample is drawn. Quiet for reduced motion.
;(() => {
  'use strict'
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
  if (!still) document.documentElement.classList.add('motion')

  const reveal = () => {
    const nodes = [...document.querySelectorAll('.reveal')]
    if (still || !nodes.length) {
      nodes.forEach((node) => node.classList.add('shown'))
      return
    }
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        entry.target.classList.add('shown')
        observer.unobserve(entry.target)
      }
    }, { threshold: 0.18 })
    nodes.forEach((node) => observer.observe(node))
  }

  const rail = () => {
    const links = [...document.querySelectorAll('.section-rail a')]
    const sections = links.map((link) => document.querySelector(link.getAttribute('href'))).filter(Boolean)
    if (!sections.length) return
    const mark = () => {
      const line = window.innerHeight * 0.34
      let current = sections[0]
      for (const section of sections) {
        if (section.getBoundingClientRect().top <= line) current = section
      }
      if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4) current = sections.at(-1)
      for (const link of links) {
        if (link.getAttribute('href') === `#${current.id}`) link.setAttribute('aria-current', 'true')
        else link.removeAttribute('aria-current')
      }
    }
    mark()
    addEventListener('scroll', mark, { passive: true })
    addEventListener('resize', mark)
  }

  const copy = () => {
    for (const button of document.querySelectorAll('[data-copy]')) {
      button.addEventListener('click', async () => {
        const text = button.parentElement.querySelector('code').textContent
        try {
          await navigator.clipboard.writeText(text)
          button.textContent = 'Copied'
          setTimeout(() => (button.textContent = 'Copy'), 1400)
        } catch {}
      })
    }
  }

  // ── The dock: one static sample, drawn once ──
  const icon = {
    term: '<path d="M5 8l4 4-4 4M12 16h6"/>',
    web: '<circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c3 3 3 13 0 16M12 4c-3 3-3 13 0 16"/>',
    code: '<path d="M9 5c-3 0-2 7-4 7 2 0 1 7 4 7M15 5c3 0 2 7 4 7-2 0-1 7-4 7"/>',
    spark: '<path d="M12 4l2 6 6 2-6 2-2 6-2-6-6-2 6-2z"/>',
  }
  const building = [['term', '#2b2b3a', 1], ['web', '#4a6cf0', 1, 2], ['code', '#4b3db0', 0], ['spark', '#e7743f', 0]]

  const dock = () => {
    const spec = document.getElementById('dockspec')
    const apps = document.getElementById('apps')
    if (!spec || !apps) return
    spec.style.setProperty('--mode', '#b18cff')
    apps.innerHTML = building.map(([name, bg, run, badge]) =>
      `<span class="tile${run ? ' run' : ''}" style="--bg:${bg}"><svg viewBox="0 0 24 24">${icon[name]}</svg>${badge ? `<i class="badge">${badge}</i>` : ''}</span>`).join('')
  }

  reveal()
  rail()
  copy()
  dock()
})()
