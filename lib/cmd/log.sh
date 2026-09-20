# ent log: git log for every worktree, one screen you tab through.

help_log() { cat <<'EOF'
log [-- <git log args>]                git log for every worktree, full screen
  Same keys as `ent status` (tab switches worktree, q quits).
  Default view: git log --graph --oneline --decorate -n 200
  Pass your own instead:  ent log -- --stat -n 20
EOF
}

# render_log <branch> <path>: what one worktree's screen shows.
render_log() {
  local p="$2"
  if (( ${#LOG_ARGS[@]} )); then
    git -c color.ui="$VIEW_COLOR" -C "$p" log "${LOG_ARGS[@]}"
  else
    git -c color.ui="$VIEW_COLOR" -C "$p" log --graph --oneline --decorate -n 200
  fi
}

cmd_log() {
  # Everything after `--` belongs to git log, e.g. `ent log -- --stat -n 20`.
  LOG_ARGS=(${REST_ARGS[@]+"${REST_ARGS[@]}"})
  view_run "ent log" render_log
}
