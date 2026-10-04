# Testing ctx

There are three levels. The first two never touch your real Claude Code setup.

## 1. Automated tests (macOS / Linux, or Git Bash)

```bash
tests/run-tests.sh both      # hooks, status line, search, helper modes, UTF-8 (50 scenarios × 2 implementations)
tests/test-install.sh both   # install / re-install / uninstall / status line handling, --config-dir and the duplicate-install warning
```
`both` runs the Python and the PowerShell implementation; use `python` or `pwsh` for one. The PowerShell runs need `pwsh` (`PWSH=/path/to/pwsh`).

On Windows, run these from Git Bash with a real Python behind the name `python3`. The Microsoft Store shortcut of that name does not work; a bash function is enough:
```bash
python3() { "C:/Python314/python.exe" "$@"; }; export -f python3
```

## 2. Windows smoke test

```powershell
powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
```
Runs in a temporary sandbox with Windows PowerShell 5.1 (the version Claude Code's hooks use on Windows):
- the hooks, the status line, search and a full handoff, including Turkish (non-ASCII) folder names and text;
- the hook's run time, which is added to every message you send;
- the installer against a **copy** of your `~/.claude/settings.json`: it checks that your hooks, settings and status line survive, that a second install adds nothing, and that uninstall restores the file exactly. If ctx is already installed on your machine, its own hooks are stripped from the copy first so the checks start from a clean baseline;
- installing into another `.claude` folder with `-ConfigDir`: the skill, hooks and `SKILL.md` path land in that folder only, a second copy elsewhere produces a warning and is left untouched, and `-Uninstall -ConfigDir` removes just the folder you name.

Your real `~/.claude` folder is not written to. Run it with `pwsh` too if you use PowerShell 7.

## 3. End-to-end in Claude Code

Install (see the README), restart Claude Code, then work through this list in a throwaway folder. If you installed with `-ConfigDir` / `--config-dir`, open Claude Code in a project that reads that `.claude` folder, and install ctx in **one** place only (a second copy makes every hook run twice; the installer warns about it).

| # | Do | Expect |
|---|---|---|
| 1 | `/hooks` | `UserPromptSubmit`, `PreCompact` and `SessionStart` each list a ctx hook |
| 2 | Look at the status line | `ctx <folder name>` and, after the first reply, a percentage |
| 3 | `/ctx window 30000` | Shrinks the assumed window so the threshold is reached in a few messages (check that the percentage jumps) |
| 4 | Send a message | Claude answers, then asks whether to archive and continue clean (once) |
| 5 | Say yes | "Saved as ctx-001 … type /clear"; the status line shows `handoff ready` |
| 6 | `/clear` | The new session starts with "ctx-001 loaded" and a short recap |
| 7 | `/ctx` | The list shows ctx-001 |
| 8 | `/ctx search <a word from the session>` | Hits with file and line; no files opened |
| 9 | `/ctx pull 1` | A numbered list of items to bring back |
| 10 | `/ctx save`, then `/ctx merge 1 2` | A draft and a request for approval; after approval the originals are in `archive/` |
| 11 | `/compact` | One line saying the conversation was archived as ctx-NNN |
| 12 | `/ctx pin test-pin`, then `/ctx pins` in another folder | The pin is listed; `/ctx pin-load test-pin` loads it |
| 13 | `/ctx window 200000` (or `1000000`) | Back to your real window size |

Remove the test data afterwards from `~/.claude/ctx/projects/<folder name>` and `~/.claude/ctx/pins/test-pin.md`.

## Rolling back

```powershell
powershell -ExecutionPolicy Bypass -File install\install.ps1 -Uninstall
```
```bash
./install/install.sh --uninstall
```
If you installed into another folder, add `-ConfigDir <folder>` (Windows) or `--config-dir <folder>` (macOS / Linux) to remove that copy.

The installer also leaves `settings.json.bak-ctx` next to your settings: the file exactly as it was before the last install or uninstall.

## Reporting a problem

Open an issue with the bug report template. The most useful details are your OS, `claude --version`, your PowerShell or Python version and the output of the helper's `where` mode.
