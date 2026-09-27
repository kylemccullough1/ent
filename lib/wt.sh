# ent Windows Terminal: open a folder in a new WT tab or window.
# Used by --tab / --new-window (see emit_path in output.sh) and by `ent open`.
#
# The command it builds, for `ent go feature/x --tab`:
#   MSYS_NO_PATHCONV=1 wt.exe -w 0 nt --title feature/x -d 'C:\...\branches\feature\x\core'
# -w 0 is "the most recent window" (a new tab there); -w new is a new window.

# wt_bin: REPLY = the Windows Terminal program to run. Returns 1 when there is none.
#   1. $ENT_WT, when it is set. Tests point it at a fake `wt` that writes down the
#      arguments it was given, so they can check the command without opening windows
#      (and run on macOS and Linux too). Set but not runnable counts as "none".
#   2. Otherwise wt.exe on PATH, on Windows only. Git Bash reports OSTYPE=msys and
#      Cygwin reports cygwin. WT installs wt.exe as an app alias in
#      %LOCALAPPDATA%\Microsoft\WindowsApps, which is on PATH by default.
wt_bin() {
  REPLY=""
  if [[ -n "${ENT_WT+set}" ]]; then
    [[ -n "$ENT_WT" && -x "$ENT_WT" ]] || return 1
    REPLY="$ENT_WT"; return 0
  fi
  case "${OSTYPE:-}" in msys*|cygwin*) ;; *) return 1 ;; esac
  REPLY="$(command -v wt.exe 2>/dev/null || true)"
  [[ -n "$REPLY" ]]
}

# wt_require: the preflight. Stops before a verb changes anything when WT is missing.
wt_require() {
  wt_bin || die "--tab, --new-window and \`ent open\` need Windows Terminal (wt.exe); it wasn't found"
}

# wt_open <folder> <title>: open <folder> in a new tab (OPEN_MODE=tab) or window
# (OPEN_MODE=window), with the tab named <title>. The shell prompt hook keeps the
# title current after that (completions/ent.bash, __ent_prompt_hook).
wt_open() {
  local dir="$1" title="$2" bin target=0 win prof
  wt_require; bin="$REPLY"
  [[ "$OPEN_MODE" == window ]] && target=new
  # wt.exe is a Windows program, so it needs C:\... rather than /c/...
  win="$dir"
  if command -v cygpath >/dev/null 2>&1; then win="$(cygpath -w "$dir")"; fi
  local args=(-w "$target" nt)
  prof="$(cfg wtProfile 2>/dev/null || true)"
  if [[ -n "$prof" ]]; then args+=(-p "$prof"); fi
  # wt reads a bare ; as "next command", and git allows ; in branch names.
  args+=(--title "${title//;/\\;}" -d "$win")
  # MSYS_NO_PATHCONV stops Git Bash rewriting arguments that look like /paths.
  run env MSYS_NO_PATHCONV=1 "$bin" "${args[@]}"
}
