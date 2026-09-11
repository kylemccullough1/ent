#!/usr/bin/env bash
# Exercises git-grove against throwaway groves under a temp directory, with an isolated git config.
# Run: bash git-grove.test.sh          (exit 0 = all pass)
set -uo pipefail
G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-grove"
T="$(mktemp -d)"
export GIT_CONFIG_GLOBAL="$T/gitconfig" NO_COLOR=1 GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@x
git config --global init.defaultBranch main; git config --global commit.gpgsign false; git config --global core.autocrlf false
export PATH="$(dirname "$G"):$PATH"     # so `git grove` and the shell wrapper resolve to this copy

bad=0; n=0
step() { echo; echo "=== $*"; }
pass() { n=$((n+1)); echo "PASS $*"; }
fail() { n=$((n+1)); bad=1; echo "FAIL $*"; }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (want '$1' got '$2')"; fi; }
# expect_ok <msg> <cmd...>: cmd must exit 0. Its stdout is left in $T/out, stderr in $T/err.
expect_ok()   { local msg="$1"; shift; if "$@" >"$T/out" 2>"$T/err"; then pass "$msg"; else fail "$msg: $(tr '\n' ' ' <"$T/err")"; fi; }
# expect_fail <msg> <stderr-substring> <cmd...>: cmd must fail and say why.
expect_fail() { local msg="$1" want="$2"; shift 2
  if "$@" >"$T/out" 2>"$T/err"; then fail "$msg (expected failure)"
  elif grep -qF -- "$want" "$T/err"; then pass "$msg"
  else fail "$msg (stderr lacks '$want'): $(tr '\n' ' ' <"$T/err")"; fi; }
W()   { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }        # git prints C:/... on Windows
gin() { local d="$1"; shift; (cd "$d" && bash "$G" "$@"); }       # run git-grove from inside <dir>
commit_in() { (cd "$1" && echo "$2" >"$2.txt" && git add -A && git commit -qm "$2"); }

step "fake remote: main + feature/remote-only"
mkdir "$T/src"; (cd "$T/src" && git init -q -b main . && echo hi >README.md && git add . && git commit -qm init \
  && git checkout -q -b feature/remote-only && echo r >r.txt && git add . && git commit -qm remote && git checkout -q main)
SRC="$(W "$T/src")"; URL="file:///${SRC#/}"; [[ "$SRC" == /* ]] && URL="file://$SRC"

step "init from a URL"
expect_ok "init url" gin "$T" init "$URL" g1
G1="$(W "$T/g1")"
check "gitdir: ./.bare" "$(cat "$T/g1/.git")" ".git pointer content"
check "1" "$(wc -l <"$T/g1/.git" | tr -d ' ')" ".git pointer is one line"
[[ -d "$T/g1/.bare" && -d "$T/g1/main" ]] && pass "layout .bare + main/" || fail "layout"
check "refs/remotes/origin/main" "$(git -C "$T/g1" symbolic-ref refs/remotes/origin/HEAD)" "set-head wrote origin/HEAD"
check "main" "$(git -C "$T/g1" symbolic-ref --short HEAD)" "bare HEAD is main"
check "origin/main" "$(git -C "$T/g1/main" rev-parse --abbrev-ref '@{u}')" "main tracks origin/main"
gin "$T" init "$URL" g1 >/dev/null 2>&1 && fail "init into non-empty dir" || pass "init refuses non-empty dir"

step "init from an existing clone (unpushed local branch + tracking survive; clone untouched)"
git clone -q "$T/src" "$T/clone"
(cd "$T/clone" && git checkout -q -b feature/local-only && echo l >l.txt && git add . && git commit -qm local && git checkout -q main)
before="$(git -C "$T/clone" for-each-ref --format='%(refname) %(objectname)' | sort)"
expect_ok "init clone" gin "$T" init "$T/clone" g2
check "1" "$(git -C "$T/g2" show-ref --verify -q refs/heads/feature/local-only && echo 1)" "local-only branch imported"
check "origin/main" "$(git -C "$T/g2/main" rev-parse --abbrev-ref '@{u}')" "tracking replayed for main"
check "$(git -C "$T/clone" remote get-url origin)" "$(git -C "$T/g2" remote get-url origin)" "origin is the clone's origin"
check "$before" "$(git -C "$T/clone" for-each-ref --format='%(refname) %(objectname)' | sort)" "clone unchanged"

step "init a brand-new repo by name"
expect_ok "init name" gin "$T" init fresh
[[ -d "$T/fresh/.bare" && -d "$T/fresh/main" ]] && pass "fresh layout" || fail "fresh layout"
check "1" "$(git -C "$T/fresh/main" rev-list --count HEAD)" "one initial commit"

step "init when origin's default branch is not main"
mkdir "$T/srcdev"; (cd "$T/srcdev" && git init -q -b develop . && echo d >d && git add . && git commit -qm dev)
expect_ok "init develop-default" gin "$T" init "$T/srcdev" gdev
check "develop" "$(git -C "$T/gdev" symbolic-ref --short HEAD)" "bare HEAD re-pointed at develop"
expect_fail "rm develop refused" "protected" gin "$T/gdev" rm develop --apply

step "add: new / remote / local / --no-track"
expect_ok "add new" gin "$T/g1/main" add feature/new
[[ -d "$T/g1/feature-new" ]] && pass "folder feature-new/" || fail "folder feature-new/"
check "feature/new" "$(git -C "$T/g1/feature-new" branch --show-current)" "branch checked out"
git -C "$T/g1/feature-new" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && fail "new branch has upstream" || pass "new branch has no upstream"
expect_ok "add remote-tracking" gin "$T/g1/main" add feature/remote-only
check "origin/feature/remote-only" "$(git -C "$T/g1/feature-remote-only" rev-parse --abbrev-ref '@{u}')" "tracks origin"
git -C "$T/g1" branch feature/local main
expect_ok "add existing local" gin "$T/g1/main" add feature/local
check "feature/local" "$(git -C "$T/g1/feature-local" branch --show-current)" "attached local branch"
expect_ok "add from remote-tracking base" gin "$T/g1/main" add feature/z origin/main
git -C "$T/g1/feature-z" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && fail "--no-track: upstream leaked from base" || pass "--no-track: no upstream from remote base"
commit_in "$T/g1/feature-new" n1
expect_ok "add from inside a tree" gin "$T/g1/feature-new" add feature/child
check "$(git -C "$T/g1" rev-parse feature/new)" "$(git -C "$T/g1" rev-parse feature/child)" "base = the branch you stand in"
expect_fail "reserved name roots" "reserved" gin "$T/g1/main" add roots
expect_fail "dash/slash folder collision" "already exists" gin "$T/g1/main" add feature-new
expect_fail "already has a worktree" "already has a worktree" gin "$T/g1/main" add feature/new
gin "$T/g1/main" add feature/new-dup >/dev/null 2>&1; :

step "roots: --from, --from ., literal name, buckets"
expect_ok "add root" gin "$T/g1/main" add auth --from feature/new
[[ -d "$T/g1/roots/feature-new/auth" ]] && pass "root folder in bucket" || fail "root folder"
check "feature/new-auth" "$(git -C "$T/g1/roots/feature-new/auth" branch --show-current)" "root branch name"
check "feature/new" "$(git -C "$T/g1" config branch.feature/new-auth.groveParent)" "groveParent recorded"
expect_ok "subroot --from ." gin "$T/g1/roots/feature-new/auth" add jwt --from .
[[ -d "$T/g1/roots/feature-new-auth/jwt" ]] && pass "subroot in its own bucket" || fail "subroot bucket"
check "feature/new-auth" "$(git -C "$T/g1" config branch.feature/new-auth-jwt.groveParent)" "subroot parent"
expect_ok "root with literal branch name" gin "$T/g1/main" add feature/lit --from=feature/new
check "feature/lit" "$(git -C "$T/g1/roots/feature-new/feature-lit" branch --show-current)" "literal name kept"
expect_fail "root rejects [base]" "drop the [base]" gin "$T/g1/main" add x --from feature/new main
expect_fail "root of unknown parent" "does not exist" gin "$T/g1/main" add x --from feature/nope

step "list"
git -C "$T/g1" branch orphan-branch main
git -C "$T/g1" branch behind main; git -C "$T/g1" branch -u origin/feature/remote-only behind
expect_ok "list" gin "$T/g1/main" list
grep -qE '^[|`]-- feature/new-auth +roots/feature-new/auth/' "$T/out" && pass "root drawn under parent with its own path" || fail "root row: $(grep new-auth "$T/out")"
grep -qE '^[| ]   [|`]-- feature/new-auth-jwt +roots/feature-new-auth/jwt/' "$T/out" && pass "subroot drawn at depth 2" || fail "subroot row: $(grep jwt "$T/out")"
grep -qE '^[|`]-- feature/lit +roots/feature-new/feature-lit/' "$T/out" && pass "literal-name root drawn" || fail "lit row: $(grep lit "$T/out")"
grep -qE '^orphan-branch +\(none\)' "$T/out" && pass "(none) for branch without worktree" || fail "(none) row"
grep -qE '^behind +\(none\) +origin/feature/remote-only v1' "$T/out" && pass "ahead/behind on a (none) branch" || fail "behind row: $(grep '^behind' "$T/out")"
expect_ok "list --json" gin "$T/g1" list --json
grep -q '"branch": "feature/new-auth", "parent": "feature/new"' "$T/out" && pass "json parent" || fail "json parent"
grep -q '"branch": "behind", "parent": null, "path": null, "upstream": "origin/feature/remote-only", "ahead": 0, "behind": 1' "$T/out" && pass "json behind" || fail "json behind"
expect_ok "list from grove root" gin "$T/g1" list

step "go / up / down / path"
check "$G1/feature-new" "$(gin "$T/g1/main" go feature/new)" "go"
check "$G1/feature-new" "$(gin "$T/g1/roots/feature-new/auth" up)" "up from a root"
check "$G1/roots/feature-new/auth" "$(gin "$T/g1/roots/feature-new-auth/jwt" up)" "up from depth 3"
check "$G1/roots/feature-new/auth" "$(gin "$T/g1/feature-new" down auth)" "down by name"
check "$G1/roots/feature-new-auth/jwt" "$(gin "$T/g1/roots/feature-new/auth" down jwt)" "down at depth 2"
check "$G1" "$(gin "$T/g1/feature-new" path)" "path = grove root"
check "$G1/roots/feature-new/auth" "$(gin "$T/g1" path feature/new-auth)" "path <branch>"
expect_fail "go unknown" "no branch" gin "$T/g1" go nonexistent
check "" "$(cat "$T/out")" "go failure prints nothing on stdout"
expect_fail "up from a tree" "has no parent" gin "$T/g1/feature-new" up
git -C "$T/g1" config branch.orphan-branch.groveParent behind
gin "$T/g1" add kid --from orphan-branch >/dev/null 2>&1
expect_fail "up when parent has no worktree" "has no worktree" gin "$T/g1/roots/orphan-branch/kid" up

step "shell wrapper does not cd on failure"
out="$(cd "$T/g1/main" && source "$(dirname "$G")/completions/git-grove.bash" && grove go nonexistent 2>/dev/null; pwd -W 2>/dev/null || pwd -P)"
check "$G1/main" "$out" "wrapper stayed put"
out="$(cd "$T/g1/main" && source "$(dirname "$G")/completions/git-grove.bash" && grove go feature/new 2>/dev/null && { pwd -W 2>/dev/null || pwd -P; })"
check "$G1/feature-new" "$out" "wrapper cd on success"

step "rm: preview, rules 1-4, tidy"
expect_fail "rule 2: has roots" "Use -r" gin "$T/g1/main" rm feature/new-auth --apply
expect_ok "preview with -r" gin "$T/g1/main" rm -r feature/new-auth
git -C "$T/g1" show-ref --verify -q refs/heads/feature/new-auth-jwt && pass "preview changed nothing" || fail "preview deleted"
commit_in "$T/g1/roots/feature-new-auth/jwt" j1
expect_fail "rule 4: unique commits" "commit(s) not on" gin "$T/g1/main" rm feature/new-auth-jwt --apply
(cd "$T/g1/roots/feature-new/auth" && git merge -q feature/new-auth-jwt)
expect_ok "rule 4 passes when merged only into parent" gin "$T/g1/main" rm feature/new-auth-jwt --apply
[[ ! -d "$T/g1/roots/feature-new-auth" ]] && pass "empty bucket removed" || fail "bucket left"
git -C "$T/g1" show-ref --verify -q refs/heads/feature/new-auth-jwt && fail "branch left" || pass "branch deleted with -D"
git -C "$T/g1" config --get branch.feature/new-auth-jwt.groveParent >/dev/null 2>&1 && fail "groveParent left" || pass "groveParent gone"
expect_fail "rule 4 again for auth (has jwt's commit)" "commit(s) not on" gin "$T/g1/main" rm feature/new-auth --apply
expect_ok "rm literal root" gin "$T/g1/main" rm feature/lit --apply
(cd "$T/g1/feature-new" && git merge -q feature/new-auth)
expect_ok "rm auth after merge into parent" gin "$T/g1/main" rm feature/new-auth --apply
[[ ! -d "$T/g1/roots/feature-new" ]] && pass "bucket removed" || fail "bucket feature-new left"
(cd "$T/g1/feature-new" && git push -q -u origin feature/new)
expect_fail "rule 2 for the tree: child feature/child? no - child is a tree; so rule 4" "commit(s) not on" gin "$T/g1/main" rm feature/child --apply
expect_ok "rule 4 passes for pushed-but-unmerged" gin "$T/g1/main" rm feature/new --apply
[[ ! -d "$T/g1/feature-new" ]] && pass "tree folder removed" || fail "tree folder left"
expect_ok "add dirty" gin "$T/g1/main" add feature/dirty
echo x >"$T/g1/feature-dirty/x.txt"
expect_fail "rule 3: dirty" "uncommitted" gin "$T/g1/main" rm feature/dirty --apply
expect_ok "rule 3 with -f" gin "$T/g1/main" rm -f feature/dirty --apply
expect_fail "rule 1: standing inside" "standing inside" gin "$T/g1/feature-local" rm feature/local --apply
expect_fail "rule 1: main" "protected" gin "$T/g1/feature-local" rm main --apply
expect_ok "rm by path" gin "$T/g1/main" rm "$T/g1/feature-local" --apply
[[ ! -d "$T/g1/feature-local" ]] && pass "rm by path removed folder" || fail "rm by path"
expect_fail "rm a non-worktree dir" "not a worktree" gin "$T/g1/main" rm "$T/src" --apply
expect_ok "rm branch without worktree" gin "$T/g1/main" rm orphan-branch -r --apply
git -C "$T/g1" show-ref --verify -q refs/heads/orphan-branch && fail "orphan-branch left" || pass "orphan-branch deleted"
expect_ok "rm -rf bundled + child unique commit discarded" gin "$T/g1/main" rm -rf feature/child --apply

step "config: .gitgrove on the default branch, git config, env, protect union"
printf 'branchPattern = ^(contributor/)?(feature|defect)/[A-Za-z0-9._-]+$\nprotect = integration\n' >"$T/g1/main/.gitgrove"
(cd "$T/g1/main" && git add .gitgrove && git commit -qm gitgrove)
expect_fail "pattern: hotfix/x refused from a worktree" "branchPattern" gin "$T/g1/feature-z" add hotfix/x
expect_fail "pattern: refused from grove root" "branchPattern" gin "$T/g1" add hotfix/x
expect_ok "pattern: feature/ok accepted" gin "$T/g1/main" add feature/ok
expect_ok "pattern not applied to roots" gin "$T/g1/main" add spike --from feature/ok
git -C "$T/g1" branch integration main
expect_fail "protect from .gitgrove" "protected" gin "$T/g1/main" rm integration --apply
printf 'branchPattern = ^nothing$\n' >"$T/g1/feature-z/.gitgrove"
expect_ok "uncommitted .gitgrove on a feature branch is ignored" gin "$T/g1/feature-z" add feature/still-ok
rm "$T/g1/feature-z/.gitgrove"
git -C "$T/g1" config grove.branchPattern ""
expect_ok "local git config opts out of the team pattern" gin "$T/g1/main" add hotfix/y
git -C "$T/g1" config --unset grove.branchPattern
expect_fail "env GROVE_BRANCHPATTERN wins" "branchPattern" env GROVE_BRANCHPATTERN='^only/' bash -c "cd '$T/g1/main' && bash '$G' add feature/nope"
git -C "$T/g1" branch extra main
expect_fail "env GROVE_PROTECT unions" "protected" env GROVE_PROTECT=extra bash -c "cd '$T/g1/main' && bash '$G' rm extra --apply"
expect_ok "without env, extra is removable" gin "$T/g1/main" rm extra --apply

step "dry-run, --print-path, auto-prune"
expect_ok "dry-run add" gin "$T/g1/main" add feature/dry -n
git -C "$T/g1" show-ref --verify -q refs/heads/feature/dry && fail "dry-run created a branch" || pass "dry-run created nothing"
grep -q '^\$ git -C .* worktree add --no-track -b feature/dry' "$T/err" && pass "dry-run still echoes the git line" || fail "dry-run echo: $(cat "$T/err")"
expect_ok "print-path" gin "$T/g1/main" add feature/pp --print-path
check "$G1/feature-pp" "$(cat "$T/out")" "--print-path: stdout is the path alone"
rm -rf "$T/g1/feature-pp"
expect_ok "add after a hand-deleted folder" gin "$T/g1/main" add feature/pp
grep -q '^\$ git -C .* worktree prune' "$T/err" && pass "prune echoed before add" || fail "prune echo"
check "feature/pp" "$(git -C "$T/g1/feature-pp" branch --show-current)" "re-attached after prune"

step "sync"
expect_ok "sync" gin "$T/g1/main" sync
grep -q 'fetch --all --prune' "$T/err" && pass "sync fetches" || fail "sync fetch echo"
(cd "$T/src" && git checkout -q feature/remote-only && echo more >>r.txt && git commit -qam more && git checkout -q main \
  && echo more >>README.md && git commit -qam more)      # main also advances; the grove's main has its own commit -> diverged
echo dirty >"$T/g1/feature-pp/d.txt"
expect_ok "sync --pull" gin "$T/g1/main" sync --pull
check "$(git -C "$T/src" rev-parse feature/remote-only)" "$(git -C "$T/g1" rev-parse feature/remote-only)" "clean tracking worktree fast-forwarded"
grep -q 'skip main: diverged' "$T/err" && pass "diverged worktree skipped under --ff-only" || fail "diverged skip: $(grep skip "$T/err")"
grep -q 'skip feature/pp: no upstream' "$T/err" && pass "no-upstream worktree skipped" || fail "skip message: $(grep skip "$T/err")"

step "merge: diff, confirm, dirty target, parent / all / siblings"
expect_ok "init g3" gin "$T" init g3
expect_ok "tree a" gin "$T/g3/main" add feature/a
commit_in "$T/g3/feature-a" a1
expect_ok "root r1" gin "$T/g3/feature-a" add r1 --from .
expect_ok "root r2" gin "$T/g3/feature-a" add r2 --from .
commit_in "$T/g3/roots/feature-a/r1" r1c
commit_in "$T/g3/roots/feature-a/r2" r2c
expect_fail "merge asks for -y without a terminal" "pass -y" gin "$T/g3/roots/feature-a/r1" merge parent </dev/null
git -C "$T/g3" merge-base --is-ancestor feature/a-r1 feature/a && fail "merged without confirmation" || pass "nothing merged without confirmation"
expect_ok "merge parent -y" gin "$T/g3/roots/feature-a/r1" merge parent -y
grep -q 'diff --stat feature/a...feature/a-r1' "$T/err" && pass "diff shown before merging" || fail "diff echo: $(grep diff "$T/err")"
git -C "$T/g3" merge-base --is-ancestor feature/a-r1 feature/a && pass "r1 merged into parent" || fail "r1 not merged"
expect_ok "merge parent again" gin "$T/g3/roots/feature-a/r1" merge parent -y
grep -q 'already contains' "$T/err" && pass "up-to-date merge is a no-op" || fail "no-op message"
echo dirty >"$T/g3/feature-a/dirty.txt"
expect_fail "dirty target refused" "uncommitted changes" gin "$T/g3/roots/feature-a/r2" merge parent -y
rm "$T/g3/feature-a/dirty.txt"
expect_ok "merge all (from the parent)" gin "$T/g3/feature-a" merge all -y
git -C "$T/g3" merge-base --is-ancestor feature/a-r2 feature/a && pass "r2 merged by 'all'" || fail "r2 not merged"
expect_ok "merge siblings (from r1)" gin "$T/g3/roots/feature-a/r1" merge siblings -y
git -C "$T/g3" merge-base --is-ancestor feature/a-r2 feature/a-r1 && pass "r2 merged into r1 by 'siblings'" || fail "siblings"
expect_fail "merge unknown target" "no branch" gin "$T/g3/roots/feature-a/r1" merge feature/zzz -y
expect_fail "merge from the grove root" "inside a worktree" gin "$T/g3" merge feature/a -y
expect_fail "merge parent from a tree" "has no parent" gin "$T/g3/feature-a" merge parent -y
expect_fail "merge into a branch without a worktree" "has no worktree" bash -c "git -C '$T/g3' branch nowt main && cd '$T/g3/feature-a' && bash '$G' merge nowt -y"

step "merge: conflicts, MERGING badge, --abort, --continue"
expect_ok "tree b" gin "$T/g3/main" add feature/b
(cd "$T/g3/feature-b" && echo one >c.txt && git add c.txt && git commit -qm b1)
expect_ok "tree c" gin "$T/g3/main" add feature/c
(cd "$T/g3/feature-c" && echo two >c.txt && git add c.txt && git commit -qm c1)
expect_fail "conflict reported" "conflicts merging" gin "$T/g3/feature-c" merge feature/b -y
git -C "$T/g3/feature-b" rev-parse -q --verify MERGE_HEAD >/dev/null && pass "MERGE_HEAD left in the target" || fail "no MERGE_HEAD"
grep -q 'c.txt' "$T/err" && pass "conflicted file named" || fail "conflicted file list"
expect_ok "list during merge" gin "$T/g3" list
grep -qE '^feature/b .*MERGING' "$T/out" && pass "MERGING badge" || fail "badge: $(grep '^feature/b' "$T/out")"
expect_fail "second merge refused mid-merge" "already in the middle" gin "$T/g3/feature-c" merge feature/b -y
expect_fail "abort from the wrong worktree" "no merge in progress" gin "$T/g3/feature-c" merge --abort
expect_ok "abort" gin "$T/g3/feature-b" merge --abort
git -C "$T/g3/feature-b" rev-parse -q --verify MERGE_HEAD >/dev/null && fail "MERGE_HEAD after abort" || pass "abort cleared the merge"
check "one" "$(cat "$T/g3/feature-b/c.txt")" "abort restored the file"
expect_fail "conflict again" "conflicts" gin "$T/g3/feature-c" merge feature/b -y
(cd "$T/g3/feature-b" && echo resolved >c.txt && git add c.txt)
expect_ok "continue" gin "$T/g3/feature-b" merge --continue
git -C "$T/g3/feature-b" rev-parse -q --verify MERGE_HEAD >/dev/null && fail "MERGE_HEAD after continue" || pass "continue completed the merge"
check "2" "$(git -C "$T/g3/feature-b" log -1 --format=%P | wc -w | tr -d ' ')" "merge commit has two parents"
expect_fail "continue with nothing in progress" "no merge in progress" gin "$T/g3/feature-b" merge --continue

step "finish"
expect_ok "root fin" gin "$T/g3/feature-a" add fin --from .
commit_in "$T/g3/roots/feature-a/fin" f1
FIN_SHA="$(git -C "$T/g3" rev-parse feature/a-fin)"
expect_fail "finish from inside the source" "standing inside" gin "$T/g3/roots/feature-a/fin" finish feature/a-fin -y --apply
expect_ok "finish preview" gin "$T/g3/feature-a" finish feature/a-fin
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-fin && pass "preview changed nothing" || fail "preview removed the branch"
grep -q 'diff --stat' "$T/err" && pass "preview shows the diff stat" || fail "preview diff"
expect_ok "finish --apply -y (target defaults to parent)" gin "$T/g3/feature-a" finish feature/a-fin -y --apply
git -C "$T/g3" merge-base --is-ancestor "$FIN_SHA" feature/a && pass "fin merged into parent" || fail "fin not merged"
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-fin && fail "branch left" || pass "source branch deleted"
[[ ! -d "$T/g3/roots/feature-a/fin" ]] && pass "source folder removed" || fail "folder left"
git -C "$T/g3" config --get branch.feature/a-fin.groveParent >/dev/null 2>&1 && fail "groveParent left" || pass "groveParent gone"
expect_fail "finish a protected branch" "protected" gin "$T/g3/feature-a" finish main -y --apply
expect_ok "root p" gin "$T/g3/feature-a" add p --from .
expect_ok "root q under p" gin "$T/g3/roots/feature-a/p" add q --from .
expect_fail "finish a source that still has roots" "still has root" gin "$T/g3/feature-a" finish feature/a-p -y --apply
echo dirty >"$T/g3/roots/feature-a-p/q/d.txt"
expect_fail "finish a dirty source" "uncommitted changes" gin "$T/g3/feature-a" finish feature/a-p-q -y --apply
expect_ok "finish a dirty source with -f" gin "$T/g3/feature-a" finish feature/a-p-q -y -f --apply
[[ ! -d "$T/g3/roots/feature-a-p" ]] && pass "bucket of the finished root removed" || fail "bucket left"
expect_ok "root cf (will conflict)" gin "$T/g3/feature-a" add cf --from .
(cd "$T/g3/roots/feature-a/cf" && echo x >c2.txt && git add c2.txt && git commit -qm cfx)
(cd "$T/g3/feature-a" && echo y >c2.txt && git add c2.txt && git commit -qm ay)
expect_fail "finish hits a conflict" "conflicts merging" gin "$T/g3/feature-a" finish feature/a-cf -y --apply
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-cf && pass "source kept while conflicted" || fail "source removed despite conflict"
(cd "$T/g3/feature-a" && echo z >c2.txt && git add c2.txt)
expect_ok "finish --continue finds the source from MERGE_HEAD" gin "$T/g3/feature-a" finish --continue
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-cf && fail "source left after --continue" || pass "source removed after --continue"
[[ ! -d "$T/g3/roots/feature-a/cf" ]] && pass "source folder removed after --continue" || fail "folder left"
expect_ok "finish a tree into the branch you stand in" gin "$T/g3/main" finish feature/b -y --apply
git -C "$T/g3" show-ref --verify -q refs/heads/feature/b && fail "feature/b left" || pass "tree finished into main"
git -C "$T/g3" merge-base --is-ancestor "$(git -C "$T/g3" rev-parse main)" main && pass "main advanced" || fail "main"

step "finish all"
expect_ok "clear r1 (has a sibling-merge commit only it knows)" gin "$T/g3/feature-a" rm feature/a-r1 -f --apply
expect_ok "clear r2" gin "$T/g3/feature-a" rm feature/a-r2 --apply
expect_ok "clear p (left from the finish step)" gin "$T/g3/feature-a" rm feature/a-p --apply
expect_ok "root r1" gin "$T/g3/feature-a" add r1 --from .
expect_ok "sub-root s1 under r1" gin "$T/g3/roots/feature-a/r1" add s1 --from .
expect_ok "root r2" gin "$T/g3/feature-a" add r2 --from .
commit_in "$T/g3/roots/feature-a-r1/s1" s1c; commit_in "$T/g3/roots/feature-a/r1" r1c2; commit_in "$T/g3/roots/feature-a/r2" r2c2
S1="$(git -C "$T/g3" rev-parse feature/a-r1-s1)"; R2="$(git -C "$T/g3" rev-parse feature/a-r2)"
expect_ok "finish all preview" gin "$T/g3/feature-a" finish all
check "feature/a-r1-s1 -> feature/a-r1
feature/a-r1 -> feature/a
feature/a-r2 -> feature/a" "$(sed 's/^  //' "$T/out")" "preview lists deepest first"
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-r1-s1 && pass "preview changed nothing" || fail "preview removed"
echo dirty >"$T/g3/roots/feature-a/r2/d.txt"
expect_fail "finish all refuses a dirty root" "uncommitted changes" gin "$T/g3/feature-a" finish all -y --apply
rm "$T/g3/roots/feature-a/r2/d.txt"
expect_fail "finish all from a branch without roots is fine, from the grove root is not" "inside the worktree" gin "$T/g3" finish all -y --apply
expect_ok "finish all --apply -y" gin "$T/g3/feature-a" finish all -y --apply
git -C "$T/g3" merge-base --is-ancestor "$S1" feature/a && pass "sub-root's work reached the top" || fail "s1 not on feature/a"
git -C "$T/g3" merge-base --is-ancestor "$R2" feature/a && pass "r2 merged" || fail "r2 not merged"
check "" "$(git -C "$T/g3" for-each-ref --format='%(refname:short)' 'refs/heads/feature/a-*')" "every root branch removed"
[[ ! -d "$T/g3/roots" ]] && pass "roots/ folder gone" || fail "roots/ left: $(ls "$T/g3/roots")"
expect_ok "finish all with nothing to do" gin "$T/g3/feature-a" finish all -y --apply
grep -q 'has no roots' "$T/err" && pass "no-roots message" || fail "no-roots"
expect_ok "root ok1" gin "$T/g3/feature-a" add ok1 --from .; commit_in "$T/g3/roots/feature-a/ok1" ok1c
expect_ok "root zbad (sorts after ok1)" gin "$T/g3/feature-a" add zbad --from .
(cd "$T/g3/roots/feature-a/zbad" && echo b >k.txt && git add k.txt && git commit -qm bad)
(cd "$T/g3/feature-a" && echo a >k.txt && git add k.txt && git commit -qm a)
expect_fail "finish all stops at the first conflict" "conflicts merging" gin "$T/g3/feature-a" finish all -y --apply
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-zbad && pass "conflicting root kept" || fail "zbad removed"
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-ok1 && fail "ok1 should have been finished first" || pass "roots before the conflict were finished"
expect_ok "abort the stuck merge" gin "$T/g3/feature-a" finish --abort
expect_ok "rm the conflicting root" gin "$T/g3/feature-a" rm feature/a-zbad -f --apply

step "finish . (from inside the source) and list swatch"
expect_ok "root dot" gin "$T/g3/feature-a" add dot --from .
commit_in "$T/g3/roots/feature-a/dot" dotc
DOT="$(git -C "$T/g3" rev-parse feature/a-dot)"
expect_ok "finish . preview" gin "$T/g3/roots/feature-a/dot" finish .
git -C "$T/g3" merge-base --is-ancestor "$DOT" feature/a && fail "preview merged" || pass "finish . preview merges nothing"
expect_ok "finish . --apply -y (no wrapper)" gin "$T/g3/roots/feature-a/dot" finish . -y --apply
git -C "$T/g3" merge-base --is-ancestor "$DOT" feature/a && pass "merged into parent" || fail "not merged"
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-dot && pass "source kept (we are standing in it)" || fail "source removed while inside"
grep -q 'git grove rm feature/a-dot --apply' "$T/err" && pass "tells you the rm to run" || fail "rm hint: $(cat "$T/err")"
expect_ok "finish . --print-path prints the target folder" gin "$T/g3/roots/feature-a/dot" finish . -y --apply --print-path
check "$(W "$T/g3/feature-a")" "$(cat "$T/out")" "--print-path is the target path alone"
expect_ok "rm dot afterwards" gin "$T/g3/feature-a" rm feature/a-dot --apply
expect_ok "root dot2" gin "$T/g3/feature-a" add dot2 --from .
commit_in "$T/g3/roots/feature-a/dot2" dot2c
out="$(cd "$T/g3/roots/feature-a/dot2" && source "$(dirname "$G")/completions/git-grove.bash" && grove finish . -y --apply >/dev/null 2>&1; pwd -W 2>/dev/null || pwd -P)"
check "$(W "$T/g3/feature-a")" "$out" "wrapper: finish . lands you in the parent"
git -C "$T/g3" show-ref --verify -q refs/heads/feature/a-dot2 && fail "wrapper left the source branch" || pass "wrapper removed the source"
[[ ! -d "$T/g3/roots/feature-a/dot2" ]] && pass "wrapper removed the source folder" || fail "folder left"
expect_ok "list --json has color" gin "$T/g3" list --json
grep -q '"branch": "feature/a", .*"color": "#[0-9a-f]\{6\}"' "$T/out" && pass "json color field" || fail "json color: $(grep '"feature/a"' "$T/out")"
out="$(source "$G"; GROVE="$T/g3"; O_RST=x; swatch main | od -An -c | tr -d ' \n')"
[[ "$out" == *'033[48;2;'* && "$out" == *'033[0m'* ]] && pass "swatch emits a 24-bit background block" || fail "swatch: $out"
out="$(source "$G"; GROVE="$T/g3"; O_RST=; swatch main)"
check "" "$out" "no swatch without a color terminal"

step "destroy"
expect_fail "destroy from inside" "standing inside" gin "$T/g3" destroy "$T/g3" -y
echo dirty >"$T/g3/feature-a/dd.txt"
expect_fail "destroy refuses dirty worktrees" "uncommitted changes" gin "$T" destroy g3 -y
expect_fail "destroy needs a terminal to type the name" "no terminal" gin "$T" destroy g3 -f </dev/null
[[ -d "$T/g3" ]] && pass "still there after refusals" || fail "deleted despite refusal"
expect_ok "destroy -f -y" gin "$T" destroy g3 -f -y
[[ ! -d "$T/g3" ]] && pass "grove folder deleted" || fail "grove folder left"
expect_fail "destroy a non-grove" "not a grove" gin "$T" destroy src -y

step "destroy with outside worktrees"
expect_ok "init g4" gin "$T" init g4
git -C "$T/g4" branch outsider main
git -C "$T/g4" worktree add "$T/g4-outside" outsider
[[ -d "$T/g4-outside" ]] && pass "outside worktree exists" || fail "outside worktree missing"
expect_ok "destroy g4 with outside worktree" gin "$T" destroy g4 -f -y
[[ ! -d "$T/g4" ]] && pass "grove folder deleted" || fail "grove folder left"
[[ ! -d "$T/g4-outside" ]] && pass "outside worktree removed" || fail "outside worktree left: $(ls "$T/g4-outside" 2>/dev/null)"

step "color / paint"
c1="$(gin "$T/g1/main" color feature/ok)"
[[ "$c1" =~ ^#[0-9a-f]{6}$ ]] && pass "color is #rrggbb ($c1)" || fail "color format: $c1"
check "$c1" "$(gin "$T/g1/main" color feature/ok)" "color is stable"
check "$c1" "$(gin "$T/g1/main" color feature/ok-spike)" "root inherits its tree's color"
check "$c1" "$(gin "$T/g1/roots/feature-ok/spike" color)" "color with no argument = the branch you stand in"
expect_fail "color of unknown branch" "no branch" gin "$T/g1/main" color feature/nope
expect_fail "--set rejects a bad color" "#rrggbb" gin "$T/g1/main" color feature/ok --set red
expect_ok "--set pins the tree color" gin "$T/g1/main" color feature/ok --set '#123456'
check "#123456" "$(gin "$T/g1/roots/feature-ok/spike" color)" "pinned color reaches the roots"
check "#123456" "$(git -C "$T/g1" config branch.feature/ok.groveColor)" "pin stored on the tree, not the root"
expect_ok "custom palette" bash -c "git -C '$T/g1' config grove.palette '#010101 #020202' && cd '$T/g1/main' && bash '$G' color main"
[[ "$(cat "$T/out")" == "#010101" || "$(cat "$T/out")" == "#020202" ]] && pass "palette override used" || fail "palette: $(cat "$T/out")"
git -C "$T/g1" config --unset grove.palette
paint() { (cd "$1" && shift && env -u NO_COLOR "$@" bash "$G" paint | od -An -c | tr -d ' \n'); }
p="$(paint "$T/g1/roots/feature-ok/spike" WT_SESSION=x)"
[[ "$p" == *'033]11;rgb:12/34/56\a'* ]] && pass "paint sets the background (OSC 11)" || fail "paint bg: $p"
[[ "$p" == *'033]4;264;rgb:12/34/56\a'* ]] && pass "paint sets the Windows Terminal tab (OSC 4;264)" || fail "paint tab: $p"
p="$(paint "$T/g1/feature-ok" TERM=xterm)"
[[ "$p" == *'033]11;'* && "$p" != *'264'* ]] && pass "no tab sequence outside Windows Terminal" || fail "tab seq leaked: $p"
p="$(paint "$T" WT_SESSION=x)"
[[ "$p" == *'033]111\a'* && "$p" == *'033[2;263;264,|'* ]] && pass "paint resets outside a grove" || fail "reset: $p"
p="$(paint "$T/g1" WT_SESSION=x)"
[[ "$p" == *'033]111\a'* ]] && pass "paint resets at the grove root (no branch)" || fail "root reset: $p"
check "" "$(paint "$T/g1/feature-ok" TERMINAL_EMULATOR=JetBrains-JediTerm)" "silent in JetBrains' terminal"
check "" "$(cd "$T/g1/feature-ok" && bash "$G" paint | od -An -c | tr -d ' \n')" "silent under NO_COLOR"
git -C "$T/g1" config --global grove.paint false
check "" "$(paint "$T/g1/feature-ok")" "silent when grove.paint=false"
git -C "$T/g1" config --global --unset grove.paint
git -C "$T/g1" config --global grove.paintReset '#0c0c0c'
p="$(paint "$T")"
[[ "$p" == *'033]11;rgb:0c/0c/0c\a'* ]] && pass "paintReset pins the reset color" || fail "paintReset: $p"
git -C "$T/g1" config --global --unset grove.paintReset

step "help / version / usage errors"
expect_ok "help" bash "$G" help
grep -q 'cheat sheet' "$T/out" && pass "help prints the cheat sheet" || fail "help output"
expect_ok "help rm" bash "$G" help rm; grep -q 'Preview by default' "$T/out" && pass "help <verb>" || fail "help rm"
expect_ok "-h add" bash "$G" add -h; grep -q 'usage: git grove add' "$T/out" && pass "-h with verb" || fail "-h add"
check "git-grove $(grep -m1 '^VERSION=' "$G" | cut -d= -f2)" "$(bash "$G" --version)" "--version"
bash "$G" --bogus >/dev/null 2>&1; check 2 $? "unknown option exits 2"
bash "$G" nope >/dev/null 2>&1; check 2 $? "unknown verb exits 2"
bash "$G" >/dev/null 2>&1; check 0 $? "bare invocation exits 0"
(cd "$T/src" && bash "$G" list >/dev/null 2>&1); check 1 $? "refuses to run in a normal clone"

step "helpers (sourced)"
out="$(source "$G"; dashed feature/x/y)"; check "feature-x-y" "$out" "dashed"
out="$(source "$G"; GROVE="$T/g1"; default_branch)"; check "main" "$out" "default_branch"
out="$(source "$G"; GROVE="$T/g1"; children_of feature/ok)"; check "feature/ok-spike" "$out" "children_of"
out="$(source "$G"; fmt_cmd g commit -m "two words")"; check "git -C  commit -m 'two words'" "$out" "fmt_cmd quotes spaces (GROVE unset)"

cd "$T/.." 2>/dev/null; rm -rf "$T"
echo; echo "$n checks, $( [[ $bad == 0 ]] && echo ALL PASS || echo SOME FAILED )"; exit $bad
