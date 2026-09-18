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
and the `ent` wrapper. After that `git ent` works everywhere, and `ent branch`
and `ent twig` will also `cd` into the new worktree for you.

## Use

```bash
ent init my-app                    # new repo -> my-app/.bare, my-app/main/core/
ent init git@host:org/repo.git     # from a remote
ent init ../old-clone new-ent      # from an existing clone (left untouched)

ent branch feature/x               # new top-level branch
ent twig auth                      # from inside feature/x/core: branch feature/x-auth
ent branch merge -y                # merge current branch into its parent and finish
ent up                             # cd to parent
ent down auth                      # cd into a twig
ent go feature/x                   # cd to a named branch or twig
ent list                           # everything, twigs nested under their parents
ent rm feature/x-auth              # remove a branch (confirms)
ent rm feature/x-auth -f           # remove without prompting
ent sync                           # fetch all; merge main into worktrees
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

## Shell prompt

Because only `core/` directories are real git worktrees, a plain git prompt
shows the bare repo's default branch (`main`) when you are in an ent container.

If you already use Git Bash / git-prompt.sh, just source the ent completion
file after git-prompt in your `~/.bashrc`:

```bash
source "$SHARE/completions/ent.bash"
```

Ent automatically makes `__git_ps1` container-aware, so `branches/logic/`
will display `(logic)`.

For custom prompts, the underlying helper is also available:

```bash
PS1='[\u@\h \W$(__ent_ps1 ":%s")]\$ '
```

`__ent_ps1` prints the resolved ent branch (or nothing when cwd is outside
an ent), so it composes safely with any existing prompt.

## Developing ent itself

- Tests: `bash ent.test.sh`. It builds throwaway ents under a temp directory.
- Re-run `./install.sh` after editing `git-ent`, `lib/paths.sh`, `cheatsheet.md`,
  or `completions/ent.bash`.
- This repo is itself an ent; the default branch worktree is `main/core/`.
