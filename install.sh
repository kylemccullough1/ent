#!/usr/bin/env bash
# Install git-ent for the current user. Usage: ./install.sh [bin-dir]
#   git-ent, lib/, completions/  ->  ~/.local/share/git-ent/
#   a small git-ent launcher     ->  ~/.local/bin/git-ent (or [bin-dir])
# Copies, not symlinks: re-run after editing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/git-ent"

rm -rf "$SHARE"
mkdir -p "$BIN" "$SHARE"
cp -R "$HERE/lib" "$HERE/completions" "$SHARE/"
cp "$HERE/git-ent" "$SHARE/git-ent"
chmod 755 "$SHARE/git-ent"

# The launcher on PATH runs the shared copy, which finds lib/ next to itself.
cat > "$BIN/git-ent" <<LAUNCHER
#!/usr/bin/env bash
exec "$SHARE/git-ent" "\$@"
LAUNCHER
chmod 755 "$BIN/git-ent"

echo "installed $BIN/git-ent ($("$BIN/git-ent" --version))"

case ":$PATH:" in *":$BIN:"*) ;; *)
  echo
  echo "$BIN is not on your PATH. Add to your shell rc file:"
  echo "  export PATH=\"$BIN:\$PATH\""
;; esac

cat <<MSG

For tab completion and the \`ent\` command that cds into worktrees, add to ~/.bashrc:
  source "$SHARE/completions/ent.bash"

Then: ent help
MSG
