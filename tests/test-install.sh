#!/usr/bin/env bash
# Installer tests: keeps existing settings, safe to re-run, clean uninstall, careful with the status line,
# installs into another .claude folder (--config-dir) and warns about a second copy.
# Usage: tests/test-install.sh [sh|ps1|both]   (ps1 needs pwsh; point to it with PWSH=/path/to/pwsh)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/.."
WHICH="${1:-both}"; PWSH="${PWSH:-pwsh}"
FAILS=0; PASSES=0
ok()   { PASSES=$((PASSES+1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { FAILS=$((FAILS+1));  printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# $1 settings, $2 expected ctx hook count, $3 expected statusLine: ours|other|none
check() {
python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
want, sl_want = int(sys.argv[2]), sys.argv[3]
mark = "skills/ctx/scripts/ctx."
h = d.get("hooks", {})
n = sum(1 for ev in h for g in h[ev] for x in g.get("hooks", []) if mark in x.get("command", "").replace("\\", "/"))
assert n == want, "ctx hooks: %d, expected %d" % (n, want)
assert d.get("model") == "opus", "unrelated setting lost"
mine = [x["command"] for g in h.get("PreCompact", []) for x in g["hooks"] if "my-hook" in x["command"]]
assert mine == ["my-hook.sh"], "user's own hook lost: %r" % mine
if want:
    ss = [g for g in h["SessionStart"] if mark in g["hooks"][0]["command"].replace("\\", "/")][0]
    assert ss["matcher"] == "startup|clear|compact"
sl = d.get("statusLine")
got = "none" if sl is None else ("ours" if mark in sl.get("command", "").replace("\\", "/") and sl["command"].endswith(" statusline") else "other")
assert got == sl_want, "statusLine: %s, expected %s" % (got, sl_want)
print("ok")
PY
}

# $1 settings: number of ctx hooks registered in it
count_ctx() {
python3 - "$1" <<'PY'
import json, sys
h = json.load(open(sys.argv[1], encoding="utf-8")).get("hooks", {})
print(sum(1 for ev in h for g in h[ev] for x in g.get("hooks", []) if "skills/ctx/scripts/ctx." in x.get("command", "").replace("\\", "/")))
PY
}

suite() {
  local kind="$1" T; T="$(mktemp -d)"
  command -v cygpath >/dev/null 2>&1 && T="$(cygpath -m "$T")"   # Git Bash: give Windows python / pwsh a path they can open
  echo "== install.$kind =="
  export HOME="$T" USERPROFILE="$T"; unset CLAUDE_CONFIG_DIR
  local S="$T/.claude/settings.json"
  mkdir -p "$T/.claude"
  printf '{\n  "model": "opus",\n  "hooks": {\n    "PreCompact": [ { "hooks": [ { "type": "command", "command": "my-hook.sh" } ] } ]\n  }\n}\n' > "$S"
  inst() {
    if [ "$kind" = sh ]; then bash "$REPO/install/install.sh" "$@"
    else
      local a=(); for x in "$@"; do case "$x" in --uninstall) a+=(-Uninstall);; --root) a+=(-Root);; --statusline) a+=(-StatusLine);; --config-dir) a+=(-ConfigDir);; *) a+=("$x");; esac; done
      "$PWSH" -NoProfile -NonInteractive -File "$REPO/install/install.ps1" "${a[@]}"
    fi
  }
  inst --root "$T/vault" >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ok "install runs" || fail "install exit code $rc"
  [ -f "$T/.claude/skills/ctx/SKILL.md" ] && [ -f "$T/.claude/skills/ctx/scripts/ctx.py" ] && [ -f "$T/.claude/skills/ctx/scripts/ctx.ps1" ] && ok "skill files copied" || fail "skill files missing"
  [ -f "$T/.claude/skills/ctx-statusline/.claude-plugin/plugin.json" ] && [ -f "$T/.claude/skills/ctx-statusline/hooks/hooks.json" ] && [ -f "$T/.claude/skills/ctx-statusline/hooks/register.ts" ] && ok "desktop status line plugin copied" || fail "desktop status line plugin missing"
  r="$(check "$S" 3 ours 2>&1)"; [ "$r" = ok ] && ok "3 hooks + status line added; existing setting and hook kept" || fail "settings" "$r"
  [ -f "$S.bak-ctx" ] && ok "backup written" || fail "no backup"
  grep -q "vault" "$T/.claude/ctx/settings.json" 2>/dev/null && ok "--root applied" || fail "--root not applied"
  inst >/dev/null 2>&1
  r="$(check "$S" 3 ours 2>&1)"; [ "$r" = ok ] && ok "re-install does not duplicate" || fail "re-install" "$r"
  mkdir -p "$T/.claude/ctx/projects/x"; echo data > "$T/.claude/ctx/projects/x/ctx-001.md"
  inst --uninstall >/dev/null 2>&1
  r="$(check "$S" 0 none 2>&1)"; [ "$r" = ok ] && ok "uninstall: ctx hooks and status line removed, others kept" || fail "uninstall settings" "$r"
  [ ! -e "$T/.claude/skills/ctx" ] && ok "uninstall: skill removed" || fail "uninstall: skill still there"
  [ ! -e "$T/.claude/skills/ctx-statusline" ] && ok "uninstall: desktop status line plugin removed" || fail "uninstall: plugin still there"
  [ -f "$T/.claude/ctx/projects/x/ctx-001.md" ] && ok "uninstall: archive data kept" || fail "uninstall: data deleted!"

  python3 -c "import json;p='$S';d=json.load(open(p));d['statusLine']={'type':'command','command':'my-status.sh'};json.dump(d,open(p,'w'))"
  out="$(inst 2>&1)"
  r="$(check "$S" 3 other 2>&1)"; [ "$r" = ok ] && case "$out" in *"already have a status line"*) ok "existing status line left alone, with a note";; *) fail "no note about the status line" "$out";; esac || fail "existing status line" "$r"
  inst --uninstall >/dev/null 2>&1
  r="$(check "$S" 0 other 2>&1)"; [ "$r" = ok ] && ok "uninstall keeps a status line that is not ctx's" || fail "uninstall other status line" "$r"
  inst --statusline >/dev/null 2>&1
  r="$(check "$S" 3 ours 2>&1)"; [ "$r" = ok ] && ok "--statusline replaces it" || fail "--statusline" "$r"

  # Install into another .claude folder. The default install from above is still in place.
  V="$T/vault/.claude"; before="$(cksum < "$S")"
  out="$(inst --config-dir "$V" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && [ -f "$V/skills/ctx/SKILL.md" ] && [ -f "$V/skills/ctx/scripts/ctx.py" ] && ok "--config-dir: skill copied into that folder" || fail "--config-dir install" "$out"
  [ "$(count_ctx "$V/settings.json")" = 3 ] && ok "--config-dir: 3 hooks in that folder's settings.json" || fail "--config-dir hooks"
  [ -f "$V/skills/ctx-statusline/.claude-plugin/plugin.json" ] && ok "--config-dir: desktop status line plugin copied into that folder" || fail "--config-dir plugin"
  grep -q "$V/skills/ctx/scripts/ctx.py" "$V/skills/ctx/SKILL.md" && ! grep -q '\$HOME/.claude/skills/ctx' "$V/skills/ctx/SKILL.md" && ok "--config-dir: SKILL.md helper path points at that folder" || fail "--config-dir SKILL.md path"
  case "$out" in *WARNING*"$(basename "$T")"*settings.json*) ok "--config-dir: warns about the copy in the default folder";; *) fail "no duplicate warning" "$out";; esac
  [ "$(cksum < "$S")" = "$before" ] && ok "--config-dir: the other settings.json was not changed" || fail "the other settings.json changed"
  inst --config-dir "$V" >/dev/null 2>&1
  [ "$(count_ctx "$V/settings.json")" = 3 ] && ok "--config-dir: re-install does not duplicate" || fail "--config-dir re-install"
  inst --uninstall --config-dir "$V" >/dev/null 2>&1
  [ ! -e "$V/skills/ctx" ] && [ ! -e "$V/skills/ctx-statusline" ] && [ "$(count_ctx "$V/settings.json")" = 0 ] && ok "--config-dir: uninstall removes only that copy" || fail "--config-dir uninstall"
  [ "$(count_ctx "$S")" = 3 ] && [ -f "$T/.claude/skills/ctx/SKILL.md" ] && [ -d "$T/.claude/skills/ctx-statusline" ] && ok "--config-dir: the default install is untouched" || fail "default install disturbed"
  inst --uninstall >/dev/null 2>&1
  out="$(inst --config-dir "$V" 2>&1)"
  case "$out" in *WARNING*) fail "warned although it is the only copy" "$out";; *) ok "--config-dir: no warning when it is the only copy";; esac
  rm -rf "$T"
}

case "$WHICH" in sh) suite sh;; ps1) suite ps1;; both) suite sh; suite ps1;; esac
echo; echo "Result: $PASSES passed, $FAILS failed"; [ "$FAILS" -eq 0 ]
