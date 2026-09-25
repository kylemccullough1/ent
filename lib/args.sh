# ent args: global flags and positional argument access.
#
# Global flags may appear anywhere on the line. Words that are not global flags
# land in ARGS, so for `ent branch merge -y`, ARGS=(branch merge).  Each verb
# defines its own parse_<verb>_args to handle command-specific flags.

set -euo pipefail

DRY_RUN=0 VERBOSE=0 QUIET=0 HELP=0 YES=0
FROM="" REMOTE="" WORKTREES="" FORCE=0 RECURSIVE=0 MERGE_ABORT=0 MERGE_CONTINUE=0 WIN=0 HERE=0
ARGS=()
REST_ARGS=()     # whatever followed `--`, passed on to git (see cmd_log)
ENT=""

# parse_globals: consume only global flags. Unknown flags are left in ARGS so
# the command-specific parser can handle them.
parse_globals() {
  ARGS=() REST_ARGS=()
  while (( $# > 0 )); do
    case "$1" in
      --dry-run|-n)   DRY_RUN=1 ;;
      --verbose|-v)   VERBOSE=1 ;;
      --quiet|-q)     QUIET=1 ;;
      --help|-h)      HELP=1 ;;
      --yes|-y)       YES=1 ;;
      --version)      echo "git-ent $VERSION"; exit 0 ;;
      --)             shift; REST_ARGS=("$@"); break ;;
      *)              ARGS+=("$1") ;;
    esac
    shift
  done
}

# arg <n>: the nth word after the verb (1-based), or empty.
arg() { if (( ${#ARGS[@]} > $1 )); then printf '%s' "${ARGS[$1]}"; fi; }
