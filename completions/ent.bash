# bash: tab completion for `git ent`, plus the `ent` shell function.
# Source this from ~/.bashrc (install.sh prints the line).
#
# git's own completion looks for a function named _git_<subcommand> when completing
# `git <subcommand> ...`, so defining _git_ent is all it takes to complete `git ent <TAB>`.

_git_ent_verbs="init branch twig rm sync list status log path up down go open destroy help track"
_git_ent_opts="--dry-run --verbose --quiet --help --version --recursive --force --from --remote --yes --win --here --worktrees --abort --continue --tab --new-window"

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
    --from|rm|path|merge|destroy|track|go|open)
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

# ---------- Windows Terminal tab title ----------
# __ent_branch_from_path: REPLY = the branch that owns the current folder, worked out
# from folder names alone: no git, no processes, so it is cheap enough for a prompt.
#   <ent>                                   -> ent
#   <ent>/main/...                          -> the default branch (ent.main)
#   <ent>/branches/<b>/...                  -> <b>
#   <ent>/branches/<b>/twigs/<t>/...        -> twigs/<b>/<t>   (main/twigs/<t> too)
# A branch name can hold slashes (feature/x), so the container is the first prefix
# under branches/ whose core/ is a real checkout (it holds a .git file). A plain
# folder level such as branches/feature/ has none; anything below the container
# is either its checkout or its twigs. Returns 1 outside an ent.
__ent_branch_from_path() {
  REPLY=""
  local d="$PWD" root=""
  while [[ -n "$d" ]]; do
    if [[ -d "$d/.bare" && -f "$d/.git" ]]; then root="$d"; break; fi
    d="${d%/*}"
  done
  [[ -n "$root" ]] || return 1
  local rel="${PWD#"$root"}" base="" rest="" prefix="" seg best="" after=""
  case "$rel" in
    /main|/main/*)
      __ent_main_name "$root"; best="$REPLY" after="${rel#/main}"; after="${after#/}"
      base="$root/main" ;;
    /branches/*)
      rest="${rel#/branches/}"
      while [[ -n "$rest" ]]; do
        seg="${rest%%/*}"
        if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
        prefix="${prefix:+$prefix/}$seg"
        if [[ -e "$root/branches/$prefix/core/.git" ]]; then best="$prefix" after="$rest"; break; fi
      done
      base="$root/branches/$best" ;;
  esac
  if [[ -z "$best" ]]; then REPLY=ent; return 0; fi
  if [[ "$after" == twigs/?* ]]; then
    seg="${after#twigs/}"; seg="${seg%%/*}"
    if [[ -e "$base/twigs/$seg/core/.git" ]]; then REPLY="twigs/$best/$seg"; return 0; fi
  fi
  REPLY="$best"
}

# __ent_main_name <ent-root>: REPLY = ent.main from .bare/config (read line by line,
# no git call), or "main" when it is not set.
__ent_main_name() {
  local line sec="" key val
  REPLY=main
  [[ -f "$1/.bare/config" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      \[*) sec="$line" ;;
      *=*)
        [[ "$sec" == "[ent]" ]] || continue
        key="${line%%=*}"; key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" == main ]] || continue
        val="${line#*=}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [[ -n "$val" ]] && REPLY="$val" ;;
    esac
  done < "$1/.bare/config"
  return 0
}

# __ent_prompt_hook: runs before every prompt (PROMPT_COMMAND) inside Windows Terminal
# and keeps the tab title on the ent branch you are standing in, so a tab opened
# with `ent go x --tab` stays right after `ent go y` inside it.
#
# Git Bash's default prompt sets the title on every prompt with
# "\033]0;$TITLEPREFIX:$PWD\007" inside PS1. The hook swaps that piece, once, for
# ${__ENT_TITLE:-$TITLEPREFIX:$PWD}: the branch inside an ent, the usual title
# outside one. A PS1 without that piece gets the title escape printed directly.
# The work is skipped while the folder has not changed.
__ENT_TITLE="" __ENT_HOOK_PWD=""
__ent_prompt_hook() {
  local from='$TITLEPREFIX:$PWD' to='${__ENT_TITLE:-$TITLEPREFIX:$PWD}'
  if [[ "$PS1" == *"$from"* && "$PS1" != *__ENT_TITLE* ]]; then PS1="${PS1//"$from"/$to}"; fi
  if [[ "$PWD" != "$__ENT_HOOK_PWD" ]]; then
    __ENT_HOOK_PWD="$PWD"
    if __ent_branch_from_path; then __ENT_TITLE="$REPLY"; else __ENT_TITLE=""; fi
  fi
  if [[ -n "$__ENT_TITLE" && "$PS1" != *__ENT_TITLE* ]]; then printf '\033]0;%s\007' "$__ENT_TITLE"; fi
  return 0
}

# Only inside Windows Terminal, which sets WT_SESSION in every tab. Programs started
# from a WT tab inherit it too, so VS Code's terminal and tmux are left out.
if [[ -n "${WT_SESSION:-}" && "${TERM_PROGRAM:-}" != vscode && -z "${TMUX:-}" ]]; then
  if [[ "${PROMPT_COMMAND:-}" != *__ent_prompt_hook* ]]; then
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}__ent_prompt_hook"
  fi
fi
