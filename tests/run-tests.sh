#!/usr/bin/env bash
# ctx test suite. Usage: tests/run-tests.sh [python|pwsh|both]   (default: both)
# Point to a specific PowerShell with PWSH=/path/to/pwsh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../skill/ctx/scripts"
WHICH="${1:-both}"
PWSH="${PWSH:-pwsh}"
FAILS=0; PASSES=0

ok()   { PASSES=$((PASSES+1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { FAILS=$((FAILS+1));  printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
has()  { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

# $1 file, $2 last usage total, $3 trailing compact_boundary (0/1), $4 filler KB placed before ($5=before) or after ($5=after) the usage line
make_transcript() {
python3 - "$1" "$2" "$3" "${4:-0}" "${5:-before}" <<'PY'
import json, sys
path, total, boundary, filler_kb, where = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", int(sys.argv[4]), sys.argv[5]
L = []
L.append({"type": "user", "message": {"role": "user", "content": "old topic before the boundary"}})
L.append({"type": "system", "subtype": "compact_boundary"})
L.append({"type": "user", "isCompactSummary": True, "message": {"role": "user", "content": "Previous summary: login screen done"}})
L.append({"type": "user", "message": {"role": "user", "content": "Let's add the signup form"}})
L.append({"type": "user", "isMeta": True, "message": {"role": "user", "content": "meta line, must not be saved"}})
L.append({"type": "user", "message": {"role": "user", "content": "[ctx] hook note, must not be saved"}})
L.append({"type": "assistant", "isSidechain": True, "message": {"role": "assistant", "content": [{"type": "text", "text": "subagent text, must not be saved"}],
          "usage": {"input_tokens": 999999}}})
filler = [{"type": "progress", "data": "x" * 1000} for _ in range(filler_kb)]
if where == "before":
    L += filler
L.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Added the form: src/signup.tsx"}, {"type": "tool_use", "name": "Write"}],
          "usage": {"input_tokens": 10, "cache_read_input_tokens": total - 60, "cache_creation_input_tokens": 0, "output_tokens": 50}}})
L.append({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "tool output"}]}})
if where == "after":
    L += filler
if boundary:
    L.append({"type": "system", "subtype": "compact_boundary"})
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(json.dumps(x, ensure_ascii=False) for x in L) + "\n")
PY
}

run_suite() {
  local impl="$1"
  local T; T="$(mktemp -d)"
  export CTX_HOME="$T/ctxhome" NO_COLOR=1
  unset CLAUDE_PROJECT_DIR
  local P="$T/work/klarhim"; mkdir -p "$P"
  local TR="$T/tr.jsonl"
  run() {
    if [ "$impl" = python ]; then python3 "$SCRIPTS/ctx.py" "$@"
    else "$PWSH" -NoProfile -NonInteractive -File "$SCRIPTS/ctx.ps1" "$@"; fi
  }
  hookin() { printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","source":"%s","trigger":"auto"}' "$TR" "$P" "${1:-}"; }
  echo "== $impl =="
  cd "$P" || return
  local D="$CTX_HOME/projects/klarhim"

  # --- check ---
  make_transcript "$TR" 100000 0
  out="$(hookin | run check)"; [ -z "$out" ] && ok "check: silent below threshold (50%)" || fail "check: silent below threshold" "$out"
  make_transcript "$TR" 150000 0
  out="$(hookin | run check)"; has "$out" "75% full" && has "$out" "Project: klarhim" && ok "check: note above threshold (75%)" || fail "check: note above threshold" "$out"
  out="$(hookin | run check)"; [ -z "$out" ] && ok "check: asks only once per session" || fail "check: must not ask twice" "$out"
  make_transcript "$TR" 150000 1
  out="$(hookin | run check)"; [ -z "$out" ] && [ ! -e "$CTX_HOME/.state/asked-s1" ] && ok "check: resets after compaction" || fail "check: reset after compaction" "$out"
  make_transcript "$TR" 150000 0 700 after
  out="$(printf '{"session_id":"big1","transcript_path":"%s","cwd":"%s"}' "$TR" "$P" | run check)"; has "$out" "75% full" && ok "check: large transcript, usage before the tail (fallback)" || fail "check: large transcript fallback" "$out"
  make_transcript "$TR" 150000 0 700 before
  out="$(printf '{"session_id":"big2","transcript_path":"%s","cwd":"%s"}' "$TR" "$P" | run check)"; has "$out" "75% full" && ok "check: large transcript, usage in the tail" || fail "check: large transcript tail" "$out"

  # --- save ---
  make_transcript "$TR" 150000 0
  hookin | run save
  f="$D/ctx-001.md"
  if [ -f "$f" ]; then
    c="$(cat "$f")"
    has "$c" "no: 1" && has "$c" "project: klarhim" && has "$c" "type: auto" && ok "save: ctx-001 with front matter" || fail "save: front matter" "$c"
    has "$c" "Let's add the signup form" && has "$c" "Added the form" && has "$c" "PREVIOUS SUMMARY" && ok "save: conversation text captured" || fail "save: text missing"
    if has "$c" "old topic" || has "$c" "meta line" || has "$c" "hook note" || has "$c" "subagent" || has "$c" "tool output"; then fail "save: unwanted lines included" "$c"; else ok "save: pre-boundary/meta/[ctx]/subagent/tool output excluded"; fi
  else fail "save: ctx-001 not created"; fi
  [ -s "$D/.path" ] && ok "save: project path recorded" || fail "save: .path missing"
  hookin | run save
  [ -f "$D/ctx-002.md" ] && ok "save: second record is ctx-002" || fail "save: ctx-002 missing"
  [ "$(run next)" = "3" ] && ok "next: 3" || fail "next" "$(run next)"

  # --- list / where ---
  out="$(run list)"; has "$out" "001 |" && has "$out" "002 |" && has "$out" "project: klarhim" && ok "list: two records" || fail "list" "$out"
  out="$(run where)"; has "$out" "project: klarhim" && has "$out" "threshold=70" && ok "where" || fail "where" "$out"

  # --- start ---
  run pending 1 >/dev/null
  out="$(hookin clear | run start)"; has "$out" "ctx-001 loaded" && has "$out" "Let's add the signup form" && ok "start clear: handoff loaded" || fail "start clear" "$out"
  out="$(hookin clear | run start)"; [ -z "$out" ] && ok "start clear: pending is single-use" || fail "start clear: must not load again" "$out"
  out="$(hookin compact | run start)"; has "$out" "klarhim/ctx-002" && ok "start compact: number reported" || fail "start compact" "$out"

  mkdir -p "$D/archive"; mv "$D/ctx-002.md" "$D/archive/"
  [ "$(run next)" = "3" ] && ok "next: archived numbers are never reused" || fail "next archive" "$(run next)"

  rm -f "$CTX_HOME/.last-cleanup"
  out="$(hookin startup | run start)"; [ -z "$out" ] && [ -f "$CTX_HOME/.last-cleanup" ] && ok "start startup: silent first time, stamp created" || fail "start startup first" "$out"
  out="$(hookin startup | run start)"; [ -z "$out" ] && ok "start startup: silent before it is due" || fail "start startup early" "$out"
  python3 -c "import datetime,os;open('$CTX_HOME/.last-cleanup','w').write((datetime.date.today()-datetime.timedelta(days=20)).isoformat());t=(datetime.datetime.now()-datetime.timedelta(days=40)).timestamp();os.utime('$D/archive/ctx-002.md',(t,t))"
  out="$(hookin startup | run start)"; has "$out" "Cleanup is due" && has "$out" "has 1 files" && ok "start startup: cleanup reminder" || fail "start startup cleanup" "$out"
  [ -f "$D/archive/ctx-002.md" ] && ok "cleanup: nothing deleted automatically" || fail "cleanup: a file was deleted!"
  out="$(hookin startup | run start)"; [ -z "$out" ] && ok "start startup: reminds once per period" || fail "start startup repeat" "$out"

  # --- statusline ---
  make_transcript "$TR" 150000 0
  out="$(printf '{"session_id":"s9","transcript_path":"%s","workspace":{"current_dir":"%s"}}' "$TR" "$P" | run statusline)"
  [ "$out" = "ctx klarhim #002 | 75%" ] && ok "statusline: project, number, fill" || fail "statusline" "$out"
  run pending 1 >/dev/null
  out="$(printf '{"transcript_path":"%s","cwd":"%s"}' "$TR" "$P" | run statusline)"; has "$out" "handoff ready" && ok "statusline: shows pending handoff" || fail "statusline pending" "$out"
  rm -f "$D/.pending"
  out="$(printf '{"cwd":"%s"}' "$P" | run statusline)"; [ "$out" = "ctx klarhim #002" ] && ok "statusline: no transcript yet" || fail "statusline no transcript" "$out"
  out="$(printf '{"transcript_path":"%s","cwd":"%s"}' "$TR" "$P" | NO_COLOR= run statusline)"; has "$out" $'\033[31m75%' && ok "statusline: red at/above threshold" || fail "statusline color" "$(printf '%q' "$out")"

  # --- settings ---
  run set threshold 50 >/dev/null
  make_transcript "$TR" 120000 0
  out="$(printf '{"session_id":"s2","transcript_path":"%s","cwd":"%s"}' "$TR" "$P" | run check)"; has "$out" "60% full" && ok "set threshold 50: asks at 60%" || fail "set threshold" "$out"
  run set window 1000000 >/dev/null; has "$(run where)" "window=1000000" && ok "set window" || fail "set window"
  run set nonsense 5 >/dev/null 2>&1; [ $? -ne 0 ] && ok "set: unknown key rejected" || fail "set unknown key"

  # --- search ---
  printf -- '---\nno: 4\ntitle: payments\n---\nDecided on Stripe Checkout for payments.\nWebhook secret lives in .env\n' > "$D/ctx-004.md"
  out="$(run search stripe)"; has "$out" "projects/klarhim/ctx-004.md:5:" && has "$out" "Stripe Checkout" && ok "search: case-insensitive hit with file and line" || fail "search" "$out"
  out="$(run search webhook env)"; has "$out" "ctx-004.md:6:" && ok "search: all words must match" || fail "search AND" "$out"
  out="$(run search signup)"; has "$out" "archive/ctx-002.md" && ok "search: includes the archive" || fail "search archive" "$out"
  out="$(run search zzzz)"; [ "$out" = "(no matches)" ] && ok "search: no matches" || fail "search none" "$out"

  # --- non-ASCII (UTF-8 in and out) ---
  printf -- '---\nno: 5\ntitle: ödeme akışı\n---\nÖdeme ağ geçidi: İyzico, şimdilik test modunda.\n' > "$D/ctx-005.md"
  run pending 5 >/dev/null
  out="$(hookin clear | run start)"; has "$out" "Ödeme ağ geçidi: İyzico, şimdilik" && ok "UTF-8: Turkish content survives the handoff" || fail "UTF-8 handoff" "$out"
  out="$(run search ağ geçidi)"; has "$out" "ctx-005.md:5:" && ok "UTF-8: search with Turkish words" || fail "UTF-8 search" "$out"
  out="$(run list)"; has "$out" "005 |" && has "$out" "ödeme akışı" && ok "UTF-8: Turkish title in the list" || fail "UTF-8 list" "$out"
  mkdir -p "$T/work/müşteri-paneli"
  out="$(printf '{"cwd":"%s"}' "$T/work/müşteri-paneli" | run statusline)"; [ "$out" = "ctx müşteri-paneli" ] && ok "UTF-8: Turkish folder name from hook input" || fail "UTF-8 folder" "$out"

  # --- roots ---
  local K="$T/vault"; mkdir -p "$K/proj-a/src" "$K/proj-b"
  run add-root "$K" >/dev/null
  out="$(cd "$K/proj-a/src" && run where)"; has "$out" "project: proj-a" && ok "root: project found from a sub-folder" || fail "root sub-folder" "$out"
  out="$(cd "$K" && run where)"; has "$out" "project: _general" && ok "root: _general when no active project" || fail "root _general" "$out"
  run project proj-b >/dev/null
  out="$(cd "$K" && run where)"; has "$out" "project: proj-b" && ok "root: active project via 'project'" || fail "root .active" "$out"
  printf '{"session_id":"s3","transcript_path":"%s","cwd":"%s/proj-a"}' "$TR" "$K" | CLAUDE_PROJECT_DIR="$K" run save
  [ -f "$CTX_HOME/projects/proj-a/ctx-001.md" ] && ok "root: hook picks the sub-project from cwd" || fail "root hook"
  mkdir -p "$CTX_HOME/pins"
  printf -- '---\nname: auth-flow\nproject: proj-a\ndescription: JWT login\n---\nrefresh token rotation\n' > "$CTX_HOME/pins/auth-flow.md"
  out="$(cd "$P" && run search --all rotation)"; has "$out" "pins/auth-flow.md" && ok "search --all: covers pins" || fail "search --all pins" "$out"
  out="$(cd "$P" && run search --all signup)"; has "$out" "projects/proj-a/ctx-001.md" && has "$out" "projects/klarhim/" && ok "search --all: covers every project" || fail "search --all projects" "$out"
  out="$(cd "$P" && run search rotation)"; [ "$out" = "(no matches)" ] && ok "search: project scope by default" || fail "search scope" "$out"

  # --- names / pins / robustness ---
  mkdir -p "$T/x/app" "$T/y/app"
  a="$(cd "$T/x/app" && run where | sed -n 1p)"; b="$(cd "$T/y/app" && run where | sed -n 1p)"
  [ "$a" = "project: app" ] && has "$b" "project: app-" && ok "two projects with the same name stay apart ($b)" || fail "name collision" "$a / $b"
  out="$(run pins)"; has "$out" "auth-flow | proj-a | JWT login" && ok "pins" || fail "pins" "$out"
  out="$(printf 'broken json' | run check; echo "rc=$?")"; [ "$out" = "rc=0" ] && ok "broken input: silent, exit 0" || fail "broken input" "$out"
  out="$(printf '' | run save; echo "rc=$?")"; [ "$out" = "rc=0" ] && ok "empty input: silent, exit 0" || fail "empty input" "$out"
  out="$(printf 'nope' | run statusline; echo "rc=$?")"; has "$out" "rc=0" && ok "statusline: survives broken input" || fail "statusline broken" "$out"

  cd / && rm -rf "$T"
}

case "$WHICH" in
  python) run_suite python ;;
  pwsh)   run_suite pwsh ;;
  both)   run_suite python; run_suite pwsh ;;
esac
echo
echo "Result: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
