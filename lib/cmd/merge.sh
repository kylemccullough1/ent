# ent branch merge: merge the current branch into its target, then remove it.

help_merge() { cat <<'EOF'
branch merge [-y]                      merge the current branch into its parent, then remove it
  A branch merges into main; a twig merges into the branch or twig it grew from.
  Run inside the core/ folder. The branch's own twigs are merged into it first.
  Shows the diff and asks before merging unless -y.
  On conflicts: fix them, then `ent branch merge --continue` (or --abort).
  --tab / --new-window open the branch it merged into in Windows Terminal; this
  shell moves to the ent root, since the folder it stood in is gone.
EOF
}

# mid_merge <worktree>: true while a merge there is unfinished (MERGE_HEAD exists).
mid_merge() { git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; }

worktree_dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }

# do_merge <src> <target>: merge src into target's worktree. Returns 1 on refusal or conflict.
do_merge() {
  local src="$1" tgt="$2" tp
  [[ "$src" != "$tgt" ]] || die "cannot merge $src into itself"
  has_local "$src" || die "no branch '$src'"
  has_local "$tgt" || die "no branch '$tgt'"
  wt_path_of "$tgt" || die "$tgt has no worktree to merge into"
  tp="$REPLY"
  if mid_merge "$tp"; then die "$tgt is already mid-merge. Use branch merge --abort or --continue from $tp"; fi
  if worktree_dirty "$tp"; then die "$tgt has uncommitted changes in $tp"; fi
  if git -C "$ENT" merge-base --is-ancestor "$src" "$tgt"; then note "$tgt already contains $src"; return 0; fi
  note "Changes $src would bring into $tgt:"
  run git --no-pager -C "$tp" diff --stat "$tgt...$src"
  confirm "Merge $src into $tgt?" || return 1
  if (( DRY_RUN )); then note "(dry run: not merged)"; return 0; fi
  if run git -C "$tp" merge --no-edit "$src"; then note "Merged $src into $tgt."; return 0; fi
  if mid_merge "$tp"; then
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
  top="$(git -C "${ENT_PWD:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || die "run from inside the worktree that is mid-merge"
  mid_merge "$top" || die "no merge in progress in $top"
  if (( MERGE_ABORT )); then run git -C "$top" merge --abort
  else run env GIT_EDITOR=true git -C "$top" merge --continue; fi
  return 0
}

cmd_merge() {
  ensure_ent
  MERGE_ABORT=0 MERGE_CONTINUE=0
  take_flags "branch merge" --abort:MERGE_ABORT --continue:MERGE_CONTINUE
  if merge_abort_or_continue; then return 0; fi
  local src target
  [[ -z "$(arg 2)" ]] || usage_die "branch merge [-y]   (merges into the parent; no target)"
  src="$(ent_branch_of_core)" || die "run from inside a core worktree"
  [[ "$src" != "$S_MAIN" ]] || die "$S_MAIN has no parent to merge into"
  parent_of "$src"; target="${REPLY:-$S_MAIN}"
  has_local "$target" || die "parent branch '$target' no longer exists"

  if [[ -n "$(ent_children "$src")" ]]; then
    confirm "Also merge the twigs of $src (all levels) into $src before merging into $target?" || return 1
    merge_twigs_up "$src" || return 1
  fi

  do_merge "$src" "$target" || return 1
  local target_core; target_core="$(ent_core "$target")"
  cd "$ENT"   # step out of the folder that is about to be removed
  RM_LEFTOVER=()
  rm_tree "$src"
  if (( ${#RM_LEFTOVER[@]} )); then emit_path "$target_core" "Merged $src; its folder is still there (see above)" "$target"
  else emit_path "$target_core" "Merged and finished $src" "$target"; fi
  # With --tab the target opened elsewhere, but this shell still stands in the
  # folder just removed; hand the wrapper the ent root to move it somewhere real.
  if [[ -n "$OPEN_MODE" ]]; then printf '%s\n' "$ENT"; fi
}

# merge_twigs_up <branch>: merge every twig below <branch> into its parent,
# deepest first, so nothing below is left unmerged when the tree is removed.
merge_twigs_up() {
  local child kids
  children_of "$1"
  kids=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  for child in ${kids[@]+"${kids[@]}"}; do
    merge_twigs_up "$child" || return 1
    do_merge "$child" "$1" || return 1
  done
}
