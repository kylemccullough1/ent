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
