# zsh: the `ent` command, tab completion, and a prompt helper.
# Source this from ~/.zshrc after compinit (install.sh prints the line).

# `ent` runs `git ent` and, for verbs that print a folder, cds into it.
# (A program can't change your shell's folder; only a shell function can.)
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

# ---------- completion ----------
_ent_verbs=(init branch twig rm sync list status log path up down go destroy help)
_ent_flags=(--dry-run --verbose --quiet --help --version --recursive --force --from --remote --yes --win --here --worktrees --abort --continue)

# _ent: completes `ent ...`; words[1] is the command, words[2] the verb.
_ent() {
  if [[ "$PREFIX" == -* ]]; then compadd -- $_ent_flags; return; fi
  if (( CURRENT == 2 )); then compadd -- $_ent_verbs; return; fi
  local -a branches
  branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)"})
  case "${words[2]}" in
    branch)            (( CURRENT == 3 )) && compadd -- merge ;;
    rm|path|go|sync)   compadd -- $branches ;;
    twig)              [[ "${words[CURRENT-1]}" == --from ]] && compadd -- $branches ;;
    help)              compadd -- $_ent_verbs merge ;;
  esac
}

# `git ent <TAB>`: zsh's git completion calls _git-<cmd> for commands it is told about.
_git-ent() { _ent; }
zstyle ':completion:*:*:git:*' user-commands ent:'a git worktree per branch, as nested folders'
# Load zsh's completion system if ~/.zshrc hasn't already (oh-my-zsh and most setups have).
if (( ! $+functions[compdef] )); then autoload -Uz compinit && compinit -i; fi
compdef _ent ent

# ---------- prompt ----------
# __ent_in_ent: true when an ent root sits above the current folder: both .bare
# (the git database) and the .git pointer file, so a stray .bare does not count.
# Uses only shell builtins, so prompts outside an ent cost nothing.
__ent_in_ent() {
  local d="$PWD"
  while [[ -n "$d" ]]; do [[ -d "$d/.bare" && -f "$d/.git" ]] && return 0; d="${d%/*}"; done
  return 1
}

# __ent_ps1 [format]: the ent branch that owns the current folder ("ent" at the
# ent root), printed through format (default "%s"). Prints nothing outside an ent.
#   setopt PROMPT_SUBST
#   PROMPT='%~$(__ent_ps1 " (%s)") %# '
__ent_ps1() {
  __ent_in_ent || return 0
  local b; b="$(git ent __where 2>/dev/null)"
  [[ -n "$b" ]] && printf -- "${1:-%s}" "$b"
  return 0
}
