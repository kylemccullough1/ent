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
  has_local "$1" && die "branch '$1' already exists"
  case "$(ent_slug "$1")" in main|branches|twigs|core|.bare|.git) die "'$1' resolves to a reserved name" ;; esac
  return 0
}

cmd_branch() {
  ensure_ent
  local branch pat base core_dir
  branch="$(arg 1)"
  [[ -n "$branch" && -z "$(arg 2)" ]] || usage_die "branch <name> [--from <base>]"
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
  emit_path "$core_dir" "Created branch $branch at $core_dir"
}
