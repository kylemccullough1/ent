# ent branch merge: merge the current branch into its target, then remove it.

help_merge() { cat <<'EOF'
branch merge [-y]                      merge the current branch into its parent, then remove it
  A branch merges into main; a twig merges into the branch or twig it grew from.
  Run inside the core/ folder. The branch's own twigs are merged into it first.
  Shows the diff and asks before merging unless -y.
  On conflicts: fix them, then `ent branch merge --continue` (or --abort).
EOF
}

# merge_head_of <worktree>: path of MERGE_HEAD, which exists while a merge is unfinished.
merge_head_of() { git -C "$1" rev-parse --path-format=absolute --git-path MERGE_HEAD 2>/dev/null; }

worktree_dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }

# do_merge <src> <target>: merge src into target's worktree. Returns 1 on refusal or conflict.
do_merge() {
  local src="$1" tgt="$2" tp
  [[ "$src" != "$tgt" ]] || die "cannot merge $src into itself"
  has_local "$src" || die "no branch '$src'"
  has_local "$tgt" || die "no branch '$tgt'"
  wt_path_of "$tgt" || die "$tgt has no worktree to merge into"
  tp="$REPLY"
  if [[ -f "$(merge_head_of "$tp")" ]]; then die "$tgt is already mid-merge. Use branch merge --abort or --continue from $tp"; fi
  if worktree_dirty "$tp"; then die "$tgt has uncommitted changes in $tp"; fi
  if git -C "$ENT" merge-base --is-ancestor "$src" "$tgt"; then note "$tgt already contains $src"; return 0; fi
  note "Changes $src would bring into $tgt:"
  run git --no-pager -C "$tp" diff --stat "$tgt...$src"
  confirm "Merge $src into $tgt?" || return 1
  if (( DRY_RUN )); then note "(dry run: not merged)"; return 0; fi
  if run git -C "$tp" merge --no-edit "$src"; then note "Merged $src into $tgt."; return 0; fi
  if [[ -f "$(merge_head_of "$tp")" ]]; then
    warn "conflicts merging $src into $tgt"
    git -C "$tp" diff --name-only --diff-filter=U >&2
    note "Resolve in $tp, then: ent branch merge --continue (or --abort)"
    return 1
  fi
  die "git merge failed in $tp"
}

# merge_abort_or_continue: handle --abort / --continue in the current worktree.
merge_abort_or_continue() {
  (( MERGE_ABORT || MERGE_CONTINUE )) || return 1
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || die "run from inside the worktree that is mid-merge"
  [[ -f "$(merge_head_of "$top")" ]] || die "no merge in progress in $top"
  if (( MERGE_ABORT )); then run git -C "$top" merge --abort
  else run env GIT_EDITOR=true git -C "$top" merge --continue; fi
  return 0
}

cmd_merge() {
  ensure_ent
  if merge_abort_or_continue; then return 0; fi
  local src target child
  [[ -z "$(arg 2)" ]] || usage_die "branch merge [-y]   (merges into the parent; no target)"
  src="$(ent_branch_of_core)" || die "run from inside a core worktree"
  [[ "$src" != "$S_MAIN" ]] || die "$S_MAIN has no parent to merge into"
  parent_of "$src"; target="${REPLY:-$S_MAIN}"
  has_local "$target" || die "parent branch '$target' no longer exists"

  children_of "$src"
  if (( ${#REPLY_LIST[@]} )); then
    local kids=("${REPLY_LIST[@]}")
    confirm "Also merge twigs of $src into $src before merging into $target?" || return 1
    for child in "${kids[@]}"; do do_merge "$child" "$src" || return 1; done
  fi

  do_merge "$src" "$target" || return 1
  rm_tree "$src"
  note "Merged and finished $src"
}
