# ent tree: JSON-backed node tree metadata.
# Sourced by git-ent. Everything here is plain bash 3.2.

set -euo pipefail

_ENT_TREE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f note >/dev/null 2>&1; then source "$_ENT_TREE_LIB/output.sh"; fi

T_CANOPY=""                       # default branch name
T_NAME=()                         # node names, file order
T_TYPE=()                         # canopy|branch|twig
T_PARENT=()                       # parent name, or empty
T_CHILDREN=()                     # space-separated children names
T_WORKTREE=()                     # worktree path relative to ENT root

_tree_file()   { printf '%s/.bare/ent.json' "$ENT"; }
_tree_lock()   { printf '%s/.bare/ent.json.lock' "$ENT"; }

# _rel_path <base> <abs>: print <abs> relative to <base>.
_rel_path() {
  local base="$1" abs="$2"
  base="$(cd "$base" && { pwd -W 2>/dev/null || pwd -P; })"
  abs="$(cd "$abs" && { pwd -W 2>/dev/null || pwd -P; })"
  case "$abs" in
    "$base"/*) printf '%s' "${abs#"$base"/}" ;;
    *) printf '%s' "$abs" ;;
  esac
}

# tree_lock / tree_unlock: advisory lock using mkdir (atomic everywhere).
tree_lock() {
  local lock="$(_tree_lock)" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if (( waited >= 100 )); then
      # The lock is older than 10 seconds; something died. Break it.
      warn "breaking stale lock $lock"
      rmdir "$lock" 2>/dev/null || true
      mkdir "$lock" 2>/dev/null && break
      die "cannot acquire lock $lock"
    fi
    sleep 0.1 2>/dev/null || sleep 1
    waited=$((waited + 1))
  done
}

tree_unlock() {
  rmdir "$(_tree_lock)" 2>/dev/null || true
}

# _tree_parse <file>: print a flat representation the shell can read:
#   CANOPY <canopy>
#   NODE <name> <type> <parent> <children> <worktree>
_tree_parse() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    BEGIN { in_nodes=0; node=""; canopy=""; type=""; parent=""; children=""; worktree="" }
    { sub(/\r$/, "") }
    /^[[:space:]]*"canopy"[[:space:]]*:[[:space:]]*"/ {
      match($0, /"canopy"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)
      canopy=m[1]
      next
    }
    /^[[:space:]]*"nodes"[[:space:]]*:[[:space:]]*\{/ { in_nodes=1; next }
    in_nodes && /^[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*\{/ {
      match($0, /"([^"]+)"[[:space:]]*:[[:space:]]*\{/, m)
      node=m[1]
      type=""; parent=""; children=""; worktree=""
      next
    }
    node != "" && /^[[:space:]]*"type"[[:space:]]*:/ {
      match($0, /"type"[[:space:]]*:[[:space:]]*"([^"]+)"/, m); type=m[1]
      next
    }
    node != "" && /^[[:space:]]*"parent"[[:space:]]*:/ {
      if ($0 ~ /null/) parent=""
      else { match($0, /"parent"[[:space:]]*:[[:space:]]*"([^"]*)"/, m); parent=m[1] }
      next
    }
    node != "" && /^[[:space:]]*"children"[[:space:]]*:/ {
      match($0, /\[([^\]]*)\]/, m)
      raw=m[1]
      n=split(raw, parts, /,[[:space:]]*/)
      children=""
      for (j=1; j<=n; j++) {
        gsub(/"/, "", parts[j])
        if (parts[j] == "") continue
        if (children != "") children=children " "
        children=children parts[j]
      }
      next
    }
    node != "" && /^[[:space:]]*"worktree"[[:space:]]*:/ {
      match($0, /"worktree"[[:space:]]*:[[:space:]]*"([^"]+)"/, m); worktree=m[1]
      next
    }
    node != "" && /^[[:space:]]*\}[[:space:]]*,?$/ {
      printf "NODE\036%s\036%s\036%s\036%s\036%s\n", node, type, parent, children, worktree
      node=""
      next
    }
    END { if (canopy != "") printf "CANOPY\036%s\n", canopy }
  ' "$f"
}

# _tree_index_of <branch>: set T_INDEX to the node index, or empty if absent.
_tree_index_of() {
  local i=0
  while (( i < ${#T_NAME[@]} )); do
    if [[ "${T_NAME[$i]}" == "$1" ]]; then T_INDEX=$i; return 0; fi
    i=$((i + 1))
  done
  T_INDEX=""; return 1
}

# tree_load: read .bare/ent.json into the tree arrays. If the file is missing,
# bootstrap it from the existing Git state (one-time upgrade).
tree_load() {
  local f line node tmp_name tmp_type tmp_parent tmp_children tmp_worktree
  f="$(_tree_file)"
  T_CANOPY="main"; T_NAME=(); T_TYPE=(); T_PARENT=(); T_CHILDREN=(); T_WORKTREE=()

  if [[ ! -f "$f" ]]; then
    tree_bootstrap
    return 0
  fi

  while IFS= read -r line; do
    case "$line" in
      CANOPY*)
        T_CANOPY="${line#CANOPY$'\036'}"
        ;;
      NODE*)
        IFS=$'\036' read -r _ node tmp_type tmp_parent tmp_children tmp_worktree <<<"$line"
        T_NAME+=("$node")
        T_TYPE+=("$tmp_type")
        T_PARENT+=("$tmp_parent")
        T_CHILDREN+=("$tmp_children")
        T_WORKTREE+=("$tmp_worktree")
        ;;
    esac
  done < <(_tree_parse "$f")
}

# _tree_collect_children <parent>: print space-separated child names.
_tree_collect_children() {
  local p="$1" i=0 out=""
  while (( i < ${#T_NAME[@]} )); do
    if [[ "${T_PARENT[$i]}" == "$p" ]]; then
      if [[ -n "$out" ]]; then out+=" "; fi
      out+="${T_NAME[$i]}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# _tree_write: persist the in-memory arrays to .bare/ent.json atomically.
_tree_write() {
  local f="$(_tree_file)" tmp="$(_tree_file).tmp" i n child first
  {
    printf '{\n'
    printf '  "canopy": "%s",\n' "$T_CANOPY"
    printf '  "nodes": {\n'
    for (( i=0; i < ${#T_NAME[@]}; i++ )); do
      n="${T_NAME[$i]}"
      printf '    "%s": {\n' "$n"
      printf '      "type": "%s",\n' "${T_TYPE[$i]}"
      if [[ -n "${T_PARENT[$i]}" ]]; then
        printf '      "parent": "%s",\n' "${T_PARENT[$i]}"
      else
        printf '      "parent": null,\n'
      fi
      printf '      "children": ['
      first=1
      for child in ${T_CHILDREN[$i]}; do
        if (( first )); then first=0; else printf ', '; fi
        printf '"%s"' "$child"
      done
      printf '],\n'
      printf '      "worktree": "%s"\n' "${T_WORKTREE[$i]}"
      printf '    }'
      if (( i < ${#T_NAME[@]} - 1 )); then printf ','; fi
      printf '\n'
    done
    printf '  }\n}\n'
  } > "$tmp"
  mv "$tmp" "$f"
}

# tree_bootstrap: create .bare/ent.json from the current Git state.
# Used once when an ent has no metadata file yet.
tree_bootstrap() {
  local f="$(_tree_file)" branch parent wt_tmp
  T_CANOPY="$(git -C "$ENT" config ent.canopy 2>/dev/null || true)"
  if [[ -z "$T_CANOPY" ]]; then
    T_CANOPY="$(git -C "$ENT" config ent.main 2>/dev/null || true)"
  fi
  [[ -n "$T_CANOPY" ]] || T_CANOPY="main"

  # Build nodes from local branches and known parents.
  while read -r branch; do
    [[ -n "$branch" ]] || continue
    parent=""
    if [[ "$branch" == twigs/* ]]; then
      parent="$(git -C "$ENT" config --get "branch.$branch.entParent" 2>/dev/null || true)"
    fi
    T_NAME+=("$branch")
    if [[ "$branch" == "$T_CANOPY" ]]; then T_TYPE+=("canopy")
    elif [[ "$branch" == twigs/* ]]; then T_TYPE+=("twig")
    else T_TYPE+=("branch")
    fi
    T_PARENT+=("$parent")
    # children and worktree filled below
    T_CHILDREN+=("")
    T_WORKTREE+=("")
  done < <(git -C "$ENT" for-each-ref --format='%(refname:short)' refs/heads | sort)

  # Fill children from parents.
  local i=0
  while (( i < ${#T_NAME[@]} )); do
    T_CHILDREN[$i]="$(_tree_collect_children "${T_NAME[$i]}")"
    i=$((i + 1))
  done

  # Fill worktree paths from git worktree list.
  while read -r wt_tmp; do
    IFS=' ' read -r branch path <<<"$wt_tmp"
    [[ "$branch" == refs/heads/* ]] || continue
    branch="${branch#refs/heads/}"
    _tree_index_of "$branch" || continue
    T_WORKTREE[$T_INDEX]="$(_rel_path "$ENT" "$path")"
  done < <(git -C "$ENT" worktree list --porcelain | awk '/^worktree /{p=$2} /^branch /{print $2 " " p}')

  # Ensure the canopy node exists even if no branches were found.
  if ! _tree_index_of "$T_CANOPY"; then
    T_NAME=("$T_CANOPY" ${T_NAME[@]+"${T_NAME[@]}"})
    T_TYPE=("canopy" ${T_TYPE[@]+"${T_TYPE[@]}"})
    T_PARENT=("" ${T_PARENT[@]+"${T_PARENT[@]}"})
    T_CHILDREN=("" ${T_CHILDREN[@]+"${T_CHILDREN[@]}"})
    T_WORKTREE=("main/core" ${T_WORKTREE[@]+"${T_WORKTREE[@]}"})
  fi

  tree_lock
  _tree_write
  tree_unlock
}

# tree_canopy: print the canopy branch.
tree_canopy() { printf '%s' "$T_CANOPY"; }

# tree_node_exists <branch>: true if the node exists.
tree_node_exists() {
  _tree_index_of "$1" 2>/dev/null
}

# tree_parent_of <branch>: REPLY = parent name, empty if none.
tree_parent_of() {
  _tree_index_of "$1" || { REPLY=""; return 1; }
  REPLY="${T_PARENT[$T_INDEX]}"
}

# tree_children_of <branch>: REPLY_LIST = children names.
tree_children_of() {
  _tree_index_of "$1" || { REPLY_LIST=(); return 1; }
  REPLY_LIST=(${T_CHILDREN[$T_INDEX]})
}

# tree_worktree_of <branch>: REPLY = relative worktree path.
tree_worktree_of() {
  _tree_index_of "$1" || { REPLY=""; return 1; }
  REPLY="${T_WORKTREE[$T_INDEX]}"
}

# tree_type_of <branch>: REPLY = type.
tree_type_of() {
  _tree_index_of "$1" || { REPLY=""; return 1; }
  REPLY="${T_TYPE[$T_INDEX]}"
}

# tree_add_node <branch> <type> <parent> <worktree>: add a node and persist.
tree_add_node() {
  local branch="$1" type="$2" parent="$3" worktree="$4"
  tree_lock
  tree_load
  if _tree_index_of "$branch"; then
    tree_unlock
    die "node '$branch' already exists"
  fi
  T_NAME+=("$branch")
  T_TYPE+=("$type")
  T_PARENT+=("$parent")
  T_CHILDREN+=("")
  T_WORKTREE+=("$worktree")
  if [[ -n "$parent" ]] && _tree_index_of "$parent"; then
    if [[ -n "${T_CHILDREN[$T_INDEX]}" ]]; then
      T_CHILDREN[$T_INDEX]+=" $branch"
    else
      T_CHILDREN[$T_INDEX]="$branch"
    fi
  fi
  _tree_write
  tree_unlock
}

# tree_remove_node <branch>: remove node and persist. Caller must remove children first.
tree_remove_node() {
  local branch="$1" parent i=0 new_name=() new_type=() new_parent=() new_children=() new_worktree=()
  tree_lock
  tree_load
  _tree_index_of "$branch" || { tree_unlock; die "node '$branch' not found"; }
  parent="${T_PARENT[$T_INDEX]}"
  # Rebuild arrays without this node.
  while (( i < ${#T_NAME[@]} )); do
    if [[ "${T_NAME[$i]}" != "$branch" ]]; then
      new_name+=("${T_NAME[$i]}")
      new_type+=("${T_TYPE[$i]}")
      new_parent+=("${T_PARENT[$i]}")
      new_children+=("${T_CHILDREN[$i]}")
      new_worktree+=("${T_WORKTREE[$i]}")
    fi
    i=$((i + 1))
  done
  T_NAME=("${new_name[@]}")
  T_TYPE=("${new_type[@]}")
  T_PARENT=("${new_parent[@]}")
  T_CHILDREN=("${new_children[@]}")
  T_WORKTREE=("${new_worktree[@]}")
  # Remove from parent's children list.
  if [[ -n "$parent" ]] && _tree_index_of "$parent"; then
    local c kids=()
    for c in ${T_CHILDREN[$T_INDEX]}; do
      [[ "$c" == "$branch" ]] || kids+=("$c")
    done
    T_CHILDREN[$T_INDEX]="${kids[*]}"
  fi
  _tree_write
  tree_unlock
}

# tree_update_worktree <branch> <worktree>: change a node's worktree path.
tree_update_worktree() {
  tree_lock; tree_load
  _tree_index_of "$1" || { tree_unlock; die "node '$1' not found"; }
  T_WORKTREE[$T_INDEX]="$2"
  _tree_write
  tree_unlock
}

# tree_adopt_if_missing <branch>: if the Git branch exists but the node does not,
# create the ent folder and add the node.
tree_adopt_if_missing() {
  local branch="$1" container core_dir parent type
  if _tree_index_of "$branch"; then return 0; fi
  if ! git -C "$ENT" show-ref -q --verify "refs/heads/$branch"; then
    die "branch '$branch' not found"
  fi
  parent=""
  type="branch"
  if [[ "$branch" == twigs/* ]]; then
    die "cannot auto-adopt a twig without a recorded parent"
  fi
  container="$ENT/branches/$branch"
  core_dir="$container/core"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  mkdir -p "$container/twigs"
  git -C "$ENT" worktree add "$core_dir" "$branch" >&2
  tree_add_node "$branch" "$type" "$parent" "branches/$branch/core"
}
