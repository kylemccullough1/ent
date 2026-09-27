# ent navigation: print a folder for the `ent` shell wrapper to cd into.

help_up()   { echo "up                                     go to the parent's core/ (or the ent root from a branch)"; }
help_down() { echo "down [name]                            go into a twig (the only one, or by name)"; }
help_go()   { echo "go <branch>                            go to any branch or twig (feature/x or feature-x)"; }
help_path() { cat <<'EOF'
path <branch> [--win]                  print a branch's core/ path
  --win  print it as a Windows path (C:\...) under Git Bash
EOF
}

cmd_up() {
  ensure_ent
  # Anywhere inside the ent that is not a worktree -- the root itself, or a
  # bare container like branches/ -- has main/core as the sensible landing
  # spot, so `up` is never a dead end.
  local b
  if b="$(ent_branch_of_cwd)"; then emit_path "$(ent_parent_core "$b")"
  else emit_path "$(ent_core "$S_MAIN")"; fi
}

cmd_down() {
  ensure_ent
  local b name choices=() child match=""
  name="$(arg 1)"
  b="$(ent_branch_of_cwd 2>/dev/null || true)"
  if [[ -z "$b" ]]; then
    top_branches; choices=("$S_MAIN" ${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  else
    children_of "$b"; choices=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  fi
  if (( ! ${#choices[@]} )); then
    if [[ -n "$b" ]]; then
      die "no children to move down into: '$b' has no twigs. Make one with \`ent twig <name>\`, or jump to another branch with \`ent go <branch>\`"
    fi
    die "no children to move down into: this ent has no branches yet. Make one with \`ent branch <name>\`"
  fi
  if [[ -z "$name" ]]; then
    if (( ${#choices[@]} > 1 )); then
      echo "Multiple choices:" >&2; printf '  %s\n' "${choices[@]}" >&2
      die "run 'ent down <name>'"
    fi
    emit_path "$(ent_core "${choices[0]}")"; return
  fi
  for child in "${choices[@]}"; do
    if [[ "$child" == "$name" || "$(ent_twigname "$child")" == "$name" || "$(ent_slug "$child")" == "$name" ]]; then
      [[ -z "$match" ]] || { echo "Multiple choices: $match $child" >&2; die "run 'ent down <name>'"; }
      match="$child"
    fi
  done
  [[ -n "$match" ]] || die "no child matches '$name'"
  emit_path "$(ent_core "$match")"
}

# go_emit <branch>: hand back the branch's folder. A branch with no worktree (its
# folder removed, or made with plain git) is adopted first: naming it is asking
# for it, and emitting a path that is not there just makes the shell wrapper
# fail at `cd`.
go_emit() {
  tree_adopt_if_missing "$1"
  emit_path "$(ent_core "$1")"
}

cmd_go() {
  ensure_ent
  local name b
  name="$(arg 1)"
  [[ -n "$name" && -z "$(arg 2)" ]] || usage_die "go <branch>"
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" == "$name" ]] && { go_emit "$b"; return; }
  done
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$(ent_slug "$b")" == "$name" ]] && { go_emit "$b"; return; }
  done
  # A twig's short name, e.g. `go mainc` for twigs/mainb/mainc.
  local match=""
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" == twigs/* && "${b##*/}" == "$name" ]] || continue
    [[ -z "$match" ]] || { echo "Multiple twigs named '$name': $match $b" >&2; die "use the full branch name"; }
    match="$b"
  done
  [[ -n "$match" ]] && { go_emit "$match"; return; }
  die "no branch matches '$name'"
}

# cmd_where (internal, used by the prompt helpers): the branch that owns the current
# folder, or "ent" at the ent root. Prints nothing and succeeds anywhere else.
cmd_where() {
  ENT="$(ent_root 2>/dev/null)" || return 0
  load_state
  local b
  if b="$(ent_branch_of_cwd 2>/dev/null)"; then
    # git's prompt writes an unfinished operation as "branch|MERGING"; match it.
    state_of "$b" && b="$b|$REPLY"
    printf '%s\n' "$b"
  elif [[ "$(ent_norm "$PWD")" == "$ENT" ]]; then
    echo ent
  fi
  return 0
}

parse_path_args() {
  local i=0 new_args=()
  WIN=0
  while (( i < ${#ARGS[@]} )); do
    local a="${ARGS[$i]}"
    case "$a" in
      --win) WIN=1 ;;
      -*)    die "unknown path option: $a" ;;
      *)     new_args+=("$a") ;;
    esac
    i=$((i+1))
  done
  ARGS=("${new_args[@]}")
}

cmd_path() {
  ensure_ent
  parse_path_args
  local branch p
  branch="$(arg 1)"
  [[ -n "$branch" && -z "$(arg 2)" ]] || usage_die "path <branch> [--win]"
  p="$(ent_core "$branch")"
  if (( WIN )) && command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else printf '%s\n' "$p"; fi
}
