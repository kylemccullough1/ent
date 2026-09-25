# ent log: per-ent and global logging.
# Format: [<ISO-8601>] [<LEVEL>] [<script>:<line>] <message>

set -euo pipefail

_LOG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ent"

# _log_target: the file to write to.
_log_target() {
  if [[ -n "${ENT:-}" && -d "$ENT/.bare" ]]; then
    printf '%s/.bare/ent.log' "$ENT"
  else
    [[ -d "$_LOG_DIR" ]] || mkdir -p "$_LOG_DIR" 2>/dev/null || true
    printf '%s/global.log' "$_LOG_DIR"
  fi
}

# _log_caller_info: parse a caller(0) line into "file:line".
_log_caller_info() {
  local line _ func file
  read -r line func file <<<"$1"
  if [[ -n "$file" && -n "$line" ]]; then
    printf '%s:%s' "${file##*/}" "$line"
  else
    printf '%s' "-"
  fi
}

# _log_write <level> <msg> <caller-line>
_log_write() {
  local level="$1" msg="$2" caller_line="${3:-}"
  local target info
  target="$(_log_target)"
  [[ -n "$target" ]] || return 0
  if [[ -z "$caller_line" ]]; then
    caller_line="$(caller 0 2>/dev/null || true)"
  fi
  info="$(_log_caller_info "$caller_line")"
  printf '[%s] [%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)" "$level" "$info" "$msg" >> "$target" 2>/dev/null || true
}

# Direct log entry points.
log_info()  { _log_write INFO "$*" ""; }
log_warn()  { _log_write WARN "$*" ""; }
log_error() { _log_write ERROR "$*" ""; }
log_global() { _log_write INFO "$*" ""; }

# Hooks for output.sh note/warn/die wrappers.  They pass caller 1 so the log
# entry points at the code that called note/warn/die, not at output.sh itself.
_log_info_from_output()  { _log_write INFO "$*" "$(caller 1 2>/dev/null || true)"; }
_log_warn_from_output()  { _log_write WARN "$*" "$(caller 1 2>/dev/null || true)"; }
_log_error_from_output() { _log_write ERROR "$*" "$(caller 1 2>/dev/null || true)"; }
