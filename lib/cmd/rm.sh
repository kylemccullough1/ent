# ent rm: remove a branch or twig: its worktree, its folder, and the git branch.

help_rm() { cat <<'EOF'
rm <branch> [-r] [-f] [-y]             remove a branch or twig and its folder
  Lists what will go and asks first (-y skips the question).
  -r  also remove its twigs      -f  remove even with uncommitted or unmerged work
  Also clears up what is left over: a folder git no longer lists as a worktree,
  a worktree whose folder was deleted or moved, a branch with no folder, or a
  folder whose git branch is gone. A leftover folder still holding files needs -f.
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

# is_protected <branch>: the default branch, or listed in the protect setting.
is_protected() {
  local p
  [[ "$1" != "$S_MAIN" ]] || return 0
  for p in $(cfg_all protect); do [[ "$1" != "$p" ]] || return 0; done
  return 1
}

# rm_one <branch>: remove one branch from whatever state it is in: its worktree
# (wherever git has it), the git branch, its ent record and its folders.
#   - a worktree git lists but whose folder is gone: pruned first, or git keeps
#     calling the branch checked out and refuses to delete it
#   - a folder git no longer lists (a remove that failed halfway): deleted;
#     one that still holds files needs --force, since no worktree owns them
#   - no git branch any more: the record and the folder still go
# When Windows will not let a folder go (something is standing in it), the rest
# is removed anyway and the record is kept, so `ent rm <branch>` can finish.
rm_one() {
  local b="$1" core_dir container live="" d
  core_dir="$(ent_core "$b")" container="$(ent_container "$b")"
  if (( DRY_RUN )); then note "(dry run) would remove $b and $container"; return 0; fi
  if wt_path_of "$b"; then live="$REPLY"; fi
  if [[ -n "$live" && ! -d "$live" ]]; then run git -C "$ENT" worktree prune; live=""; fi
  # Checked before anything is deleted, so a refusal leaves everything as it was.
  if [[ -d "$core_dir" && "$core_dir" != "$live" ]] && has_files "$core_dir" && (( ! FORCE )); then
    die "$core_dir is not a worktree but still holds files; look at them, then pass --force"
  fi
  if [[ -n "$live" ]]; then
    if worktree_dirty "$live"; then
      (( FORCE )) || die "branch '$b' has uncommitted changes; pass --force or commit them"
      warn "force-removing dirty worktree $b"
    fi
    rm_worktree "$b" "$live"
  fi
  if has_local "$b"; then
    if git -C "$ENT" branch -d "$b" >/dev/null 2>&1; then :
    elif merged_into_parent "$b" || (( FORCE )); then run git -C "$ENT" branch -D "$b"
    else die "branch '$b' is not fully merged; pass --force to delete"; fi
  fi
  git -C "$ENT" config --unset "branch.$b.entParent" >/dev/null 2>&1 || true
  for d in "$live" "$core_dir"; do
    rm_leftover "$d" && continue
    warn "could not delete $d: something is standing in it (a shell, an editor, a terminal). Leave it, then run: ent rm $b"
    RM_LEFTOVER+=("$d")
    return 0   # keep the record: it is how the rerun finds the folder
  done
  tree_remove_node "$b"
  prune_empty_dirs "$container/twigs"
  return 0
}

# rm_worktree <branch> <path>: git worktree remove. When Windows keeps the folder
# (something is standing in it) git still unregisters the worktree and deletes
# what it can, then fails; that is fine, rm_leftover sees to the folder. Any
# other failure (uncommitted changes, a lock) leaves it registered: stop there.
rm_worktree() {
  local flags=()
  if (( FORCE )); then flags=(--force --force); fi   # twice also takes a locked one
  if run git -C "$ENT" worktree remove ${flags[@]+"${flags[@]}"} "$2"; then return 0; fi
  load_state
  if wt_path_of "$1"; then die "could not remove the worktree of '$1' at $2"; fi
}

# rm_leftover <dir>: delete a folder that is no longer any worktree. Returns 1
# when it is still there afterwards.
rm_leftover() {
  [[ -n "$1" && -d "$1" ]] || return 0
  run rm -rf "$1" 2>/dev/null || true
  [[ ! -d "$1" ]]
}

# has_files <dir>: true when anything but folders is inside.
has_files() { [[ -n "$(find "$1" ! -type d 2>/dev/null | head -n 1)" ]]; }

# prune_empty_dirs <dir>: remove <dir> and the empty folders above it, stopping
# at branches/ and main/. A twigs/ folder stays while its branch's core/ does,
# and nothing outside the ent is touched (a worktree kept outside by init --here).
prune_empty_dirs() {
  local d="$1"
  while [[ "$d" == "$ENT"/?* && "$d" != "$ENT/branches" && "$d" != "$ENT/main" ]]; do
    if [[ "${d##*/}" == twigs && -d "${d%/twigs}/core" ]]; then break; fi
    if [[ -d "$d" ]]; then rmdir "$d" 2>/dev/null || break; fi
    d="${d%/*}"
  done
}

# rm_describe <branch>: REPLY = what there is to remove, for the preview, e.g.
# "worktree, branch" or "leftover folder (not a worktree), no git branch".
rm_describe() {
  local b="$1" core live="" out=""
  core="$(ent_core "$b")"
  if wt_path_of "$b"; then live="$REPLY"; fi
  if [[ -n "$live" && ! -d "$live" ]]; then out="worktree whose folder is gone"
  elif [[ -n "$live" && "$live" != "$core" ]]; then out="worktree at $live"
  elif [[ -n "$live" ]]; then out="worktree"; fi
  if [[ -d "$core" && "$core" != "$live" ]]; then out+="${out:+, }leftover folder (not a worktree)"; fi
  if has_local "$b"; then out+="${out:+, }branch"; else out+="${out:+, }no git branch"; fi
  REPLY="$out"
}

cmd_rm() {
  ensure_ent
  FORCE=0 RECURSIVE=0
  take_flags rm "--force|-f:FORCE" "--recursive|-r:RECURSIVE"
  cd "$ENT"   # never stand inside a worktree that is about to be removed
  local branch t
  branch="$(arg 1)"
  [[ -n "$branch" && -z "$(arg 2)" ]] || usage_die "rm <branch> [-r] [-f]"
  [[ "$branch" != "$S_MAIN" ]] || die "cannot remove the default branch '$S_MAIN'"
  is_protected "$branch" && die "branch '$branch' is protected"
  # The name becomes a folder path below, so it must be a legal branch name:
  # `ent rm ../..` must never reach rm -rf.
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "'$branch' is not a branch name"
  # No branch is fine as long as something is left to remove: a record or a folder.
  has_local "$branch" || tree_node_exists "$branch" || [[ -d "$(ent_container "$branch")" ]] \
    || die "nothing named '$branch': no branch, no ent record, no folder"
  children_of "$branch"
  if (( ${#REPLY_LIST[@]} )) && (( ! RECURSIVE )); then
    die "branch '$branch' has twigs; pass --recursive to remove them too"
  fi
  echo "Will remove:" >&2
  for t in "$branch" $(ent_descendants "$branch"); do
    rm_describe "$t"; printf '  %s  (%s)\n' "$t" "$REPLY" >&2
  done
  confirm "Remove $branch?" || { note "Cancelled."; return 0; }
  RM_LEFTOVER=()
  rm_tree "$branch"
  (( ${#RM_LEFTOVER[@]} )) || note "Removed $branch"
}
