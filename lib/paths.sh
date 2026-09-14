# ent path-resolution library.
# All paths produced here are normalized with ent_norm when crossing the git/bash boundary.
set -euo pipefail

# Global associative arrays populated by ent_load_worktrees
#   ENT_WT_PATH[branch] = normalized absolute path to the worktree's core/
#   ENT_WT_BRANCH[path] = branch name for a normalized core path
declare -g -A ENT_WT_PATH
declare -g -A ENT_WT_BRANCH

# ---------- normalization ----------

# ent_norm <path>: print a canonical windows/mixed path (C:/...) if cygpath is available,
# else the path unchanged. Use long-name form (-ml) so comparisons with git's output are stable.
ent_norm() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -ml "$1"
  else
    printf '%s' "$1"
  fi
}

# ent_root: walk up from $PWD looking for a directory containing .bare
ent_root() {
  local d="${PWD}"
  while [[ "$d" != "/" ]]; do
    if [[ -d "$d/.bare" ]]; then
      ent_norm "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

# ent_main: the configured default branch for this ent (default main)
ent_main() {
  ent_config_get ent.main 2>/dev/null || echo main
}

# ent_config_get <key>: read key from the bare repo config
ent_config_get() {
  git -C "${ENT}" config --get "$1"
}

# ent_slug <branch>: feature/foo -> feature-foo
ent_slug() {
  printf '%s' "${1//\//-}"
}

# ent_parent <branch>: parent stored in branch.<b>.entParent, or empty
ent_parent() {
  git -C "${ENT}" config --get "branch.$1.entParent" 2>/dev/null || true
}

# ent_twigname <branch>: strip "<parent>-" prefix from branch name
ent_twigname() {
  local b="$1" p
  p="$(ent_parent "$b")"
  if [[ -n "$p" && "$b" == "$p"-* ]]; then
    printf '%s' "${b#"$p-"}"
  else
    printf '%s' "$b"
  fi
}

# ent_depth <branch>: count entParent hops from branch to main or a root
ent_depth() {
  local b="$1" d=0 p seen=""
  while [[ -n "$b" ]]; do
    if [[ "$b" == "$(ent_main)" ]]; then
      echo "$d"; return 0
    fi
    if [[ "$seen" == *" $b "* ]]; then
      echo "cycle" >&2; return 1
    fi
    seen="$seen $b "
    p="$(ent_parent "$b")"
    if [[ -z "$p" ]]; then
      echo "$d"; return 0
    fi
    b="$p"; d=$((d+1))
  done
  echo "$d"
}

# ent_container <branch>: absolute container path for a branch
#   main             -> ENT/main
#   root branch      -> ENT/branches/<slug>
#   twig             -> $(ent_container parent)/twigs/<twigname>
ent_container() {
  local b="$1" main p twig
  main="$(ent_main)"
  if [[ "$b" == "$main" ]]; then
    printf '%s/main' "${ENT}"
    return 0
  fi
  p="$(ent_parent "$b")"
  if [[ -z "$p" ]]; then
    printf '%s/branches/%s' "${ENT}" "$(ent_slug "$b")"
  else
    twig="$(ent_twigname "$b")"
    printf '%s/twigs/%s' "$(ent_container "$p")" "$twig"
  fi
}

# ent_core <branch>: absolute path to the branch's checked-out worktree
ent_core() {
  printf '%s/core' "$(ent_container "$1")"
}

# ent_branch_of_cwd: print current branch if cwd is inside a core/ worktree
ent_branch_of_cwd() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 1
  top="$(ent_norm "$top")"
  # must end in /core
  [[ "$(basename "$top")" == "core" ]] || return 1
  git symbolic-ref --short -q HEAD 2>/dev/null || return 1
}

# ent_load_worktrees: populate ENT_WT_PATH and ENT_WT_BRANCH from porcelain
ent_load_worktrees() {
  ENT_WT_PATH=()
  ENT_WT_BRANCH=()
  local path_bare='' branch='' path=''
  while IFS= read -r line; do
    if [[ "$line" == worktree* ]]; then
      path_bare="${line#worktree }"
    elif [[ "$line" == branch* ]]; then
      branch="${line#branch }"
      branch="${branch#refs/heads/}"
      [[ -n "$path_bare" && -n "$branch" ]] || continue
      path="$(ent_norm "$path_bare")"
      ENT_WT_PATH["$branch"]="$path"
      ENT_WT_BRANCH["$path"]="$branch"
      path_bare=''; branch=''
    fi
  done < <(git -C "${ENT}" worktree list --porcelain)
}
