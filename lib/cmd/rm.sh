# ent rm: remove a branch or twig: its worktree, its folder, and the git branch.

help_rm() { cat <<'EOF'
rm <branch> [-r] [-f] [-y]             remove a branch or twig and its folder
  Lists what will go and asks first (-y skips the question).
  -r  also remove its twigs      -f  remove even with uncommitted or unmerged work
  The default branch and anything in the protect setting are refused.
EOF
}

# rm_tree <branch>: remove the branch's twigs (deepest first), then the branch.
rm_tree() {
  local child kids
  children_of "$1"
  kids=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  for child in ${kids[@]+"${kids[@]}"}; do rm_tree "$child"; done
  rm_one "$1"
}

# merged_into_parent <branch>: true when the branch is contained in its parent or in main.
merged_into_parent() {
  parent_of "$1"
  if [[ -n "$REPLY" ]] && git -C "$ENT" merge-base --is-ancestor "$1" "$REPLY" 2>/dev/null; then return 0; fi
  git -C "$ENT" merge-base --is-ancestor "$1" "$S_MAIN" 2>/dev/null
}

rm_one() {
  local b="$1" core_dir container
  core_dir="$(ent_core "$b")" container="$(ent_container "$b")"
  if [[ -d "$core_dir" ]] && worktree_dirty "$core_dir"; then
    (( FORCE )) || die "branch '$b' has uncommitted changes; pass --force or commit them"
    warn "force-removing dirty worktree $b"
  fi
  if [[ -d "$core_dir" ]]; then
    if (( FORCE )); then run git -C "$ENT" worktree remove --force "$core_dir"
    else run git -C "$ENT" worktree remove "$core_dir"; fi
  fi
  if git -C "$ENT" branch -d "$b" >/dev/null 2>&1; then :
  elif merged_into_parent "$b" || (( FORCE )); then run git -C "$ENT" branch -D "$b"
  else die "branch '$b' is not fully merged; pass --force to delete"; fi
  git -C "$ENT" config --unset "branch.$b.entParent" >/dev/null 2>&1 || true
  rmdir "$container/twigs" 2>/dev/null || true
  rmdir "$container" 2>/dev/null || true
  # branches/feature/x leaves an empty branches/feature behind
  local up="${container%/*}"
  while [[ "$up" == "$ENT/branches/"* ]] && rmdir "$up" 2>/dev/null; do up="${up%/*}"; done
  return 0
}

cmd_rm() {
  ensure_ent
  cd "$ENT"   # never stand inside a worktree that is about to be removed
  local branch p
  branch="$(arg 1)"
  [[ -n "$branch" && -z "$(arg 2)" ]] || usage_die "rm <branch> [-r] [-f]"
  [[ "$branch" != "$S_MAIN" ]] || die "cannot remove the default branch '$S_MAIN'"
  for p in $(cfg protect); do [[ "$branch" != "$p" ]] || die "branch '$branch' is protected"; done
  has_local "$branch" || die "branch '$branch' not found"
  children_of "$branch"
  if (( ${#REPLY_LIST[@]} )) && (( ! RECURSIVE )); then
    die "branch '$branch' has twigs; pass --recursive to remove them too"
  fi
  echo "Will remove:" >&2
  { echo "$branch"; ent_descendants "$branch"; } | sed 's/^/  /' >&2
  confirm "Remove $branch?" || { note "Cancelled."; return 0; }
  rm_tree "$branch"
  note "Removed $branch"
}
