# ent init: build a new ent from a name, a URL, or an existing clone.

help_init() { cat <<'EOF'
init <name | url | clone-path> [dir]   build a new ent
  name        start an empty repo:          ent init my-app
  url         clone a remote:               ent init git@host:org/repo.git
  clone-path  import an existing clone:     ent init ../old-clone new-ent
  The default branch is checked out at <dir>/main/core.

init --here [path]                     turn an existing repo into an ent, in place
  .git becomes .bare and everything else moves down into main/core, including
  ignored files such as node_modules and .env. The folder keeps its name.
  Needs a clean tree, a branch checked out (not a detached HEAD), and no
  submodules. -n shows what would move and changes nothing; -y skips the question.
  --worktrees move|drop  answers the question asked when the repo already has
                         other git worktrees registered.
EOF
}

parse_init_args() {
  local i=0 new_args=()
  HERE=0; WORKTREES=""
  while (( i < ${#ARGS[@]} )); do
    local a="${ARGS[$i]}"
    case "$a" in
      --here)  HERE=1 ;;
      --worktrees)
        i=$((i+1)); WORKTREES="${ARGS[$i]:-}"
        case "$WORKTREES" in move|drop) ;; *) die "--worktrees takes move or drop" ;; esac
        ;;
      -*)      die "unknown init option: $a" ;;
      *)       new_args+=("$a") ;;
    esac
    i=$((i+1))
  done
  ARGS=("${new_args[@]}")
}

cmd_init() {
  parse_init_args
  if (( HERE )); then cmd_init_here; return $?; fi
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
  # `ent init .` from inside a repo would otherwise resolve [dir] to the repo's
  # own name and build a nested ent inside the repo it is importing from.
  if [[ "$kind" == clone ]]; then
    local tgt; tgt="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)/$(basename "$dir")"
    local srcreal; srcreal="$(cd "$src" && pwd -P)"
    if [[ "$tgt" == "$srcreal" || "$tgt" == "$srcreal"/* ]]; then
      die "'$dir' is inside '$src'; to convert that repo in place use: ent init --here"
    fi
  fi
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
    if [[ -z "$def" ]]; then
      local c; for c in main master; do
        if git -C "$ENT" show-ref -q --verify "refs/heads/$c" 2>/dev/null || git -C "$ENT" show-ref -q --verify "refs/remotes/origin/$c" 2>/dev/null; then
          def="$c"; break
        fi
      done
    fi
    [[ -n "$def" ]] || die "could not determine the default branch: no origin/HEAD, main, or master"
    run git -C "$ENT" symbolic-ref HEAD "refs/heads/$def"
    if ! git -C "$ENT" show-ref -q --verify "refs/heads/$def" 2>/dev/null; then
      run git -C "$ENT" branch --track "$def" "origin/$def"
    elif git -C "$ENT" show-ref -q --verify "refs/remotes/origin/$def" 2>/dev/null && [[ -z "$(git -C "$ENT" config --get "branch.$def.merge" 2>/dev/null || true)" ]]; then
      run git -C "$ENT" branch --set-upstream-to="origin/$def" "$def"
    fi
  fi

  run mkdir -p "$dir/main"
  run git -C "$ENT" worktree add "$dir/main/core" "$def"
  worktree_bare_guard "$dir/main/core"
  # ent.canopy first: load_state writes .bare/ent.json on first use, and it
  # reads the canopy from that key. The other order records "main" for a
  # develop or master repo, and the file then wins forever.
  run git -C "$ENT" config ent.canopy "$def"
  load_state

  case "$OSTYPE" in msys*|cygwin*) note "Windows: deep paths can exceed MAX_PATH. If git complains, run: git config core.longpaths true" ;; esac
  emit_path "$dir/main/core" "Ent ready at $dir (default branch: $def)"
}

# init_empty_branch <name>: create <name> pointing at an empty "Initial commit".
# commit-tree + update-ref does what `worktree add --orphan` does, on any git.
init_empty_branch() {
  local tree commit
  run git -C "$ENT" symbolic-ref HEAD "refs/heads/$1"
  tree="$(git -C "$ENT" mktree </dev/null)"
  commit="$(git -C "$ENT" commit-tree "$tree" -m "Initial commit")"
  run git -C "$ENT" update-ref "refs/heads/$1" "$commit"
}

# ---------------------------------------------------------------------------
# ent init --here: turn an existing repo into an ent.
#
# Normally in place: .git becomes .bare, the repo folder becomes the ent root,
# and everything else moves down into main/core. When the repo already has
# other git worktrees and you choose to keep them, the ent is built alongside
# as <name>-ent instead, because those worktrees have to be moved into it.
#
# Two paths matter here and they are not always the same folder:
#   SRC  the repo being converted, where .git is now
#   ENT  where .bare and the layout end up (SRC itself, or <name>-ent)
#
# Why the detour through .ent-stage/core rather than filling main/core directly:
# `git worktree add` refuses a path that already exists and is not empty, so a
# folder cannot be filled first and registered second -- git has to make it.
# But if git makes main/core first and the repo has its own top-level main/
# folder, sweeping the root would move main/ into main/core/main/, inside
# itself, which fails. So git makes the worktree under a name we control, we
# fill it, then git moves it. The inner folder is called core so git's
# bookkeeping lands in .bare/worktrees/core, the name a plain `ent branch` gives.
# ---------------------------------------------------------------------------

_HERE_SRC=""      # repo being converted; set when the first mutation is due
_HERE_ENT=""      # where the ent is being built
_HERE_DONE=0      # 1 past the point of no return; disarms the rollback
_HERE_CONTAINER=""  # the branch container step 8 created, if it got that far
_HERE_KEEP=""     # worktrees that survive, to repair once the git dir has moved
_HERE_DROP=""     # worktrees to remove, once the final question is answered

# init_here_recovery_file <src> <ent>: the undo script, written before anything
# moves. The trap covers a failed command or a Ctrl-C; nothing survives the
# process being killed outright, and this file is what is left for that case.
init_here_recovery_file() {
  local src="$1" ent="$2" f="$1/.ent-convert-recovery.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Undo a half-finished `ent init --here` on %s.\n' "$src"
    printf '# Written %s. Safe to run more than once. Delete it once the repo is well.\n' "$(date)"
    printf 'set -uo pipefail\n'
    printf 'src=%q\n' "$src"
    printf 'ent=%q\n' "$ent"
    cat <<'EOS'

# An empty container may have been created just before the failure. It goes
# first: with an empty main/ sitting there, moving a tracked main/ back would
# land it at main/main instead.
rmdir "$ent/main" 2>/dev/null
if [ -d "$ent/branches" ]; then
  find "$ent/branches" -depth -type d -empty -exec rmdir {} + 2>/dev/null
fi

shopt -s dotglob nullglob
if [ -d "$ent/.ent-stage/core" ]; then
  for e in "$ent"/.ent-stage/core/*; do
    [ "$(basename "$e")" = .git ] && continue
    mv "$e" "$src/" || { echo "stuck on $e -- close whatever holds it, then re-run"; exit 1; }
  done
fi
shopt -u dotglob nullglob

if [ -d "$ent/.bare" ] && [ ! -d "$src/.git" ]; then
  [ -f "$src/.git" ] && rm -f "$src/.git"
  [ -f "$ent/.git" ] && rm -f "$ent/.git"
  rm -f "$src/.git.ent-tmp" "$ent/.git.ent-tmp"
  mv "$ent/.bare" "$src/.git" || exit 1
  git -C "$src" config core.bare false   # not --unset: that exits 5 when absent
fi
rm -rf "$ent/.ent-stage"
[ "$ent" = "$src" ] || rmdir "$ent" 2>/dev/null
git -C "$src" worktree prune             # drops the stale stage registration
echo "recovered: $src"
EOS
  } > "$f"
  chmod +x "$f" 2>/dev/null || true
}

# init_here_rollback <src> <ent>: undo as much as was done, stopping at the
# first step that will not budge rather than forcing it. On Windows the usual
# cause is a locked file (OneDrive, an editor), and a file that would not move
# in will not move back out either -- thrashing at it only grows the mess.
init_here_rollback() {
  local src="$1" ent="$2" e
  warn "conversion failed; rolling back $src"
  # Step 8 may have created an empty container before failing. It has to go
  # first: if the repo carries its own main/ folder, moving that back while an
  # empty main/ sits there would land it at main/main instead.
  if [[ -n "$_HERE_CONTAINER" ]]; then
    local up="$_HERE_CONTAINER"
    while [[ "$up" == "$ent/"* ]] && rmdir "$up" 2>/dev/null; do up="${up%/*}"; done
  fi
  if [[ -d "$ent/.ent-stage/core" ]]; then
    shopt -s dotglob nullglob
    for e in "$ent"/.ent-stage/core/*; do
      if [[ "$(basename "$e")" == .git ]]; then continue; fi
      if ! mv "$e" "$src/" 2>/dev/null; then
        shopt -u dotglob nullglob
        warn "could not move $e back; stopping here rather than forcing it"
        warn "close whatever holds it, then run: $src/.ent-convert-recovery.sh"
        return 1
      fi
    done
    shopt -u dotglob nullglob
  fi
  if [[ -d "$ent/.bare" && ! -d "$src/.git" ]]; then
    [[ -f "$src/.git" ]] && rm -f "$src/.git"
    [[ -f "$ent/.git" ]] && rm -f "$ent/.git"
    rm -f "$src/.git.ent-tmp" "$ent/.git.ent-tmp"
    if ! mv "$ent/.bare" "$src/.git" 2>/dev/null; then
      warn "could not restore $src/.git; run: $src/.ent-convert-recovery.sh"
      return 1
    fi
    git -C "$src" config core.bare false 2>/dev/null || true
  fi
  rm -rf "$ent/.ent-stage"
  [[ "$ent" == "$src" ]] || rmdir "$ent" 2>/dev/null || true
  git -C "$src" worktree prune >/dev/null 2>&1 || true
  if [[ -d "$src/.git" ]] && git -C "$src" status >/dev/null 2>&1; then
    rm -f "$src/.ent-convert-recovery.sh"
    note "Rolled back cleanly: $src is the repo it was."
  else
    warn "rollback finished but $src does not look healthy; see $src/.ent-convert-recovery.sh"
    return 1
  fi
}

# init_here_trap: fires on exit, error or interrupt while the window is open.
init_here_trap() {
  local src="$_HERE_SRC" ent="$_HERE_ENT"
  [[ -n "$src" ]] || return 0
  (( _HERE_DONE )) && return 0
  _HERE_SRC=""          # idempotent: an EXIT after an INT must not run twice
  init_here_rollback "$src" "$ent" || true
}

# init_here_default <root> <current>: the repo's real default branch. origin/HEAD
# first, then a local or remote main/master, else the branch that is checked out.
init_here_default() {
  local root="$1" cur="$2" d c
  d="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  if [[ -z "$d" ]]; then
    for c in main master; do
      if git -C "$root" show-ref --verify -q "refs/heads/$c" \
      || git -C "$root" show-ref --verify -q "refs/remotes/origin/$c"; then d="$c"; break; fi
    done
  fi
  printf '%s' "${d:-$cur}"
}

# init_here_sweep <src> <dest>: move every entry of <src> into <dest>, except
# the ones ent owns. Dotfiles come too, and so do ignored files: carrying
# node_modules and .env across is the whole reason for moving rather than
# re-checking-out.
init_here_sweep() {
  local src="$1" dest="$2" e
  shopt -s dotglob nullglob
  for e in "$src"/*; do
    case "$(basename "$e")" in
      .bare|.git|.ent-stage|.git.ent-tmp|.ent-convert-recovery.sh) continue ;;
    esac
    mv "$e" "$dest/" || { shopt -u dotglob nullglob; die "could not move $e into $dest"; }
  done
  shopt -u dotglob nullglob
}

# init_here_wt_branch <path>: the branch a worktree is on, or empty if detached.
init_here_wt_branch() { git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true; }

# init_here_worktrees <src> <paths>: decide what to do about worktrees the repo
# already has. Prints REPLY_LIST-free results into _HERE_KEEP (paths to repair)
# and echoes the ent root to build in. Returns non-zero to cancel.
init_here_worktrees() {
  local src="$1" paths="$2" p b answer
  echo "'$(basename "$src")' has other git worktrees registered:" >&2
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    b="$(init_here_wt_branch "$p")"; b="${b:-(detached)}"
    printf '    %-24s %s\n' "$b" "$p" >&2
  done <<< "$paths"
  echo >&2
  echo "  [m] move    build $(basename "$src")-ent beside it and give each worktree" >&2
  echo "              its own branches/<branch>/core folder there" >&2
  echo "  [d] drop    remove those worktree folders (their branches are kept)" >&2
  echo "              and convert $src in place" >&2
  echo "  [c] cancel  change nothing" >&2
  echo >&2
  echo "  Tip: \`ent init <url>\` clones a remote into a fresh ent, and" >&2
  echo "       \`ent init <name>\` builds an empty one." >&2

  if [[ -n "$WORKTREES" ]]; then answer="${WORKTREES:0:1}"
  elif choose "Choose [m/d/c]: " "m d c"; then answer="$REPLY"
  else die "'$src' has other worktrees and there is no terminal to ask on; pass --worktrees move|drop"
  fi

  # Cancel first, before any check: cancelling touches nothing, so a dirty
  # worktree is no reason to refuse it.
  if [[ "$answer" == c ]]; then note "Cancelled."; return 1; fi

  # Tracked changes stop either choice: we would be moving or deleting work
  # that is not recorded anywhere.
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ -n "$(git -C "$p" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
      die "worktree $p has uncommitted changes; commit or stash them first"
    fi
  done <<< "$paths"

  # This function only decides. Nothing is removed or moved here: the removals
  # for `drop` would otherwise run before the final "Convert?" question, and
  # answering no there would leave the folders already deleted.
  case "$answer" in
    d)
      # `worktree remove` deletes the folder, so untracked files there would be
      # gone for good. "Nothing is deleted" has to hold, so this one refuses.
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        local u; u="$(git -C "$p" ls-files --others --exclude-standard 2>/dev/null)"
        if [[ -n "$u" ]]; then
          init_here_list_paths "worktree $p has untracked files:" "$u"
          die "removing that worktree would delete them; commit them, delete them, or choose move"
        fi
      done <<< "$paths"
      _HERE_DROP="$paths"; _HERE_KEEP=""
      ;;
    m)
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        # A worktree inside the repo would be carried off by the sweep as a
        # plain folder, leaving its registration pointing at the old path.
        if [[ "$p" == "$src"/* ]]; then
          die "worktree $p is inside the repo being converted; ent cannot keep it where it is. Move it outside the repo first, or choose drop to remove it (its branch is kept)"
        fi
        # `worktree move` carries the whole folder, so untracked files are safe.
        # They are still shown, so the move is never a surprise.
        local u; u="$(git -C "$p" ls-files --others --exclude-standard 2>/dev/null)"
        if [[ -n "$u" ]]; then init_here_list_paths "worktree $p brings untracked files along:" "$u"; fi
      done <<< "$paths"
      _HERE_KEEP="$paths"; _HERE_DROP=""
      ;;
  esac
  return 0
}


_HERE_UNTRACKED=""   # untracked, non-ignored files in the repo being converted

# init_here_list_paths <heading> <paths>: print a capped list on stderr.
init_here_list_paths() {
  local n; n="$(printf '%s\n' "$2" | grep -c . || true)"
  note "$1"
  printf '%s\n' "$2" | head -20 | sed 's/^/    /' >&2
  if (( n > 20 )); then note "    ...and $((n - 20)) more"; fi
  return 0
}

# init_here_ask_untracked <src> <dest>: untracked files move like everything
# else, but only after a yes. Ignored files are never asked about -- .gitignore
# is already the answer. Returns 1 when the answer is no.
init_here_ask_untracked() {
  local src="$1" dest="$2" n
  [[ -n "$_HERE_UNTRACKED" ]] || return 0
  n="$(printf '%s\n' "$_HERE_UNTRACKED" | grep -c . || true)"
  init_here_list_paths "'$(basename "$src")' has $n untracked file(s):" "$_HERE_UNTRACKED"
  note "They would move into $dest with everything else and stay untracked."
  if (( DRY_RUN )); then return 0; fi
  if ! confirm "Carry them along?"; then
    note "Cancelled. Commit them, delete them, or add them to .gitignore, then convert again."
    return 1
  fi
  return 0
}
cmd_init_here() {
  local path src ent gd cur def parked="" stage_core p b
  path="$(arg 1)"; path="${path:-.}"
  [[ -z "$(arg 2)" ]] || usage_die "init --here [path]"
  [[ -d "$path" ]] || die "'$path' is not a directory"
  # ---------- preflight: nothing is touched until all of this passes ----------
  # An ent root is bare, so it is not a work tree: say "already an ent" before
  # the work-tree test gets to call it something more confusing.
  local abs; abs="$(ent_abs_path "$path")"
  ! is_ent_root "$abs" || die "'$abs' is already an ent"
  [[ "$(git -C "$path" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] \
    || die "'$path' is not a git work tree (a bare repo, or already converted)"
  # Take the root in git's own spelling: on Git Bash `pwd` says /c/... while git
  # says C:/..., and comparing the two forms never matches.
  src="$(git -C "$path" rev-parse --show-toplevel)"
  [[ -z "$(git -C "$path" rev-parse --show-prefix)" ]] \
    || die "run this at the top of the repo: cd $src"
  gd="$(git -C "$src" rev-parse --absolute-git-dir)"
  if [[ -f "$src/.git" || "$gd" == */worktrees/* ]]; then
    die "'$src' is a linked worktree, not a repo of its own; convert the repo it belongs to"
  fi
  [[ "$gd" == "$src/.git" ]] || die "this repo's git dir is $gd, not $src/.git"
  [[ -d "$gd" ]] || die "$src/.git is not a directory"
  if [[ -e "$src/.bare" ]]; then
    if is_ent_root "$src"; then die "'$src' is already an ent"; fi
    die "'$src/.bare' already exists and is not an ent's git directory; move it aside first"
  fi
  [[ ! -e "$src/.ent-stage" ]] || die "'$src/.ent-stage' is in the way; move it aside first"
  cur="$(git -C "$src" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [[ -n "$cur" ]] || die "HEAD is detached; check out a branch first"
  # Tracked changes still stop the conversion; untracked files only need a yes.
  if [[ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]]; then
    note "$(git -C "$src" status --porcelain --untracked-files=no | head -10)"
    die "'$src' has uncommitted changes; commit or stash them first"
  fi
  # ls-files --others --exclude-standard is exactly "untracked and not ignored":
  # ignored files are carried over without asking, so they must not be listed.
  _HERE_UNTRACKED="$(git -C "$src" ls-files --others --exclude-standard)"
  if [[ -f "$src/.gitmodules" ]] && [[ -n "$(git -C "$src" submodule status 2>/dev/null || true)" ]]; then
    die "'$src' has submodules; ent cannot convert it in place (their .git files point into the old .git/modules path)"
  fi
  case "$OSTYPE" in msys*|cygwin*)
    local here; here="$(ent_norm "$(pwd -P)")"
    if [[ "$here" != "$src" && "$here" == "$src"/* ]]; then
      die "Windows cannot move a folder your shell is standing in; cd $src first"
    fi ;;
  esac

  # Worktrees the repo already has decide where the ent gets built.
  ent="$src"
  local linked; linked="$(git -C "$src" worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2)"
  if [[ -n "$linked" ]]; then
    init_here_worktrees "$src" "$linked" || return 0
    if [[ -n "$_HERE_KEEP" ]]; then
      ent="$(dirname "$src")/$(basename "$src")-ent"
      if [[ -e "$ent" && -n "$(ls -A "$ent" 2>/dev/null)" ]]; then
        die "'$ent' exists and is not empty; move it aside first"
      fi
    fi
  fi

  def="$(init_here_default "$src" "$cur")"
  git -C "$src" show-ref --verify -q "refs/heads/$def" \
    || git -C "$src" show-ref --verify -q "refs/remotes/origin/$def" \
    || def="$cur"
  [[ "$def" == "$cur" ]] || parked="$cur"


  # Untracked files come along, but only after a yes. Asked before the preview
  # so a no costs nothing and the preview never promises what was declined.
  local landing; if [[ -n "$parked" ]]; then landing="branches/$cur/core/"; else landing="main/core/"; fi
  init_here_ask_untracked "$src" "$landing" || return 0
  # ---------- say what will happen ----------
  note "Will convert $src into an ent:"
  [[ "$ent" == "$src" ]] || note "  the ent is built beside it, at $ent"
  note "  .git/              ->  .bare/                 the git database, made bare"
  if [[ -z "$parked" ]]; then
    note "  everything else    ->  main/core/             branch $def"
  else
    note "  everything else    ->  branches/$cur/core/    branch $cur, your files"
    note "  (a fresh checkout) ->  main/core/             branch $def"
    warn "HEAD is on '$cur', but this repo's default branch is '$def'."
    note "  If you only wanted '$def', run \`git checkout $def\` first and convert again;"
    note "  you can always make the branch folder later with \`ent branch\`."
  fi
  if [[ -n "$_HERE_KEEP" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      b="$(init_here_wt_branch "$p")"
      if [[ -n "$b" ]]; then note "  $p  ->  branches/$b/core/"; fi
    done <<< "$_HERE_KEEP"
  fi
  if [[ -n "$_HERE_DROP" ]]; then
    init_here_list_paths "  these worktree folders will be removed (their branches are kept):" "$_HERE_DROP"
  fi
  note "  Ignored files (node_modules, .env) move with everything else."
  if [[ -z "$_HERE_DROP" ]]; then note "  Nothing is deleted."; fi
  if [[ -n "$_HERE_UNTRACKED" ]] && (( DRY_RUN )); then note "  The untracked files listed above move too."; fi
  if (( DRY_RUN )); then note "(dry run) nothing was changed"; return 0; fi
  confirm "Convert $src?" || { note "Cancelled."; return 0; }

  # The `drop` removals waited for that yes, so they run before anything else.
  if [[ -n "$_HERE_DROP" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      run git -C "$src" worktree remove "$p"
    done <<< "$_HERE_DROP"
    # Those folders were untracked content in the repo, so the list gathered
    # during preflight is now stale; step 7 compares against it.
    _HERE_UNTRACKED="$(git -C "$src" ls-files --others --exclude-standard)"
  fi

  # ---------- the window opens here ----------
  [[ "$ent" == "$src" ]] || run mkdir -p "$ent"
  init_here_recovery_file "$src" "$ent"
  _HERE_SRC="$src" _HERE_ENT="$ent" _HERE_DONE=0
  trap init_here_trap EXIT INT TERM

  # 1. Move the git dir. Pre-staging the pointer keeps the window in which no
  # .git exists down to a single rename: with no .git, git resolves *upward*,
  # so inside a nested repo every command after this would quietly target the
  # outer repository instead.
  say "printf 'gitdir: ./.bare\n' > $ent/.git.ent-tmp"
  printf 'gitdir: ./.bare\n' > "$ent/.git.ent-tmp"
  run mv "$src/.git" "$ent/.bare"
  run mv "$ent/.git.ent-tmp" "$ent/.git"

  # 2. Make it bare, so the branch is checked out nowhere and worktree add is free.
  run git -C "$ent/.bare" config core.bare true
  ENT="$ent"

  # 3. Any worktree we kept still points at <src>/.git, which is now a file or
  # gone. Each path has to be named: a bare `worktree repair` does not find them.
  if [[ -n "$_HERE_KEEP" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      run git -C "$ent" worktree repair "$p"
    done <<< "$_HERE_KEEP"
  fi

  # 4. The staging worktree: git makes the folder, we fill it afterwards.
  stage_core="$ent/.ent-stage/core"
  run mkdir -p "$ent/.ent-stage"
  run git -C "$ent" worktree add --no-checkout "$stage_core" "$cur"
  worktree_bare_guard "$stage_core"

  # 5. Sweep the working files down into it.
  note "Moving the working files down (dotfiles and ignored files included):"
  say mv "$src/*" "$stage_core/"
  init_here_sweep "$src" "$stage_core"

  # 6. Rebuild the index from HEAD. Load-bearing: --no-checkout leaves the index
  # genuinely empty despite printing "checking out", and an empty index makes
  # `git write-tree` return the empty tree -- a later `git commit -a` would then
  # commit the deletion of the whole repo. A mixed reset touches no file on disk.
  run git -C "$stage_core" reset -q

  # 7. Last chance to stop, before anything is renamed into place. Tracked files
  # must match HEAD exactly; untracked files must be the same set we were given
  # permission to carry -- no more (something appeared) and no fewer (something
  # was lost on the way down).
  [[ -z "$(git -C "$stage_core" status --porcelain --untracked-files=no)" ]] \
    || die "the staged worktree has tracked changes; stopping before the move"
  if [[ "$(git -C "$stage_core" ls-files --others --exclude-standard | LC_ALL=C sort)" \
     != "$(printf '%s' "$_HERE_UNTRACKED" | LC_ALL=C sort)" ]]; then
    die "the untracked files in the staged worktree are not the ones we started with; stopping before the move"
  fi

  # 8. Into the layout. `worktree move` needs the destination's parent to exist,
  # and beats mv + repair: between a plain mv and the repair the worktree reads
  # as prunable, so a concurrent `git gc` would unregister it.
  local dest_container
  if [[ -n "$parked" ]]; then dest_container="$ent/branches/$parked"; else dest_container="$ent/main"; fi
  _HERE_CONTAINER="$dest_container"
  run mkdir -p "$dest_container"
  run git -C "$ent" worktree move "$stage_core" "$dest_container/core"
  run rmdir "$ent/.ent-stage"
  _HERE_DONE=1
  trap - EXIT INT TERM
  rm -f "$src/.ent-convert-recovery.sh"

  # Past here the conversion has landed; anything left is additive.

  # Kept worktrees move first. One of them may be checked out on the default
  # branch, and git will not let that branch be checked out twice -- so that
  # worktree becomes main/core rather than getting a second checkout beside it.
  # They become ordinary top-level branches: nothing records a parent, so none
  # of them can be reconstructed as a twig.
  if [[ -n "$_HERE_KEEP" ]]; then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      b="$(init_here_wt_branch "$p")"
      if [[ -z "$b" ]]; then warn "worktree $p is on a detached HEAD; leaving it where it is"; continue; fi
      # A branch literally named main can only take main/core when it IS the
      # default branch; otherwise it would collide with the ent's own main/.
      if [[ "$b" != "$def" ]]; then
        case "$(ent_slug "$b")" in
          main|branches|twigs|core|.bare|.git)
            warn "worktree $p is on '$b', a reserved name here; leaving it where it is"; continue ;;
        esac
      fi
      local kept_dest
      if [[ "$b" == "$def" ]]; then kept_dest="$ent/main/core"; run mkdir -p "$ent/main"
      else kept_dest="$ent/branches/$b/core"; run mkdir -p "$ent/branches/$b/twigs"; fi
      run git -C "$ent" worktree move "$p" "$kept_dest"
      worktree_bare_guard "$kept_dest"
    done <<< "$_HERE_KEEP"
    if rmdir "$src" 2>/dev/null; then note "Removed the emptied $src"; fi
  fi

  if [[ -n "$parked" ]]; then
    run mkdir -p "$dest_container/twigs"
    if ! git -C "$ent" show-ref --verify -q "refs/heads/$def"; then
      run git -C "$ent" branch --track "$def" "origin/$def"
    fi
    run git -C "$ent" symbolic-ref HEAD "refs/heads/$def"
    # Only when no kept worktree already supplied it.
    if [[ ! -d "$ent/main/core" ]]; then
      run mkdir -p "$ent/main"
      run git -C "$ent" worktree add "$ent/main/core" "$def"
      worktree_bare_guard "$ent/main/core"
    fi
  fi
  run git -C "$ent" config ent.canopy "$def"
  case "$OSTYPE" in msys*|cygwin*) note "Windows: deep paths can exceed MAX_PATH. If git complains, run: git config core.longpaths true" ;; esac
  emit_path "$ent/main/core" "Ent ready at $ent (default branch: $def)"
}
