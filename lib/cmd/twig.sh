# ent twig: create a child worktree of a branch or another twig.

help_twig() { cat <<'EOF'
twig <name> [--from <parent>]          create a twig of the current branch or twig
  Inside feature/x, `twig auth` makes branch feature/x-auth at
  branches/feature/x/twigs/auth/core, cut from feature/x.
  From main or the ent root, name the parent with --from.
  Nesting stops at maxDepth (default 2) from .entrc.
EOF
}

cmd_twig() {
  ensure_ent
  local name parent branch container core_dir depth
  name="$(arg 1)"
  [[ -n "$name" && -z "$(arg 2)" ]] || usage_die "twig <name> [--from <parent>]"
  if [[ -n "$FROM" ]]; then
    parent="$FROM"
  else
    parent="$(ent_branch_of_cwd)" || die "ent twig <name> must be inside a branch or twig, or use --from"
    [[ "$parent" != "$S_MAIN" ]] || die "ent twig <name> must be inside a branch or twig, or use --from"
  fi
  has_local "$parent" || die "parent branch '$parent' not found"
  branch="$parent-$name"
  check_new_name "$branch"
  depth="$(ent_depth "$parent")"; depth=$((depth + 1))
  (( depth <= $(max_depth) )) || die "twig '$name' would be at depth $depth; maxDepth is $(max_depth)"
  # entParent is recorded only after the worktree exists, so build the path from the parent.
  container="$(ent_container "$parent")/twigs/$name"
  core_dir="$container/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "$container"
  run git -C "$ENT" worktree add --no-track -b "$branch" "$core_dir" "$parent"
  run git -C "$ENT" config "branch.$branch.entParent" "$parent"
  emit_path "$core_dir" "Created twig $branch at $core_dir"
}
