# ent destroy: delete an entire ent folder.

help_destroy() { cat <<'EOF'
destroy <dir> [-f]                     delete a whole ent (asks you to type its name)
EOF
}

cmd_destroy() {
  local dir a
  dir="$(arg 1)"
  [[ -n "$dir" && -z "$(arg 2)" ]] || usage_die "destroy <dir> [-f]"
  # Deliberately looser than is_ent_root: if `init` dies halfway you are left
  # with a .bare and no valid pointer, and destroy is the tool that clears it up.
  # Typing the folder name is the guard here.
  [[ -d "$dir/.bare" ]] || die "'$dir' is not an ent (no .bare)"
  if (( ! FORCE )); then
    [[ -t 0 ]] || die "refusing to destroy without a terminal; pass --force"
    read -r -p "Type the directory name to destroy '$dir': " a
    [[ "$a" == "$(basename "$dir")" ]] || die "destroy cancelled"
  fi
  run rm -rf "$dir"
}
