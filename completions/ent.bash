# bash: tab completion for `git ent`, plus the `ent` shell function.
# Source this from ~/.bashrc (install.sh prints the line).
#
# git's own completion looks for a function named _git_<subcommand> when completing
# `git <subcommand> ...`, so defining _git_ent is all it takes to complete `git ent <TAB>`.

_git_ent_verbs="init branch twig rm sync list path up down go destroy help"
_git_ent_opts="--dry-run --verbose --quiet --help --version --recursive --force --print-path --no-track --from --yes --abort --continue --pull --rebase --ff-only"

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
  case "${1:-}" in
    init|branch|twig|go|up|down)
      local p
      p="$(git ent "$@" --print-path)" || return $?
      cd "$p" ;;
    *) git ent "$@" ;;
  esac
}

# Prompt helper: prints the current ent branch if cwd is inside an ent container,
# or "ent" if cwd is the ent root. Returns empty everywhere else.
# Use in PS1 like:
#   PS1='[\u@\h \W$(__ent_ps1 " (%s)")]\$ '
__ENT_SHARE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
__ent_ps1() {
  local fmt="${1:-%s}" branch root pwd_w
  branch="$(
    bash -c 'source "$1" >/dev/null 2>&1; ent_branch_of_cwd 2>/dev/null' \
      _ "$__ENT_SHARE/lib/paths.sh"
  )"
  if [[ -z "$branch" ]]; then
    root="$(
      bash -c 'source "$1" >/dev/null 2>&1; ent_root 2>/dev/null' \
        _ "$__ENT_SHARE/lib/paths.sh"
    )"
    pwd_w="$(pwd -W 2>/dev/null || pwd -P)"
    if [[ -n "$root" && "$(cygpath -ml "$pwd_w" 2>/dev/null || echo "$pwd_w")" == "$root" ]]; then
      branch="ent"
    fi
  fi
  [[ -n "$branch" ]] && printf "$fmt" "$branch"
}

# If git's __git_ps1 prompt helper is loaded, make it ent-aware so that
# ent container directories show the resolved ent branch instead of the bare
# repo's HEAD. Inside an actual core/ worktree the real git prompt is used so
# dirty-state markers still appear. Outside an ent, the original helper is used.
if declare -f __git_ps1 >/dev/null 2>&1; then
  eval "$(declare -f __git_ps1 | sed 's/^__git_ps1/__ent_git_ps1/')"
  __git_ps1() {
    local top ent_branch fmt
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    top="${top##*/}"
    # Inside an actual core/ worktree, keep git's dirty-state prompt.
    if [[ "$top" == "core" ]]; then
      __ent_git_ps1 "$@"
      return
    fi
    ent_branch="$(__ent_ps1 '%s')"
    if [[ -n "$ent_branch" ]]; then
      fmt="${1:- (%s)}"
      printf "$fmt" "$ent_branch"
    else
      __ent_git_ps1 "$@"
    fi
  }
fi

# Make sure git completion/prompt is loaded before this point in ~/.bashrc.
