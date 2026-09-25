# ent prompt: yes/no and choose-one helpers.

set -euo pipefail

# confirm: ask a yes/no question on the terminal. --yes answers yes to everything.
confirm() {
  if (( YES )); then return 0; fi
  local a
  read -r -p "$1 [y/N] " a || return 1
  [[ "$a" == [yY] ]]
}

# choose <prompt> <letters>: ask for one letter out of <letters> (space separated).
# REPLY is the letter chosen. Returns 1 once the input runs out -- no terminal,
# or a pipe with nothing useful in it -- so callers can fall back to a flag.
# `read -p` writes its prompt to stderr, which is why this still works inside
# the `ent` shell wrapper: that captures stdout only.
choose() {
  local prompt="$1" letters="$2" a x
  while read -r -p "$prompt" a; do
    for x in $letters; do
      if [[ "$a" == "$x" ]]; then REPLY="$a"; return 0; fi
    done
  done
  return 1
}
