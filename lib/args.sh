# ent args: global flags and positional argument access.
#
# Global flags may appear anywhere on the line. Words that are not global flags
# land in ARGS, so for `ent branch merge -y`, ARGS=(branch merge). Each verb
# then calls take_flags, which takes its own flags out and refuses the rest.

set -euo pipefail

DRY_RUN=0 VERBOSE=0 QUIET=0 HELP=0 YES=0
FROM="" REMOTE="" WORKTREES="" FORCE=0 RECURSIVE=0 MERGE_ABORT=0 MERGE_CONTINUE=0 WIN=0 HERE=0
ARGS=()
REST_ARGS=()     # whatever followed `--`, passed on to git (see cmd_log)
RM_LEFTOVER=()   # folders rm_one could not delete (something was standing in them)
ENT=""

# parse_globals: consume only global flags. Unknown flags are left in ARGS for
# the verb's take_flags to handle.
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

# take_flags <verb> [spec...]: move the verb's own flags out of ARGS into
# variables, and refuse any other word that starts with -. A spec is
# "<names>:<VAR>" for a switch (VAR=1) or "<names>=<VAR>" for an option that
# takes the next word. <names> is |-separated: "--force|-f:FORCE", "--from=FROM".
# A verb with no flags calls it with no specs, so `ent list --bogus` fails.
take_flags() {
  local verb="$1" i=0 a spec names var hit kept=()
  shift
  while (( i < ${#ARGS[@]} )); do
    a="${ARGS[$i]}"
    if [[ "$a" != -* ]]; then kept+=("$a"); i=$((i + 1)); continue; fi
    hit=0
    for spec in "$@"; do
      case "$spec" in
        *=*) names="${spec%%=*}" var="${spec#*=}" ;;
        *)   names="${spec%%:*}" var="${spec#*:}" ;;
      esac
      case "|$names|" in *"|$a|"*) ;; *) continue ;; esac
      hit=1
      if [[ "$spec" == *=* ]]; then
        i=$((i + 1))
        [[ -n "${ARGS[$i]:-}" ]] || die "$a requires a value"
        printf -v "$var" '%s' "${ARGS[$i]}"
      else
        printf -v "$var" '%s' 1
      fi
      break
    done
    (( hit )) || die "unknown $verb option: $a"
    i=$((i + 1))
  done
  ARGS=(${kept[@]+"${kept[@]}"})
}

# arg <n>: the nth word after the verb (1-based), or empty.
arg() { if (( ${#ARGS[@]} > $1 )); then printf '%s' "${ARGS[$1]}"; fi; }
