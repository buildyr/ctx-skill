---
name: ctx
description: Numbered, per-project context archive with cross-project pins. Hands off to a clean context when the window fills, saves, lists, searches, pulls information from earlier contexts, merges, pins and cleans up with approval. Use when the user types /ctx, when a hook note starting with "[ctx]" arrives, or when the user asks things like "what was in context 2", "bring back X from the earlier context", "search the archive for X", "pin this structure", "load the X structure from the other project" (in any language, e.g. Turkish "2. context'te ne vardı", "şu yapıyı pinle").
---

# ctx — per-project context archive

Goal: lower token cost by handing long contexts off early and cleanly, and by never loading anything that is not needed.
User argument: `$ARGUMENTS` (if empty or not substituted, take the command from the message; with no command, run `list`).
Reply in the user's language.

## Helper: `CTX`
Never guess paths, numbers or listings; ask this helper. Wherever this file says `CTX <mode>`, run the one for your platform with Bash:
- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.claude/skills/ctx/scripts/ctx.ps1" <mode>`
- macOS / Linux: `python3 "$HOME/.claude/skills/ctx/scripts/ctx.py" <mode>`

| Mode | Output / effect |
|---|---|
| `where` | `project`, `dir` (active project's archive), `archive`, `pins`, `settings` |
| `list` | `NNN \| date \| type \| title \| summary` rows plus the archive count |
| `next` | next free number |
| `pins` | `name \| project \| description` rows |
| `search [--all] WORDS` | `path:line: text` hits; all words must match; `--all` covers every project and the pins |
| `pending N` | the next `/clear` opens with ctx-N |
| `project NAME` | selects the active project when working in a root folder |
| `set KEY VALUE` | `window`, `threshold`, `cleanupEveryDays`, `archiveAgeDays`, `maxActive` |
| `add-root PATH` | marks PATH as a root (vault) whose sub-folders are separate projects |

Run `CTX where` the first time you need it in a session and reuse the result. Below, `<dir>`, `<archive>` and `<pins>` are the paths from that output; `search` paths are relative to the ctx data root (the parent of `projects/`).

## Golden rule: nothing is deleted without approval
No file or content is deleted or overwritten unless the user explicitly approves. When files are merged or tidied, the originals are **moved** to `<archive>`. Permanent deletion happens only in `cleanup`, and only for the files the user picks.

## Token rules
- Use `CTX list` / `CTX pins` / `CTX search` instead of opening files to find things.
- Do not load any context or pin unless the user asks or the task needs it.
- Keep summaries short (aim for 40-80 lines). Do not copy code; give file paths and function names, and read the file when needed.
- Never load a raw automatic record (`type: auto`) in full; offer `summarize` first.

## File format
```
---
no: 7
project: <project>
date: YYYY-MM-DD HH:MM
type: auto | manual | merged
status: active
title: short title
summary: one line
sources: [2, 3]     # merged only
---
```
Body sections: **Goal**, **Decisions** (with reasons), **Done** (with file paths), **Tried and failed**, **Open tasks**, **Key facts**. Leave out empty sections. Write the body in the user's language.
New file name: `<dir>/ctx-NNN.md`, where NNN is the three-digit form of `CTX next`.

## Commands
Turkish aliases are in brackets; accept either.

### `list` [liste]
Show `CTX list` as a short table.

### `show N` [goster]
Read `<dir>/ctx-NNN.md` and summarise it. Give the raw text if the user asks for all of it.

### `save [title]` [kaydet]
Write the current session in the format above under the next number (`type: manual`). Confirm the number in one line.

### `handoff` [devir]
When a hook note "[ctx] ... full" arrives: answer the actual message first, then end with one question: "Context is X% full. Shall I archive this session and continue in a clean context?" The user can also trigger this any time with `/ctx handoff`.
If yes:
1. Do `save`.
2. Run `CTX pending <no>`.
3. Say: "Saved as ctx-NNN. Type `/clear` and the new context will open with it." (You cannot start the new session yourself.)
If no: do not ask again in this session. If they say "don't ask, just do it": for the rest of this session do steps 1-3 without asking when the note arrives.
When a note "[ctx] This new context starts from the handoff ..." arrives, the record is now the context: say "ctx-NNN loaded", summarise where you left off in 3-5 bullets and continue with the open tasks.

### `switch N` [gec]
If the current session has anything worth keeping, offer `save` first. Then run `CTX pending N` and say "Type `/clear` and it will open with ctx-N". For reopening a whole earlier session word for word, suggest Claude Code's `/resume`; ctx files are summaries.

### `pull N [topic]` [al]
Use for requests like "what was in context 2" or "bring back the API decision from 3".
1. Read the file (look in `<archive>` if it was archived). With a topic, extract only that part. Without one, give a numbered list of 4-8 items and ask which to take.
2. Fold the chosen items into the current work, flag anything that conflicts or is outdated, then continue. Do not touch the old file.

### `search WORDS` [ara]
Run `CTX search WORDS` (add `--all` when the user wants every project and the pins). Show the hits grouped by file, then offer `pull` for the relevant one. Do not open files just to search.

### `summarize N` [ozetle]
Turn a raw automatic record into the summary format and show the draft. On approval, move the raw file to `<archive>/ctx-NNN-raw.md` and write the summary as `<dir>/ctx-NNN.md`.

### `merge N M ...` [birlestir]
1. Read the files and write one combined summary: collapse duplicates, prefer the newest on conflicts, drop what no longer holds.
2. Show the draft and, in 2-3 bullets, what was dropped. **Wait for approval.**
3. On approval write the new number (`type: merged`, `sources`) and move the source files to `<archive>` without deleting them.

### `tidy N` [temizle]
Remove clutter from one file and show the draft. On approval move the old version to `<archive>/ctx-NNN-old.md` and write the new one under the same number.

### `cleanup` [temizlik]
Use when the "[ctx] Cleanup is due" note arrives or the user asks.
1. List the files in `<archive>` (name, date, title); if there are many active contexts, suggest merge candidates.
2. Let the user pick what to delete ("all", "1-5", "none").
3. Delete only those and list what was deleted. With no choice, delete nothing.

### `pin <name> [what]`
Save an important structure or feature of the current project (architecture, auth flow, design system, API schema…) for use in other projects as `<pins>/<name>.md`:
```
---
name: <name>
project: <project>
description: one-line description (shown in listings)
date: YYYY-MM-DD
---
```
Body of at most ~60 lines: what it is, how it works, key file paths (absolute) and interfaces, dependencies, gotchas. Do not copy code. Ask before overwriting an existing pin with the same name.

### `pins` [pinler]
Show `CTX pins`.

### `pin-load <name>` [pin-al]
Read the pin and use it as context. When the user mentions a structure from another project, check `CTX pins` first; if there is a match load only that pin, otherwise say there is no pin and do not scan the other project's files.

### `threshold P` [limit] / `window T` [pencere] / `project NAME` [proje] / `root PATH` [kok]
- `threshold P` → `CTX set threshold P` (handoff question at P% full)
- `window T` → `CTX set window T` (context window size; 1000000 for 1M-context models)
- `project NAME` → `CTX project NAME` (active project when working in a root folder)
- `root PATH` → `CTX add-root PATH` (a vault-like folder whose sub-folders are separate projects)
Changes apply from the next message.
