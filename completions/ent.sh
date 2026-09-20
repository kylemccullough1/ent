# git-ent shell setup. One line in your shell's startup file loads this:
#   source "$HOME/.local/share/git-ent/completions/ent.sh"
# It loads the zsh or bash version depending on which shell is reading it, and
# does nothing in any other shell. Written in plain sh so nothing here can fail
# in a shell that only reads it by accident (dash reading ~/.profile, say).

if [ -z "${__ENT_LOADED:-}" ]; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    # ${(%):-%x} is zsh for "the file currently being sourced".
    __ent_dir="${${(%):-%x}:A:h}"
    __ENT_LOADED=1
    . "$__ent_dir/ent.zsh"
    unset __ent_dir
  elif [ -n "${BASH_VERSION:-}" ]; then
    __ent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    __ENT_LOADED=1
    . "$__ent_dir/ent.bash"
    unset __ent_dir
  fi
fi
