# ent run: command execution, dry-run awareness, and worktree guards.

set -euo pipefail

# run: a command that changes something. Echoed; skipped under --dry-run.
# Its stdout goes to stderr so only emit_path writes to stdout.
run()   { say "$@"; if (( DRY_RUN )); then return 0; fi; "$@" >&2; }
runat() { local d="$1"; shift; say "$@"; if (( DRY_RUN )); then return 0; fi; (cd "$d" && "$@") >&2; }

# worktree_bare_guard <worktree-dir>: keep a new worktree usable when
# extensions.worktreeConfig is switched on.
#
# `git sparse-checkout` turns that extension on. With it on, git stops ignoring
# the ent's shared core.bare=true inside linked worktrees and starts honouring
# it, so every worktree in the ent answers "this operation must be run in a work
# tree". Writing core.bare=false into the worktree's own config undoes that.
# Only written when the extension is on, so ordinary ents stay untouched.
worktree_bare_guard() {
  local on
  on="$(git -C "$ENT" config --bool --get extensions.worktreeConfig 2>/dev/null || true)"
  [[ "$on" == true ]] || return 0
  run git -C "$1" config --worktree core.bare false
}
