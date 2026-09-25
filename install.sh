#!/usr/bin/env bash
# Install git-ent for the current user.
# Usage: ./install.sh [bin-dir] [--rc <file>]... [--no-rc]
#   git-ent, lib/, completions/, uninstall.sh  ->  ~/.local/share/git-ent/
#   a small git-ent launcher                   ->  ~/.local/bin/git-ent (or [bin-dir])
#   one `source` line                          ->  your shell's startup file(s)
# Copies, not symlinks: re-run after editing.
#
#   --rc <file>   set up this file instead of the ones found automatically (repeatable).
#                 ENT_RC=<file> does the same.
#   --no-rc       don't touch any startup file. ENT_NO_RC=1 does the same.
set -euo pipefail

BIN="" NO_RC="${ENT_NO_RC:-}" RC_FILES=()
while (( $# > 0 )); do
  case "$1" in
    --rc)     RC_FILES+=("${2:?--rc needs a file}"); shift ;;
    --no-rc)  NO_RC=1 ;;
    -*)       echo "unknown option: $1" >&2; exit 1 ;;
    *)        BIN="$1" ;;
  esac
  shift
done
[[ -z "${ENT_RC:-}" ]] || RC_FILES+=("$ENT_RC")

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN:-$HOME/.local/bin}"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/git-ent"

rm -rf "$SHARE"
mkdir -p "$BIN" "$SHARE" "${XDG_CONFIG_HOME:-$HOME/.config}/ent"
cp -R "$HERE/lib" "$HERE/completions" "$SHARE/"
cp "$HERE/git-ent" "$HERE/uninstall.sh" "$SHARE/"
chmod 755 "$SHARE/git-ent" "$SHARE/uninstall.sh"

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
# from one `source` line. completions/ent.sh picks the zsh or bash version itself,
# so every startup file gets the same line.
#
# The line says $HOME literally rather than /Users/you, so a startup file shared
# between machines keeps working.
RC_SHARE="${SHARE/#$HOME/\$HOME}"
RC_LINE="source \"$RC_SHARE/completions/ent.sh\""
RC_RECORD="$SHARE/rc-files"     # what uninstall.sh should clean up
CHANGED=()

# add_to_rc <rc-file>: make sure RC_LINE is in <rc-file>, exactly once.
#   - install.sh is re-run after every update, so running it again must not
#     add a second copy.
#   - The file may not exist yet (a fresh machine has no ~/.bashrc).
#   - Leave a comment above the line so a person reading their startup file later
#     knows where it came from.
#   The check matches the text anywhere in the file, not only whole lines, so a line
#   you commented out ("# source ...") counts as present and stays switched off.
add_to_rc() {
  local rc="$1"
  printf '%s\n' "$rc" >> "$RC_RECORD"
  if [[ -f "$rc" ]] && grep -qF -- "$RC_LINE" "$rc"; then
    echo "  $rc (already set up)"
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  printf '\n# git-ent: the `ent` command, tab completion and prompt helper (added by install.sh)\n%s\n' \
    "$RC_LINE" >> "$rc"
  CHANGED+=("$rc")
  echo "  $rc"
}

# loads_bashrc <file>: true when a bash login file already reads ~/.bashrc.
loads_bashrc() { [[ -f "$1" ]] && grep -q '\.bashrc' "$1"; }

# rc_targets: every startup file to set up, for every shell this user has.
# $SHELL is only the login shell, so installed shells count too.
rc_targets() {
  local login="${SHELL##*/}"
  if [[ "$login" == zsh ]] || command -v zsh >/dev/null 2>&1; then
    # zsh reads $ZDOTDIR/.zshrc when ZDOTDIR is set (dotfiles kept in ~/.config/zsh).
    printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
  fi
  if [[ "$login" == bash ]] || [[ -f "$HOME/.bashrc" ]]; then
    printf '%s\n' "$HOME/.bashrc"
    # A login shell (macOS Terminal, Git Bash on Windows) reads .bash_profile and
    # never .bashrc, unless .bash_profile loads it. Cover that case too.
    if [[ -f "$HOME/.bash_profile" ]] && ! loads_bashrc "$HOME/.bash_profile"; then
      printf '%s\n' "$HOME/.bash_profile"
    fi
  fi
}

if [[ -z "$NO_RC" ]]; then
  : > "$RC_RECORD"
  echo
  if (( ${#RC_FILES[@]} )); then
    echo "Shell setup:"
    for rc in "${RC_FILES[@]}"; do add_to_rc "$rc"; done
  else
    targets=()
    while IFS= read -r rc; do targets+=("$rc"); done < <(rc_targets)
    if (( ${#targets[@]} )); then
      echo "Shell setup:"
      for rc in "${targets[@]}"; do add_to_rc "$rc"; done
    else
      echo "No bash or zsh startup file found. To set up your shell yourself, add:"
      echo "  $RC_LINE"
    fi
  fi
fi

echo
if (( ${#CHANGED[@]} )); then
  echo "Open a new terminal so the \`ent\` command goes live."
else
  echo "Run: ent help"
fi
echo "To remove git-ent later: $SHARE/uninstall.sh"
