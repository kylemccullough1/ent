# ent track: set or change the upstream of an existing local branch.

help_track() { cat <<'EOF'
track [<branch>] --remote <remote-branch>
  Link an existing local branch to origin/<remote-branch>.
  If <branch> is omitted, use the branch you are standing in.
EOF
}

parse_track_args() {
  local i=0 new_args=()
  REMOTE=""
  while (( i < ${#ARGS[@]} )); do
    local a="${ARGS[$i]}"
    case "$a" in
      --remote) i=$((i+1)); REMOTE="${ARGS[$i]:-}"; [[ -n "$REMOTE" ]] || die "--remote requires a value" ;;
      -*)       die "unknown track option: $a" ;;
      *)        new_args+=("$a") ;;
    esac
    i=$((i+1))
  done
  ARGS=("${new_args[@]}")
}

cmd_track() {
  ensure_ent
  parse_track_args
  local branch
  [[ -n "$REMOTE" ]] || usage_die "track [<branch>] --remote <remote-branch>"
  branch="$(arg 1)"
  [[ -z "$(arg 2)" ]] || usage_die "track [<branch>] --remote <remote-branch>"
  if [[ -z "$branch" ]]; then
    branch="$(ent_branch_of_cwd 2>/dev/null)" || die "track --remote needs a branch name when outside a branch"
  fi
  has_local "$branch" || die "branch '$branch' not found locally"
  has_remote "$REMOTE" || die "remote branch '$REMOTE' not found"
  run git -C "$ENT" branch --set-upstream-to="origin/$REMOTE" "$branch"
  note "Set $branch to track origin/$REMOTE"
}
