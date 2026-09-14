# bash: tab completion for `git ent`, plus the `ent` shell function.
# Source this from ~/.bashrc (install.sh prints the line).
#
# git's own completion looks for a function named _git_<subcommand> when completing
# `git <subcommand> ...`, so defining _git_ent is all it takes to complete `git ent <TAB>`.

_git_ent_verbs="init add rm merge sync list path check destroy help"
_git_ent_opts="--dry-run --verbose --quiet --help --version --recursive --force --apply --print-path --no-track --from --yes --abort --continue --pull --rebase --ff-only"

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
    add)
      if (( COMP_CWORD == start+1 )); then
        COMPREPLY=( $(compgen -W "twig" -- "$cur") ); return
      fi ;;
  esac
}

_git_ent() { _git_ent_complete 2; }

# `ent` wrapper for `git ent`: performs the cd for verbs that print a path.
# Install.sh will source this file; if it is sourced twice, the function is replaced harmlessly.
ent() {
  case "${1:-}" in
    init|add|go)
      local p
      p="$(git ent "$@" --print-path)" || return $?
      cd "$p" ;;
    *) git ent "$@" ;;
  esac
}

# Make sure git completion is loaded before this point in ~/.bashrc.
