#!/usr/bin/env bash
# Remove git-ent from this user account: everything install.sh created, and nothing else.
# Usage: ./uninstall.sh [bin-dir] [-y]
#   ~/.local/share/git-ent/            deleted
#   ~/.local/bin/git-ent (launcher)    deleted, only if it is install.sh's launcher
#   ~/.zshrc, ~/.bashrc                the line install.sh added (and its comment) removed
# Your ents (repos made with `ent init`) are never touched.
set -euo pipefail
YES=0 BIN=""
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    -*)       echo "unknown option: $a" >&2; exit 1 ;;
    *)        BIN="$a" ;;
  esac
done
BIN="${BIN:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/git-ent"

# Running from inside $SHARE means deleting our own file. Windows refuses to delete a
# file that is in use, so re-run from a temporary copy first.
case "$(cd "$(dirname "$0")" && pwd -P)" in
  "$(cd "$SHARE" 2>/dev/null && pwd -P)")
    _copy="$(mktemp)"; cp "$0" "$_copy"; exec bash "$_copy" "$@" ;;
esac

MARKER='# git-ent: the `ent` command, tab completion and prompt helper (added by install.sh)'

if (( ! YES )) && [[ -t 0 ]]; then
  read -r -p "Uninstall git-ent from $SHARE, $BIN and your shell rc files? [y/N] " a
  [[ "$a" == [yY] ]] || { echo "Cancelled."; exit 0; }
fi

# ---------- files ----------
if [[ -d "$SHARE" ]]; then rm -rf "$SHARE"; echo "Removed $SHARE"; fi
# Only delete a launcher install.sh wrote (it execs .../git-ent/git-ent), never
# some other program that happens to be called git-ent.
if [[ -f "$BIN/git-ent" ]] && grep -q 'git-ent/git-ent' "$BIN/git-ent"; then
  rm -f "$BIN/git-ent"; echo "Removed $BIN/git-ent"
fi

# ---------- shell rc files ----------
# remove_from_rc <rc-file>: drop install.sh's comment and source line, plus the blank
# line install.sh put before them. Lines you wrote yourself are kept.
remove_from_rc() {
  local rc="$1" tmp
  [[ -f "$rc" ]] || return 0
  grep -qF 'git-ent/completions/ent.' "$rc" || return 0
  tmp="$(mktemp)"
  awk -v marker="$MARKER" '
    # hold a blank line back: print it only if the next line is not our marker
    held { if ($0 != marker) print ""; held = 0 }
    $0 == ""     { held = 1; next }
    $0 == marker { next }
    /^[#[:space:]]*source .*git-ent\/completions\/ent\.(zsh|bash)/ { next }
    { print }
    END { if (held) print "" }
  ' "$rc" > "$tmp"
  # Write through `cat` rather than `mv`, so a symlinked rc file (dotfiles repos)
  # stays a symlink and keeps its permissions.
  cat "$tmp" > "$rc"
  rm -f "$tmp"
  echo "Removed the git-ent lines from $rc"
}
remove_from_rc "$HOME/.zshrc"
remove_from_rc "$HOME/.bashrc"

echo
echo "git-ent is uninstalled. Open a new terminal so the \`ent\` command goes away."
echo "Your ents (the folders made by \`ent init\`) were not touched."
