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
            core/                 twig twigs/feature/x/db (parent: feature/x)
```

Every branch folder is a **container** holding `core/` (the checkout) and
`twigs/` (its children). Nothing is checked out inside another checkout, so build
tools never wander into a neighbour.

**Requirements:** bash 3.2+ and git 2.20+, which is already what you have with
macOS, any Linux, and Git for Windows (Git Bash). Tested on Apple's bash 3.2
with git 2.39, and on bash 5.3 with git 2.55. Recognizing squash merges by
content during `sync` needs git 2.38+; older git skips just that check, and
`ent init --here` needs git 2.29+ only when it has to keep worktrees the repo
already had.

## Install

```bash
git clone https://github.com/kylemccullough1/ent.git && cd ent
./install.sh
```

The installer:

- copies git-ent into `~/.local/share/git-ent` and puts a launcher in `~/.local/bin`
- adds one `source` line to the startup files of the shells you have, once each:
  `${ZDOTDIR:-~}/.zshrc` for zsh, `~/.bashrc` for bash, and `~/.bash_profile` as
  well when that file doesn't already read `.bashrc` (macOS Terminal and Git Bash
  start bash as a login shell, which reads only `.bash_profile`). It prints every
  file it changed. Re-running never adds a second copy, and a line you comment out
  stays commented out.

The line loads `completions/ent.sh`, which pulls in the zsh or bash version
depending on which shell reads it, so the same line works everywhere.

```bash
./install.sh --rc ~/.config/zsh/my.zsh   # set up this file instead (repeatable)
ENT_RC=~/.config/zsh/my.zsh ./install.sh # same, as an environment variable
./install.sh --no-rc                     # touch no startup file
```

Open a new terminal and you have the `ent` command (which `cd`s into the folders
it creates or finds), tab completion, and the prompt helper. `git ent ...` works
even without the `source` line. Re-run `./install.sh` after pulling updates.

`ent branch merge`, `ent rm` and `ent sync` can delete the folder you are
standing in, and Windows will not delete a folder that any process (your shell,
or the `git.exe` that `git ent` starts) has as its current folder. So the `ent`
command runs those three from the ent root and then brings you back, or into
the parent after a merge. Plain `git ent branch merge` from inside the branch
still merges, but on Windows it leaves an empty folder; `ent rm <branch>` clears
it.

To remove it: `~/.local/share/git-ent/uninstall.sh` (or `./uninstall.sh` from the
repo). It removes what the installer added, including the `source` line in every
file it recorded, and leaves your ents alone.

## Use

```bash
ent init my-app                    # new repo: my-app/.bare, my-app/main/core
ent init git@host:org/repo.git     # from a remote
ent init ../old-clone new-ent      # from an existing clone (left untouched)
ent init --here                    # turn the repo you are in into an ent, in place

ent branch feature/x               # branches/feature/x/core, cut from where you stand
ent branch --remote feature/x      # same name as the remote branch
ent branch feature/x --remote feature/x  # explicit local name, still tracking origin/feature/x
ent track feature/x --remote feature/x   # link an existing local branch to a remote branch
ent twig db                        # inside feature/x: branch twigs/feature/x/db
ent up / ent down db / ent go feature/x
ent list                           # the whole tree
ent status                         # git status of every worktree, full screen
ent log                            # git log of every worktree, full screen
ent branch merge                   # merge into the parent, then remove the branch
ent sync                           # update main from origin, merge main into your work
ent rm feature/x -r                # remove a branch and its twigs (asks first)
ent rm feature/x                   # also clears a half-removed branch (leftover folder, missing branch)
ent help [verb]                    # every verb and flag
```

## Adopting a repo you already have: `ent init --here`

`ent init <path> <dir>` copies from a clone and leaves it alone. `ent init --here`
does the opposite: it converts the repo in place, so the folder keeps its name
and everything in it comes along.

```
before                       after
my-app/                      my-app/
  .git/          (dir)         .bare/         the git database, now bare
  src/                         .git           one line: "gitdir: ./.bare"
  node_modules/  (ignored)     main/
  .env           (ignored)       core/        src/, node_modules/, .env, …
  README.md
```

Ignored files come too. `node_modules` and `.env` exist only on your disk, so a
conversion that re-checked-out the tree would lose them; this one moves the
files it finds instead. Your commits, branches, tags, stash, reflog, hooks,
remotes and upstream tracking are all in `.git`, which is renamed rather than
rebuilt, so they survive untouched.

It asks for a clean tree, a branch checked out, and no submodules. "Clean" here
means no changes to files git already tracks: commit or stash those first.

Untracked files -- files git has never been told about, and that `.gitignore`
does not cover -- do come along, but ent lists them and asks first:

```
'my-app' has 2 untracked file(s):
    notes.txt
    scratch/try.sql
They would move into main/core/ with everything else and stay untracked.
Carry them along? [y/N]
```

Say no and nothing is touched. `-y` answers yes, and `-n` lists them and asks
nothing. Ignored files are never asked about: `.gitignore` already said what
they are.

Run it with `-n` first to see what would move without changing anything.

If you are standing on a branch that is not the repo's default, both get a
folder: the default is checked out fresh at `main/core`, and the branch you were
on keeps your files at `branches/<branch>/core`. Check out the default branch
first if you would rather start with just that one.

If the repo already has other `git worktree`s, ent asks what to do with them:
**move** them into a new `<name>-ent` beside the original, each at
`branches/<branch>/core`; **drop** those worktree folders, keeping their
branches, and convert in place; or **cancel**. `--worktrees move|drop` answers
without asking. Whichever you pick, nothing happens until you answer the final
`Convert ...?` — the folders **drop** would remove are listed there first, so
saying no really does leave everything alone.

**move** cannot keep a worktree that lives *inside* the repo being converted
(`git worktree add ./sub`): the conversion moves the repo's contents, which
would carry that folder off and break its registration. ent refuses and says
so; move it elsewhere first, or choose **drop**.

Nothing is deleted. If a step fails, ent rolls the conversion back by itself and
tells you whether that worked. A kill or a power cut is the one thing no rollback
survives, so before touching anything it writes `.ent-convert-recovery.sh` into
the repo — the undo, already filled in for that folder. It is removed once the
conversion lands.

On Windows, close editors and pause OneDrive first: moving a folder is a rename,
and an open handle blocks it.

## How branches relate

- A **branch** always has **main** as its parent *for merging*: `ent branch
  merge` sends it into main. On disk it is a different story -- branches sit
  beside `main` under the ent root, not inside it, which is how `ent list` draws
  them and what `ent up` and `ent down` follow. `ent branch <name>` cuts it from
  the branch or twig you are standing in (main when you are at the ent root),
  from `--from <base>` (another local branch), or from `--remote <remote-branch>`
  on origin, which sets the upstream. With `--remote` the local name is optional
  and defaults to the remote branch name; otherwise the name is used exactly as
  typed. `ent track [<branch>] --remote <remote-branch>` links an existing local
  branch to a remote branch.
- A **twig** belongs to the branch it was made from. A twig `db` of branch
  `feature/x` is the branch `twigs/feature/x/db`, and its parent is recorded in
  `.bare/config` as `branch.<twig>.entParent`. That record is local, never pushed.
  Twigs go **one level deep**: git stores branches as paths, so a name cannot be
  both a branch and a folder of branches. `twigs/feature/x/db` therefore cannot
  have a twig of its own, and `twigs/` is reserved as a branch name.
- `ent branch merge` merges into the parent: a branch into main, a twig into its
  branch. The branch's own twigs are merged into it first, then it is removed.
- `ent sync`:
  1. With an `origin`: fetch, fast-forward main, then for each branch this pull
     merged (merge commit, squash, or rebase), ask whether to delete it.
     Branches that were already in main before the pull, such as brand-new ones,
     are never offered.
  2. Merge main into every branch and twig, or `ent sync <branch>` for one.
     Folders with uncommitted changes are skipped; conflicts are left in place
     and listed. A branch with an unfinished merge shows as `[MERGING]` in
     `ent list` and as `mainb|MERGING` in the prompt until you finish or abort it.
- A branch can end up with **no folder** — you deleted it by hand, or the branch
  was made with plain git. `ent list` marks it `[no worktree]`, and `ent go`
  refuses it rather than sending your shell somewhere that is not there. Run
  `ent branch <name>` on it to build the folder back: because the branch already
  exists, that adopts it instead of refusing.

## Looking around: `ent status` and `ent log`

Both open a full screen you page through, one worktree at a time. The viewer
restores the terminal (alternate screen, cursor, and mouse-reporting modes) when
you quit:

```
tab / shift-tab   next / previous worktree      j k, arrows   scroll
space / b         page down / up                g G           top / bottom
r                 reload                        q             quit
```

They open on the worktree you are standing in. `ent log -- --stat -n 20` passes
everything after `--` to `git log`. Piped or redirected, both print every
worktree in order instead, so `ent status | grep ...` works.

## Settings: `.entrc` (optional)

Commit a `.entrc` on your repo's default branch to share rules with everyone
who uses ent on it. `.entrc.example` shows the format. Keys:

| Key | Effect |
|---|---|
| `branchPattern` | Regular expression every new branch name must match. Twigs are exempt. |
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
  folder, `ent` at the root, and nothing outside an ent. An unfinished merge or
  rebase shows the way git writes it: `mainb|MERGING`.

```bash
PS1='[\u@\h \W$(__ent_ps1 " (%s)")]\$ '               # bash
setopt PROMPT_SUBST; PROMPT='%~$(__ent_ps1 " (%s)") %# '   # zsh
```

Outside an ent the helper runs no programs at all, so it never slows your prompt.

## How the code is laid out

| File | Job |
|---|---|
| `git-ent` | Finds `lib/`, loads it, and dispatches the verb. |
| `lib/output.sh` | Messages on stderr (`note`, `warn`, `die`), `emit_path`, and `say`, which lists git commands under `-n` only. |
| `lib/args.sh` | Global flags (`-n`, `-v`, `-q`, `-y`, `-h`); each verb parses its own flags in `parse_<verb>_args`. |
| `lib/run.sh` | `run` (skipped under `-n`) and the sparse-checkout guard for new worktrees. |
| `lib/prompt.sh` | `confirm` and `choose`. |
| `lib/log.sh` | Appends messages to `.bare/ent.log`, or `~/.config/ent/global.log` outside an ent. |
| `lib/tree.sh` | `.bare/ent.json`: which branches and twigs ent manages, their parents, and where their folders go. |
| `lib/state.sh` | Reads git's state once (3 git calls) into arrays; all lookups use them. |
| `lib/paths.sh` | Where things live: `ent_root`, `ent_container`, which branch owns a folder. |
| `lib/config.sh` | Settings layers and `.entrc`. |
| `lib/cmd/<verb>.sh` | One verb each, with its `help_<verb>` text. |
| `lib/view.sh` | The full-screen viewer behind `status` and `log`. |
| `completions/ent.sh` | Loaded by your shell; picks ent.zsh or ent.bash. |
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
- A few behaviours genuinely differ between Windows and the Unixes (how a folder
  path is spelled, and what counts as a link), so those tests come in pairs and
  each half runs only where it applies. The other half prints `SKIP`, and the
  last line counts them: `220 checks, 3 skipped, ALL PASS`. A skip is never
  counted as a pass.
- `.github/workflows/test.yml` runs the suite on every push against macOS with
  Apple's `/bin/bash`, which is bash 3.2 and the oldest ent supports; Linux with
  bash 5; and Windows with Git Bash. That is where 3.2 and BSD-tool
  compatibility is actually checked, since most machines only have one of the
  three.
- Re-run `./install.sh` after editing to update your installed copy.
