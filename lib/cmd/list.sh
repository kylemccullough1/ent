# ent list: draw every branch with its twigs nested underneath.

help_list() { cat <<'EOF'
list                                   show branches and twigs as a tree
  Markers:  [relocated] checked out somewhere other than its ent folder
            [orphan] its parent branch no longer exists
            [no worktree] the branch has no folder (`ent go <branch>` makes one)
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
    if [[ "$REPLY" != "$container/core" ]]; then marks+="relocated "; fi
  else
    label+=" [no worktree]"   # a branch with nowhere to stand; `ent go` gives it one
  fi
  parent_of "$b"
  if [[ -n "$REPLY" ]] && ! has_local "$REPLY"; then marks+="orphan "; fi
  if [[ -n "$marks" ]]; then marks=" [${marks% }]"; fi
  if [[ "$b" == "$S_MAIN" ]]; then label=" [main]$label"; fi
  # An unfinished merge or rebase, the way git's own prompt reports it.
  state_of "$b" && label+=" [$REPLY]"
  printf '%s%s%s%s\n' "$indent" "$b" "$marks" "$label"
  # The canopy's children are the branches, which cmd_list draws itself from
  # top_branches (that also covers branches with no node yet).
  kids=()
  if [[ "$b" != "$S_MAIN" ]]; then children_of "$b"; kids=(${REPLY_LIST[@]+"${REPLY_LIST[@]}"}); fi
  for child in ${kids[@]+"${kids[@]}"}; do
    list_node "$child" "$indent  " "$container/twigs/${child##*/}"
  done
}
