# ent paths: where things live on disk.
#
#   <ent>/main/core/                          the default branch
#   <ent>/branches/<branch>/core/             a branch (feature/x -> branches/feature/x/core)
#   <container>/twigs/<name>/core/            a twig, nested under its parent's container
#
# A container is the folder that holds core/ (the checkout) and twigs/ (its children).

_ENT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f load_state >/dev/null; then source "$_ENT_LIB/state.sh"; fi

# ent_norm <path>: rewrite a path into the exact spelling git uses, so the two
# can be compared as strings. Two things have to be settled, in this order:
#
#   1. follow links   a junction or symlink is renamed to the real folder,
#                     because `git worktree list` always prints the real one
#   2. spell it       Git Bash writes /c/x where git writes C:/x; cygpath -ml
#                     converts. Off Windows there is nothing to convert.
#
# Step 1 used to be skipped on Windows, because cygpath alone does not follow a
# link. That made every "which branch is this folder in" lookup miss whenever
# you reached a worktree through a junction: `ent up` and `ent down` failed and
# the prompt showed the wrong branch, while `ent list` still worked because it
# resolves the path itself.
ent_norm() {
  local p
  p="$( (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1" )"
  if command -v cygpath >/dev/null 2>&1; then cygpath -ml "$p"; else printf '%s' "$p"; fi
}

# ent_abs_path <dir>: absolute path of an existing directory (C:/... on Windows).
ent_abs_path() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }

# is_ent_root <dir>: true when <dir> is an ent root. Both halves must hold:
# .bare is the git database and .git is the one-line pointer naming it. A lone
# .bare folder (a backup, an unrelated bare repo) is not an ent.
is_ent_root() {
  [[ -d "$1/.bare" && -f "$1/.git" ]] || return 1
  local p; p="$(<"$1/.git")"
  [[ "${p%$'\r'}" == "gitdir: ./.bare" ]]   # tolerate a CRLF-mangled pointer
}

# ent_root: walk up from the current folder to the one that is an ent root.
# Starts from the real path (pwd -P), so a symlink pointing into an ent still works.
ent_root() {
  local d; d="$(pwd -P)"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if is_ent_root "$d"; then ent_norm "$d"; return 0; fi
    d="${d%/*}"
  done
  return 1
}

# ent_slug <branch>: feature/foo -> feature-foo (accepted by `go` as a shorthand).
ent_slug() { printf '%s' "${1//\//-}"; }

# ent_twigname <branch>: the twig's own name, which is the last part of
# twigs/<branch>/<twig>. For anything else the name is returned unchanged.
ent_twigname() {
  if [[ "$1" == twigs/* ]]; then printf '%s' "${1##*/}"; else printf '%s' "$1"; fi
}

# ent_canopy: the default branch name for the current ent.
ent_canopy() { state_ready; printf '%s' "$S_MAIN"; }

# ent_container <branch>: the folder holding the branch's core/ and twigs/.
ent_container() {
  state_ready
  local rel
  if [[ "$1" == "$S_MAIN" ]]; then printf '%s/main' "$ENT"; return 0; fi
  if tree_worktree_of "$1" 2>/dev/null && [[ -n "$REPLY" ]]; then
    rel="$REPLY"
    if [[ "$rel" == */core ]]; then
      printf '%s/%s' "$ENT" "${rel%/core}"
    else
      printf '%s/%s' "$ENT" "$rel"
    fi
    return 0
  fi
  # Fallback for branches that exist in git but have not been recorded in the
  # node tree yet.  This keeps older ents working until auto-adoption runs.
  parent_of "$1"
  if [[ -z "$REPLY" ]]; then
    printf '%s/branches/%s' "$ENT" "$1"
  else
    local p="$REPLY" twig; twig="$(ent_twigname "$1")"
    printf '%s/twigs/%s' "$(ent_container "$p")" "$twig"
  fi
}

# ent_core <branch>: the branch's checkout folder.
ent_core() {
  state_ready
  if tree_worktree_of "$1" 2>/dev/null && [[ -n "$REPLY" ]]; then
    printf '%s/%s' "$ENT" "$REPLY"
    return 0
  fi
  printf '%s/core' "$(ent_container "$1")"
}

# ent_parent_core <branch>: the parent's core/, or the ent root for a top-level branch.
ent_parent_core() {
  parent_of "$1"
  if [[ -n "$REPLY" ]]; then ent_core "$REPLY"; else printf '%s' "$ENT"; fi
}

# _branch_at_cwd <strip>: the checked-out branch whose folder holds the current
# directory, longest match first. With strip=/core the match is on the container
# (so branches/x/ and branches/x/twigs/ count); with strip="" only core/ counts.
_branch_at_cwd() {
  local strip="$1" cwd root dir i=0 best="" best_len=0
  root="$(ent_root 2>/dev/null)" || return 1
  local ENT="$root"
  state_ready
  cwd="$(ent_norm "$PWD")"
  while (( i < ${#S_WT_BRANCH[@]} )); do
    dir="${S_WT_PATH[$i]}"
    [[ -n "$strip" ]] && dir="${dir%"$strip"}"
    if [[ "$cwd" == "$dir" || "$cwd" == "$dir"/* ]] && (( ${#dir} > best_len )); then
      best="${S_WT_BRANCH[$i]}" best_len=${#dir}
    fi
    i=$((i + 1))
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# ent_branch_of_cwd: branch whose container holds the current directory.
ent_branch_of_cwd() { _branch_at_cwd /core; }

# ent_branch_of_core: branch whose core/ checkout holds the current directory.
# Commands that act on checked-out files (branch merge) require this.
ent_branch_of_core() { _branch_at_cwd ""; }
