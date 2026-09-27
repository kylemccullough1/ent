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
_ent_verbs=(init branch twig rm sync list status log path up down go open destroy help track)
_ent_flags=(--dry-run --verbose --quiet --help --version --recursive --force --from --remote --yes --win --here --worktrees --abort --continue --tab --new-window)

# _ent: completes `ent ...`; words[1] is the command, words[2] the verb.
_ent() {
  if [[ "$PREFIX" == -* ]]; then compadd -- $_ent_flags; return; fi
  if (( CURRENT == 2 )); then compadd -- $_ent_verbs; return; fi
  local -a branches remote_branches
  branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)"})
  remote_branches=(${(f)"$(git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | sed 's|^origin/||')"})
  case "${words[2]}" in
    branch)
      case "${words[CURRENT-1]}" in
        --from)   compadd -- $branches ;;
        --remote) compadd -- $remote_branches ;;
        *)        (( CURRENT == 3 )) && compadd -- merge ;;
      esac ;;
    rm|path|go|open|sync|track) compadd -- $branches ;;
    twig)                 [[ "${words[CURRENT-1]}" == --from ]] && compadd -- $branches ;;
    help)                 compadd -- $_ent_verbs merge ;;
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

# ---------- Windows Terminal tab title ----------
# __ent_branch_from_path: REPLY = the branch that owns the current folder, worked out
# from folder names alone (no git, no processes). Same rules as in ent.bash:
#   <ent> -> ent, <ent>/main/... -> ent.main, <ent>/branches/<b>/... -> <b>,
#   .../twigs/<t>/... -> twigs/<b>/<t>. Returns 1 outside an ent.
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

# __ent_main_name <ent-root>: REPLY = ent.main from .bare/config, or "main".
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

# __ent_prompt_hook: runs before every prompt inside Windows Terminal and titles the
# tab with the ent branch you are standing in. zsh has no standard title in its
# prompt, so the title escape is printed on each prompt while inside an ent (printf
# is a builtin); the branch is only worked out again when the folder changes.
__ENT_TITLE="" __ENT_HOOK_PWD=""
__ent_prompt_hook() {
  if [[ "$PWD" != "$__ENT_HOOK_PWD" ]]; then
    __ENT_HOOK_PWD="$PWD"
    if __ent_branch_from_path; then __ENT_TITLE="$REPLY"; else __ENT_TITLE=""; fi
  fi
  [[ -n "$__ENT_TITLE" ]] && printf '\033]0;%s\007' "$__ENT_TITLE"
  return 0
}

# Only inside Windows Terminal (WT_SESSION), and not in VS Code or tmux, which inherit it.
if [[ -n "${WT_SESSION:-}" && "${TERM_PROGRAM:-}" != vscode && -z "${TMUX:-}" ]]; then
  (( ${precmd_functions[(Ie)__ent_prompt_hook]} )) || precmd_functions+=(__ent_prompt_hook)
fi
