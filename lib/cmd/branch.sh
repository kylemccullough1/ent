# ent branch: create a top-level branch under <ent>/branches/.

help_branch() { cat <<'EOF'
branch <name> [--from <base>]          create a branch at branches/<name>/core
  Inside feature/x, a bare name like `foo` becomes feature/foo.
  Cut from the default branch, or from --from <base>.
  The name must match branchPattern if .entrc sets one.
EOF
}

# check_new_name <branch>: refuse names that exist or collide with ent's own folders.
check_new_name() {
  has_local "$1" && die "branch '$1' already exists"
  case "$(ent_slug "$1")" in main|branches|twigs|core|.bare|.git) die "'$1' resolves to a reserved name" ;; esac
  return 0
}

cmd_branch() {
  ensure_ent
  local given branch pat base core_dir
  given="$(arg 1)"
  [[ -n "$given" && -z "$(arg 2)" ]] || usage_die "branch <name> [--from <base>]"
  branch="$(ent_branch_name_for_arg "$given")"
  check_new_name "$branch"
  pat="$(branch_pattern)"
  if [[ -n "$pat" && ! "$branch" =~ $pat ]]; then die "branch '$branch' does not match branchPattern: $pat"; fi
  if [[ -n "$FROM" ]]; then
    base="$FROM"; has_local "$base" || has_remote "$base" || die "base branch '$base' not found"
  else
    base="$S_MAIN"
  fi
  has_local "$base" || base="origin/$base"
  core_dir="$ENT/branches/$branch/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "$ENT/branches/$branch/twigs"
  run git -C "$ENT" worktree add --no-track -b "$branch" "$core_dir" "$base"
  emit_path "$core_dir" "Created branch $branch at $core_dir"
}
