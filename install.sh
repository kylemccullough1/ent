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

# ---------- shell setup ----------
# The `ent` command (which cds for you), tab completion and the prompt helper come
# from one `source` line in your shell's startup file.

# add_to_rc <rc-file> <line>: make sure <line> is in <rc-file>, exactly once.
#   - install.sh is re-run after every update, so running it again must not
#     add a second copy.
#   - The file may not exist yet (a fresh machine has no ~/.bashrc).
#   - Leave a comment above the line so a person reading their rc file later
#     knows where it came from.
#   Print what happened (added / already there) so the user sees it.
#   The check matches the text anywhere in the file, not only whole lines, so a line
#   you commented out ("# source ...") counts as present and stays switched off.
add_to_rc() {
  local rc="$1" line="$2"
  if [[ -f "$rc" ]] && grep -qF -- "$line" "$rc"; then
    echo "$rc already sources ent; left unchanged."
    return 0
  fi
  printf '\n# git-ent: the `ent` command, tab completion and prompt helper (added by install.sh)\n%s\n' \
    "$line" >> "$rc"
  echo "Added to $rc: $line"
}

# Pick the startup file for the shell you log in with. ENT_NO_RC=1 skips this step.
# The line says $HOME literally rather than /Users/you, so an rc file shared between
# machines keeps working.
if [[ -z "${ENT_NO_RC:-}" ]]; then
  RC_SHARE="${SHARE/#$HOME/\$HOME}"
  case "${SHELL##*/}" in
    zsh)  add_to_rc "$HOME/.zshrc"  "source \"$RC_SHARE/completions/ent.zsh\"" ;;
    bash) add_to_rc "$HOME/.bashrc" "source \"$RC_SHARE/completions/ent.bash\"" ;;
    *)    echo "Add to your shell's startup file: source \"$RC_SHARE/completions/ent.bash\"" ;;
  esac
fi

echo
echo "Open a new terminal (or source your rc file), then: ent help"
