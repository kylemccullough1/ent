# git grove — cheat sheet

A grove is one repo laid out as a bare database plus one folder per branch. Every mutating
command prints the `$ git ...` it runs, so you always see the git underneath.

## Words

| Word  | Meaning                                       | Where on disk                              |
|-------|-----------------------------------------------|--------------------------------------------|
| grove | one repo in this layout                       | `<dir>/.bare` + `<dir>/.git` + folders     |
| tree  | a branch worktree                             | `<grove>/<branch-with-slashes-dashed>/`    |
| root  | a worktree that records a parent branch       | `<grove>/roots/<parent-dashed>/<name>/`    |

A root is a tree with a parent. The parent is stored in `git config branch.<b>.groveParent`,
local to your machine, never pushed. Nothing is ever nested inside another worktree.

```
personal/
  .bare/                 git database          .git   "gitdir: ./.bare"
  main/                  tree  main
  feature-x/             tree  feature/x
  roots/feature-x/auth/  root  feature/x-auth   (parent feature/x)
  roots/feature-x/db/    root  feature/x-db     (parent feature/x)
  roots/feature-x-auth/jwt/   root feature/x-auth-jwt  (parent feature/x-auth)
```

## Verbs and the git behind them

| Command | Raw git | Notes |
|---|---|---|
| `git grove init <name>` | `git init --bare .bare` · `printf 'gitdir: ./.bare' > .git` · `git worktree add --orphan -b main main` · empty commit | brand-new repo |
| `git grove init <url \| clone> [dir]` | `git remote add origin` · `git fetch origin` · `git remote set-head origin -a` · `git symbolic-ref HEAD refs/heads/<default>` · `git worktree add` | from a clone: also `git fetch <clone> '+refs/heads/*:refs/heads/*'` and its tracking config. The clone is untouched. |
| `git grove add <branch> [base]` | `git worktree prune` then one of: `git worktree add <path> <branch>` · `git worktree add --track -b <branch> <path> origin/<branch>` · `git worktree add --no-track -b <branch> <path> <base>` | base = the branch you are standing in, else main. `branchPattern` applies. |
| `git grove add <name> --from <parent>` | same, plus `git config branch.<parent>-<name>.groveParent <parent>` | a root. `--from .` = current branch. No `branchPattern`. |
| `git grove list [--json]` | `git worktree list --porcelain` · `git for-each-ref` · `git rev-list --left-right --count` · `git status --porcelain` | roots drawn under parents; `(none)` = branch without a worktree; `MERGING` badge |
| `git grove rm <branch> [-r] [-f] [--apply]` | `git worktree remove` · `git config --unset branch.<b>.groveParent` · `git branch -D` | **preview unless `--apply`**. See rules below. |
| `git grove go <branch>` / `up` / `down <name>` | | print a path; the `grove` shell function does the `cd` |
| `git grove path [branch]` | | grove top folder, or a branch's folder |
| `git grove sync [--pull [--rebase]]` | `git fetch --all --prune` · per worktree `git merge --ff-only @{u}` or `git rebase @{u}` | one fetch updates every worktree (shared object store) |

Global options: `-n/--dry-run` (echo, don't run) · `-v/--verbose` (echo reads too) · `-q/--quiet`
· `--print-path` · `-V/--version` · `-h/--help`. Short flags bundle: `rm -rf`.

## `rm` refuses, in order

1. main, anything in `protect`, the folder you are standing in — **no override**
2. a branch that still has roots — `-r` removes them too, deepest first
3. uncommitted changes — `-f` discards
4. commits on neither main, the parent, nor the upstream — `-f` loses them

`-D` is used, not `-d`: rule 4 already proved the commits are safe, and `-d` would re-check against
whichever HEAD you happen to be on.

## Everyday flow

```
git grove add feature/thing            # plant a tree; cd into it (or use the `grove` function)
git grove add spike --from .           # a root for a side experiment; work, commit
git grove up                           # back to the parent
git grove list                         # where everything is
git grove rm feature/thing-spike       # preview; add --apply when it says what you expect
```

## Gotchas

- **Never delete a worktree folder by hand.** Git remembers it and `add` fails. `git grove add`
  and `list` run `git worktree prune` first so a hand-deleted folder heals itself.
- **`feature/x` and `feature/x/y` cannot both be branches** (git stores refs as files). Roots use
  a hyphen: `feature/x-y`.
- **`feature/x` and `feature-x` share the folder `feature-x/`.** Whichever exists first owns it.
- **`add` from inside a worktree forks off *that* branch**, not main. Pass a base if you mean main.
- **The stash is shared across worktrees.** Prefer a WIP commit on the branch.
- **A branch can only be checked out in one worktree at a time.** That is the feature.
- **`.gitgrove` is read from the default branch** (`git show main:.gitgrove`), so an edit takes
  effect once it lands there.
- **Windows:** the `.git` pointer must be one ASCII line. PowerShell's `echo >` writes UTF-16 + BOM
  and breaks it — that is why `init` uses `printf` in bash.

## Merging and finishing (v2)

| Command | Raw git | Notes |
|---|---|---|
| `git grove merge <target>` | in `<target>`'s folder: `git diff --stat target...source` · `git diff target...source` · `git merge --no-edit <source>` | run from the source's worktree. Refuses a dirty or mid-merge target. Asks, or `-y`. |
| `git grove merge parent` | same | (in a root) target = the recorded parent |
| `git grove merge siblings` | same, once per sibling | (in a root) every sibling root → this root; stops at the first conflict |
| `git grove merge all` | same, once per root | every root of this branch → this branch |
| `git grove merge --abort` / `--continue` | `git merge --abort` · `git merge --continue` | from the worktree that is mid-merge |
| `git grove finish <source> [target] --apply` | the merge above, then `git worktree remove` · `git config --unset groveParent` · `git branch -D` | preview unless `--apply`. Target defaults to the parent, else the branch you stand in. Refuses: protected source, standing inside it, roots under it, dirty source (`-f`). |
| `git grove finish --continue` | `git merge --continue`, then the removal | the source is found from `MERGE_HEAD` |
| `git grove destroy <dir>` | `rm -rf <dir>` | type the folder name to confirm (`-y` skips). Refuses dirty worktrees unless `-f`. |

Conflicts: the merge stops with markers in the files and `MERGE_HEAD` set; your prompt shows
`(branch|MERGING)` and `list` shows a `MERGING` badge. Resolve, `git add`, then `--continue` — or
`--abort` to go back to before the merge.
