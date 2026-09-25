# ent core: output, running commands, prompting, and argument parsing.
# Sourced by git-ent. Everything here is plain bash 3.2.

# ---------- output ----------
# Messages go to stderr. stdout is reserved for paths the `ent` shell wrapper cds into.
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
note() { (( QUIET )) || printf '%s\n' "$*" >&2; }
warn() { printf '%sgit ent: %s%s\n' "$E_YEL" "$*" "$E_RST" >&2; }
die()  { printf '%sgit ent: %s%s\n' "$E_RED" "$1" "$E_RST" >&2; exit "${2:-1}"; }
usage_die() { die "usage: ent $1"; }

# ---------- running commands ----------
# run: a command that changes something. Echoed; skipped under --dry-run.
# Its stdout goes to stderr so only emit_path writes to stdout.
run()   { say "$@"; if (( DRY_RUN )); then return 0; fi; "$@" >&2; }
runat() { local d="$1"; shift; say "$@"; if (( DRY_RUN )); then return 0; fi; (cd "$d" && "$@") >&2; }

# worktree_bare_guard <worktree-dir>: keep a new worktree usable when
# extensions.worktreeConfig is switched on.
#
# `git sparse-checkout` turns that extension on. With it on, git stops ignoring
# the ent's shared core.bare=true inside linked worktrees and starts honouring
# it, so every worktree in the ent answers "this operation must be run in a
# work tree". Writing core.bare=false into the worktree's own config undoes
# that. Only written when the extension is on, so ordinary ents stay untouched.
worktree_bare_guard() {
  local on
  on="$(git -C "$ENT" config --bool --get extensions.worktreeConfig 2>/dev/null || true)"
  [[ "$on" == true ]] || return 0
  run git -C "$1" config --worktree core.bare false
}

# emit_path: print a path on stdout (for the `ent` wrapper to cd into) and a note on stderr.
emit_path() { printf '%s\n' "$1"; if [[ -n "${2:-}" ]]; then note "$2"; fi; return 0; }

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

# ---------- argument parsing ----------
# Flags may appear anywhere on the line. Words that are not flags land in ARGS,
# so for `ent branch merge -y`, ARGS=(branch merge).
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
