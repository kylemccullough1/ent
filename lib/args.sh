# ent args: global flags and positional argument access.
#
# Flags may appear anywhere on the line. Words that are not flags land in ARGS,
# so for `ent branch merge -y`, ARGS=(branch merge).

set -euo pipefail

DRY_RUN=0 VERBOSE=0 QUIET=0 HELP=0 FORCE=0 RECURSIVE=0 YES=0 WIN=0 HERE=0
MERGE_ABORT=0 MERGE_CONTINUE=0 FROM="" REMOTE="" WORKTREES=""
ARGS=()
REST_ARGS=()     # whatever followed `--`, passed on to git (see cmd_log)
ENT=""

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run|-n)   DRY_RUN=1 ;;
      --verbose|-v)   VERBOSE=1 ;;
      --quiet|-q)     QUIET=1 ;;
      --help|-h)      HELP=1 ;;
      --force|-f)     FORCE=1 ;;
      --recursive|-r) RECURSIVE=1 ;;
      --yes|-y)       YES=1 ;;
      --win)          WIN=1 ;;
      --here)         HERE=1 ;;
      --abort)        MERGE_ABORT=1 ;;
      --continue)     MERGE_CONTINUE=1 ;;
      --from)         FROM="${2:-}"; shift || true; [[ -n "$FROM" ]] || die "--from requires a value" ;;
      --remote)       REMOTE="${2:-}"; shift || true; [[ -n "$REMOTE" ]] || die "--remote requires a value" ;;
      --worktrees)    WORKTREES="${2:-}"; shift || true
                      case "$WORKTREES" in move|drop) ;; *) die "--worktrees takes move or drop" ;; esac ;;
      --version)      echo "git-ent $VERSION"; exit 0 ;;
      --)             shift; break ;;
      -*)             die "unknown option: $1" ;;
      *)              ARGS+=("$1") ;;
    esac
    shift
  done
  while (( $# > 0 )); do REST_ARGS+=("$1"); shift; done
}

# arg <n>: the nth word after the verb (1-based), or empty.
arg() { if (( ${#ARGS[@]} > $1 )); then printf '%s' "${ARGS[$1]}"; fi; }
