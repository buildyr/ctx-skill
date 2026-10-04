#!/usr/bin/env python3
"""ctx - numbered, per-project context archive for Claude Code (macOS / Linux).

Hook modes (read Claude Code's JSON from stdin):
  check       UserPromptSubmit : past the threshold, leaves one note asking Claude to offer a handoff;
                                 below it prints nothing (zero tokens)
  save        PreCompact       : saves the conversation as ctx-NNN.md before compaction
  start       SessionStart     : clear -> loads a pending handoff, compact -> reports the archive number,
                                 startup -> reminds about cleanup when it is due
  statusline  statusLine       : one line: project, last ctx number, context fill

Tool modes (called by the skill):
  where                  active project and folder paths
  list                   context list of the active project (front matter only)
  next                   next free number
  pins                   pin list
  search [--all] WORDS   case-insensitive search in the archive (--all: every project and pins)
  pending N              the next /clear opens with ctx-N
  project NAME           select the active project when working in a root folder
  set KEY VALUE          settings.json value (window, threshold, cleanupEveryDays, archiveAgeDays, maxActive)
  add-root PATH          mark PATH as a root (vault) whose sub-folders are separate projects

ctx.ps1 implements exactly the same behaviour; apply every change to both.
"""
import datetime
import hashlib
import json
import os
import re
import sys

INT_DEFAULTS = {"window": 200000, "threshold": 70, "cleanupEveryDays": 14, "archiveAgeDays": 30, "maxActive": 10}
TAIL_BYTES = 512 * 1024
SEARCH_MAX = 40


# ---------------- helpers ----------------
def root_dir():
    if os.environ.get("CTX_HOME"):
        return os.environ["CTX_HOME"]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        return os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "ctx")
    return os.path.join(os.path.expanduser("~"), ".claude", "ctx")


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def load_settings():
    s = dict(INT_DEFAULTS)
    s["roots"] = []
    p = os.path.join(root_dir(), "settings.json")
    if os.path.exists(p):
        try:
            j = json.loads(read_text(p))
            for k in INT_DEFAULTS:
                if j.get(k) is not None:
                    s[k] = int(j[k])
            if isinstance(j.get("roots"), list):
                s["roots"] = [str(x) for x in j["roots"]]
        except Exception:
            pass
    return s


def save_settings(s):
    o = {k: s[k] for k in INT_DEFAULTS}
    o["roots"] = list(s["roots"])
    write_text(os.path.join(root_dir(), "settings.json"), json.dumps(o, ensure_ascii=False, indent=2) + "\n")


def norm(path):
    return os.path.normcase(os.path.abspath(path)).replace("\\", "/").rstrip("/")


def resolve_project(cwd, s):
    """Returns (project_name, project_folder)."""
    base = norm(os.environ.get("CLAUDE_PROJECT_DIR") or cwd or os.getcwd())
    here = norm(cwd) if cwd else base
    projects = os.path.join(root_dir(), "projects")
    for r in s["roots"]:
        rn = norm(r)
        if base == rn or base.startswith(rn + "/"):
            src = here if (here == rn or here.startswith(rn + "/")) else base
            rest = src[len(rn):].strip("/")
            seg = rest.split("/")[0] if rest else ""
            name = seg if seg and not seg.startswith(".") else None
            if not name:
                ap = os.path.join(root_dir(), ".active")
                if os.path.exists(ap):
                    name = read_text(ap).strip() or None
            name = name or "_general"
            return name, os.path.join(projects, name)
    name = re.sub(r"[^\w.-]", "_", os.path.basename(base) or "_general")
    pdir = os.path.join(projects, name)
    marker = os.path.join(pdir, ".path")
    if os.path.exists(marker) and read_text(marker).strip() != base:
        name = name + "-" + hashlib.sha1(base.encode("utf-8")).hexdigest()[:6]
        pdir = os.path.join(projects, name)
        marker = os.path.join(pdir, ".path")
    if not os.path.exists(marker):
        write_text(marker, base + "\n")
    return name, pdir


def ctx_numbers(d):
    out = []
    if os.path.isdir(d):
        for f in os.listdir(d):
            m = re.match(r"^ctx-(\d+)\.md$", f)
            if m:
                out.append(int(m.group(1)))
    return out


def max_number(pdir):
    nums = ctx_numbers(pdir)
    arch = os.path.join(pdir, "archive")
    if os.path.isdir(arch):
        for f in os.listdir(arch):
            m = re.match(r"^ctx-(\d+)", f)
            if m:
                nums.append(int(m.group(1)))
    return max(nums) if nums else 0


def front_matter(path):
    fm = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            if f.readline().strip() != "---":
                return fm
            for line in f:
                if line.strip() == "---":
                    break
                m = re.match(r"^(\w+):\s*(.*)$", line.rstrip("\n"))
                if m:
                    fm[m.group(1)] = m.group(2).strip()
    except Exception:
        pass
    return fm


def text_of(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    return "\n".join(b["text"] for b in content if isinstance(b, dict) and b.get("type") == "text" and b.get("text"))


def tail_lines(path, nbytes):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > nbytes:
            f.seek(size - nbytes)
        data = f.read()
    lines = data.decode("utf-8", errors="replace").split("\n")
    if size > nbytes:
        lines = lines[1:]  # first line is probably cut
    return lines, size > nbytes


def context_tokens(transcript):
    """Context size from the last main-conversation usage; 0 right after a compaction."""
    lines, truncated = tail_lines(transcript, TAIL_BYTES)
    for attempt in (0, 1):
        for line in reversed(lines):
            if '"compact_boundary"' in line:
                return 0
            if '"usage"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("isSidechain"):
                continue
            u = (e.get("message") or {}).get("usage")
            if not u:
                continue
            return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"))
        if not truncated or attempt:
            break
        lines, truncated = tail_lines(transcript, os.path.getsize(transcript) + 1)
    return 0


def percent(tokens, s):
    return int(round(100.0 * tokens / max(1, s["window"])))


def read_input():
    # Claude Code sends UTF-8; read bytes so the locale encoding never matters
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace").lstrip("﻿")
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def out(s=""):
    # always emit UTF-8, whatever the console code page is
    sys.stdout.buffer.write((s + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def input_cwd(inp):
    return inp.get("cwd") or (inp.get("workspace") or {}).get("current_dir")


# ---------------- hook modes ----------------
def mode_check(inp, s):
    tp = inp.get("transcript_path")
    if not tp or not os.path.exists(tp):
        return
    proj, _ = resolve_project(input_cwd(inp), s)
    tokens = context_tokens(tp)
    pct = percent(tokens, s)
    flag = os.path.join(root_dir(), ".state", "asked-" + str(inp.get("session_id", "x")))
    if pct < s["threshold"]:
        if os.path.exists(flag):
            os.remove(flag)
        return
    if os.path.exists(flag):
        return
    write_text(flag, str(pct))
    out("[ctx] Project: %s. Context is about %d%% full (%d / %d tokens). First answer the user's message, "
        "then end your reply with the 'handoff' question from the ctx skill." % (proj, pct, tokens, s["window"]))


def mode_start(inp, s):
    source = inp.get("source", "")
    proj, pdir = resolve_project(input_cwd(inp), s)

    if source == "clear":
        pending = os.path.join(pdir, ".pending")
        if not os.path.exists(pending):
            return
        try:
            num = int(read_text(pending).strip())
        finally:
            os.remove(pending)
        cid = "%03d" % num
        path = os.path.join(pdir, "ctx-%s.md" % cid)
        if not os.path.exists(path):
            return
        out("[ctx] Project: %s. This new context starts from the handoff %s/ctx-%s. Treat the record below as this "
            "session's context; in your first reply say 'ctx-%s loaded', summarise where we left off in 3-5 bullets "
            "and offer to continue with the open tasks." % (proj, proj, cid, cid))
        out()
        out(read_text(path))
        return

    if source == "compact":
        mx = max_number(pdir)
        if mx > 0:
            out("[ctx] The conversation before compaction was archived as %s/ctx-%03d. Tell the user in one line in your first reply." % (proj, mx))
        return

    if source == "startup":
        root = root_dir()
        if not os.path.isdir(root):
            return
        now = datetime.datetime.now().timestamp()
        state = os.path.join(root, ".state")
        if os.path.isdir(state):
            for f in os.listdir(state):
                fp = os.path.join(state, f)
                if os.path.getmtime(fp) < now - 7 * 86400:
                    os.remove(fp)
        today = datetime.date.today()
        stamp = os.path.join(root, ".last-cleanup")
        if not os.path.exists(stamp):
            write_text(stamp, today.isoformat())
            return
        try:
            last = datetime.date.fromisoformat(read_text(stamp).strip())
        except Exception:
            last = today
        if (today - last).days < s["cleanupEveryDays"]:
            return
        write_text(stamp, today.isoformat())
        cut = now - s["archiveAgeDays"] * 86400
        old = 0
        pr = os.path.join(root, "projects")
        if os.path.isdir(pr):
            for p in os.listdir(pr):
                a = os.path.join(pr, p, "archive")
                if os.path.isdir(a):
                    old += sum(1 for f in os.listdir(a) if os.path.getmtime(os.path.join(a, f)) < cut)
        active = len(ctx_numbers(pdir))
        if old == 0 and active < s["maxActive"]:
            return
        out("[ctx] Cleanup is due. The archive has %d files older than %d days; project %s has %d active contexts. "
            "After answering the user's first message, ask in one line whether they want to review them with '/ctx cleanup'. "
            "Never delete anything on your own." % (old, s["archiveAgeDays"], proj, active))


def mode_save(inp, s):
    tp = inp.get("transcript_path")
    if not tp or not os.path.exists(tp):
        return
    proj, pdir = resolve_project(input_cwd(inp), s)
    entries = []
    with open(tp, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.strip():
                try:
                    entries.append(json.loads(line))
                except Exception:
                    pass
    start = 0
    for i, e in enumerate(entries):
        if e.get("subtype") == "compact_boundary":
            start = i + 1
    chunks = []
    for e in entries[start:]:
        if e.get("type") not in ("user", "assistant") or e.get("isMeta") or e.get("isSidechain"):
            continue
        t = text_of((e.get("message") or {}).get("content")).strip()
        if not t or t.startswith("[ctx]"):
            continue
        if len(t) > 3000:
            t = t[:3000] + " ...[truncated]"
        who = "PREVIOUS SUMMARY" if e.get("isCompactSummary") else ("USER" if e.get("type") == "user" else "CLAUDE")
        chunks.append("### %s\n%s\n" % (who, t))
    if not chunks:
        return
    nxt = max_number(pdir) + 1
    header = ("---\nno: %d\nproject: %s\ndate: %s\ntype: auto\nstatus: active\ntitle: (raw record before %s compaction)\n"
              "summary: not summarised yet\n---\n\n") % (nxt, proj, datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
                                                       inp.get("trigger") or "unknown")
    write_text(os.path.join(pdir, "ctx-%03d.md" % nxt), header + "\n".join(chunks))


def mode_statusline(inp, s):
    proj, pdir = resolve_project(input_cwd(inp), s)
    parts = ["ctx " + proj]
    mx = max_number(pdir)
    if mx:
        parts.append("#%03d" % mx)
    if os.path.exists(os.path.join(pdir, ".pending")):
        parts.append("handoff ready")
    line = " ".join(parts)
    tp = inp.get("transcript_path")
    if tp and os.path.exists(tp):
        pct = percent(context_tokens(tp), s)
        txt = "%d%%" % pct
        if not os.environ.get("NO_COLOR"):
            color = "31" if pct >= s["threshold"] else ("33" if pct >= s["threshold"] - 10 else "32")
            txt = "\033[%sm%s\033[0m" % (color, txt)
        line += " | " + txt
    out(line)


# ---------------- tool modes ----------------
def tool_where(s):
    proj, pdir = resolve_project(None, s)
    out("project: " + proj)
    out("dir: " + pdir.replace("\\", "/"))
    out("archive: " + os.path.join(pdir, "archive").replace("\\", "/"))
    out("pins: " + os.path.join(root_dir(), "pins").replace("\\", "/"))
    out("settings: " + " ".join("%s=%d" % (k, s[k]) for k in INT_DEFAULTS))


def tool_list(s):
    proj, pdir = resolve_project(None, s)
    out("project: " + proj)
    nums = sorted(ctx_numbers(pdir))
    if not nums:
        out("(no contexts yet)")
    for n in nums:
        fm = front_matter(os.path.join(pdir, "ctx-%03d.md" % n))
        out("%03d | %s | %s | %s | %s" % (n, fm.get("date", ""), fm.get("type", ""), fm.get("title", ""), fm.get("summary", "")))
    a = os.path.join(pdir, "archive")
    out("archive: %d files" % (len(os.listdir(a)) if os.path.isdir(a) else 0))


def tool_pins():
    d = os.path.join(root_dir(), "pins")
    files = sorted(f for f in os.listdir(d) if f.endswith(".md")) if os.path.isdir(d) else []
    if not files:
        out("(no pins)")
    for f in files:
        fm = front_matter(os.path.join(d, f))
        out("%s | %s | %s" % (fm.get("name", f[:-3]), fm.get("project", ""), fm.get("description", "")))


def tool_search(s, args):
    every = "--all" in args
    words = [w.lower() for w in args if w != "--all"]
    if not words:
        sys.stderr.write("usage: search [--all] WORDS\n")
        return 2
    root = root_dir()
    dirs = []
    if every:
        pr = os.path.join(root, "projects")
        if os.path.isdir(pr):
            for p in sorted(os.listdir(pr)):
                dirs += [os.path.join(pr, p), os.path.join(pr, p, "archive")]
        dirs.append(os.path.join(root, "pins"))
    else:
        _, pdir = resolve_project(None, s)
        dirs = [pdir, os.path.join(pdir, "archive")]
    hits = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".md"):
                continue
            fp = os.path.join(d, f)
            try:
                lines = read_text(fp).split("\n")
            except Exception:
                continue
            for i, line in enumerate(lines, 1):
                low = line.lower()
                if all(w in low for w in words):
                    snip = line.strip()
                    if len(snip) > 160:
                        snip = snip[:157] + "..."
                    hits.append("%s:%d: %s" % (os.path.relpath(fp, root).replace("\\", "/"), i, snip))
    if not hits:
        out("(no matches)")
    for h in hits[:SEARCH_MAX]:
        out(h)
    if len(hits) > SEARCH_MAX:
        out("... %d more matches, narrow the search" % (len(hits) - SEARCH_MAX))
    return 0


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    args = sys.argv[2:]
    s = load_settings()
    hooks = {"check": mode_check, "save": mode_save, "start": mode_start, "statusline": mode_statusline}
    if mode in hooks:
        try:
            hooks[mode](read_input(), s)
        except Exception:
            pass  # a hook must never block Claude Code
        return 0
    if mode == "where":
        tool_where(s)
    elif mode == "list":
        tool_list(s)
    elif mode == "next":
        out(str(max_number(resolve_project(None, s)[1]) + 1))
    elif mode == "pins":
        tool_pins()
    elif mode == "search":
        return tool_search(s, args)
    elif mode == "pending" and args:
        write_text(os.path.join(resolve_project(None, s)[1], ".pending"), str(int(args[0])))
        out("ok: the next /clear opens with ctx-%03d" % int(args[0]))
    elif mode == "project" and args:
        write_text(os.path.join(root_dir(), ".active"), args[0].strip())
        out("ok: active project " + args[0].strip())
    elif mode == "set" and len(args) == 2 and args[0] in INT_DEFAULTS:
        s[args[0]] = int(args[1])
        save_settings(s)
        out("ok: %s=%s" % (args[0], args[1]))
    elif mode == "add-root" and args:
        p = norm(args[0])
        if p not in [norm(r) for r in s["roots"]]:
            s["roots"].append(p)
        save_settings(s)
        out("ok: root " + p)
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
