# ent branch: create a top-level branch under <ent>/branches/.

help_branch() { cat <<'EOF'
branch <name> [--from <base>] | branch [<name>] --remote <remote-branch>
  create a branch at branches/<name>/core
  Cut from the branch or twig you are standing in (main from the ent root),
  from --from <base> (another local branch), or from --remote <remote-branch>
  on origin. --remote sets the upstream to origin/<remote-branch>.
  With --remote, <name> is optional and defaults to <remote-branch>.
  The name is used exactly as given and must match branchPattern if .entrc sets one.
EOF
}

# check_new_name <branch>: refuse names that exist or collide with ent's own folders.
# `twigs/...` is where twig branches live, so a branch may not claim that namespace.
check_new_name() {
  if has_local "$1"; then
    wt_path_of "$1" && die "branch '$1' already exists, at $REPLY"
    die "branch '$1' already exists"
  fi
  case "$(ent_slug "$1")" in main|branches|twigs|core|.bare|.git) die "'$1' resolves to a reserved name" ;; esac
  return 0
}

cmd_branch() {
  ensure_ent
  FROM="" REMOTE=""
  take_flags branch --from=FROM --remote=REMOTE
  local branch pat base core_dir track_arg
  [[ -z "$FROM" || -z "$REMOTE" ]] || die "--from and --remote are mutually exclusive"

  if [[ -n "$REMOTE" ]]; then
    branch="$(arg 1)"
    [[ -n "$branch" ]] || branch="$REMOTE"
  elif [[ -n "$FROM" ]]; then
    branch="$(arg 1)"
    [[ -n "$branch" ]] || usage_die "branch <name> --from <base>"
  else
    branch="$(arg 1)"
    [[ -n "$branch" ]] || usage_die "branch <name> [--from <base>] | branch [<name>] --remote <remote-branch>"
  fi
  [[ -z "$(arg 2)" ]] || usage_die "branch <name> [--from <base>] | branch [<name>] --remote <remote-branch>"

  # An existing branch with no worktree is adopted rather than refused. This
  # comes before the twigs/ guard: that guard stops you CREATING a twig branch
  # by hand, but an existing one deserves its folder back like any other.
  if has_local "$branch" && ! wt_path_of "$branch"; then
    tree_adopt_if_missing "$branch"
    emit_path "$(ent_core "$branch")" "Gave existing branch $branch a folder"
    return
  fi
  [[ "$branch" != twigs/* ]] || die "'twigs/' is reserved for twig branches; pick another name"
  check_new_name "$branch"
  pat="$(branch_pattern)"
  if [[ -n "$pat" && ! "$branch" =~ $pat ]]; then die "branch '$branch' does not match branchPattern: $pat"; fi
  if [[ -n "$REMOTE" ]]; then
    has_remote "$REMOTE" || die "remote branch '$REMOTE' not found"
    base="origin/$REMOTE"
    track_arg="--track"
  elif [[ -n "$FROM" ]]; then
    has_local "$FROM" || die "base branch '$FROM' not found locally"
    base="$FROM"
    track_arg="--no-track"
  else
    base="$(ent_branch_of_cwd 2>/dev/null)" || base="$S_MAIN"
    track_arg="--no-track"
  fi
  core_dir="$ENT/branches/$branch/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "$ENT/branches/$branch/twigs"
  run git -C "$ENT" worktree add "$track_arg" -b "$branch" "$core_dir" "$base"
  worktree_bare_guard "$core_dir"
  tree_add_node "$branch" branch "$S_MAIN" "branches/$branch/core"
  emit_path "$core_dir" "Created branch $branch at $core_dir"
}
