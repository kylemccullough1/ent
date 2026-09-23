# ent list: draw every branch with its twigs nested underneath.

help_list() { cat <<'EOF'
list                                   show branches and twigs as a tree
  Markers:  [?] checked out somewhere other than its ent folder
            [!] its parent branch no longer exists
            [MERGING] / [REBASING] / ... an operation is unfinished there
EOF
}

cmd_list() {
  ensure_ent
  local b tops
  list_node "$S_MAIN" "" "$ENT/main"
  top_branches
  tops=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  for b in ${tops[@]+"${tops[@]}"}; do list_node "$b" "" "$(ent_container "$b")"; done
}

# list_node <branch> <indent> <container>: print one line, then its twigs.
# The container is passed down so no path has to be recomputed per twig.
list_node() {
  local b="$1" indent="$2" container="$3" marks="" label="" kids child
  if wt_path_of "$b"; then
    if [[ "$REPLY" != "$container/core" ]]; then marks+="?"; fi
  else
    label+=" [no worktree]"   # a branch with nowhere to stand
  fi
  parent_of "$b"
  if [[ -n "$REPLY" ]] && ! has_local "$REPLY"; then marks+="!"; fi
  [[ -n "$marks" ]] && marks=" [$marks]"
  if [[ "$b" == "$S_MAIN" ]]; then label=" [main]$label"; fi
  # An unfinished merge or rebase, the way git's own prompt reports it.
  state_of "$b" && label+=" [$REPLY]"
  printf '%s%s%s%s\n' "$indent" "$b" "$marks" "$label"
  children_of "$b"
  kids=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"})
  for child in ${kids[@]+"${kids[@]}"}; do
    list_node "$child" "$indent  " "$container/twigs/${child##*/}"
  done
}
