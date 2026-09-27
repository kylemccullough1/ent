# ent status: git status for every worktree, one screen you tab through.

help_status() { cat <<'EOF'
status                                 git status for every worktree, full screen
  tab / shift-tab  next / previous worktree      j k and arrows  scroll
  space b          page down / up                g G             top / bottom
  r                reload                        q               quit
  Piped or redirected (ent status > file), it prints every worktree instead.
EOF
}

# render_status <branch> <path>: what one worktree's screen shows.
render_status() {
  local b="$1" p="$2"
  git -c color.ui="$VIEW_COLOR" -C "$p" status --short --branch
  # --short says nothing when a merge is unfinished; git status's long form does.
  if mid_merge "$p"; then
    printf '\n%s\n' "$(git -c color.ui="$VIEW_COLOR" -C "$p" status --long | sed -n '/^You have unmerged paths/,$p')"
  fi
}

cmd_status() { take_flags status; view_run "ent status" render_status; }
