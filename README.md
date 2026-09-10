# git-grove

One bash file that turns a repo into a **grove**: a bare git database plus one folder per branch,
so switching branches is `cd`, not `checkout`. Side experiments become **roots** — worktrees that
remember which branch they grew from — and `list` draws the whole thing as a tree.

Every command that changes something prints the `$ git ...` it runs. The point is to learn the git
underneath, not to hide it.

```
personal/
  .bare/                      the git database
  .git                        one line: "gitdir: ./.bare"
  main/                       tree  main
  feature-x/                  tree  feature/x
  roots/
    feature-x/auth/           root  feature/x-auth      parent feature/x
    feature-x/db/             root  feature/x-db        parent feature/x
    feature-x-auth/jwt/       root  feature/x-auth-jwt  parent feature/x-auth
```

Requirements: bash 4+, git 2.42+ (for `worktree add --orphan`). Linux, macOS, Git Bash on Windows.

## Install

```bash
git clone <this repo> && cd grove
./install.sh                 # copies git-grove to ~/.local/bin and prints what to add to your shell
```

`install.sh` prints three lines for `~/.bashrc`: the `PATH` entry, `source` for tab completion, and
the `grove` function below. Anything named `git-<x>` on `PATH` runs as `git <x>`, so after that
`git grove` works everywhere.

### The `grove` shell function (recommended)

A subcommand runs in its own process and cannot change your shell's directory. `add`, `init`,
`go`, `up`, and `down` therefore print a path; this function does the `cd`, and only when the
command succeeded — `cd "$(failed-command)"` would otherwise land you in `$HOME`.

```bash
grove() {
  case "${1:-}" in
    add|init|go|up|down)
      local p
      p="$(git grove "$@" --print-path)" || return $?
      cd "$p" ;;
    *) git grove "$@" ;;
  esac
}
```

PowerShell (`$PROFILE`), with the same success check:

```powershell
# `git grove` resolves directly from PowerShell because ~/.local/bin is on PATH; no bash.exe needed
function grove {
  switch ($args[0]) {
    { $_ -in 'add','init','go','up','down' } {
      $p = & git grove @args --print-path
      if ($LASTEXITCODE -eq 0) { Set-Location $p }
    }
    'finish' {
      if ($args[1] -eq '.') {        # finish the branch we stand in: merge, cd to the target, then remove it
        $src = git symbolic-ref --short -q HEAD
        $p = & git grove @args --print-path
        if ($LASTEXITCODE -eq 0 -and $p) { Set-Location $p; & git grove rm $src --apply }
      } else { & git grove @args }
    }
    default { & git grove @args }
  }
}
```

## Use

```bash
git grove init my-app                    # new repo -> my-app/.bare, my-app/main/
git grove init git@host:org/repo.git     # from a remote
git grove init ../old-clone new-grove    # from an existing clone (it is left untouched)

grove add feature/x                      # plant a tree and cd into it
grove add auth --from .                  # a root of feature/x: branch feature/x-auth
grove up                                 # back to feature/x
grove down auth                          # and into the root again
git grove list                           # everything, roots under their parents
git grove rm feature/x-auth              # preview what would go
git grove rm feature/x-auth --apply      # do it
git grove sync --pull                    # fetch everything, fast-forward every clean worktree
```

`git grove help` prints the cheat sheet; `git grove help <verb>` one verb's usage.

## Concepts, briefly

- **Tree** — a worktree for a branch at `<grove>/<branch>/` with `/` turned into `-`, so
  `feature/x` lives in `feature-x/`. That keeps every worktree a sibling at the top level.
- **Root** — a worktree that records a parent branch (`git config branch.<b>.groveParent`). Its
  branch is `<parent>-<name>` and its folder is `roots/<parent-dashed>/<name>/`. Roots nest
  logically to any depth; on disk they stay flat.
- **Why flat?** A checkout inside another checkout is a real subdirectory of that project:
  `dotnet build`, webpack, tsc, test discovery, Docker contexts, and IDE indexers all walk into it.
  Keeping worktrees out of each other is the one rule that makes everything else work.
- **Parentage is local.** Worktree registrations and `branch.*` config live in `.bare/` and are
  never pushed. Your teammates see ordinary branches; the tree is yours.

## Removal is careful

`rm` previews unless you pass `--apply`, and refuses, in order: the default branch or anything in
`protect` (no override); a branch that still has roots (`-r`); uncommitted changes (`-f`); commits
that exist on neither the default branch, the parent, nor the upstream (`-f`). A branch that is
merged only into its parent, or only pushed for review, is considered safe.

## Team settings: `.gitgrove`

Commit a `.gitgrove` on the default branch to give everyone the same rules. Copy
`.gitgrove.example` to start. Keys:

| Key | Effect |
|---|---|
| `branchPattern` | ERE that tree names must match. Empty or absent = no rule. Never applied to roots. |
| `protect` | extra branch names `rm` refuses, space-separated |

Precedence, nearest wins: `GROVE_<KEY>` env → `git config grove.<key>` (global, then the grove's
`.bare/config`) → `.gitgrove` → built-in. A user can opt out of a team `branchPattern` locally with
`git config grove.branchPattern ""`. `protect` is the exception: it is a union of every layer.

The file is read with `git show <default>:.gitgrove`, so it is the same file from every worktree and
from the grove's top folder, and an edit takes effect when it lands on the default branch. It is
parsed, never sourced.

## Developing

- Tests: `bash git-grove.test.sh`. It builds throwaway groves under a temp directory with an
  isolated git config and exercises every verb. It is the only CI.
- The installed copy in `~/.local/bin` is a copy, not a link: re-run `./install.sh` after editing.
- This repo is itself a grove. `main/` holds the released script; work happens in trees.

## Prior art

[brightdigit/git-trees](https://github.com/brightdigit/git-trees) uses the same `.bare` + pointer
layout and a `--print-path` wrapper. Branch parentage in local git metadata is how git-spice,
Graphite, and git-branchless do it too.

## Merging and finishing

```bash
cd roots/feature-x/auth
git grove merge parent                   # show the diff, confirm, merge feature/x-auth into feature/x
git grove merge siblings                 # pull every sibling root into this one
cd ../../../feature-x
git grove merge all                      # pull every root of feature/x into it
git grove finish feature/x-auth          # preview: merge auth in, then remove it
git grove finish feature/x-auth --apply  # do it (worktree, folder, branch, groveParent all go)
grove finish . --apply                  # same, from inside the root: merges, cds to the parent, removes it
git grove merge --abort                  # mid-conflict: undo
git grove merge --continue               # mid-conflict: after resolving and `git add`
git grove destroy ../old-grove           # delete a whole grove; type its name to confirm
```

`merge` never removes anything; `finish` is merge plus the tidy-up. Both refuse a target with
uncommitted changes and stop at the first conflict, leaving git's normal conflict state for you to
resolve. Pass `-y` to skip the confirmation (scripts, Claude).

## One color per tree

Every tree gets a color — a stable hash of its name, so `feature/x` is the same shade in every grove and
on every machine — and its roots share it. `git grove paint` prints the escape sequences that set the
terminal background (and the tab, in Windows Terminal) to that color, or reset them when you leave the
grove. Wire it into your prompt so it runs after every `cd`:

```bash
# bash: sourcing completions/git-grove.bash already does this
PROMPT_COMMAND="git grove paint${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

```powershell
# PowerShell $PROFILE
function prompt {
  Write-Host -NoNewline (& git grove paint)
  "PS $($executionContext.SessionState.Path.CurrentLocation)> "
}
```

- Pin a tree's color: `git grove color feature/x --set '#1f2a44'`.
- Your own palette: `git config grove.palette "#1f2a44 #1e3a2a ..."` (dark tints work best).
- Off: `git config --global grove.paint false`, or set `NO_COLOR`.
- Supported: Windows Terminal (background + tab), Git Bash's mintty window, VS Code's terminal. Not
  supported by JetBrains' terminal (open request IJPL-218303); `paint` detects it and prints nothing.
- If leaving a grove does not restore your theme's background, pin it:
  `git config --global grove.paintReset "#0c0c0c"` (Windows Terminal's default dark background).
- A tab started with `wt --tabColor` ignores the tab sequence.
