# ent twig: create a child worktree of a branch.

help_twig() { cat <<'EOF'
twig <name> [--from <branch>]          create a twig of the current branch
  Inside mainb, `twig mainc` makes branch twigs/mainb/mainc at
  branches/mainb/twigs/mainc/core, cut from mainb.
  From main or the ent root, name the branch with --from.
  Twigs go one level deep: git cannot have both a branch and a folder of the
  same name, so a twig of a twig has no name left to use.
EOF
}

parse_twig_args() {
  local i=0 new_args=()
  FROM=""
  while (( i < ${#ARGS[@]} )); do
    local a="${ARGS[$i]}"
    case "$a" in
      --from)   i=$((i+1)); FROM="${ARGS[$i]:-}"; [[ -n "$FROM" ]] || die "--from requires a value" ;;
      -*)       die "unknown twig option: $a" ;;
      *)        new_args+=("$a") ;;
    esac
    i=$((i+1))
  done
  ARGS=("${new_args[@]}")
}

cmd_twig() {
  ensure_ent
  parse_twig_args
  local name parent branch container core_dir
  name="$(arg 1)"
  [[ -n "$name" && -z "$(arg 2)" ]] || usage_die "twig <name> [--from <branch>]"
  [[ "$name" != */* ]] || die "twig name '$name' cannot contain '/'"
  if [[ -n "$FROM" ]]; then
    parent="$FROM"
  else
    parent="$(ent_branch_of_cwd)" || die "ent twig <name> must be inside a branch, or use --from"
    [[ "$parent" != "$S_MAIN" ]] || die "ent twig <name> must be inside a branch, or use --from"
  fi
  has_local "$parent" || die "branch '$parent' not found"
  branch="twigs/$parent/$name"
  # A twig's name is already twigs/<branch>/<twig>, and git refuses to create
  # twigs/<branch>/<twig>/<name> while twigs/<branch>/<twig> is a branch: one name
  # cannot be both a ref and a folder of refs.
  parent_of "$parent"
  if [[ -n "$REPLY" || "$parent" == twigs/* ]]; then
    die "'$parent' is a twig, and twigs go one level deep: git cannot create a branch under '$parent' while that name is itself a branch"
  fi
  check_new_name "$branch"
  # entParent is recorded only after the worktree exists, so build the path from the parent.
  container="$(ent_container "$parent")/twigs/$name"
  core_dir="$container/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "$container"
  run git -C "$ENT" worktree add --no-track -b "$branch" "$core_dir" "$parent"
  worktree_bare_guard "$core_dir"
  tree_add_node "$branch" twig "$parent" "branches/$parent/twigs/$name/core"
  run git -C "$ENT" config "branch.$branch.entParent" "$parent"
  emit_path "$core_dir" "Created twig $branch at $core_dir"
}
