# ent sync: fetch, fast-forward main, and fast-forward clean worktrees to main.

help_sync() { cat <<'EOF'
sync                                   fetch; fast-forward main and clean worktrees
EOF
}

cmd_sync() {
  ensure_ent; cd "$ENT"
  local b p up stale=""
  run git -C "$ENT" fetch --all --prune
  if wt_path_of "$S_MAIN" && ! worktree_dirty "$REPLY"; then
    p="$REPLY"
    up="$(git -C "$ENT" rev-parse --abbrev-ref "$S_MAIN@{u}" 2>/dev/null || true)"
    if [[ -n "$up" ]]; then run git -C "$p" merge --ff-only "$up" || true; fi
  fi
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" != "$S_MAIN" ]] || continue
    wt_path_of "$b" || continue
    p="$REPLY"
    if worktree_dirty "$p"; then warn "skip $b: uncommitted changes"; continue; fi
    run git -C "$p" merge --ff-only "$S_MAIN" || warn "$b: could not fast-forward to $S_MAIN"
  done
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" != "$S_MAIN" ]] || continue
    has_remote "$b" && continue
    if git -C "$ENT" merge-base --is-ancestor "$b" "$S_MAIN" 2>/dev/null; then stale+=" $b"; fi
  done
  if [[ -n "$stale" ]]; then
    echo "Local branches merged into $S_MAIN with no remote tracking branch:"
    printf '  %s\n' $stale
    if [[ -t 0 ]]; then
      if confirm "Remove these local branches and their worktrees?"; then
        for b in $stale; do rm_tree "$b" || warn "could not remove $b"; done
      fi
    else
      echo "Run interactively to clean them up."
    fi
  fi
  load_state
  cmd_list
}
