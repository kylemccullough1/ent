#!/usr/bin/env bash
# Install git-ent for the current user. Usage: ./install.sh [bin-dir]
#   git-ent            -> ~/.local/bin/git-ent
#   lib/paths.sh       -> ~/.local/share/git-ent/lib/paths.sh
#   cheatsheet.md      -> ~/.local/share/git-ent/
#   completions/*.bash -> ~/.local/share/git-ent/
# Copies, not symlinks: re-run after editing the script.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/git-ent"

mkdir -p "$BIN" "$SHARE/lib" "$SHARE/completions"
install -m 755 "$HERE/git-ent" "$SHARE/git-ent"
install -m 644 "$HERE/lib/paths.sh" "$SHARE/lib/paths.sh"
install -m 644 "$HERE/cheatsheet.md" "$SHARE/cheatsheet.md"
install -m 644 "$HERE/completions/ent.bash" "$SHARE/completions/ent.bash"

# Wrapper on PATH so git-ent can locate its lib wherever SHARE is.
cat > "$BIN/git-ent" <<EOF
#!/usr/bin/env bash
exec "$SHARE/git-ent" "\$@"
EOF
chmod +x "$BIN/git-ent"

echo "installed $BIN/git-ent ($("$BIN/git-ent" --version))"

case ":$PATH:" in *":$BIN:"*) ;; *)
  echo
  echo "$BIN is not on your PATH. Add to ~/.bashrc:"
  echo "  export PATH=\"$BIN:\$PATH\""
;; esac

cat <<EOF

For tab completion and the \`ent\` function that cds into new worktrees, add to ~/.bashrc:
  source "$SHARE/completions/ent.bash"

Then: git ent help
EOF
