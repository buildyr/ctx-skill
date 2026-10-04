import type { Register } from 'claude-code'

// ctx status line for surfaces that do not draw Claude Code's own `statusLine` (the desktop app).
// In the terminal the settings.json status line already shows it, so this stays quiet there.

async function refresh($: any, cwd: string) {
  try {
    const cfg = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${(await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME'))}/.claude`
    let window = 200000
    try {
      const w = Number(JSON.parse(await $.fs.read(`${cfg}/ctx/settings.json`)).window)
      if (w > 0) window = w
    } catch {}
    const { context } = await $.session.usage()
    const pct = Math.round(((context.tokens ?? 0) / window) * 100)
    const parts = cwd.split(String.fromCharCode(92)).join('/').split('/').filter((p: string) => p !== '')
    const name = parts.length > 0 ? parts[parts.length - 1] : 'ctx'
    $.ui.status(`ctx ${name} | ${pct}%`)
  } catch {}
}

export const register: Register = on => {
  let cwd = ''
  let isQuiet = false

  on('session.start', async ($, e, next) => {
    cwd = e.cwd
    isQuiet = e.surface === 'terminal'
    const r = await next(e)
    if (!isQuiet) await refresh($, cwd)
    return r
  })

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (!isQuiet) await refresh($, cwd)
    return r
  })
}
