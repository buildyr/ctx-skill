# Changelog

## 0.1.0 — unreleased
- Per-project numbered context archive; threshold question and handoff via `/clear`; PreCompact backup.
- Status line: project, last context number and colour-coded fill.
- Archive search (`/ctx search`, `--all` for every project and the pins).
- Cross-project pins (`/ctx pin`, `/ctx pin-load`).
- Nothing deleted without approval: merge and tidy move originals to the archive; `/ctx cleanup` deletes only what you pick; periodic cleanup reminder.
- Root-folder (vault) support; projects with the same folder name are kept apart.
- Two equivalent implementations, Windows (PowerShell 5.1+) and macOS / Linux (Python 3); install and uninstall scripts; test suites.
- Turkish command aliases and a Turkish README.
- UTF-8 hook and helper I/O on Windows PowerShell 5.1, so non-ASCII text and folder names survive.
- Desktop app status line: the `ctx-statusline` plugin (`plugin/ctx-statusline`) shows the project and context fill where the `statusLine` setting is not drawn; the installers copy it to `skills/ctx-statusline` and the uninstallers remove it. Quiet in the terminal.
- Windows smoke test (`tests/smoke.ps1`), end-to-end checklist (`TESTING.md`) and a bug report template.
