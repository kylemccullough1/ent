# ent config: settings layered as
#   ENT_<KEY> env var  >  ent.<key> in .bare/config  >  committed .entrc  >  built-in default
# .entrc is optional. It lives on the default branch and is read with `git show`,
# so every worktree sees the same file. It is parsed as key = value, never sourced.

# teamfile_get <key>: value of <key> in the default branch's .entrc, or empty.
teamfile_get() {
  git -C "$ENT" show "$(ent_main):.entrc" 2>/dev/null | awk -v k="$1" '
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    { key=$0; sub(/=.*/, "", key); gsub(/[[:space:]]/, "", key)
      if (key == k) { val=$0; sub(/^[^=]*=[[:space:]]*/, "", val); print val; exit } }' || true
}

# env_get <key>: value of ENT_<KEY> if it is set. Returns 1 when unset.
env_get() {
  local name; name="ENT_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  [[ -n "${!name+x}" ]] || return 1
  printf '%s' "${!name}"
}

# cfg <key>: the first layer that sets <key> wins.
cfg() {
  local v
  if v="$(env_get "$1")"; then printf '%s' "$v"; return; fi
  state_ready
  if state_cfg "$1"; then printf '%s' "$REPLY"; return; fi
  teamfile_get "$1"
}

# cfg_all <key>: every layer's value joined with spaces (for list settings like protect).
cfg_all() {
  local out="" v
  if v="$(env_get "$1")"; then out+=" $v"; fi
  state_ready
  if state_cfg "$1"; then out+=" $REPLY"; fi
  out+=" $(teamfile_get "$1")"
  printf '%s' "$out"
}

max_depth()      { local v; v="$(cfg maxDepth)"; printf '%s' "${v:-2}"; }
branch_pattern() { cfg branchPattern; }
