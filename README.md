# git-ent

A thin bash wrapper around git that gives every branch its own folder, so
switching branches is `cd`, not `checkout`. Side experiments become **twigs**,
branches nested under the branch they grew from.

```
my-app/
  .bare/                          the git database (a bare repo)
  .git                            one line: "gitdir: ./.bare"
  main/
    core/                         main checked out here
  branches/
    feature/
      x/
        core/                     branch feature/x
        twigs/
          db/
            core/                 twig feature/x-db (parent: feature/x)
```

Every branch folder is a **container** holding `core/` (the checkout) and
`twigs/` (its children). Nothing is checked out inside another checkout, so build
tools never wander into a neighbour.

**Requirements:** bash 3.2+ and git 2.20+, which is already what you have with
macOS, any Linux, and Git for Windows (Git Bash). Tested on Apple's bash 3.2
with git 2.39, and on bash 5.3 with git 2.55. Recognizing squash merges by
content during `sync` needs git 2.38+; older git skips just that check.

## Install

```bash
git clone https://github.com/kylemccullough1/ent.git && cd ent
./install.sh
```

The installer:

- copies git-ent into `~/.local/share/git-ent` and puts a launcher in `~/.local/bin`
- adds one `source` line to `~/.zshrc` or `~/.bashrc` (whichever shell you use),
  once; re-running it never adds a second copy, and a line you comment out stays
  commented out. Set `ENT_NO_RC=1` to skip this.

Open a new terminal and you have the `ent` command (which `cd`s into the folders
it creates or finds), tab completion, and the prompt helper. `git ent ...` works
even without the `source` line. Re-run `./install.sh` after pulling updates.

To remove it: `~/.local/share/git-ent/uninstall.sh` (or `./uninstall.sh` from the
repo). It deletes what the installer added, including the `source` line and its
comment, and leaves your ents alone.

## Use

```bash
ent init my-app                    # new repo: my-app/.bare, my-app/main/core
ent init git@host:org/repo.git     # from a remote
ent init ../old-clone new-ent      # from an existing clone (left untouched)

ent branch feature/x               # branches/feature/x/core, cut from where you stand
ent twig db                        # inside feature/x: twig feature/x-db
ent up / ent down db / ent go feature/x
ent list                           # the whole tree
ent branch merge                   # merge into the parent, then remove the branch
ent sync                           # update main from origin, merge main into your work
ent rm feature/x -r                # remove a branch and its twigs (asks first)
ent help [verb]                    # every verb and flag
```

## How branches relate

- A **branch** always has **main** as its parent. `ent branch <name>` cuts it from
  the branch or twig you are standing in (main when you are at the ent root), or
  from `--from <base>`. The name is used exactly as typed.
- A **twig**'s parent is the branch or twig it was made from, recorded in
  `.bare/config` as `branch.<twig>.entParent`. That record is local and never pushed.
- `ent branch merge` merges into the parent: a branch into main, a twig into its
  parent. The branch's own twigs are merged into it first, then it is removed.
- `ent sync`:
  1. With an `origin`: fetch, fast-forward main, then for each branch this pull
     merged (merge commit, squash, or rebase), ask whether to delete it.
     Branches that were already in main before the pull, such as brand-new ones,
     are never offered.
  2. Merge main into every branch and twig, or `ent sync <branch>` for one.
     Folders with uncommitted changes are skipped; conflicts are left in place
     and listed.

## Settings: `.entrc` (optional)

Commit a `.entrc` on your repo's default branch to share rules with everyone
who uses ent on it. `.entrc.example` shows the format. Keys:

| Key | Effect |
|---|---|
| `branchPattern` | Regular expression every new branch name must match. Twigs are exempt. |
| `maxDepth` | How deep twigs may nest (default 2). |
| `protect` | Branch names `ent rm` refuses, space-separated. |

For a rule only on your machine, put it in the bare repo's config instead; it is
never pushed:

```bash
git config ent.branchPattern '^(feature|defect)/'
```

Order: `ENT_<KEY>` environment variable, then `ent.<key>` in `.bare/config`, then
`.entrc`. `protect` combines all three.

## Prompt

A container folder such as `branches/feature/x/` is not a git checkout, so a
normal git prompt shows the wrong branch there. After sourcing the completion
file:

- **bash:** if git's `__git_ps1` is loaded, it becomes ent-aware automatically.
- **either shell:** `__ent_ps1 " (%s)"` prints the ent branch for the current
  folder, `ent` at the root, and nothing outside an ent.

```bash
PS1='[\u@\h \W$(__ent_ps1 " (%s)")]\$ '               # bash
setopt PROMPT_SUBST; PROMPT='%~$(__ent_ps1 " (%s)") %# '   # zsh
```

Outside an ent the helper runs no programs at all, so it never slows your prompt.

## How the code is laid out

| File | Job |
|---|---|
| `git-ent` | Finds `lib/`, loads it, and dispatches the verb. |
| `lib/core.sh` | Output (`say`, `note`, `warn`, `die`), `run`, `confirm`, flag parsing. |
| `lib/state.sh` | Reads git's state once (3 git calls) into arrays; all lookups use them. |
| `lib/paths.sh` | Where things live: `ent_root`, `ent_container`, which branch owns a folder. |
| `lib/config.sh` | Settings layers and `.entrc`. |
| `lib/cmd/<verb>.sh` | One verb each, with its `help_<verb>` text. |
| `completions/ent.bash`, `ent.zsh` | The `ent` wrapper, tab completion, prompt helper. |
| `install.sh`, `uninstall.sh` | Copy into `~/.local`, add or remove the rc `source` line. |

Two conventions run through the code:

- **stdout carries only a path** for the `ent` wrapper to `cd` into; every
  message goes to stderr.
- **Lookups set `REPLY`** instead of printing (`parent_of b; echo "$REPLY"`),
  which avoids starting a subshell. On Git Bash for Windows each subshell is a
  full process start.

## Developing

- `bash ent.test.sh` builds throwaway ents in a temp folder and runs every verb.
  Run it under both `/bin/bash` (3.2) and a modern bash before pushing.
- Re-run `./install.sh` after editing to update your installed copy.
