# bash: tab completion for `git ent`, plus the `ent` shell function.
# Source this from ~/.bashrc (install.sh prints the line).
#
# git's own completion looks for a function named _git_<subcommand> when completing
# `git <subcommand> ...`, so defining _git_ent is all it takes to complete `git ent <TAB>`.

_git_ent_verbs="init branch twig rm sync list status log path up down go destroy help track"
_git_ent_opts="--dry-run --verbose --quiet --help --version --recursive --force --from --remote --yes --win --here --worktrees --abort --continue"

_git_ent_branches() { git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; }
_git_ent_remote_branches() { git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | sed 's|^origin/||'; }

# _git_ent_complete <index-of-first-word-after-ent>
_git_ent_complete() {
  local start="$1" cur prev verb="" i
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  for (( i=start; i<COMP_CWORD; i++ )); do
    case "${COMP_WORDS[i]}" in -*) ;; *) verb="${COMP_WORDS[i]}"; break ;; esac
  done
  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$_git_ent_opts" -- "$cur") ); return
  fi
  case "$prev" in
    --from|rm|path|merge|destroy|track)
      COMPREPLY=( $(compgen -W "$(_git_ent_branches)" -- "$cur") ); return ;;
    --remote)
      COMPREPLY=( $(compgen -W "$(_git_ent_remote_branches)" -- "$cur") ); return ;;
    help)
      COMPREPLY=( $(compgen -W "$_git_ent_verbs" -- "$cur") ); return ;;
  esac
  if [[ -z "$verb" ]]; then
    COMPREPLY=( $(compgen -W "$_git_ent_verbs" -- "$cur") ); return
  fi
  case "$verb" in
    branch)
      if (( COMP_CWORD == start+1 )); then
        COMPREPLY=( $(compgen -W "merge" -- "$cur") ); return
      elif (( COMP_CWORD == start+2 )) && [[ "$prev" == "merge" ]]; then
        COMPREPLY=( $(compgen -W "$(_git_ent_branches)" -- "$cur") ); return
      fi ;;
  esac
}

_git_ent() { _git_ent_complete 2; }

# `ent` wrapper for `git ent`: performs the cd for verbs that print a path.
# Install.sh will source this file; if it is sourced twice, the function is replaced harmlessly.
ent() {
  # Help and dry runs print text, not a folder: just show it.
  local a p="" rc here=""
  for a in "$@"; do
    case "$a" in -h|--help|-n|--dry-run) git ent "$@"; return ;; esac
  done
  # branch merge, rm and sync can delete the folder you are standing in. Windows
  # will not delete a folder any process has as its current folder, and both this
  # shell and the git.exe that `git ent` starts would be sitting in it. So run
  # them from the ent root; ENT_PWD tells git-ent where you really were.
  case "${1:-}/${2:-}" in
    branch/merge|rm/*|sync/*) if __ent_root; then here="$PWD"; cd "$__ENT_ROOT" || return; fi ;;
  esac
  case "${1:-}" in
    init|branch|twig|go|up|down) p="$(ENT_PWD="$here" git ent "$@")"; rc=$? ;;
    *) ENT_PWD="$here" git ent "$@"; rc=$? ;;
  esac
  if (( rc == 0 )) && [[ -n "$p" ]]; then cd "$p"
  elif [[ -n "$here" ]]; then
    # Back where you were, unless that folder was just removed.
    if [[ -d "$here" ]]; then cd "$here"; else echo "ent: $here was removed; you are at $__ENT_ROOT" >&2; fi
  fi
  return $rc
}

# ---------- prompt ----------
# __ent_in_ent: true when an ent root sits above the current folder: both .bare
# (the git database) and the .git pointer file, so a stray .bare does not count.
# Uses only shell builtins (no processes), so prompts outside an ent cost nothing.
# __ent_root sets __ENT_ROOT to that root, for the wrapper above.
__ent_root() {
  local d="$PWD"
  while [[ -n "$d" ]]; do
    if [[ -d "$d/.bare" && -f "$d/.git" ]]; then __ENT_ROOT="$d"; return 0; fi
    d="${d%/*}"
  done
  return 1
}
__ent_in_ent() { __ent_root; }

# __ent_ps1 [format]: the ent branch that owns the current folder ("ent" at the
# ent root), printed through format (default "%s"). Prints nothing outside an ent.
#   PS1='[\u@\h \W$(__ent_ps1 " (%s)")]\$ '
__ent_ps1() {
  __ent_in_ent || return 0
  local b; b="$(git ent __where 2>/dev/null)"
  [[ -n "$b" ]] && printf -- "${1:-%s}" "$b"
  return 0
}

# If git's __git_ps1 prompt is loaded, make it ent-aware. An ent container folder
# (branches/x/, twigs/) is not a git checkout, so plain __git_ps1 would show the bare
# repo's HEAD there. Inside a real core/ checkout the original runs, keeping git's
# dirty markers; outside an ent the original runs untouched.
# The __ent_git_ps1 check stops a second `source` from wrapping the wrapper.
if declare -f __git_ps1 >/dev/null 2>&1 && ! declare -f __ent_git_ps1 >/dev/null 2>&1; then
  eval "$(declare -f __git_ps1 | sed 's/^__git_ps1/__ent_git_ps1/')"
  __git_ps1() {
    __ent_in_ent || { __ent_git_ps1 "$@"; return; }
    local top; top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ "${top##*/}" == core ]]; then __ent_git_ps1 "$@"; return; fi
    __ent_ps1 "${1:- (%s)}"
  }
fi

# Load git's completion and prompt before sourcing this file in ~/.bashrc.
