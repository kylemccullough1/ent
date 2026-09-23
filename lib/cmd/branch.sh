# ent branch: create a top-level branch under <ent>/branches/.

help_branch() { cat <<'EOF'
branch <name> [--from <base>]          create a branch at branches/<name>/core
  Cut from the branch or twig you are standing in (main from the ent root),
  or from --from <base>. Its parent is always main.
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

# branch_adopt <branch>: the branch exists but has no worktree, so give it its
# folder back. The "already exists" refusal is there to stop you clobbering a
# branch; with no folder there is nothing to clobber. branchPattern is not
# applied here -- the branch exists either way, and refusing it a folder over a
# naming rule helps nobody.
branch_adopt() {
  local branch="$1" core_dir container
  container="$(ent_container "$branch")" core_dir="$container/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "$container/twigs"
  # No -b: the branch is already there, we are only checking it out.
  run git -C "$ENT" worktree add "$core_dir" "$branch"
  worktree_bare_guard "$core_dir"
  emit_path "$core_dir" "Gave existing branch $branch a folder at $core_dir"
}

cmd_branch() {
  ensure_ent
  local branch pat base core_dir
  branch="$(arg 1)"
  [[ -n "$branch" && -z "$(arg 2)" ]] || usage_die "branch <name> [--from <base>]"
  # An existing branch with no worktree is adopted rather than refused. This
  # comes before the twigs/ guard: that guard stops you CREATING a twig branch
  # by hand, but an existing one deserves its folder back like any other.
  if has_local "$branch" && ! wt_path_of "$branch"; then branch_adopt "$branch"; return; fi
  [[ "$branch" != twigs/* ]] || die "'twigs/' is reserved for twig branches; pick another name"
  check_new_name "$branch"
  pat="$(branch_pattern)"
  if [[ -n "$pat" && ! "$branch" =~ $pat ]]; then die "branch '$branch' does not match branchPattern: $pat"; fi
  if [[ -n "$FROM" ]]; then
    base="$FROM"; has_local "$base" || has_remote "$base" || die "base branch '$base' not found"
  else
    base="$(ent_branch_of_cwd 2>/dev/null)" || base="$S_MAIN"
  fi
  has_local "$base" || base="origin/$base"
  core_dir="$ENT/branches/$branch/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "$ENT/branches/$branch/twigs"
  run git -C "$ENT" worktree add --no-track -b "$branch" "$core_dir" "$base"
  worktree_bare_guard "$core_dir"
  emit_path "$core_dir" "Created branch $branch at $core_dir"
}
