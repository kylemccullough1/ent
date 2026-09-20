# bash: tab completion for `git ent`, plus the `ent` shell function.
# Source this from ~/.bashrc (install.sh prints the line).
#
# git's own completion looks for a function named _git_<subcommand> when completing
# `git <subcommand> ...`, so defining _git_ent is all it takes to complete `git ent <TAB>`.

_git_ent_verbs="init branch twig rm sync list status log path up down go destroy help"
_git_ent_opts="--dry-run --verbose --quiet --help --version --recursive --force --from --yes --win --abort --continue"

_git_ent_branches() { git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; }

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
    --from|rm|path|merge|destroy|help)
      [[ "$prev" == help ]] && { COMPREPLY=( $(compgen -W "$_git_ent_verbs" -- "$cur") ); return; }
      COMPREPLY=( $(compgen -W "$(_git_ent_branches)" -- "$cur") ); return ;;
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
  local a
  for a in "$@"; do
    case "$a" in -h|--help|-n|--dry-run) git ent "$@"; return ;; esac
  done
  case "${1:-}" in
    init|branch|twig|go|up|down)
      local p
      p="$(git ent "$@")" || return $?
      if [[ -n "$p" ]]; then cd "$p"; fi ;;
    *) git ent "$@" ;;
  esac
}

# ---------- prompt ----------
# __ent_in_ent: true when an ent's .bare folder sits above the current folder.
# Uses only shell builtins (no processes), so prompts outside an ent cost nothing.
__ent_in_ent() {
  local d="$PWD"
  while [[ -n "$d" ]]; do [[ -d "$d/.bare" ]] && return 0; d="${d%/*}"; done
  return 1
}

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
