# git-ent

One bash file that turns a repo into an **ent**: a bare git database plus a
nested container layout, so switching branches is `cd`, not `checkout`. Side
experiments become **twigs** — worktrees that remember which branch they grew
from — and `list` draws the whole thing as a tree.

```
personal/
  .bare/                      the git database
  .git                        one line: "gitdir: ./.bare"
  .entrc                      team settings (committed on the default branch)
  main/
    core/                     worktree for main
    twigs/
      auth/
        core/                 worktree for main-auth
        twigs/
          jwt/
            core/             worktree for main-auth-jwt
  branches/
    feature-x/
      core/                   worktree for feature/x
      twigs/
        db/
          core/               worktree for feature/x-db
```

Every container holds `core/` (the actual worktree) and `twigs/` (its
children). Nothing is ever checked out inside another worktree, so there is no
ignore pattern to maintain and no risk of nested build tools walking into
children.

Requirements: bash 4+, git 2.42+ (for `worktree add --orphan`). Linux, macOS,
Git Bash on Windows.

## Install

```bash
git clone <this repo> && cd <repo>
./install.sh                 # copies git-ent to ~/.local/bin and prints what to source
```

`install.sh` prints one line for `~/.bashrc`: the `source` for tab completion
and the `ent` wrapper. After that `git ent` works everywhere, and `ent add ...`
will also `cd` into the new worktree for you.

## Use

```bash
ent init my-app                    # new repo -> my-app/.bare, my-app/main/core/
ent init git@host:org/repo.git     # from a remote
ent init ../old-clone new-ent      # from an existing clone (left untouched)

ent add feature/x                  # new top-level branch
ent add twig auth                  # from inside feature/x/core: branch feature/x-auth
ent merge parent -y                # merge the current twig into its parent
ent up                             # if supported by your shell wrapper, cd to parent
ent down auth                      # cd into a twig
ent list                           # everything, twigs nested under their parents
ent rm feature/x-auth              # preview what would go
ent rm feature/x-auth --apply      # do it
ent sync --pull                    # fetch everything, fast-forward every clean worktree
```

`git ent help` prints the cheat sheet.

## Concepts, briefly

- **Branch** — a top-level worktree under `<ent>/branches/<slug>/core/`.
- **Twig** — a child worktree that records a parent branch in
  `git config branch.<b>.entParent`. Its folder is
  `<parent-container>/twigs/<name>/core/`. Twig names are stable: a twig of
  `feature/x` called `auth` becomes branch `feature/x-auth`.
- **Parentage is local.** Worktree registrations and `branch.*` config live in
  `.bare/` and are never pushed.

## Team settings: `.entrc`

Commit a `.entrc` on the default branch to share rules. Copy `.entrc.example`
to start. Keys:

| Key | Effect |
|---|---|
| `branchPattern` | ERE that branch names must match. Empty/absent = no rule. Never applied to twigs. |
| `maxDepth` | Maximum nesting depth for twigs (default 2). |
| `protect` | Extra branch names `rm` refuses, space-separated. |

Precedence: `ENT_<KEY>` env → `ent.<key>` in `.bare/config` → `.entrc` →
built-in. `protect` is a union of every layer.

## Developing ent itself

- Tests: `bash ent.test.sh`. It builds throwaway ents under a temp directory.
- Re-run `./install.sh` after editing `git-ent`, `lib/paths.sh`, `cheatsheet.md`,
  or `completions/ent.bash`.
- This repo is itself an ent; the default branch worktree is `main/core/`.
