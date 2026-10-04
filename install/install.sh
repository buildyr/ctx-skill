#!/usr/bin/env bash
# ctx installer (macOS / Linux)
#   ./install/install.sh                    install / update
#   ./install/install.sh --root ~/vault     also mark ~/vault as a root folder
#   ./install/install.sh --statusline       replace an existing status line with ctx's
#   ./install/install.sh --config-dir ~/vault/.claude   install into another .claude folder
#   ./install/install.sh --uninstall        remove (archive data in ~/.claude/ctx is kept)
#                                           (add --config-dir to remove from that folder instead)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../skill/ctx"
DEFAULT_DIR="$HOME/.claude"
ENV_DIR="${CLAUDE_CONFIG_DIR:-}"
MODE=install; ROOT=""; FORCE_SL=0; CONFIG_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --root) ROOT="${2:?--root needs a path}"; shift ;;
    --statusline) FORCE_SL=1 ;;
    --config-dir) CONFIG_DIR="${2:?--config-dir needs a path}"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

CLAUDE_DIR="${CONFIG_DIR:-${ENV_DIR:-$DEFAULT_DIR}}"
# The archive location is decided by ctx.py itself (CLAUDE_CONFIG_DIR or ~/.claude), not by where the skill is installed.
DATA_DIR="${ENV_DIR:-$DEFAULT_DIR}/ctx"
DEST="$CLAUDE_DIR/skills/ctx"
PLUG_SRC="$HERE/../plugin/ctx-statusline"
PLUG_DEST="$CLAUDE_DIR/skills/ctx-statusline"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v python3 >/dev/null || { echo "python3 not found; ctx needs python3." >&2; exit 1; }
mkdir -p "$CLAUDE_DIR"

update_settings() { # $1 = install|uninstall
python3 - "$SETTINGS" "$DEST/scripts/ctx.py" "$1" "$FORCE_SL" <<'PY'
import json, os, shutil, sys
path, script, mode, force_sl = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        txt = f.read().strip()
    data = json.loads(txt) if txt else {}
    shutil.copyfile(path, path + ".bak-ctx")
MARK = "skills/ctx/scripts/ctx."
ours = lambda cmd: MARK in (cmd or "").replace("\\", "/")
hooks = data.setdefault("hooks", {})
for ev in list(hooks):
    hooks[ev] = [g for g in hooks[ev] if not any(ours(h.get("command")) for h in g.get("hooks", []))]
    if not hooks[ev]:
        del hooks[ev]
sl = data.get("statusLine")
sl_ours = isinstance(sl, dict) and ours(sl.get("command"))
note = ""
if mode == "install":
    cmd = lambda m: 'python3 "%s" %s' % (script, m)
    hooks.setdefault("UserPromptSubmit", []).append({"hooks": [{"type": "command", "command": cmd("check")}]})
    hooks.setdefault("PreCompact", []).append({"hooks": [{"type": "command", "command": cmd("save")}]})
    hooks.setdefault("SessionStart", []).append({"matcher": "startup|clear|compact", "hooks": [{"type": "command", "command": cmd("start")}]})
    if sl is None or sl_ours or force_sl:
        data["statusLine"] = {"type": "command", "command": cmd("statusline"), "padding": 0}
    else:
        note = "You already have a status line, so it was left alone. Re-run with --statusline to use ctx's."
elif sl_ours:
    del data["statusLine"]
if not hooks:
    del data["hooks"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
if note:
    print(note)
PY
}

# Claude Code merges hooks from every settings.json it reads, so ctx registered in two places runs twice.
# Look at the places this machine is known to use (default folder, CLAUDE_CONFIG_DIR, each ctx root's .claude) and only warn.
warn_duplicates() {
python3 - "$CLAUDE_DIR" "$DEFAULT_DIR" "$ENV_DIR" "$DATA_DIR/settings.json" "$ROOT" <<'PY'
import json, os, re, sys
here, default, env, cs, root = sys.argv[1:6]
norm = lambda p: os.path.abspath(os.path.expanduser(p)).replace("\\", "/").rstrip("/").lower()
cands = [default] + ([env] if env else [])
try:
    with open(cs, encoding="utf-8") as f:
        cands += [os.path.join(r, ".claude") for r in json.load(f).get("roots", []) if r]
except Exception:
    pass
if root:
    cands.append(os.path.join(root, ".claude"))
seen = {norm(here)}
for c in cands:
    n = norm(c)
    if n in seen:
        continue
    seen.add(n)
    f = os.path.join(os.path.expanduser(c), "settings.json")
    try:
        with open(f, encoding="utf-8") as fh:
            has = re.search(r"skills[/\\]+ctx[/\\]+scripts[/\\]+ctx\.", fh.read())
    except Exception:
        has = None
    if has:
        print("")
        print("WARNING: ctx hooks are also registered in %s." % f)
        print("  Claude Code merges both files, so every ctx hook would run twice. Nothing was changed there.")
        print('  To remove that copy: ./install/install.sh --uninstall --config-dir "%s"' % c)
PY
}

if [ "$MODE" = uninstall ]; then
  [ -f "$SETTINGS" ] && update_settings uninstall
  rm -rf "$DEST" "$PLUG_DEST"
  echo "ctx removed from $CLAUDE_DIR. Its hooks and status line were taken out of settings.json (backup: settings.json.bak-ctx)."
  echo "Your archive is still in $DATA_DIR; delete it by hand if you no longer need it."
  exit 0
fi

rm -rf "$DEST"; mkdir -p "$DEST"
cp -R "$SRC/." "$DEST/"
chmod +x "$DEST/scripts/ctx.py"

# Status line for the desktop app (a plugin Claude Code loads from the skills folder; quiet in the terminal).
rm -rf "$PLUG_DEST"; mkdir -p "$PLUG_DEST"
cp -R "$PLUG_SRC/." "$PLUG_DEST/"

# SKILL.md ships with the default location in its helper commands; point the installed copy at where it really is.
if [ "$DEST" != "$DEFAULT_DIR/skills/ctx" ]; then
  python3 - "$DEST/SKILL.md" "$DEST" <<'PY'
import sys
p, real = sys.argv[1], sys.argv[2].replace("\\", "/")
with open(p, encoding="utf-8") as f:
    t = f.read()
with open(p, "w", encoding="utf-8", newline="") as f:
    f.write(t.replace("$HOME/.claude/skills/ctx", real))
PY
fi

update_settings install
[ -n "$ROOT" ] && python3 "$DEST/scripts/ctx.py" add-root "$ROOT"

echo "ctx installed:"
echo "  skill    : $DEST"
echo "  desktop status line plugin: $PLUG_DEST"
echo "  settings : $SETTINGS (backup: settings.json.bak-ctx)"
echo "  data     : $DATA_DIR"
warn_duplicates
echo ""
echo "Restart Claude Code, check with /hooks, then use /ctx."
