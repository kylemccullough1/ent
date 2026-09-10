# bash: tab completion for `git grove`, plus the `grove` shell function.
# Source this from ~/.bashrc (install.sh prints the line).
#
# git's own completion looks for a function named _git_<subcommand> when completing
# `git <subcommand> ...`, so defining _git_grove is all it takes to complete `git grove <TAB>`.

_git_grove_verbs="init add list rm merge finish destroy go up down path sync color paint help"
_git_grove_opts="--dry-run --verbose --quiet --help --version --recursive --force --apply --print-path --no-track --from --json --pull --ff-only --rebase --yes --abort --continue --set"

_git_grove_branches() { git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; }

# _git_grove_complete <index-of-first-word-after-grove>
_git_grove_complete() {
  local start="$1" cur prev verb="" i
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  for (( i=start; i<COMP_CWORD; i++ )); do
    case "${COMP_WORDS[i]}" in -*) ;; *) verb="${COMP_WORDS[i]}"; break ;; esac
  done
  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$_git_grove_opts" -- "$cur") ); return
  fi
  case "$prev" in
    --from|go|rm|path|help|merge|finish|color)
      [[ "$prev" == help ]] && { COMPREPLY=( $(compgen -W "$_git_grove_verbs" -- "$cur") ); return; }
      COMPREPLY=( $(compgen -W "$(_git_grove_branches)" -- "$cur") ); return ;;
  esac
  if [[ -z "$verb" ]]; then
    COMPREPLY=( $(compgen -W "$_git_grove_verbs" -- "$cur") ); return
  fi
  case "$verb" in
    add)  COMPREPLY=( $(compgen -W "$(_git_grove_branches)" -- "$cur") ) ;;   # [base]
    down) COMPREPLY=( $(compgen -W "$(git grove list --json 2>/dev/null | sed -n 's/.*"branch": "\([^"]*\)".*/\1/p')" -- "$cur") ) ;;
    *)    COMPREPLY=() ;;
  esac
}

# called by git's completion for `git grove ...`
_git_grove() {
  local i
  for (( i=1; i<COMP_CWORD; i++ )); do
    [[ "${COMP_WORDS[i]}" == grove ]] && { _git_grove_complete $((i+1)); return; }
  done
  _git_grove_complete 2
}

# the shell function: cd into what add/init/go/up/down print, only if the command succeeded
grove() {
  case "${1:-}" in
    add|init|go|up|down)
      local p
      p="$(git grove "$@" --print-path)" || return $?
      cd "$p" ;;
    finish)
      if [[ "${2:-}" == . ]]; then      # finish the branch we stand in: merge, cd to the target, then remove it
        local src p
        src="$(git symbolic-ref --short -q HEAD)" || { git grove "$@"; return $?; }
        p="$(git grove "$@" --print-path)" || return $?
        [[ -n "$p" ]] || return 0        # preview, or nothing merged: stay put
        cd "$p" && git grove rm "$src" --apply
      else git grove "$@"; fi ;;
    *) git grove "$@" ;;
  esac
}
_grove_fn() { _git_grove_complete 1; }
complete -F _grove_fn grove

# paint the terminal for the tree you stand in, after every prompt. Turn off: git config --global grove.paint false
if [[ "${PROMPT_COMMAND:-}" != *"git grove paint"* ]]; then
  PROMPT_COMMAND="git grove paint${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
