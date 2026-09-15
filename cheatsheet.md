# git-ent cheat sheet

```
git ent init <name | url | path-to-clone> [dir]   build an ent
git ent add <branch>                              create a top-level branch
git ent add twig <name> [--from <parent>]         create a nested twig
git ent rm <branch> [-r] [-f] [--apply]           preview/remove a branch
git ent merge <target|parent|siblings|all> [-y]   merge; --abort / --continue
git ent sync [--pull [--rebase]]                  fetch; optionally fast-forward
git ent list                                      tree of branches and twigs
git ent path <branch> [--win]                     print the core/ path
git ent check [--repair]                          report/fix moved worktrees
git ent destroy <dir> [-f]                        delete a whole ent
git ent help                                      this cheat sheet
```

The shell wrapper `ent` (sourced from completions/ent.bash) calls `git ent` and
`cd`s into the new path for `init`, `add`, and `add twig`.
