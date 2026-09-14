#!/usr/bin/env bash
# One-off migration from a git-grove 0.3.x flat layout to git-ent nested layout.
# Usage: bash migrate-grove-to-ent.sh <grove-dir>
#
# Before running: close Explorer / VS Code windows touching the grove, and pause
# OneDrive. `git worktree move` is a rename; open handles block it on Windows.
set -euo pipefail

ENT="${1:-}"
[[ -n "$ENT" ]] || { echo "Usage: migrate-grove-to-ent.sh <grove-dir>"; exit 1; }
ENT="$(cd "$ENT" && { pwd -W 2>/dev/null || pwd -P; })"
[[ -d "$ENT/.bare" ]] || { echo "'$ENT' is not a grove (no .bare)"; exit 1; }

g() { git -C "$ENT" "$@"; }
dashed() { printf '%s' "${1//\//-}"; }

main_branch() { g config --get ent.main 2>/dev/null || g symbolic-ref --short HEAD 2>/dev/null || echo main; }
parent_of() { g config --get "branch.$1.groveParent" 2>/dev/null || true; }

# Compute the new ent core path for a branch.
ent_core_for() {
  local b="$1" main p slug twig
  main="$(main_branch)"
  if [[ "$b" == "$main" ]]; then printf '%s/main/core' "$ENT"; return 0; fi
  p="$(parent_of "$b")"
  slug="$(dashed "$b")"
  if [[ -z "$p" ]]; then
    printf '%s/branches/%s/core' "$ENT" "$slug"
  else
    # twig name is the part after the parent prefix, e.g. feature/x-auth -> auth
    twig="$b"
    if [[ "$twig" == "$p"-* ]]; then twig="${twig#"$p-"}"; fi
    printf '%s/twigs/%s/core' "$(dirname "$(ent_core_for "$p")")" "$twig"
  fi
}

echo "Migrating grove at $ENT"
main="$(main_branch)"
echo "Default branch: $main"

# Read existing worktrees: path<TAB>branch
while IFS=$'\t' read -r path branch; do
  [[ -n "$path" && -n "$branch" ]] || continue
  new_path="$(ent_core_for "$branch")"
  printf '%s\t%s\t=>\t%s\n' "$branch" "$path" "$new_path"
done < <(g worktree list --porcelain | awk '
  /^worktree /{p=substr($0,10)}
  /^branch /{b=substr($0,8); sub("^refs/heads/","",b); print p "\t" b}')

if [[ -t 0 ]]; then
  read -r -p "Proceed? [y/N] " a
  [[ "$a" =~ ^[yY]$ ]] || { echo "Cancelled."; exit 0; }
fi

# Special-case the default branch: its old path is <ent>/<main> and its new path
# is <ent>/<main>/core, i.e. nested inside the old path. Move it via a temp.
main_old="$ENT/$main"
main_new="$ENT/main/core"
if [[ -d "$main_old" && ! -d "$main_new" ]]; then
  tmp_main="$ENT/.migrate-main"
  echo "Reorganising default branch $main -> main/core"
  g worktree move "$main_old" "$tmp_main"
  mv "$tmp_main" "$main_new"
  g worktree repair "$main_new" >/dev/null
fi

# Move everything else.
while IFS=$'\t' read -r path branch; do
  [[ -n "$path" && -n "$branch" ]] || continue
  [[ "$branch" == "$main" ]] && continue
  new_path="$(ent_core_for "$branch")"
  [[ "$path" == "$new_path" ]] && continue
  mkdir -p "$(dirname "$new_path")"
  echo "Moving $branch: $path -> $new_path"
  g worktree move "$path" "$new_path"
done < <(g worktree list --porcelain | awk '
  /^worktree /{p=substr($0,10)}
  /^branch /{b=substr($0,8); sub("^refs/heads/","",b); print p "\t" b}')

# Rename config keys from groveParent to entParent.
g config --get-regexp '^branch\..*\.groveParent$' 2>/dev/null | while IFS=' ' read -r key parent; do
  b="${key#branch.}"; b="${b%.groveParent}"
  g config "branch.$b.entParent" "$parent"
  g config --unset "$key"
done || true

# Record the default branch name in the new config key.
g config ent.main "$main"

# Clean up obsolete top-level folders.
rmdir "$ENT/roots" 2>/dev/null || true
for b in $(g branch --format='%(refname:short)'); do
  if [[ "$b" == "$main" ]]; then continue; fi
  old="$ENT/$(dashed "$b")"
  [[ -d "$old" ]] && rm -rf "$old"
done

# Rename .gitgrove to .entrc if present.
if [[ -f "$ENT/main/core/.gitgrove" && ! -f "$ENT/main/core/.entrc" ]]; then
  mv "$ENT/main/core/.gitgrove" "$ENT/main/core/.entrc"
  echo "Renamed main/core/.gitgrove -> main/core/.entrc"
fi

g worktree repair 2>/dev/null || true
echo "Migration complete. Run 'git ent list' to verify."
