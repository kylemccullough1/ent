#!/usr/bin/env bash
# Fresh test suite for the nested container ent layout.
set -uo pipefail

G="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-ent"
T="$(mktemp -d)"
export GIT_CONFIG_GLOBAL="$T/gitconfig" NO_COLOR=1 GIT_CONFIG_NOSYSTEM=1
export PATH="$(dirname "$G"):$PATH"

git config --global user.name t
git config --global user.email t@x
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global core.autocrlf false

bad=0; n=0
step() { echo; echo "=== $*"; }
pass() { n=$((n+1)); echo "PASS $*"; }
fail() { n=$((n+1)); bad=1; echo "FAIL $*"; }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (want '$1' got '$2')"; fi; }
expect_ok() { local msg="$1"; shift; if "$@" >"$T/out" 2>"$T/err"; then pass "$msg"; else fail "$msg: $(tr '\n' ' ' <"$T/err")"; fi; }
expect_fail() { local msg="$1" want="$2"; shift 2
  if "$@" >"$T/out" 2>"$T/err"; then fail "$msg (expected failure)"
  elif grep -qF -- "$want" "$T/err"; then pass "$msg"
  else fail "$msg (stderr lacks '$want'): $(tr '\n' ' ' <"$T/err")"; fi; }
Norm() { (cd "$1" && { cygpath -ml "$PWD" 2>/dev/null || pwd -P; }); }
ent() { local d="$1"; shift; (cd "$d" && "$BASH" "$G" "$@"); }

step "init a brand-new ent by name"
ent "$T" init fresh >/dev/null 2>&1
[[ -d "$T/fresh/.bare" && -d "$T/fresh/main/core" ]] && pass "layout .bare + main/core" || fail "layout"
check "refs/heads/main" "$(git -C "$T/fresh" symbolic-ref HEAD)" "bare HEAD is main"
check "main" "$(git -C "$T/fresh/main/core" branch --show-current)" "core is on main"
check "main" "$(git -C "$T/fresh" config ent.main)" "ent.main is main"
ent "$T" init fresh >/dev/null 2>&1 && fail "init refuses non-empty dir" || pass "init refuses non-empty dir"
expect_fail "init names the bad source" "'./nope' is neither" ent "$T" init ./nope

step "init from a URL"
mkdir "$T/src"; (cd "$T/src" && git init -q -b main . && echo hi >README.md && git add . && git commit -qm init \
  && git checkout -q -b feature/remote-only && echo r >r.txt && git add . && git commit -qm remote && git checkout -q main)
SRC="$(Norm "$T/src")"; URL="file:///${SRC#/}"; [[ "$SRC" == /* ]] && URL="file://$SRC"
ent "$T" init "$URL" g1 >/dev/null 2>&1
[[ -d "$T/g1/.bare" && -d "$T/g1/main/core" ]] && pass "url layout" || fail "url layout"
check "main" "$(git -C "$T/g1/main/core" branch --show-current)" "url worktree branch"
check "origin/main" "$(git -C "$T/g1/main/core" rev-parse --abbrev-ref '@{u}')" "main tracks origin/main"

step "init from an existing clone"
git clone -q "$T/src" "$T/clone"
(cd "$T/clone" && git checkout -q -b feature/local-only && echo l >l.txt && git add . && git commit -qm local && git checkout -q main)
ent "$T" init "$T/clone" g2 >/dev/null 2>&1
[[ -d "$T/g2/main/core" ]] && pass "clone layout" || fail "clone layout"
check "1" "$(git -C "$T/g2" show-ref --verify -q refs/heads/feature/local-only && echo 1)" "local-only branch imported"

step "init when origin default branch is not main"
mkdir "$T/srcdev"; (cd "$T/srcdev" && git init -q -b develop . && echo d >d && git add . && git commit -qm dev)
ent "$T" init "$T/srcdev" gdev >/dev/null 2>&1
check "develop" "$(git -C "$T/gdev" config ent.main)" "ent.main recorded as develop"

step "branch top-level branch"
cd "$T/g1/main/core"
ent "$T/g1" branch feature/a >/dev/null
[[ -d "$T/g1/branches/feature/a/core" ]] && pass "branch container created" || fail "branch container"
check "feature/a" "$(git -C "$T/g1/branches/feature/a/core" branch --show-current)" "branch checked out"
expect_fail "branch duplicate branch" "already exists" ent "$T/g1" branch feature/a

step "branch is cut from the branch you stand in, name kept as given"
ent "$T/g1" branch feature/base >/dev/null
(cd "$T/g1/branches/feature/base/core" && echo base >base.txt && git add base.txt && git commit -qm base)
ent "$T/g1/branches/feature/base/core" branch cut >/dev/null
[[ -d "$T/g1/branches/cut/core" ]] && pass "plain name lands in branches/cut" || fail "plain name lands in branches/cut"
check "cut" "$(git -C "$T/g1/branches/cut/core" branch --show-current)" "plain name kept as given"
[[ -f "$T/g1/branches/cut/core/base.txt" ]] && pass "cut from current branch" || fail "cut from current branch"
check "" "$(git -C "$T/g1/.bare" config --get branch.cut.entParent)" "branch has no ent parent (main)"
ent "$T/g1/main/core" branch from-main >/dev/null
[[ ! -f "$T/g1/branches/from-main/core/base.txt" ]] && pass "cut from main when in main" || fail "cut from main when in main"
ent "$T/g1/branches/feature/a/core" branch feature/456 >/dev/null

step "branch explicit full name from inside namespace"
cd "$T/g1/branches/feature/a/core"
ent "$T/g1/branches/feature/a/core" branch feature/explicit >/dev/null
[[ -d "$T/g1/branches/feature/explicit/core" ]] && pass "explicit full name branch container" || fail "explicit full name branch container"
check "feature/explicit" "$(git -C "$T/g1/branches/feature/explicit/core" branch --show-current)" "explicit full name branch name"

step "branch from main with namespace prefix"
cd "$T/g1/main/core"
ent "$T/g1/main/core" branch prefix/main-name >/dev/null
[[ -d "$T/g1/branches/prefix/main-name/core" ]] && pass "branch from main with namespace container" || fail "branch from main with namespace container"
check "prefix/main-name" "$(git -C "$T/g1/branches/prefix/main-name/core" branch --show-current)" "branch from main with namespace name"

step "old add verb is gone"
expect_fail "add is unknown" "unknown verb" ent "$T/g1" add feature/xyz

step "twig from cwd"
cd "$T/g1/branches/feature/a/core"
ent "$T/g1/branches/feature/a/core" twig auth >/dev/null
[[ -d "$T/g1/branches/feature/a/twigs/auth/core" ]] && pass "twig container created" || fail "twig container"
check "feature/a-auth" "$(git -C "$T/g1/branches/feature/a/twigs/auth/core" branch --show-current)" "twig branch checked out"
check "feature/a" "$(git -C "$T/g1/.bare" config branch.feature/a-auth.entParent)" "twig parent recorded"

step "twig with --from"
ent "$T/g1" twig db --from feature/a >/dev/null
[[ -d "$T/g1/branches/feature/a/twigs/db/core" ]] && pass "twig --from created" || fail "twig --from"

step "depth limits"
cd "$T/g1/branches/feature/a/twigs/auth/core"
ent "$T/g1/branches/feature/a/twigs/auth/core" twig deep >/dev/null
[[ -d "$T/g1/branches/feature/a/twigs/auth/twigs/deep/core" ]] && pass "twig at depth 2 created" || fail "depth 2"
expect_fail "depth limit" "maxDepth" ent "$T/g1/branches/feature/a/twigs/auth/twigs/deep/core" twig too

step "twig cannot be created at top level without --from"
cd "$T/g1/main/core"
expect_fail "twig from main without --from" "must be inside a branch or twig" ent "$T/g1" twig top-level

step "twig --from works from main"
ent "$T/g1" twig sidecar --from feature/456 >/dev/null
[[ -d "$T/g1/branches/feature/456/twigs/sidecar/core" ]] && pass "twig --from container" || fail "twig --from container"
check "feature/456-sidecar" "$(git -C "$T/g1/branches/feature/456/twigs/sidecar/core" branch --show-current)" "twig --from branch name"

step "branchPattern from .entrc"
cd "$T/g1/main/core"
printf 'branchPattern = ^feature/.*$\n' >.entrc
git add .entrc && git commit -qm "add entrc"
expect_fail "pattern reject" "does not match" ent "$T/g1" branch defect/bad
ent "$T/g1" branch feature/ok >/dev/null
[[ -d "$T/g1/branches/feature/ok/core" ]] && pass "pattern allow" || fail "pattern allow"

step "path resolution (library) from inside an ent"
cd "$T/g1/main/core"
source "$(dirname "$G")/lib/paths.sh" >/dev/null 2>&1
ENT="$(Norm "$T/g1")"
check "$(Norm "$T/g1/main/core")" "$(ent_core main)" "ent_core main"
check "$(Norm "$T/g1/branches/feature/a/core")" "$(ent_core feature/a)" "ent_core feature/a"
check "$(Norm "$T/g1/branches/feature/a/twigs/auth/core")" "$(ent_core feature/a-auth)" "ent_core twig"

step "branch resolution from container dirs"
check "main" \
  "$(cd "$T/g1/main" && ent_branch_of_cwd)" \
  "main container resolves to main"
check "feature/ok" \
  "$(cd "$T/g1/branches/feature/ok" && ent_branch_of_cwd)" \
  "branch container resolves to branch"
check "feature/456-sidecar" \
  "$(cd "$T/g1/branches/feature/456/twigs/sidecar" && ent_branch_of_cwd)" \
  "twig container resolves to twig"
check "feature/456" \
  "$(cd "$T/g1/branches/feature/456/twigs" && ent_branch_of_cwd)" \
  "twigs folder resolves to parent branch"

step "path <branch>"
cd "$T/g1/main/core"
check "$(Norm "$T/g1/branches/feature/a/core")" "$(ent "$T/g1/main/core" path feature/a)" "path prints core"

step "list"
out="$(ent "$T/g1" list)"
echo "$out" | grep -q "main \[main\]" && pass "list shows main" || fail "list main"
echo "$out" | grep -q "feature/a" && pass "list shows feature/a" || fail "list feature/a"
echo "$out" | grep -q "feature/a-auth" && pass "list shows twig" || fail "list shows twig"

step "navigation resolves paths"
cd "$T/g1/branches/feature/456/core"
check "$(Norm "$T/g1")" "$(ent "$T/g1/branches/feature/456/core" up)" "up from root branch goes to ent root"
cd "$T/g1/branches/feature/456/twigs/sidecar/core"
check "$(Norm "$T/g1/branches/feature/456/core")" "$(ent "$T/g1/branches/feature/456/twigs/sidecar/core" up)" "up from twig to parent core"
cd "$T/g1/branches/feature/456/core"
check "$(Norm "$T/g1/branches/feature/456/twigs/sidecar/core")" "$(ent "$T/g1/branches/feature/456/core" down)" "down into only child"
check "$(Norm "$T/g1/branches/feature/456/twigs/sidecar/core")" "$(ent "$T/g1/branches/feature/456/core" down sidecar)" "down sidecar by name"
ent "$T/g1/branches/feature/456/core" twig extra >/dev/null
expect_fail "down with multiple children" "Multiple choices" ent "$T/g1/branches/feature/456/core" down
check "$(Norm "$T/g1/branches/feature/456/twigs/extra/core")" "$(ent "$T/g1/branches/feature/456/core" down extra)" "down extra by name"
expect_fail "down unknown child" "no child matches" ent "$T/g1/branches/feature/456/core" down missing
expect_fail "down from leaf" "no children" ent "$T/g1/branches/feature/456/twigs/extra/core" down

cd "$T/g1"
check "$(Norm "$T/g1")" \
  "$(ent "$T/g1/branches/feature/ok" up)" \
  "up from branch container to ent root"
check "$(Norm "$T/g1/branches/feature/456/core")" \
  "$(ent "$T/g1/branches/feature/456/twigs/sidecar" up)" \
  "up from twig container to parent core"
check "$(Norm "$T/g1/branches/feature/456/twigs/sidecar/core")" \
  "$(ent "$T/g1/branches/feature/456" down sidecar)" \
  "down from branch container by name"

ent "$T/g1/branches/feature/456" twig container-test >/dev/null
[[ -d "$T/g1/branches/feature/456/twigs/container-test/core" ]] && \
  pass "twig from branch container" || fail "twig from branch container"
ent "$T/g1/branches/feature/456" twig container-ok --from feature/456 >/dev/null
[[ -d "$T/g1/branches/feature/456/twigs/container-ok/core" ]] && \
  pass "twig --from branch container" || fail "twig --from branch container"

cd "$T/g1"
expect_fail "branch merge from ent root" \
  "run from inside a core worktree" \
  ent "$T/g1" branch merge
expect_fail "branch merge from branch container" \
  "run from inside a core worktree" \
  ent "$T/g1/branches/feature/456" branch merge
check "$(Norm "$T/g1/branches/feature/456/core")" "$(ent "$T/g1" go feature/456)" "go by branch name"
check "$(Norm "$T/g1/branches/feature/456/core")" "$(ent "$T/g1" go feature-456)" "go by slug"
expect_fail "go missing name" "usage" ent "$T/g1" go
expect_fail "go extra args" "usage" ent "$T/g1" go feature/456 extra
expect_fail "go unknown branch" "no branch matches" ent "$T/g1" go nope

step "rm refuses to remove a branch that has twigs"
ent "$T/g1" rm feature/a >/dev/null 2>&1 && fail "rm feature/a without recursive" || pass "rm refuses twigs"

step "rm preview"
printf 'n\n' | ent "$T/g1" rm feature/a --recursive >/dev/null 2>&1
# a cancelled preview should not remove the directory
[[ -d "$T/g1/branches/feature/a/core" ]] && pass "preview kept branch" || fail "preview removed branch"

step "rm confirms before removing"
ent "$T/g1" branch feature/temp-rm >/dev/null
printf 'n\n' | ent "$T/g1" rm feature/temp-rm >/dev/null 2>&1
[[ -d "$T/g1/branches/feature/temp-rm/core" ]] && pass "rm cancelled on 'n'" || fail "rm cancelled on 'n'"
printf 'y\n' | ent "$T/g1" rm feature/temp-rm >/dev/null 2>&1
[[ ! -d "$T/g1/branches/feature/temp-rm" ]] && pass "rm confirmed on 'y'" || fail "rm confirmed on 'y'"

step "rm recursive confirmed"
printf 'y\n' | ent "$T/g1" rm feature/a --recursive >/dev/null
[[ ! -d "$T/g1/branches/feature/a" ]] && pass "branch directory removed" || fail "branch directory remains"
git -C "$T/g1/.bare" show-ref --verify -q refs/heads/feature/a && fail "branch ref removed" || pass "branch ref removed"
git -C "$T/g1/.bare" config --get branch.feature/a.entparent >/dev/null 2>&1 && fail "entparent config remains" || pass "entparent config removed"

step "rm rejects unknown option --apply"
expect_fail "unknown option --apply" "unknown option" ent "$T/g1" rm feature/456 --apply

step "rm refuses dirty worktree"
ent "$T/g1" branch feature/dirty >/dev/null
printf 'x' >"$T/g1/branches/feature/dirty/core/dirty.txt"
printf 'y\n' | expect_fail "rm dirty" "uncommitted changes" ent "$T/g1" rm feature/dirty

step "rm dirty worktree with --force"
printf 'y\n' | ent "$T/g1" rm feature/dirty --force >/dev/null
[[ ! -d "$T/g1/branches/feature/dirty" ]] && pass "force rm removed dirty" || fail "force rm failed"

step "branch merge: a twig merges into its parent, not main"
ent "$T/g1/main/core" branch feature/merge >/dev/null
ent "$T/g1/branches/feature/merge/core" twig sub >/dev/null
printf 'm' >"$T/g1/branches/feature/merge/twigs/sub/core/m.txt"
(cd "$T/g1/branches/feature/merge/twigs/sub/core" && git add m.txt && git commit -qm 'm')
cd "$T/g1/branches/feature/merge/twigs/sub/core"
expect_fail "branch merge rejects a target" "no target" ent "$T/g1/branches/feature/merge/twigs/sub/core" branch merge main -y
ent "$T/g1/branches/feature/merge/twigs/sub/core" branch merge -y >/dev/null
[[ -f "$T/g1/branches/feature/merge/core/m.txt" ]] && pass "twig merged into parent branch" || fail "twig merged into parent branch"
[[ ! -f "$T/g1/main/core/m.txt" ]] && pass "twig merge left main alone" || fail "twig merge left main alone"
[[ ! -d "$T/g1/branches/feature/merge/twigs/sub" ]] && pass "merge finish removed twig" || fail "merge finish removed twig"
expect_fail "main cannot branch merge" "no parent" ent "$T/g1/main/core" branch merge -y

step "rm: protect combines env, bare config and .entrc"
ent "$T/g1" branch feature/keep1 >/dev/null
ent "$T/g1" branch feature/keep2 >/dev/null
git -C "$T/g1/.bare" config ent.protect feature/keep1
ENT_PROTECT=feature/keep2 expect_fail "protected by bare config despite env" "protected" ent "$T/g1" rm feature/keep1 -y
ENT_PROTECT=feature/keep2 expect_fail "protected by env" "protected" ent "$T/g1" rm feature/keep2 -y
git -C "$T/g1/.bare" config --unset ent.protect

step "commands work through a symlink into the ent"
ln -s "$T/g1/branches/feature/ok" "$T/link-ok"
expect_ok "list through symlink" ent "$T/link-ok" list
check "$(Norm "$T/g1")" "$(ent "$T/link-ok" up)" "up through symlink"

step "branch merge into main cleans up source"
ent "$T/g1" branch feature/merge-test >/dev/null
printf ' hello' >"$T/g1/branches/feature/merge-test/core/hello.txt"
(cd "$T/g1/branches/feature/merge-test/core" && git add hello.txt && git commit -qm 'hello')
cd "$T/g1/branches/feature/merge-test/core"
printf 'y\ny\n' | ent "$T/g1/branches/feature/merge-test/core" branch merge >/dev/null
[[ -f "$T/g1/main/core/hello.txt" ]] && pass "merge into main landed" || fail "merge into main landed"
[[ ! -d "$T/g1/branches/feature/merge-test" ]] && pass "merge finish removed worktree" || fail "merge finish removed worktree"

step "sync: setup (origin R, ent E with one branch per case)"
R="$T/syncR"
mkdir "$R" && (cd "$R" && git init -q -b main . && echo a >a.txt && echo c >c.txt && git add . && git commit -qm init)
cd "$T"
"$BASH" "$G" init "$R" syncE >/dev/null 2>&1
E="$T/syncE"
commit_in() { (cd "$1" && echo "$2" >"$3" && git add "$3" && git commit -qm "$2"); }
ent "$E" branch fresh >/dev/null                       # no commits: must never be offered
ent "$E" branch done1 >/dev/null;  commit_in "$E/branches/done1/core" d1 d1.txt
ent "$E" branch sq >/dev/null;     commit_in "$E/branches/sq/core" sq sq.txt
(cd "$E/branches/sq/core" && git push -q -u origin sq 2>/dev/null)
ent "$E" branch cp >/dev/null;     commit_in "$E/branches/cp/core" cp cp.txt
ent "$E" branch work >/dev/null;   commit_in "$E/branches/work/core" w w.txt
ent "$E/branches/work/core" twig t >/dev/null
ent "$E" branch dirty >/dev/null;  echo x >"$E/branches/dirty/core/scratch.txt"
ent "$E" branch clash >/dev/null;  commit_in "$E/branches/clash/core" mine c.txt
# On origin: a merge commit, a squash merge (branch deleted), a cherry-pick, new work
git -C "$R" fetch -q "$E/.bare" done1 && git -C "$R" merge -q --no-ff -m "merge done1" FETCH_HEAD
git -C "$R" merge -q --squash sq >/dev/null && git -C "$R" commit -qm "squash sq" && git -C "$R" branch -q -D sq
git -C "$R" fetch -q "$E/.bare" cp && git -C "$R" cherry-pick FETCH_HEAD >/dev/null
commit_in "$R" new n.txt
commit_in "$R" theirs c.txt

step "sync: step 1 pulls main and removes only merged branches"
out="$(ent "$E" sync -y 2>&1)"
[[ -f "$E/main/core/n.txt" ]] && pass "sync fast-forwarded main" || fail "sync fast-forwarded main"
has_branch() { git -C "$E/.bare" show-ref -q --verify "refs/heads/$1"; }
has_branch fresh && pass "fresh branch never offered" || fail "fresh branch never offered"
has_branch done1 && fail "merge-commit branch removed" || pass "merge-commit branch removed"
has_branch sq && fail "squash-merged (gone) branch removed" || pass "squash-merged (gone) branch removed"
has_branch cp && fail "content-merged branch removed" || pass "content-merged branch removed"
[[ ! -d "$E/branches/done1" ]] && pass "merged branch folder removed" || fail "merged branch folder removed"

step "sync: step 2 merges main into branches and twigs"
[[ -f "$E/branches/work/core/n.txt" && -f "$E/branches/work/core/w.txt" ]] && pass "main merged into branch with its own work" || fail "main merged into branch with its own work"
[[ -f "$E/branches/work/twigs/t/core/n.txt" ]] && pass "main merged into twig" || fail "main merged into twig"
[[ -f "$E/branches/fresh/core/n.txt" ]] && pass "main merged into fresh branch" || fail "main merged into fresh branch"
[[ ! -f "$E/branches/dirty/core/n.txt" ]] && pass "dirty worktree skipped" || fail "dirty worktree skipped"
echo "$out" | grep -q "dirty (uncommitted changes)" && pass "skip reported" || fail "skip reported"
[[ -f "$(git -C "$E/branches/clash/core" rev-parse --git-path MERGE_HEAD)" ]] && pass "conflict left mid-merge" || fail "conflict left mid-merge"
echo "$out" | grep -q "clash" && echo "$out" | grep -q "conflicts to resolve" && pass "conflict reported" || fail "conflict reported"

step "sync <branch> merges main into just that branch"
git -C "$E/branches/clash/core" merge --abort
commit_in "$R" newer n2.txt
ent "$E" sync fresh -y >/dev/null 2>&1
[[ -f "$E/branches/fresh/core/n2.txt" ]] && pass "named branch synced" || fail "named branch synced"
[[ ! -f "$E/branches/work/core/n2.txt" ]] && pass "other branches untouched" || fail "other branches untouched"
expect_fail "sync unknown branch" "not found" ent "$E" sync nope

step "destroy"
cd "$T"
"$BASH" "$G" init doomed >/dev/null
ent "$T/doomed/main/core" branch feature/d >/dev/null
"$BASH" "$G" destroy "$T/doomed" --force >/dev/null
[[ ! -d "$T/doomed" ]] && pass "destroy removed ent" || fail "destroy"

echo
if (( bad )); then
  echo "SOME FAILURES ($n checks)"
  exit 1
else
  echo "$n checks, ALL PASS"
  exit 0
fi
