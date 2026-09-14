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
ent() { local d="$1"; shift; (cd "$d" && bash "$G" "$@"); }

step "init a brand-new ent by name"
ent "$T" init fresh >/dev/null 2>&1
[[ -d "$T/fresh/.bare" && -d "$T/fresh/main/core" ]] && pass "layout .bare + main/core" || fail "layout"
check "refs/heads/main" "$(git -C "$T/fresh" symbolic-ref HEAD)" "bare HEAD is main"
check "main" "$(git -C "$T/fresh/main/core" branch --show-current)" "core is on main"
check "main" "$(git -C "$T/fresh" config ent.main)" "ent.main is main"
ent "$T" init fresh >/dev/null 2>&1 && fail "init refuses non-empty dir" || pass "init refuses non-empty dir"

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

step "add top-level branch"
cd "$T/g1/main/core"
ent "$T/g1" add feature/a >/dev/null
[[ -d "$T/g1/branches/feature-a/core" ]] && pass "branch container created" || fail "branch container"
check "feature/a" "$(git -C "$T/g1/branches/feature-a/core" branch --show-current)" "branch checked out"
expect_fail "add duplicate branch" "already exists" ent "$T/g1" add feature/a

step "add twig from cwd"
cd "$T/g1/branches/feature-a/core"
ent "$T/g1/branches/feature-a/core" add twig auth >/dev/null
[[ -d "$T/g1/branches/feature-a/twigs/auth/core" ]] && pass "twig container created" || fail "twig container"
check "feature/a-auth" "$(git -C "$T/g1/branches/feature-a/twigs/auth/core" branch --show-current)" "twig branch checked out"
check "feature/a" "$(git -C "$T/g1/.bare" config branch.feature/a-auth.entParent)" "twig parent recorded"

step "add twig with --from"
ent "$T/g1" add twig db --from feature/a >/dev/null
[[ -d "$T/g1/branches/feature-a/twigs/db/core" ]] && pass "twig --from created" || fail "twig --from"

step "depth limits"
cd "$T/g1/branches/feature-a/twigs/auth/core"
ent "$T/g1/branches/feature-a/twigs/auth/core" add twig deep >/dev/null
[[ -d "$T/g1/branches/feature-a/twigs/auth/twigs/deep/core" ]] && pass "twig at depth 2 created" || fail "depth 2"
expect_fail "depth limit" "maxDepth" ent "$T/g1/branches/feature-a/twigs/auth/twigs/deep/core" add twig too

step "branchPattern from .entrc"
cd "$T/g1/main/core"
printf 'branchPattern = ^feature/.*$\n' >.entrc
git add .entrc && git commit -qm "add entrc"
expect_fail "pattern reject" "does not match" ent "$T/g1" add defect/bad
ent "$T/g1" add feature/ok >/dev/null
[[ -d "$T/g1/branches/feature-ok/core" ]] && pass "pattern allow" || fail "pattern allow"

step "path resolution (library) from inside an ent"
cd "$T/g1/main/core"
source "$(dirname "$G")/lib/paths.sh" >/dev/null 2>&1
# lib/paths.sh enables set -e; restore the test harness's tolerant mode.
set +e
ENT="$(Norm "$T/g1")"
check "$(Norm "$T/g1/main/core")" "$(ent_core main)" "ent_core main"
check "$(Norm "$T/g1/branches/feature-a/core")" "$(ent_core feature/a)" "ent_core feature/a"
check "$(Norm "$T/g1/branches/feature-a/twigs/auth/core")" "$(ent_core feature/a-auth)" "ent_core twig"

step "path <branch>"
cd "$T/g1/main/core"
check "$(Norm "$T/g1/branches/feature-a/core")" "$(ent "$T/g1/main/core" path feature/a)" "path prints core"

step "list"
out="$(ent "$T/g1" list)"
echo "$out" | grep -q "main \[main\]" && pass "list shows main" || fail "list main"
echo "$out" | grep -q "feature/a" && pass "list shows feature/a" || fail "list feature/a"
echo "$out" | grep -q "feature/a-auth" && pass "list shows twig" || fail "list twig"

step "check clean"
ent "$T/g1" check >/dev/null 2>&1 && pass "check clean" || fail "check clean"

step "check --repair"
ent "$T/g1" add feature/check >/dev/null
mkdir -p "$T/g1/branches/feature-check-wrong"
src_path="$(Norm "$T/g1/branches/feature-check/core")"
dest_path="$(cygpath -ml "$T/g1/branches/feature-check-wrong/core")"
git -C "$T/g1/.bare" worktree move "$src_path" "$dest_path" >/dev/null
out="$(ent "$T/g1" check 2>&1)"
echo "$out" | grep -q "moved: feature/check" && pass "check detects moved" || fail "check detect moved"
ent "$T/g1" check --apply >/dev/null
[[ -d "$T/g1/branches/feature-check/core" ]] && pass "repair restored core" || fail "repair restore"

step "rm refuses to remove a branch that has twigs"
ent "$T/g1" rm feature/a >/dev/null 2>&1 && fail "rm feature/a without recursive" || pass "rm refuses twigs"

step "rm preview"
ent "$T/g1" rm feature/a --recursive >/dev/null
# a successful preview should not remove the directory
[[ -d "$T/g1/branches/feature-a/core" ]] && pass "preview kept branch" || fail "preview removed branch"

step "rm recursive --apply"
ent "$T/g1" rm feature/a --recursive --apply >/dev/null
[[ ! -d "$T/g1/branches/feature-a" ]] && pass "branch directory removed" || fail "branch directory remains"
git -C "$T/g1/.bare" show-ref --verify -q refs/heads/feature/a && fail "branch ref removed" || pass "branch ref removed"
git -C "$T/g1/.bare" config --get branch.feature/a.entparent >/dev/null 2>&1 && fail "entparent config remains" || pass "entparent config removed"

step "rm refuses dirty worktree"
ent "$T/g1" add feature/dirty >/dev/null
printf 'x' >"$T/g1/branches/feature-dirty/core/dirty.txt"
expect_fail "rm dirty" "uncommitted changes" ent "$T/g1" rm feature/dirty --apply

step "rm dirty worktree with --force"
ent "$T/g1" rm feature/dirty --force --apply >/dev/null
[[ ! -d "$T/g1/branches/feature-dirty" ]] && pass "force rm removed dirty" || fail "force rm failed"

step "merge parent"
ent "$T/g1/main/core" add feature/merge >/dev/null
ent "$T/g1/branches/feature-merge/core" add twig sub >/dev/null
printf 'm' >"$T/g1/branches/feature-merge/twigs/sub/core/m.txt"
(cd "$T/g1/branches/feature-merge/twigs/sub/core" && git add m.txt && git commit -qm 'm')
cd "$T/g1/branches/feature-merge/twigs/sub/core"
ent "$T/g1/branches/feature-merge/twigs/sub/core" merge parent -y >/dev/null
[[ -f "$T/g1/branches/feature-merge/core/m.txt" ]] && pass "merge parent landed" || fail "merge parent"

step "sync --pull"
mkdir "$T/remote" && (cd "$T/remote" && git init -q -b main . && echo a >a.txt && git add . && git commit -qm init)
cd "$T"
bash "$G" init "$T/remote" syncent >/dev/null
echo b >"$T/remote/b.txt" && (cd "$T/remote" && git add . && git commit -qm second)
ent "$T/syncent/main/core" sync --pull -y >/dev/null
[[ -f "$T/syncent/main/core/b.txt" ]] && pass "sync pulled" || fail "sync pull"

step "destroy"
cd "$T"
bash "$G" init doomed >/dev/null
ent "$T/doomed/main/core" add feature/d >/dev/null
bash "$G" destroy "$T/doomed" --force >/dev/null
[[ ! -d "$T/doomed" ]] && pass "destroy removed ent" || fail "destroy"

echo
if (( bad )); then
  echo "SOME FAILURES ($n checks)"
  exit 1
else
  echo "$n checks, ALL PASS"
  exit 0
fi
