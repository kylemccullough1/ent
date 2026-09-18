# ent init: build a new ent from a name, a URL, or an existing clone.

help_init() { cat <<'EOF'
init <name | url | clone-path> [dir]   build a new ent
  name        start an empty repo:          ent init my-app
  url         clone a remote:               ent init git@host:org/repo.git
  clone-path  import an existing clone:     ent init ../old-clone new-ent
  The default branch is checked out at <dir>/main/core.
EOF
}

cmd_init() {
  local src dir kind=name
  src="$(arg 1)" dir="$(arg 2)"
  [[ -n "$src" ]] || usage_die "init <name | url | clone-path> [dir]"
  if [[ -d "$src" ]] && git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    kind=clone; src="$(ent_abs_path "$src")"
  elif [[ "$src" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// || "$src" =~ ^[^/[:space:]]+@[^:]+: || "$src" == *.git ]]; then
    kind=url
  elif [[ "$src" == */* || "$src" == .* ]]; then
    die "'$src' is neither a URL nor an existing git repository"
  fi
  local base; base="$(basename "${src%/}")"; base="${base%.git}"
  [[ -n "$dir" ]] || dir="$base"
  if [[ -e "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then die "'$dir' exists and is not empty; pass a different [dir]"; fi

  run mkdir -p "$dir"
  if (( DRY_RUN )); then note "(dry run) would build an ent at $dir from $kind '$src'"; return 0; fi
  dir="$(ent_abs_path "$dir")"; ENT="$dir"
  run git init -q --bare "$dir/.bare"
  say "printf 'gitdir: ./.bare\\n' > $dir/.git"
  printf 'gitdir: ./.bare\n' > "$dir/.git"

  local def
  if [[ "$kind" == name ]]; then
    def="$(git config --get init.defaultBranch 2>/dev/null || true)"; def="${def:-main}"
    init_empty_branch "$def"
  else
    local origin="$src"
    if [[ "$kind" == clone ]]; then
      origin="$(git -C "$src" remote get-url origin 2>/dev/null || true)"; origin="${origin:-$src}"
    fi
    run git -C "$ENT" remote add origin "$origin"
    run git -C "$ENT" fetch origin || warn "fetch from $origin failed; continuing with what is local"
    run git -C "$ENT" remote set-head origin -a || true
    if [[ "$kind" == clone ]]; then
      run git -C "$ENT" fetch "$src" '+refs/heads/*:refs/heads/*'
      local key val
      while read -r key val; do
        if [[ -n "$key" ]]; then run git -C "$ENT" config "$key" "$val"; fi
      done < <(git -C "$src" config --get-regexp '^branch\..*\.(remote|merge)$' 2>/dev/null || true)
    fi
    def="$(git -C "$ENT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
    load_state
    if [[ -z "$def" ]]; then
      local c; for c in main master; do if has_local "$c" || has_remote "$c"; then def="$c"; break; fi; done
    fi
    [[ -n "$def" ]] || die "could not determine the default branch: no origin/HEAD, main, or master"
    git -C "$ENT" symbolic-ref HEAD "refs/heads/$def"
    if ! has_local "$def"; then run git -C "$ENT" branch --track "$def" "origin/$def"
    elif has_remote "$def" && [[ -z "$(git -C "$ENT" config --get "branch.$def.merge" 2>/dev/null || true)" ]]; then
      run git -C "$ENT" branch --set-upstream-to="origin/$def" "$def"
    fi
  fi

  run mkdir -p "$dir/main"
  run git -C "$ENT" worktree add "$dir/main/core" "$def"
  run git -C "$ENT" config ent.main "$def"

  case "$OSTYPE" in msys*|cygwin*) note "Windows: deep paths can exceed MAX_PATH. If git complains, run: git config core.longpaths true" ;; esac
  emit_path "$dir/main/core" "Ent ready at $dir (default branch: $def)"
}

# init_empty_branch <name>: create <name> pointing at an empty "Initial commit".
# commit-tree + update-ref does what `worktree add --orphan` does, on any git.
init_empty_branch() {
  local tree commit
  git -C "$ENT" symbolic-ref HEAD "refs/heads/$1"
  tree="$(git -C "$ENT" mktree </dev/null)"
  commit="$(git -C "$ENT" commit-tree "$tree" -m "Initial commit")"
  run git -C "$ENT" update-ref "refs/heads/$1" "$commit"
}
