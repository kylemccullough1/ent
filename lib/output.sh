# ent output: stderr messages, color, and path emission.
# stdout is reserved for paths the `ent` shell wrapper will cd into.

set -euo pipefail

ESC=$'\033'
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  E_DIM="$ESC[2m" E_RED="$ESC[31m" E_YEL="$ESC[33m" E_RST="$ESC[0m"
else
  E_DIM='' E_RED='' E_YEL='' E_RST=''
fi

# fmt_cmd: quote a command line so it can be pasted back into a shell.
fmt_cmd() {
  local out="" a
  for a in "$@"; do
    if [[ -z "$a" || "$a" == *[[:space:]\'\"\$\`\\]* ]]; then a="'${a//\'/\'\\\'\'}'"; fi
    out+="${out:+ }$a"
  done
  printf '%s' "$out"
}

say()  { printf '%s$ %s%s\n' "$E_DIM" "$(fmt_cmd "$@")" "$E_RST" >&2; }

note() {
  (( QUIET )) || printf '%s\n' "$*" >&2
  if declare -f _log_info_from_output >/dev/null 2>&1; then
    _log_info_from_output "$*"
  fi
}

warn() {
  printf '%sgit ent: %s%s\n' "$E_YEL" "$*" "$E_RST" >&2
  if declare -f _log_warn_from_output >/dev/null 2>&1; then
    _log_warn_from_output "$*"
  fi
}

die()  {
  printf '%sgit ent: %s%s\n' "$E_RED" "$1" "$E_RST" >&2
  if declare -f _log_error_from_output >/dev/null 2>&1; then
    _log_error_from_output "$1"
  fi
  exit "${2:-1}"
}

usage_die() { die "usage: ent $1"; }

# emit_path: print a path on stdout (for the `ent` wrapper to cd into) and a note on stderr.
emit_path() { printf '%s\n' "$1"; if [[ -n "${2:-}" ]]; then note "$2"; fi; return 0; }
