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
#
# Plain POSIX awk only: macOS ships BSD awk and Ubuntu ships mawk, and neither
# has gawk's match(s, re, array). Values are cut out with sub() instead, and
# [ \t] stands in for [[:space:]], which old mawk builds lack.
_tree_parse() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    # val(): the string after the first colon, without its quotes.
    function val(s) {
      sub(/^[^:]*:[ \t]*"/, "", s)
      sub(/".*$/, "", s)
      return s
    }
    BEGIN { in_nodes=0; node=""; canopy=""; type=""; parent=""; children=""; worktree="" }
    { sub(/\r$/, "") }
    /^[ \t]*"canopy"[ \t]*:[ \t]*"/ { canopy=val($0); next }
    /^[ \t]*"nodes"[ \t]*:[ \t]*[{]/ { in_nodes=1; next }
    in_nodes && /^[ \t]*"[^"]+"[ \t]*:[ \t]*[{]/ {
      node=$0
      sub(/^[ \t]*"/, "", node)
      sub(/".*$/, "", node)
      type=""; parent=""; children=""; worktree=""
      next
    }
    node != "" && /^[ \t]*"type"[ \t]*:/ { type=val($0); next }
    node != "" && /^[ \t]*"parent"[ \t]*:/ {
      if ($0 ~ /:[ \t]*null/) parent=""
      else parent=val($0)
      next
    }
    node != "" && /^[ \t]*"children"[ \t]*:/ {
      raw=$0
      sub(/^[^[]*[[]/, "", raw)
      sub(/[]].*$/, "", raw)
      gsub(/[" \t]/, "", raw)
      n=split(raw, parts, ",")
      children=""
      for (j=1; j<=n; j++) {
        if (parts[j] == "") continue
        if (children != "") children=children " "
        children=children parts[j]
      }
      next
    }
    node != "" && /^[ \t]*"worktree"[ \t]*:/ { worktree=val($0); next }
    node != "" && /^[ \t]*[}][ \t]*,?$/ {
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

  local seen_canopy=0
  while IFS= read -r line; do
    case "$line" in
      CANOPY*)
        T_CANOPY="${line#CANOPY$'\036'}"
        seen_canopy=1
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

  # Every file _tree_write produces has a canopy line. No canopy means the file
  # is damaged, or awk could not run the parser. An empty tree would quietly
  # misdirect every command, so set the file aside and rebuild it from git.
  if (( ! seen_canopy )); then
    warn "could not read $f; rebuilding it from git (the old file is kept as ent.json.bad)"
    mv -f "$f" "$f.bad" 2>/dev/null || true
    T_CANOPY="main"; T_NAME=(); T_TYPE=(); T_PARENT=(); T_CHILDREN=(); T_WORKTREE=()
    tree_bootstrap
    return 0
  fi

  _tree_canopy_parents
}

# _tree_canopy_parents: files written before branches recorded the canopy as
# their parent have "parent": null on branches. Fix that in memory: each such
# branch gets the canopy as parent and joins the canopy's children. The next
# save writes the corrected form.
_tree_canopy_parents() {
  local i=0 ci
  _tree_index_of "$T_CANOPY" || return 0
  ci="$T_INDEX"
  while (( i < ${#T_NAME[@]} )); do
    if [[ "${T_TYPE[$i]}" == branch && -z "${T_PARENT[$i]}" ]]; then
      T_PARENT[$i]="$T_CANOPY"
      case " ${T_CHILDREN[$ci]} " in
        *" ${T_NAME[$i]} "*) ;;
        *) T_CHILDREN[$ci]="${T_CHILDREN[$ci]:+${T_CHILDREN[$ci]} }${T_NAME[$i]}" ;;
      esac
    fi
    i=$((i + 1))
  done
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
# Under --dry-run nothing is written: every mutation still runs in memory, so
# the rest of the command behaves the same, but the file is left alone.
_tree_write() {
  (( ${DRY_RUN:-0} )) && return 0
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

  # Build nodes from local branches and known parents. A twig's parent is the
  # branch recorded in entParent; every other branch hangs off the canopy.
  while read -r branch; do
    [[ -n "$branch" ]] || continue
    parent=""
    if [[ "$branch" == twigs/* ]]; then
      parent="$(git -C "$ENT" config --get "branch.$branch.entParent" 2>/dev/null || true)"
    elif [[ "$branch" != "$T_CANOPY" ]]; then
      parent="$T_CANOPY"
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

  # Fill worktree paths from git worktree list. substr, not $2: a worktree path
  # may contain spaces.
  while read -r wt_tmp; do
    IFS=' ' read -r branch path <<<"$wt_tmp"
    [[ "$branch" == refs/heads/* ]] || continue
    branch="${branch#refs/heads/}"
    _tree_index_of "$branch" || continue
    T_WORKTREE[$T_INDEX]="$(_rel_path "$ENT" "$path")"
  done < <(git -C "$ENT" worktree list --porcelain | awk '/^worktree /{p=substr($0, 10)} /^branch /{print $2 " " p}')

  # Ensure the canopy node exists even if no branches were found.
  if ! _tree_index_of "$T_CANOPY"; then
    T_NAME=("$T_CANOPY" ${T_NAME[@]+"${T_NAME[@]}"})
    T_TYPE=("canopy" ${T_TYPE[@]+"${T_TYPE[@]}"})
    T_PARENT=("" ${T_PARENT[@]+"${T_PARENT[@]}"})
    T_CHILDREN=("$(_tree_collect_children "$T_CANOPY")" ${T_CHILDREN[@]+"${T_CHILDREN[@]}"})
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

# _tree_drop <branch>: remove a node from the in-memory arrays and from its
# parent's children. No lock, no write: callers hold the lock and save.
_tree_drop() {
  local branch="$1" parent i=0 c
  local new_name=() new_type=() new_parent=() new_children=() new_worktree=() kids=()
  _tree_index_of "$branch" || return 0
  parent="${T_PARENT[$T_INDEX]}"
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
  # ${a[@]+...}: bash 3.2 treats an empty "${a[@]}" as unbound under set -u.
  T_NAME=(${new_name[@]+"${new_name[@]}"})
  T_TYPE=(${new_type[@]+"${new_type[@]}"})
  T_PARENT=(${new_parent[@]+"${new_parent[@]}"})
  T_CHILDREN=(${new_children[@]+"${new_children[@]}"})
  T_WORKTREE=(${new_worktree[@]+"${new_worktree[@]}"})
  if [[ -n "$parent" ]] && _tree_index_of "$parent"; then
    for c in ${T_CHILDREN[$T_INDEX]}; do
      [[ "$c" == "$branch" ]] || kids+=("$c")
    done
    T_CHILDREN[$T_INDEX]="${kids[@]+"${kids[*]}"}"
  fi
}

# tree_add_node <branch> <type> <parent> <worktree>: add a node and persist.
# A node left over for the same name is replaced. Git decides whether a branch
# exists; a leftover node (say the branch was deleted with plain git) is stale
# and must not block making the branch again.
tree_add_node() {
  local branch="$1" type="$2" parent="$3" worktree="$4" kids=""
  tree_lock
  tree_load
  # A replaced node keeps its children: re-adopting a branch whose folder was
  # deleted must not cut its twigs loose.
  if _tree_index_of "$branch"; then kids="${T_CHILDREN[$T_INDEX]}"; fi
  _tree_drop "$branch"
  T_NAME+=("$branch")
  T_TYPE+=("$type")
  T_PARENT+=("$parent")
  T_CHILDREN+=("$kids")
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

# tree_remove_node <branch>: remove node and persist. Caller must remove children
# first (rm_tree does, deepest first). A name with no node is not an error.
tree_remove_node() {
  tree_lock
  tree_load
  _tree_drop "$1"
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

# tree_adopt_if_missing <branch>: give an existing git branch with no live
# worktree its ent folder, and record it. Called only when a command names the
# branch (`ent branch <name>`, `ent go <name>`); read-only commands such as
# `list` never create folders.
#
# Uses has_local / wt_path_of / load_state (state.sh), ent_core (paths.sh) and
# run / worktree_bare_guard (run.sh). bash resolves them when this runs, and
# git-ent has sourced all of them by then.
#
# It must run in the main shell, not inside $(...): it refreshes the state
# snapshot at the end, and a subshell's refresh would be lost.
tree_adopt_if_missing() {
  local branch="$1" parent="" type="branch" core_dir worktree
  wt_path_of "$branch" && return 0
  has_local "$branch" || die "branch '$branch' not found"
  if [[ "$branch" == "$T_CANOPY" ]]; then
    type="canopy"
  elif [[ "$branch" == twigs/* ]]; then
    parent="$(git -C "$ENT" config --get "branch.$branch.entParent" 2>/dev/null || true)"
    [[ -n "$parent" ]] || die "cannot adopt twig '$branch': no parent recorded (branch.$branch.entParent)"
    type="twig"
  else
    parent="$T_CANOPY"   # a branch hangs off the canopy
  fi
  # ent_core already knows where the branch belongs: the path the tree recorded
  # for it, or the layout's default when there is no record.
  core_dir="$(ent_core "$branch")"
  worktree="${core_dir#"$ENT"/}"
  [[ -e "$core_dir" ]] && die "core directory already exists: $core_dir"
  run mkdir -p "${core_dir%/core}/twigs"
  # No -b: the branch is already there, we are only checking it out.
  run git -C "$ENT" worktree add "$core_dir" "$branch"
  worktree_bare_guard "$core_dir"
  tree_add_node "$branch" "$type" "$parent" "$worktree"
  (( DRY_RUN )) || load_state
}
