# ent state: one snapshot of everything ent needs to know about the repo,
# read with three git calls. Every lookup below answers from these arrays
# instead of starting another git process.
#
# bash 3.2 has no associative arrays, so each map is two parallel arrays:
# the key at index i pairs with the value at the same index i.
#
# Lookups put their answer in REPLY (or REPLY_LIST) instead of printing it,
# so callers can skip a $(...) subshell. On Git Bash for Windows every
# subshell is a slow process start, and `list` does many lookups.

S_ENT=""                            # ent root the snapshot was read from
S_MAIN="main"                       # default branch (ent.main)
S_CFG_KEYS=()    S_CFG_VALS=()      # ent.* settings from .bare/config, keys lowercase
S_PARENT_KEYS=() S_PARENT_VALS=()   # twig -> parent (branch.<twig>.entParent), sorted by twig
S_LOCAL=()                          # local branch names, sorted
S_REMOTE=()                         # remote-tracking names, e.g. origin/main
S_WT_BRANCH=()   S_WT_PATH=()       # branch -> path of the worktree it is checked out in
S_STATE_PATH=()  S_STATE_VAL=()     # worktree path -> unfinished operation (MERGING, ...)
REPLY="" REPLY_LIST=()

load_state() {
  S_ENT="$ENT" S_MAIN="main"
  S_CFG_KEYS=() S_CFG_VALS=() S_PARENT_KEYS=() S_PARENT_VALS=()
  S_LOCAL=() S_REMOTE=() S_WT_BRANCH=() S_WT_PATH=() S_STATE_PATH=() S_STATE_VAL=()
  local key val ref path=""

  # 1. settings and twig parents (sorted so children come out in name order)
  while read -r key val; do
    case "$key" in
      ent.*)              S_CFG_KEYS+=("${key#ent.}"); S_CFG_VALS+=("$val") ;;
      branch.*.entparent) key="${key#branch.}"; S_PARENT_KEYS+=("${key%.entparent}"); S_PARENT_VALS+=("$val") ;;
    esac
  done < <(git -C "$ENT" config --get-regexp '^(ent\.|branch\..*\.entparent$)' 2>/dev/null | sort)
  if state_cfg main && [[ -n "$REPLY" ]]; then S_MAIN="$REPLY"; fi

  # 2. branches (for-each-ref sorts by name)
  while read -r ref; do
    case "$ref" in
      refs/heads/*)        S_LOCAL+=("${ref#refs/heads/}") ;;
      refs/remotes/*/HEAD) ;;
      refs/remotes/*)      S_REMOTE+=("${ref#refs/remotes/}") ;;
    esac
  done < <(git -C "$ENT" for-each-ref --format='%(refname)' refs/heads refs/remotes)

  # 3. worktrees. git prints absolute paths with symlinks already resolved.
  while IFS= read -r ref; do
    case "$ref" in
      "worktree "*) path="${ref#worktree }" ;;
      "branch "*)   S_WT_BRANCH+=("${ref#branch refs/heads/}"); S_WT_PATH+=("$path") ;;
    esac
  done < <(git -C "$ENT" worktree list --porcelain)

  # 4. unfinished operations (a conflicted merge, a rebase, ...). Each worktree's
  # git files live in .bare/worktrees/<id>/, and git marks what is in progress with
  # the same files it uses for its own prompt. Reading them here means `list` can
  # show MERGING without running git per worktree.
  local wtdir target state
  for wtdir in "$ENT"/.bare/worktrees/*; do
    [[ -f "$wtdir/gitdir" ]] || continue
    target="$(<"$wtdir/gitdir")"        # <worktree>/.git
    target="${target%/.git}"
    state=""
    if   [[ -f "$wtdir/MERGE_HEAD" ]];       then state=MERGING
    elif [[ -d "$wtdir/rebase-merge" || -d "$wtdir/rebase-apply" ]]; then state=REBASING
    elif [[ -f "$wtdir/CHERRY_PICK_HEAD" ]]; then state=CHERRY-PICKING
    elif [[ -f "$wtdir/REVERT_HEAD" ]];      then state=REVERTING
    else continue
    fi
    S_STATE_PATH+=("$target"); S_STATE_VAL+=("$state")
  done
}

# state_of <branch>: REPLY = MERGING / REBASING / ... while an operation is
# unfinished in that branch's worktree, else empty. Returns 1 when there is none.
state_of() {
  state_ready
  wt_path_of "$1" || { REPLY=""; return 1; }
  local p="$REPLY" i=0
  while (( i < ${#S_STATE_PATH[@]} )); do
    if [[ "${S_STATE_PATH[$i]}" == "$p" ]]; then REPLY="${S_STATE_VAL[$i]}"; return 0; fi
    i=$((i + 1))
  done
  REPLY=""; return 1
}

# state_ready: load the snapshot if it is missing or belongs to another ent.
# Commands call it once in the main shell; $(...) subshells then inherit it.
state_ready() { [[ "$S_ENT" == "$ENT" ]] || load_state; }

# ---------- lookups that set REPLY ----------

# state_cfg <key>: REPLY = ent.<key> from .bare/config. Returns 1 if unset.
state_cfg() {
  local k i=0
  k="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while (( i < ${#S_CFG_KEYS[@]} )); do
    if [[ "${S_CFG_KEYS[$i]}" == "$k" ]]; then REPLY="${S_CFG_VALS[$i]}"; return 0; fi
    i=$((i + 1))
  done
  REPLY=""; return 1
}

# parent_of <branch>: REPLY = the twig's parent, or empty for main and branches.
parent_of() {
  state_ready
  local i=0
  while (( i < ${#S_PARENT_KEYS[@]} )); do
    if [[ "${S_PARENT_KEYS[$i]}" == "$1" ]]; then REPLY="${S_PARENT_VALS[$i]}"; return 0; fi
    i=$((i + 1))
  done
  REPLY=""
}

# wt_path_of <branch>: REPLY = the branch's worktree path. Returns 1 if not checked out.
wt_path_of() {
  state_ready
  local i=0
  while (( i < ${#S_WT_BRANCH[@]} )); do
    if [[ "${S_WT_BRANCH[$i]}" == "$1" ]]; then REPLY="${S_WT_PATH[$i]}"; return 0; fi
    i=$((i + 1))
  done
  REPLY=""; return 1
}

# children_of <branch>: REPLY_LIST = its twigs, in name order.
children_of() {
  state_ready
  local i=0
  REPLY_LIST=()
  while (( i < ${#S_PARENT_KEYS[@]} )); do
    if [[ "${S_PARENT_VALS[$i]}" == "$1" ]]; then REPLY_LIST+=("${S_PARENT_KEYS[$i]}"); fi
    i=$((i + 1))
  done
}

# top_branches: REPLY_LIST = branches with no parent, excluding the default branch.
# A twig whose parent branch was deleted counts too, so it is never hidden.
top_branches() {
  state_ready
  local b list=()
  for b in ${S_LOCAL[@]+"${S_LOCAL[@]}"}; do
    [[ "$b" == "$S_MAIN" ]] && continue
    parent_of "$b"
    if [[ -z "$REPLY" ]] || ! has_local "$REPLY"; then list+=("$b"); fi
  done
  REPLY_LIST=(${list[@]+"${list[@]}"})
}

# ---------- yes/no checks ----------
_in() { local want="$1" x; shift; for x in "$@"; do [[ "$x" == "$want" ]] && return 0; done; return 1; }
has_local()  { state_ready; _in "$1" ${S_LOCAL[@]+"${S_LOCAL[@]}"}; }
has_remote() { state_ready; _in "origin/$1" ${S_REMOTE[@]+"${S_REMOTE[@]}"}; }
has_origin() { state_ready; local r; for r in ${S_REMOTE[@]+"${S_REMOTE[@]}"}; do [[ "$r" == origin/* ]] && return 0; done; return 1; }

# ---------- printing wrappers, for code where a subshell is fine ----------
ent_main()         { state_ready; printf '%s' "$S_MAIN"; }
ent_parent()       { parent_of "$1"; printf '%s' "$REPLY"; }
ent_children()     { children_of "$1"; if (( ${#REPLY_LIST[@]} )); then printf '%s\n' "${REPLY_LIST[@]}"; fi; }
ent_top_branches() { top_branches;     if (( ${#REPLY_LIST[@]} )); then printf '%s\n' "${REPLY_LIST[@]}"; fi; }
local_branches()   { state_ready;      if (( ${#S_LOCAL[@]} ));    then printf '%s\n' "${S_LOCAL[@]}"; fi; }

# ent_descendants <branch>: every twig below <branch>, depth first.
ent_descendants() {
  local k
  for k in $(ent_children "$1"); do printf '%s\n' "$k"; ent_descendants "$k"; done
}
