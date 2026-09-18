# git-ent cheat sheet

```
git ent init <name | url | path-to-clone> [dir]   build an ent
git ent branch <name> [--from <base>]             create a branch
git ent twig <name> [--from <parent>]             create a nested twig
git ent rm <branch/twig> [-r] [-f]                remove a branch (confirms)
git ent branch merge [target] [-y]                merge current branch and finish
git ent sync                                      fetch all; merge main into worktrees
git ent list                                      tree of branches and twigs
git ent path <branch/twig> [--print-path]         print the core/ path
git ent up | down [name] | go <name>              navigate the tree
git ent destroy <dir> [-f]                        delete a whole ent
git ent help                                      this cheat sheet
```

The shell wrapper `ent` (sourced from completions/ent.bash) calls `git ent` and
`cd`s into the new path for `init`, `branch`, `twig`, `go`, `up`, and `down`.
