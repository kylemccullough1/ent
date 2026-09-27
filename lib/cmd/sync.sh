# ent sync: bring main up to date with origin, offer to clean up merged branches,
# then merge main into your branches and twigs.

help_sync() { cat <<'EOF'
sync [branch] [-y]                     update main from origin, then merge main into your work
  1. With an origin: fetch, fast-forward main, then for each branch that is now
     merged into main, ask whether to delete its folder and branch (-y: yes to all).
     Merge commits, squash merges and rebase merges are all recognized. Protected
     branches, uncommitted changes and twigs with unmerged work are always kept.
  2. Merge main into every branch and twig, or only into [branch].
     Folders with uncommitted changes are skipped; conflicts are left for you to
     resolve and listed at the end.
EOF
}

cmd_sync() {
  ensure_ent; cd "$ENT"
  take_flags sync
  local only; only="$(arg 1)"
  [[ -z "$(arg 2)" ]] || usage_die "sync [branch] [-y]"
  if [[ -n "$only" ]]; then
    has_local "$only" || die "branch '$only' not found"
    [[ "$only" != "$S_MAIN" ]] || die "sync updates $S_MAIN itself; name a branch or twig to merge it into"
  fi

  if has_origin; then sync_main; else note "No origin remote; skipping the pull."; fi
  load_state
  sync_worktrees "$only"
  load_state
  cmd_list
}

# ---------- step 1: pull main, offer to remove merged branches ----------

sync_main() {
  local main_path old_main new_main b reason
  old_main="$(git -C "$ENT" rev-parse "$S_MAIN")"
  run git -C "$ENT" fetch --prune origin
  if ! wt_path_of "$S_MAIN"; then
    warn "$S_MAIN has no worktree; not updating it"
  elif worktree_dirty "$REPLY"; then
    warn "$S_MAIN has uncommitted changes in $REPLY; not updating it"
  else
    main_path="$REPLY"
    if git -C "$ENT" rev-parse -q --verify "refs/remotes/origin/$S_MAIN" >/dev/null; then
      run git -C "$main_path" merge --ff-only "origin/$S_MAIN" \
        || warn "$S_MAIN has local commits that are not on origin; not fast-forwarding"
    fi
  fi
  new_main="$(git -C "$ENT" rev-parse "$S_MAIN")"
  load_state

  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" != "$S_MAIN" ]] || continue
    git -C "$ENT" show-ref -q --verify "refs/heads/$b" || continue   # removed with its parent
    reason="$(merged_reason "$b" "$old_main" "$new_main")" || continue
    offer_removal "$b" "$reason"
  done
}

# merged_reason <branch> <old-main> <new-main>: print why the branch counts as merged
# by this pull, or return 1. Only verifiable facts count:
#   - its commits are in main now (merge commit), or
#   - its changes are in main now (squash or rebase merge; needs git 2.38+).
# A branch that was already in the old main (every brand-new branch is) never counts,
# and a branch deleted on origin without being merged (a closed PR) is not offered.
merged_reason() {
  local b="$1" old="$2" new="$3"
  if git -C "$ENT" merge-base --is-ancestor "$b" "$old"; then return 1; fi
  if git -C "$ENT" merge-base --is-ancestor "$b" "$new"; then echo "merged into $S_MAIN"; return 0; fi
  if content_already_in "$new" "$b" && ! content_already_in "$old" "$b"; then
    echo "its changes are in $S_MAIN (squash or rebase merge)"; return 0
  fi
  return 1
}

# content_already_in <commit> <branch>: true when merging <branch> into <commit> would
# change nothing, i.e. the branch's changes are already there. Uses
# merge-tree --write-tree (git 2.38+); on older git it is always false.
content_already_in() {
  local tree
  tree="$(git -C "$ENT" merge-tree --write-tree "$1" "$2" 2>/dev/null | head -n 1)" || return 1
  [[ -n "$tree" && "$tree" == "$(git -C "$ENT" rev-parse "$1^{tree}")" ]]
}

# in_main <branch>: its commits or its changes are in main.
in_main() {
  git -C "$ENT" merge-base --is-ancestor "$1" "$S_MAIN" || content_already_in "$S_MAIN" "$1"
}

# offer_removal <branch> <reason>: ask, then remove the branch, its twigs, and their folders.
# Keeps everything when anything in the tree is protected, has uncommitted changes,
# or (for twigs) holds work that is not in main.
offer_removal() {
  local b="$1" reason="$2" kids t
  kids="$(ent_descendants "$b")"
  note ""
  note "$b: $reason."
  for t in "$b" $kids; do
    if is_protected "$t"; then note "Keeping $b: $t is protected."; return 0; fi
    if wt_path_of "$t" && worktree_dirty "$REPLY"; then note "Keeping $b: $t has uncommitted changes."; return 0; fi
  done
  for t in $kids; do
    in_main "$t" || { note "Keeping $b: twig $t has work that is not in $S_MAIN."; return 0; }
    note "  twig $t (also in $S_MAIN)"
  done
  confirm "Delete $b${kids:+ and its twigs}, folders and branches?" || { note "Kept $b."; return 0; }
  # Every branch in the tree is verified to be in main, so a squash-merged branch
  # that git calls "unmerged" may be deleted.
  local FORCE=1
  rm_tree "$b"
  note "Removed $b."
}

# ---------- step 2: merge main into branches and twigs ----------

sync_worktrees() {
  local only="$1" b p targets=() merged=() current=() skipped=() conflicts=()
  if [[ -n "$only" ]]; then targets=("$only"); else targets=(${S_LOCAL[@]+"${S_LOCAL[@]}"}); fi
  for b in ${targets[@]+"${targets[@]}"}; do
    [[ "$b" != "$S_MAIN" ]] || continue
    if ! wt_path_of "$b"; then [[ -z "$only" ]] || skipped+=("$b (no worktree)"); continue; fi
    p="$REPLY"
    if mid_merge "$p"; then skipped+=("$b (already mid-merge)"); continue; fi
    if worktree_dirty "$p"; then skipped+=("$b (uncommitted changes)"); continue; fi
    if git -C "$ENT" merge-base --is-ancestor "$S_MAIN" "$b"; then current+=("$b"); continue; fi
    if run git -C "$p" merge --no-edit "$S_MAIN"; then merged+=("$b")
    elif mid_merge "$p"; then conflicts+=("$b  ($p)")
    else skipped+=("$b (git merge failed)"); fi
  done

  note ""
  note "Merged $S_MAIN into: ${merged[*]:-nothing}"
  (( ${#current[@]} ))   && note "Already up to date: ${current[*]}"
  (( ${#skipped[@]} ))   && { note "Skipped:"; printf '  %s\n' "${skipped[@]}" >&2; }
  if (( ${#conflicts[@]} )); then
    warn "conflicts to resolve (then commit, or git merge --abort):"
    printf '  %s\n' "${conflicts[@]}" >&2
  fi
  return 0
}
