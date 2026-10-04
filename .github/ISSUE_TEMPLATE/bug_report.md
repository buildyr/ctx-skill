---
name: Bug report
about: Something in ctx doesn't work as described
labels: bug
---

**What happened**
<!-- What you did, what you expected and what you got instead. -->

**Environment**
- OS:
- Claude Code version (`claude --version`):
- Windows: PowerShell version (`$PSVersionTable.PSVersion`):
- macOS / Linux: Python version (`python3 --version`):

**Output of the `where` mode**
<!--
Windows:      powershell -NoProfile -File "$HOME/.claude/skills/ctx/scripts/ctx.ps1" where
macOS/Linux:  python3 "$HOME/.claude/skills/ctx/scripts/ctx.py" where
Installed with -ConfigDir / --config-dir? Use that folder instead of $HOME/.claude, and say where you installed it.
-->
```
```

**Smoke test result (Windows)**
<!-- Output of: powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -->

**Anything else**
<!-- If the handoff question or the status-line percentage stopped appearing after a Claude Code update, say which version you updated from. Please remove anything private from logs and transcripts before pasting. -->
