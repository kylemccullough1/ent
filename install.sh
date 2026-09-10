#!/usr/bin/env bash
# Install git-grove for the current user. Usage: ./install.sh [bin-dir]
#   git-grove            -> ~/.local/bin/git-grove          (or the dir you pass)
#   cheatsheet.md        -> ~/.local/share/git-grove/       (what `git grove help` prints)
#   completions/*.bash   -> ~/.local/share/git-grove/
# Copies, not symlinks: re-run after editing the script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/git-grove"

mkdir -p "$BIN" "$SHARE"
install -m 755 "$HERE/git-grove" "$BIN/git-grove"
install -m 644 "$HERE/cheatsheet.md" "$SHARE/cheatsheet.md"
install -m 644 "$HERE/completions/git-grove.bash" "$SHARE/git-grove.bash"
echo "installed $BIN/git-grove ($("$BIN/git-grove" --version))"

case ":$PATH:" in *":$BIN:"*) ;; *)
  echo
  echo "$BIN is not on your PATH. Add to ~/.bashrc:"
  echo "  export PATH=\"$BIN:\$PATH\""
;; esac

cat <<EOF

For tab completion and the \`grove\` function that cds into new worktrees, add to ~/.bashrc:
  source "$SHARE/git-grove.bash"

Then: git grove help
EOF
