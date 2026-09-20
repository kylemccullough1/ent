# ent paths: where things live on disk.
#
#   <ent>/main/core/                          the default branch
#   <ent>/branches/<branch>/core/             a branch (feature/x -> branches/feature/x/core)
#   <container>/twigs/<name>/core/            a twig, nested under its parent's container
#
# A container is the folder that holds core/ (the checkout) and twigs/ (its children).

_ENT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f load_state >/dev/null; then source "$_ENT_LIB/state.sh"; fi

# ent_norm <path>: make a path comparable with the paths git prints.
# Git Bash: /c/x -> C:/x via cygpath. Elsewhere: resolve symlinks, as git does.
ent_norm() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -ml "$1"
  else
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
  fi
}

# ent_abs_path <dir>: absolute path of an existing directory (C:/... on Windows).
ent_abs_path() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }

# ent_root: walk up from the current folder to the one that holds .bare.
# Starts from the real path (pwd -P), so a symlink pointing into an ent still works.
ent_root() {
  local d; d="$(pwd -P)"
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.bare" ]]; then ent_norm "$d"; return 0; fi
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

# ent_container <branch>: the folder holding the branch's core/ and twigs/.
ent_container() {
  state_ready
  if [[ "$1" == "$S_MAIN" ]]; then printf '%s/main' "$ENT"; return 0; fi
  parent_of "$1"
  if [[ -z "$REPLY" ]]; then
    printf '%s/branches/%s' "$ENT" "$1"
  else
    local p="$REPLY" twig; twig="$(ent_twigname "$1")"
    printf '%s/twigs/%s' "$(ent_container "$p")" "$twig"
  fi
}

# ent_core <branch>: the branch's checkout folder.
ent_core() { printf '%s/core' "$(ent_container "$1")"; }

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
