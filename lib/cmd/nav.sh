# ent navigation: print a folder for the `ent` shell wrapper to cd into.

help_up() { cat <<'EOF'
up [--tab|--new-window]                go to the parent's core/ (or the ent root from a branch)
  --tab / --new-window open it in Windows Terminal instead of moving this shell.
EOF
}
help_down() { cat <<'EOF'
down [name] [--tab|--new-window]       go into a twig (the only one, or by name)
  --tab / --new-window open it in Windows Terminal instead of moving this shell.
EOF
}
help_go() { cat <<'EOF'
go <branch> [--tab|--new-window]       go to any branch or twig (feature/x or feature-x)
  --tab / --new-window open it in Windows Terminal instead of moving this shell.
EOF
}
help_open() { cat <<'EOF'
open [<branch>] [--new-window]         open a branch in a new Windows Terminal tab
  With no name, opens the branch you are standing in (main at the ent root).
  Names work as they do for `ent go`. --new-window opens a window instead.
  The tab is titled with the branch name; your current shell stays where it is.
EOF
}
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
  if b="$(ent_branch_of_cwd)"; then
    parent_of "$b"
    if [[ -n "$REPLY" ]]; then emit_path "$(ent_core "$REPLY")" "" "$REPLY"
    else emit_path "$ENT" "" ent; fi
  else emit_path "$(ent_core "$S_MAIN")" "" "$S_MAIN"; fi
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
    emit_path "$(ent_core "${choices[0]}")" "" "${choices[0]}"; return
  fi
  for child in "${choices[@]}"; do
    if [[ "$child" == "$name" || "$(ent_twigname "$child")" == "$name" || "$(ent_slug "$child")" == "$name" ]]; then
      [[ -z "$match" ]] || { echo "Multiple choices: $match $child" >&2; die "run 'ent down <name>'"; }
      match="$child"
    fi
  done
  [[ -n "$match" ]] || die "no child matches '$name'"
  emit_path "$(ent_core "$match")" "" "$match"
}

# go_emit <branch>: hand back the branch's folder, or explain why there is none.
# A branch can exist with no worktree (its folder removed, or it was made with
# plain git), and emitting a path that is not there just makes the shell
# wrapper fail at `cd`.
go_emit() {
  if ! wt_path_of "$1"; then
    die "branch '$1' has no worktree. Give it one:  ent branch $1"
  fi
  emit_path "$(ent_core "$1")" "" "$1"
}

# go_resolve <name>: REPLY = the branch <name> means, the way `go` and `open` read it:
# the exact branch name, then the slug (feature-x for feature/x), then a twig's short
# name. Dies when nothing matches, or when two twigs share the short name.
go_resolve() {
  local name="$1" b match=""
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" == "$name" ]] && { REPLY="$b"; return 0; }
  done
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$(ent_slug "$b")" == "$name" ]] && { REPLY="$b"; return 0; }
  done
  # A twig's short name, e.g. `go mainc` for twigs/mainb/mainc.
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" == twigs/* && "${b##*/}" == "$name" ]] || continue
    [[ -z "$match" ]] || { echo "Multiple twigs named '$name': $match $b" >&2; die "use the full branch name"; }
    match="$b"
  done
  [[ -n "$match" ]] || die "no branch matches '$name'"
  REPLY="$match"
}

cmd_go() {
  ensure_ent
  local name
  name="$(arg 1)"
  [[ -n "$name" && -z "$(arg 2)" ]] || usage_die "go <branch>"
  go_resolve "$name"
  go_emit "$REPLY"
}

# cmd_open: `go` that always opens a new tab (or window, with --new-window). With no
# name it opens where you stand: the branch that owns this folder, else main.
cmd_open() {
  ensure_ent
  local name b
  name="$(arg 1)"
  [[ -z "$(arg 2)" ]] || usage_die "open [<branch>] [--new-window]"
  if [[ -n "$name" ]]; then go_resolve "$name"; go_emit "$REPLY"; return; fi
  if b="$(ent_branch_of_cwd 2>/dev/null)"; then go_emit "$b"; else go_emit "$S_MAIN"; fi
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

cmd_path() {
  ensure_ent
  local branch p
  branch="$(arg 1)"
  [[ -n "$branch" && -z "$(arg 2)" ]] || usage_die "path <branch> [--win]"
  p="$(ent_core "$branch")"
  if (( WIN )) && command -v cygpath >/dev/null 2>&1; then cygpath -w "$p"; else printf '%s\n' "$p"; fi
}
