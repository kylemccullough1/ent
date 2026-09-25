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

# ---------- platform ----------
# Some behaviour genuinely differs between Windows and the Unixes, so those
# tests come in pairs and each half runs only where it applies. A skipped test
# is counted separately and never reported as a pass.
case "$OSTYPE" in msys*|cygwin*) ON_WINDOWS=1 ;; *) ON_WINDOWS=0 ;; esac
skipped=0
skip() { skipped=$((skipped+1)); echo "SKIP $1 ($2)"; }
# unix_only <name>: true when this test should run here.
unix_only()    { if (( ON_WINDOWS )); then skip "$1" "unix only"; return 1; fi; return 0; }
windows_only() { if (( ON_WINDOWS )); then return 0; fi; skip "$1" "windows only"; return 1; }
# mklink_j <link> <target>: a Windows directory junction. Git Bash's `ln -s`
# silently copies a folder unless Developer Mode is on, so a junction is the
# link that can be relied on here. Git Bash reports one as a symlink and
# `pwd -P` resolves it, which is what ent_root walks.
mklink_j() { MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null 2>&1; }

step "node tree loads from .bare/ent.json"
source "$(dirname "$G")/lib/core.sh" >/dev/null 2>&1
source "$(dirname "$G")/lib/tree.sh" >/dev/null 2>&1
ent "$T" init tree-test >/dev/null 2>&1
ENT="$(Norm "$T/tree-test")"
cat >"$ENT/.bare/ent.json" <<'JSON'
{
  "canopy": "main",
  "nodes": {
    "main": {
      "type": "canopy",
      "parent": null,
      "children": ["feature/x"],
      "worktree": "main/core"
    },
    "feature/x": {
      "type": "branch",
      "parent": "main",
      "children": [],
      "worktree": "branches/feature/x/core"
    }
  }
}
JSON
tree_load
[[ "$(tree_canopy)" == "main" ]] && pass "tree_canopy" || fail "tree_canopy"
tree_parent_of "feature/x"; [[ "$REPLY" == "main" ]] && pass "tree_parent_of" || fail "tree_parent_of"
tree_children_of "main"; [[ "${REPLY_LIST[*]}" == "feature/x" ]] && pass "tree_children_of" || fail "tree_children_of"
tree_worktree_of "feature/x"; [[ "$REPLY" == "branches/feature/x/core" ]] && pass "tree_worktree_of" || fail "tree_worktree_of"

step "state and paths resolve from the node tree"
cd "$ENT/main/core"
source "$(dirname "$G")/lib/paths.sh" >/dev/null 2>&1
load_state
[[ "$(ent_canopy)" == "main" ]] && pass "ent_canopy" || fail "ent_canopy"
[[ "$(ent_core feature/x)" == "$ENT/branches/feature/x/core" ]] && pass "ent_core from tree" || fail "ent_core from tree"

step "concurrent writes to ent.json do not corrupt the file"
ENT="$(Norm "$T/tree-test")"
for i in 1 2 3; do
  (tree_add_node "concurrent$i" branch main "branches/concurrent$i/core" || true) &
done
wait
tree_load
n=0; for x in ${T_NAME[@]+"${T_NAME[@]}"}; do n=$((n+1)); done
(( n >= 3 )) && pass "concurrent writes survived" || fail "concurrent writes corrupted node list"

step "init a brand-new ent by name"
ent "$T" init fresh >/dev/null 2>&1
[[ -d "$T/fresh/.bare" && -d "$T/fresh/main/core" ]] && pass "layout .bare + main/core" || fail "layout"
check "refs/heads/main" "$(git -C "$T/fresh" symbolic-ref HEAD)" "bare HEAD is main"
check "main" "$(git -C "$T/fresh/main/core" branch --show-current)" "core is on main"
check "main" "$(git -C "$T/fresh" config ent.canopy)" "ent.canopy is main"
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
check "develop" "$(git -C "$T/gdev" config ent.canopy)" "ent.canopy recorded as develop"

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

step "branch from remote with --remote"
ent "$T/g1" branch imported --remote feature/remote-only >/dev/null
[[ -d "$T/g1/branches/imported/core" ]] && pass "remote branch container created" || fail "remote branch container"
check "imported" "$(git -C "$T/g1/branches/imported/core" branch --show-current)" "remote branch checked out"
check "origin/feature/remote-only" "$(git -C "$T/g1/branches/imported/core" rev-parse --abbrev-ref '@{u}')" "upstream set to remote"
[[ -f "$T/g1/branches/imported/core/r.txt" ]] && pass "remote branch content present" || fail "remote branch content present"

step "branch --remote with missing remote branch fails"
expect_fail "branch --remote missing" "remote branch 'nonexistent' not found" ent "$T/g1" branch wont-work --remote nonexistent

step "branch --from is local-only"
expect_fail "branch --from remote ref" "not found locally" ent "$T/g1" branch from-remote --from feature/remote-only

step "branch --from and --remote are mutually exclusive"
expect_fail "branch --from --remote conflict" "mutually exclusive" ent "$T/g1" branch conflict --from main --remote feature/remote-only

step "canopy config key replaces ent.main"
check "main" "$(git -C "$T/g1/.bare" config ent.canopy)" "canopy recorded"
[[ -z "$(git -C "$T/g1/.bare" config ent.main 2>/dev/null || true)" ]] && pass "ent.main removed" || fail "ent.main removed"

step "logging writes to per-ent log"
ENT="$(Norm "$T/g1")"
ent "$T/g1" branch log-test >/dev/null 2>&1
[[ -f "$ENT/.bare/ent.log" ]] && pass "per-ent log exists" || fail "per-ent log exists"
grep -q "INFO" "$ENT/.bare/ent.log" && pass "info entries written" || fail "info entries written"

step "global log catches messages outside an ent"
HGLOBAL="$T/home-global"; mkdir -p "$HGLOBAL/.config"
(cd "$T" && HOME="$HGLOBAL" "$BASH" "$G" unknown-verb >/dev/null 2>&1) || true
[[ -f "$HGLOBAL/.config/ent/global.log" ]] && pass "global log exists" || fail "global log exists"
grep -q "ERROR" "$HGLOBAL/.config/ent/global.log" && pass "global error written" || fail "global error written"

step "old add verb is gone"
expect_fail "add is unknown" "unknown verb" ent "$T/g1" add feature/xyz

step "twig from cwd"
cd "$T/g1/branches/feature/a/core"
ent "$T/g1/branches/feature/a/core" twig auth >/dev/null
[[ -d "$T/g1/branches/feature/a/twigs/auth/core" ]] && pass "twig container created" || fail "twig container"
check "twigs/feature/a/auth" "$(git -C "$T/g1/branches/feature/a/twigs/auth/core" branch --show-current)" "twig branch checked out"
check "feature/a" "$(git -C "$T/g1/.bare" config branch.twigs/feature/a/auth.entParent)" "twig parent recorded"

step "twig with --from"
ent "$T/g1" twig db --from feature/a >/dev/null
[[ -d "$T/g1/branches/feature/a/twigs/db/core" ]] && pass "twig --from created" || fail "twig --from"

step "a twig cannot have twigs (git forbids the name)"
cd "$T/g1/branches/feature/a/twigs/auth/core"
expect_fail "twig of a twig refused" "is a twig, and twigs go one level deep" \
  ent "$T/g1/branches/feature/a/twigs/auth/core" twig deep
expect_fail "twig of a twig refused via --from" "is a twig" ent "$T/g1" twig deep --from twigs/feature/a/auth
expect_fail "twig name with a slash refused" "cannot contain" ent "$T/g1/branches/feature/a/core" twig has/slash

step "twigs/ is reserved for twig branches"
expect_fail "branch named twigs" "reserved" ent "$T/g1" branch twigs
expect_fail "branch under twigs/" "reserved" ent "$T/g1" branch twigs/mine

step "twig cannot be created at top level without --from"
cd "$T/g1/main/core"
expect_fail "twig from main without --from" "must be inside a branch" ent "$T/g1" twig top-level

step "twig --from works from main"
ent "$T/g1" twig sidecar --from feature/456 >/dev/null
[[ -d "$T/g1/branches/feature/456/twigs/sidecar/core" ]] && pass "twig --from container" || fail "twig --from container"
check "twigs/feature/456/sidecar" "$(git -C "$T/g1/branches/feature/456/twigs/sidecar/core" branch --show-current)" "twig --from branch name"

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
check "$(Norm "$T/g1/branches/feature/a/twigs/auth/core")" "$(ent_core twigs/feature/a/auth)" "ent_core twig"

step "branch resolution from container dirs"
check "main" \
  "$(cd "$T/g1/main" && ent_branch_of_cwd)" \
  "main container resolves to main"
check "feature/ok" \
  "$(cd "$T/g1/branches/feature/ok" && ent_branch_of_cwd)" \
  "branch container resolves to branch"
check "twigs/feature/456/sidecar" \
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
echo "$out" | grep -q "twigs/feature/a/auth" && pass "list shows twig" || fail "list shows twig"

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
check "$(Norm "$T/g1/branches/feature/456/twigs/sidecar/core")" "$(ent "$T/g1" go twigs/feature/456/sidecar)" "go by full twig name"
check "$(Norm "$T/g1/branches/feature/456/twigs/sidecar/core")" "$(ent "$T/g1" go sidecar)" "go by twig short name"
expect_fail "go unknown branch" "no branch matches" ent "$T/g1" go nope

step "prompt helper verb (__where)"
check "feature/456" "$(ent "$T/g1/branches/feature/456/twigs" __where)" "__where in a twigs folder"
check "ent" "$(ent "$T/g1" __where)" "__where at the ent root"
check "" "$(ent "$T" __where)" "__where outside an ent prints nothing"

step "ent wrapper shows help instead of cd-ing into it"
# `pwd -P` and `pwd -W` print the same folder two different ways on Git Bash
# (/tmp/... vs C:/...), and Norm speaks the C:/... one, so each platform asks
# for the spelling that matches.
if unix_only "ent go --help leaves the folder alone"; then
  out="$(cd "$T/g1" && PATH="$(dirname "$G"):$PATH" "$BASH" --norc -c 'source "$1"; ent go --help >/dev/null; pwd -P' _ "$(dirname "$G")/completions/ent.bash" 2>&1)"
  check "$(Norm "$T/g1")" "$out" "ent go --help leaves the folder alone"
fi
if windows_only "ent go --help leaves the folder alone (windows)"; then
  out="$(cd "$T/g1" && PATH="$(dirname "$G"):$PATH" "$BASH" --norc -c 'source "$1"; ent go --help >/dev/null; pwd -W' _ "$(dirname "$G")/completions/ent.bash" 2>&1)"
  check "$(Norm "$T/g1")" "$out" "ent go --help leaves the folder alone (windows)"
fi

step "git-ent works through a symlink"
mkdir -p "$T/linkbin" && ln -s "$G" "$T/linkbin/git-ent"
check "$(Norm "$T/g1/branches/feature/456/core")" "$(cd "$T/g1" && "$BASH" "$T/linkbin/git-ent" go feature/456)" "symlinked git-ent finds lib/"

step "rm --dry-run changes nothing"
printf 'y\n' | ent "$T/g1" rm twigs/feature/a/auth -r -n >/dev/null 2>&1
check "feature/a" "$(git -C "$T/g1/.bare" config branch.twigs/feature/a/auth.entParent)" "dry run kept the twig's parent record"
[[ -d "$T/g1/branches/feature/a/twigs/auth/core" ]] && pass "dry run kept the twig folder" || fail "dry run kept the twig folder"

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

step "branch merge takes its twigs along, then prints the parent folder"
ent "$T/g1/main/core" branch feature/nest >/dev/null
ent "$T/g1/branches/feature/nest/core" twig a >/dev/null
ent "$T/g1/branches/feature/nest/core" twig b >/dev/null
commit_in2() { (cd "$1" && echo "$2" >"$3" && git add "$3" && git commit -qm "$2"); }
commit_in2 "$T/g1/branches/feature/nest/twigs/a/core" deep deep.txt
commit_in2 "$T/g1/branches/feature/nest/twigs/b/core" deeper deeper.txt
out="$(ent "$T/g1/branches/feature/nest/core" branch merge -y 2>/dev/null)"
[[ -f "$T/g1/main/core/deep.txt" && -f "$T/g1/main/core/deeper.txt" ]] && pass "twig work reached main" || fail "twig work reached main"
[[ ! -d "$T/g1/branches/feature/nest" ]] && pass "branch tree removed" || fail "branch tree removed"
check "$(Norm "$T/g1/main/core")" "$out" "branch merge prints the parent's folder"

step "rm: protect combines env, bare config and .entrc"
ent "$T/g1" branch feature/keep1 >/dev/null
ent "$T/g1" branch feature/keep2 >/dev/null
git -C "$T/g1/.bare" config ent.protect feature/keep1
ENT_PROTECT=feature/keep2 expect_fail "protected by bare config despite env" "protected" ent "$T/g1" rm feature/keep1 -y
ENT_PROTECT=feature/keep2 expect_fail "protected by env" "protected" ent "$T/g1" rm feature/keep2 -y
git -C "$T/g1/.bare" config --unset ent.protect

step "commands work through a link into the ent"
# A real symlink on Unix; a directory junction on Windows, because Git Bash's
# `ln -s` copies the folder instead of linking it unless Developer Mode is on,
# and a copy has no .bare above it for ent_root to find.
if unix_only "list/up through symlink"; then
  ln -s "$T/g1/branches/feature/ok" "$T/link-ok"
  expect_ok "list through symlink" ent "$T/link-ok" list
  check "$(Norm "$T/g1")" "$(ent "$T/link-ok" up)" "up through symlink"
fi
if windows_only "list/up through junction"; then
  mklink_j "$T/link-ok" "$T/g1/branches/feature/ok"
  expect_ok "list through junction" ent "$T/link-ok" list
  check "$(Norm "$T/g1")" "$(ent "$T/link-ok" up)" "up through junction"
fi

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
ent "$E" branch closed >/dev/null; commit_in "$E/branches/closed/core" cl cl.txt
(cd "$E/branches/closed/core" && git push -q -u origin closed 2>/dev/null)
git -C "$R" branch -q -D closed                        # PR closed without merging
ent "$E" branch prot >/dev/null;   commit_in "$E/branches/prot/core" pr pr.txt
git -C "$E/.bare" config ent.protect prot
ent "$E" branch withtwig >/dev/null; commit_in "$E/branches/withtwig/core" wt wt.txt
ent "$E/branches/withtwig/core" twig extra >/dev/null
commit_in "$E/branches/withtwig/twigs/extra/core" ex ex.txt  # twig work not in main
git -C "$R" fetch -q "$E/.bare" prot && git -C "$R" merge -q --no-ff -m "merge prot" FETCH_HEAD
git -C "$R" fetch -q "$E/.bare" withtwig && git -C "$R" merge -q --no-ff -m "merge withtwig" FETCH_HEAD
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
has_branch closed && pass "deleted-on-origin but unmerged branch kept" || fail "deleted-on-origin but unmerged branch kept"
has_branch prot && pass "protected merged branch kept" || fail "protected merged branch kept"
has_branch withtwig && has_branch twigs/withtwig/extra && pass "branch kept when its twig has unmerged work" || fail "branch kept when its twig has unmerged work"
echo "$out" | grep -q "twig twigs/withtwig/extra has work that is not in main" && pass "unmerged twig reported" || fail "unmerged twig reported"
[[ ! -d "$E/branches/done1" ]] && pass "merged branch folder removed" || fail "merged branch folder removed"

step "sync: step 2 merges main into branches and twigs"
[[ -f "$E/branches/work/core/n.txt" && -f "$E/branches/work/core/w.txt" ]] && pass "main merged into branch with its own work" || fail "main merged into branch with its own work"
[[ -f "$E/branches/work/twigs/t/core/n.txt" ]] && pass "main merged into twig" || fail "main merged into twig"
[[ -f "$E/branches/fresh/core/n.txt" ]] && pass "main merged into fresh branch" || fail "main merged into fresh branch"
[[ ! -f "$E/branches/dirty/core/n.txt" ]] && pass "dirty worktree skipped" || fail "dirty worktree skipped"
echo "$out" | grep -q "dirty (uncommitted changes)" && pass "skip reported" || fail "skip reported"
git -C "$E/branches/clash/core" rev-parse -q --verify MERGE_HEAD >/dev/null && pass "conflict left mid-merge" || fail "conflict left mid-merge"
echo "$out" | grep -q "clash" && echo "$out" | grep -q "conflicts to resolve" && pass "conflict reported" || fail "conflict reported"

step "an unfinished merge shows as MERGING"
out2="$(ent "$E" list)"
echo "$out2" | grep -q "clash \[MERGING\]" && pass "list marks the conflicted branch MERGING" || fail "list marks the conflicted branch MERGING (got: $(echo "$out2" | tr '\n' ' '))"
check "clash|MERGING" "$(ent "$E/branches/clash/core" __where)" "prompt shows branch|MERGING inside the worktree"
check "clash|MERGING" "$(ent "$E/branches/clash" __where)" "prompt shows branch|MERGING in the container folder"
echo "$out2" | grep -q "^work$" && pass "clean branches carry no state" || fail "clean branches carry no state"

step "sync <branch> merges main into just that branch"
git -C "$E/branches/clash/core" merge --abort
check "clash" "$(ent "$E/branches/clash" __where)" "MERGING clears after the merge is aborted"
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

step "status and log across worktrees"
out="$(ent "$T/g1/main/core" status)"
echo "$out" | grep -q "^=== main " && pass "status includes main" || fail "status includes main"
echo "$out" | grep -q "^=== twigs/feature/456/sidecar " && pass "status includes twigs" || fail "status includes twigs"
printf 'scratch\n' >"$T/g1/branches/feature/456/core/scratch.txt"
dbg="$(ent "$T/g1/main/core" status)"
echo "$dbg" | grep -q 'scratch.txt' && pass "status shows a dirty file" || fail "status shows a dirty file: $(echo "$dbg" | grep -A2 '=== feature/456 ' | tr '\n' '|')"
rm -f "$T/g1/branches/feature/456/core/scratch.txt"
case "$(ent "$T/g1/main/core" status)" in *$'\033'*) fail "piped status is plain text" ;; *) pass "piped status is plain text" ;; esac

out="$(ent "$T/g1/main/core" log)"
echo "$out" | grep -q "^=== main " && pass "log covers every worktree" || fail "log covers every worktree"
echo "$out" | grep -q "add entrc" && pass "log shows commits" || fail "log shows commits: $(echo "$out" | sed -n 2,3p | tr '\n' '|')"
dbg="$(ent "$T/g1/main/core" log -- -n 1 --format=%s 2>&1)"; rc=$?
echo "$dbg" | grep -q "add entrc" && pass "log passes args after -- to git" || fail "log passes args after -- to git (rc=$rc): $(echo "$dbg" | head -3 | tr '\n' '|')"
expect_fail "log rejects a bad git arg" "" ent "$T/g1/main/core" log -- --definitely-not-a-flag

step "viewer leave resets mouse modes, cursor, alternate screen, and attributes"
(
  source "$(dirname "$G")/lib/state.sh"
  source "$(dirname "$G")/lib/view.sh"
  out="$(_view_leave)"; ok=1
  for seq in $'\033[?25h' $'\033[?1049l' $'\033[?1003l' $'\033[?1002l' $'\033[?1000l' $'\033[?1006l' $'\033[?1015l' $'\033[?1005l' $'\033[0m'; do
    [[ "$out" == *"$seq"* ]] || { echo "  missing $(printf '%q' "$seq")" >&2; ok=0; }
  done
  # SGR reset should happen while still on the alternate screen.
  before_sgr="${out%%$'\033[0m'*}"
  [[ "$before_sgr" == *$'\033[?1049l'* ]] && { echo "  SGR reset happens after alternate screen leave" >&2; ok=0; }
  # Idempotence must be checked in the same shell because command substitutions fork.
  tmp="$(mktemp -d)"
  _view_leave > "$tmp/first"; _view_leave > "$tmp/second"
  [[ -s "$tmp/second" ]] && { echo "  _view_leave is not idempotent" >&2; ok=0; }
  rm -rf "$tmp"
  exit $(( ! ok ))
) && pass "viewer leave resets terminal modes" || fail "viewer leave resets terminal modes"

step "viewer tab bar fits the window"
( source "$(dirname "$G")/lib/state.sh"; source "$(dirname "$G")/lib/view.sh"
  VIEW_BRANCHES=(main mainb twigs/mainb/mainc feature/something-long defect/x)
  plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
  ok=1
  for cols in 80 40 24; do
    for sel in 0 2 4; do
      _view_tabs "$sel" "$cols"; p="$(plain "$REPLY")"
      (( ${#p} <= cols )) || { echo "  width ${#p} > $cols at sel=$sel" >&2; ok=0; }
      case "$p" in *"${VIEW_BRANCHES[$sel]}"*) ;; *) echo "  selected hidden at cols=$cols sel=$sel" >&2; ok=0 ;; esac
    done
  done
  exit $(( ! ok ))
) && pass "tab bar trims to the width and keeps the selection visible" \
  || fail "tab bar trims to the width and keeps the selection visible"

# The full-screen viewer needs a terminal; `script` gives us one where available.
if command -v script >/dev/null 2>&1; then
  view_keys() { printf '%s' "$2" | script -q /dev/null "$BASH" "$G" "$1" 2>&1 | tr -d '\r'; }
  scr="$(cd "$T/g1/branches/feature/456/core" && view_keys status q)"
  case "$scr" in *"tab/shift-tab"*) pass "viewer draws its key bar" ;; *) fail "viewer draws its key bar" ;; esac
  case "$scr" in *$'\033[?1049h'*) pass "viewer uses the alternate screen" ;; *) fail "viewer uses the alternate screen" ;; esac
  case "$scr" in *$'\033[?1049l'*) pass "viewer restores the screen on quit" ;; *) fail "viewer restores the screen on quit" ;; esac
  mouse_on=$'\033[?1003h'
  case "$scr" in *"$mouse_on"*) fail "viewer enables mouse mode" ;; *) pass "viewer does not enable mouse mode" ;; esac
  case "$scr" in *$'\033[7m'" feature/456"*) pass "viewer opens on the worktree you are in" ;; *) fail "viewer opens on the worktree you are in" ;; esac
  (cd "$T/g1/main/core" && printf 'jjGq' | script -q /dev/null "$BASH" "$G" log >/dev/null 2>&1) \
    && pass "viewer scroll keys exit cleanly" || fail "viewer scroll keys exit cleanly"
fi

step "install.sh and uninstall.sh"
REPO="$(dirname "$G")"
# inst <home> [args...]: run install.sh with a throwaway HOME
inst() { local h="$1"; shift; HOME="$h" XDG_DATA_HOME="" SHELL=/bin/zsh "$BASH" "$REPO/install.sh" "$@" >/dev/null; }
# grep -c prints 0 AND exits non-zero when nothing matches, so swallow the status.
rc_lines() { [[ -f "$1" ]] || { echo 0; return; }; grep -c 'completions/ent.sh' "$1" || true; }

H="$T/home"; mkdir -p "$H"
printf 'export EDITOR=vim\n\nalias ll="ls -la"\n' >"$H/.zshrc"; cp "$H/.zshrc" "$T/zshrc.orig"
printf 'echo bashrc\n' >"$H/.bashrc";       cp "$H/.bashrc" "$T/bashrc.orig"
printf 'echo login\n' >"$H/.bash_profile";  cp "$H/.bash_profile" "$T/bash_profile.orig"
inst "$H"; inst "$H"     # twice: must stay idempotent
check "1" "$(rc_lines "$H/.zshrc")" "install sets up .zshrc once"
check "1" "$(rc_lines "$H/.bashrc")" "install sets up .bashrc once"
check "1" "$(rc_lines "$H/.bash_profile")" "login .bash_profile set up when it does not read .bashrc"
check "git-ent $("$BASH" "$G" --version | cut -d' ' -f2)" "$("$H/.local/bin/git-ent" --version)" "installed launcher runs"
expect_ok "ent.sh loads in bash" "$BASH" -c 'source "$1"; declare -f ent >/dev/null' _ "$H/.local/share/git-ent/completions/ent.sh"

HOME="$H" XDG_DATA_HOME="" "$BASH" "$H/.local/share/git-ent/uninstall.sh" -y >/dev/null
[[ ! -e "$H/.local/share/git-ent" && ! -e "$H/.local/bin/git-ent" ]] && pass "uninstall removes files" || fail "uninstall removes files"
cmp -s "$T/zshrc.orig" "$H/.zshrc" && pass "uninstall restores .zshrc exactly" || fail "uninstall restores .zshrc exactly"
cmp -s "$T/bashrc.orig" "$H/.bashrc" && pass "uninstall restores .bashrc exactly" || fail "uninstall restores .bashrc exactly"
cmp -s "$T/bash_profile.orig" "$H/.bash_profile" && pass "uninstall restores .bash_profile exactly" || fail "uninstall restores .bash_profile exactly"

step "install.sh: .bash_profile that already reads .bashrc is left alone"
H2="$T/home2"; mkdir -p "$H2"
printf 'echo rc\n' >"$H2/.bashrc"; printf '[ -f ~/.bashrc ] && . ~/.bashrc\n' >"$H2/.bash_profile"
cp "$H2/.bash_profile" "$T/bp2.orig"
inst "$H2"
check "1" "$(rc_lines "$H2/.bashrc")" "bashrc set up"
cmp -s "$T/bp2.orig" "$H2/.bash_profile" && pass ".bash_profile untouched when it reads .bashrc" || fail ".bash_profile untouched when it reads .bashrc"

step "install.sh: ZDOTDIR, --rc and --no-rc"
H3="$T/home3"; mkdir -p "$H3/.config/zsh"
HOME="$H3" XDG_DATA_HOME="" SHELL=/bin/zsh ZDOTDIR="$H3/.config/zsh" "$BASH" "$REPO/install.sh" >/dev/null
check "1" "$(rc_lines "$H3/.config/zsh/.zshrc")" "ZDOTDIR .zshrc set up"
[[ ! -e "$H3/.zshrc" ]] && pass "~/.zshrc left alone when ZDOTDIR is set" || fail "~/.zshrc left alone when ZDOTDIR is set"

H4="$T/home4"; mkdir -p "$H4"; printf 'echo mine\n' >"$H4/.zshrc"
inst "$H4" --rc "$H4/custom.zsh"
check "1" "$(rc_lines "$H4/custom.zsh")" "--rc sets up the named file"
check "0" "$(rc_lines "$H4/.zshrc")" "--rc skips the automatic files"
HOME="$H4" XDG_DATA_HOME="" "$BASH" "$H4/.local/share/git-ent/uninstall.sh" -y >/dev/null
check "0" "$(rc_lines "$H4/custom.zsh")" "uninstall cleans the --rc file (from its record)"

H5="$T/home5"; mkdir -p "$H5"; printf 'echo mine\n' >"$H5/.zshrc"; cp "$H5/.zshrc" "$T/zshrc5.orig"
inst "$H5" --no-rc
cmp -s "$T/zshrc5.orig" "$H5/.zshrc" && pass "--no-rc changes no startup file" || fail "--no-rc changes no startup file"

step "uninstall.sh cleans up an install made by an older version"
H6="$T/home6"; mkdir -p "$H6"
printf 'alias x=1\n\n# git-ent: the `ent` command, tab completion and prompt helper (added by install.sh)\nsource "$HOME/.local/share/git-ent/completions/ent.zsh"\n' >"$H6/.zshrc"
HOME="$H6" XDG_DATA_HOME="" "$BASH" "$REPO/uninstall.sh" -y >/dev/null
check "alias x=1" "$(cat "$H6/.zshrc")" "old ent.zsh line removed"


# ---------------------------------------------------------------------------
# ent init --here
# ---------------------------------------------------------------------------

# mkrepo <dir> [branch]: a clone with a remote, an ignored file, a stash and a
# local-only branch -- everything an in-place conversion has to carry across.
mkrepo() {
  local d="$1" br="${2:-main}"
  mkdir -p "$T/origin-src"
  if [[ ! -d "$T/origin-src/.git" ]]; then
    (cd "$T/origin-src" && git init -q -b main . && echo hi >README.md \
      && git add . && git -c commit.gpgsign=false commit -qm initial)
  fi
  git clone -q "$T/origin-src" "$d"
  (cd "$d" \
    && git checkout -q -b feature/local-only && echo l >l.txt && git add l.txt \
    && git -c commit.gpgsign=false commit -qm local && git checkout -q main \
    && printf 'node_modules/\n.env\n' >.gitignore && git add .gitignore \
    && git -c commit.gpgsign=false commit -qm ignore \
    && mkdir -p node_modules && echo payload >node_modules/x && echo secret >.env \
    && echo tostash >>README.md && git stash push -q -m ent-test-stash)
  if [[ "$br" != main ]]; then
    (cd "$d" && git checkout -q -b "$br" && echo b >b.txt && git add b.txt \
      && git -c commit.gpgsign=false commit -qm onbranch)
  fi
}

step "init --here converts a repo in place"
mkrepo "$T/adopt"
ent "$T/adopt" init --here -y >/dev/null 2>&1
[[ -d "$T/adopt/.bare" && -d "$T/adopt/main/core" ]] && pass "layout .bare + main/core" || fail "layout"
check "gitdir: ./.bare" "$(cat "$T/adopt/.git")" ".git is the pointer file"
check "main" "$(git -C "$T/adopt/main/core" branch --show-current)" "core is on main"
check "main" "$(git -C "$T/adopt" config ent.canopy)" "ent.canopy recorded"
check "" "$(git -C "$T/adopt/main/core" status --porcelain)" "converted worktree is clean"
check "payload" "$(cat "$T/adopt/main/core/node_modules/x" 2>/dev/null)" "ignored node_modules moved"
check "secret" "$(cat "$T/adopt/main/core/.env" 2>/dev/null)" "ignored .env moved"
check "1" "$(git -C "$T/adopt/main/core" stash list | grep -c ent-test-stash)" "stash survived"
check "origin/main" "$(git -C "$T/adopt/main/core" rev-parse --abbrev-ref '@{u}')" "upstream survived"
check "1" "$(git -C "$T/adopt" show-ref --verify -q refs/heads/feature/local-only && echo 1)" "local-only branch survived"
check "+refs/heads/*:refs/remotes/origin/*" "$(git -C "$T/adopt" config --get remote.origin.fetch)" "fetch refspec survived"
[[ ! -e "$T/adopt/.ent-stage" && ! -e "$T/adopt/.ent-convert-recovery.sh" ]] && pass "no scratch left behind" || fail "scratch left behind"

step "init --here really rebuilds the index"
# --no-checkout leaves the index empty; without the reset write-tree returns the
# empty tree, and a later `commit -a` would record the deletion of everything.
check "$(git -C "$T/adopt/main/core" rev-parse 'HEAD^{tree}')" \
      "$(git -C "$T/adopt/main/core" write-tree)" "index matches HEAD's tree"

step "the converted ent behaves like any other"
out="$(ent "$T/adopt/main/core" list 2>/dev/null)"
echo "$out" | grep -q "main" && pass "list works on a converted ent" || fail "list works on a converted ent"
ent "$T/adopt/main/core" branch feature/after >/dev/null 2>&1
[[ -d "$T/adopt/branches/feature/after/core" ]] && pass "branch works on a converted ent" || fail "branch on converted ent"
printf 'y\n' | ent "$T/adopt" rm feature/after >/dev/null 2>&1
[[ ! -d "$T/adopt/branches/feature/after" ]] && pass "rm works on a converted ent" || fail "rm on converted ent"

step "init --here refuses what it cannot convert safely"
mkrepo "$T/dirty"; echo scratch >>"$T/dirty/README.md"
expect_fail "refuses a dirty tree" "uncommitted changes" ent "$T/dirty" init --here -y
mkrepo "$T/detached"; (cd "$T/detached" && git checkout -q --detach HEAD)
expect_fail "refuses a detached HEAD" "HEAD is detached" ent "$T/detached" init --here -y
expect_fail "refuses an existing ent" "already an ent" ent "$T/adopt" init --here -y
mkrepo "$T/hasbare"; mkdir "$T/hasbare/.bare"
expect_fail "refuses a pre-existing .bare" "already exists and is not an ent" ent "$T/hasbare" init --here -y
mkrepo "$T/subdir"; mkdir -p "$T/subdir/deep"
expect_fail "refuses running from a subdirectory" "top of the repo" ent "$T/subdir/deep" init --here -y
expect_fail "refuses a linked worktree" "linked worktree" ent "$T/adopt/main/core" init --here -y

step "init --here -n changes nothing"
mkrepo "$T/dryrun"
ent "$T/dryrun" init --here -n >/dev/null 2>&1
[[ -d "$T/dryrun/.git" && ! -e "$T/dryrun/.bare" && ! -d "$T/dryrun/main" ]] \
  && pass "dry run left the repo alone" || fail "dry run changed something"

step "init --here parks a non-default branch and checks out the default"
mkrepo "$T/onbranch" feature/x
ent "$T/onbranch" init --here -y >/dev/null 2>&1
check "main" "$(git -C "$T/onbranch/main/core" branch --show-current)" "main/core is on the default branch"
check "feature/x" "$(git -C "$T/onbranch/branches/feature/x/core" branch --show-current)" "current branch parked in its own folder"
check "payload" "$(cat "$T/onbranch/branches/feature/x/core/node_modules/x" 2>/dev/null)" "ignored files went with the parked branch"
check "main" "$(git -C "$T/onbranch" config ent.canopy)" "ent.canopy is the default, not the parked branch"
[[ -d "$T/onbranch/branches/feature/x/twigs" ]] && pass "parked branch has a twigs sibling" || fail "parked branch twigs"
check "1" "$(git -C "$T/onbranch" log --oneline feature/x | grep -c onbranch)" "parked branch kept its commits"

step "init --here with extra worktrees: drop"
mkrepo "$T/wtdrop"
git -C "$T/wtdrop" worktree add -q "$T/wtdrop-side" feature/local-only 2>/dev/null
ent "$T/wtdrop" init --here -y --worktrees drop >/dev/null 2>&1
[[ -d "$T/wtdrop/main/core" ]] && pass "drop converted in place, name kept" || fail "drop converted in place"
[[ ! -d "$T/wtdrop-side" ]] && pass "drop removed the extra worktree folder" || fail "drop removed folder"
check "1" "$(git -C "$T/wtdrop" show-ref --verify -q refs/heads/feature/local-only && echo 1)" "drop kept the branch"

step "init --here with extra worktrees: move"
mkrepo "$T/wtmove"
git -C "$T/wtmove" worktree add -q "$T/wtmove-side" feature/local-only 2>/dev/null
ent "$T/wtmove" init --here -y --worktrees move >/dev/null 2>&1
[[ -d "$T/wtmove-ent/main/core" ]] && pass "move built <name>-ent" || fail "move built <name>-ent"
[[ -d "$T/wtmove-ent/branches/feature/local-only/core" ]] && pass "extra worktree became a branch folder" || fail "extra worktree became a branch folder"
[[ ! -d "$T/wtmove-side" ]] && pass "old worktree path is gone" || fail "old worktree path is gone"
check "" "$(git -C "$T/wtmove-ent/branches/feature/local-only/core" status --porcelain)" "moved worktree is clean"
check "l" "$(cat "$T/wtmove-ent/branches/feature/local-only/core/l.txt" 2>/dev/null)" "moved worktree has its files"

step "init --here prompts when worktrees exist and no flag is given"
mkrepo "$T/wtcancel"
git -C "$T/wtcancel" worktree add -q "$T/wtcancel-side" feature/local-only 2>/dev/null
printf 'c\n' | ent "$T/wtcancel" init --here >/dev/null 2>&1
[[ -d "$T/wtcancel/.git" && ! -e "$T/wtcancel/.bare" ]] && pass "cancel changed nothing" || fail "cancel changed something"

step "sparse-checkout does not brick an ent"
# git sparse-checkout sets extensions.worktreeConfig, which makes linked
# worktrees honour the shared core.bare=true unless each one overrides it.
mkrepo "$T/sparse"
ent "$T/sparse" init --here -y >/dev/null 2>&1
ent "$T/sparse/main/core" branch feature/sp >/dev/null 2>&1
(cd "$T/sparse/main/core" && git sparse-checkout set README.md >/dev/null 2>&1)
git -C "$T/sparse/main/core" status >/dev/null 2>&1 && pass "main/core still works after sparse-checkout" || fail "main/core bricked by sparse-checkout"
git -C "$T/sparse/branches/feature/sp/core" status >/dev/null 2>&1 && pass "branch still works after sparse-checkout" || fail "branch bricked by sparse-checkout"
ent "$T/sparse/main/core" branch feature/sp2 >/dev/null 2>&1
git -C "$T/sparse/branches/feature/sp2/core" status >/dev/null 2>&1 && pass "a branch made afterwards works" || fail "branch made after sparse-checkout is bricked"

step "a lone .bare folder is not an ent"
mkdir -p "$T/fake/.bare"
expect_fail "stray .bare is not an ent" "not inside an ent" ent "$T/fake" list
mkdir -p "$T/fakedeep/.bare" "$T/fakedeep/sub"
expect_fail "stray .bare above the cwd is not an ent" "not inside an ent" ent "$T/fakedeep/sub" list
printf 'gitdir: ./.bare\r\n' >"$T/adopt/.git"
out="$(ent "$T/adopt/main/core" list 2>/dev/null)"
echo "$out" | grep -q "main" && pass "a CRLF pointer still resolves" || fail "CRLF pointer"
printf 'gitdir: ./.bare\n' >"$T/adopt/.git"


step "init --here carries untracked files after a yes"
mkrepo "$T/untr"
echo note >"$T/untr/notes.txt"; mkdir -p "$T/untr/scratch"; echo 'select 1;' >"$T/untr/scratch/try.sql"
ent "$T/untr" init --here -y >/dev/null 2>&1
[[ -f "$T/untr/main/core/notes.txt" ]] && pass "untracked file moved" || fail "untracked file moved"
[[ -f "$T/untr/main/core/scratch/try.sql" ]] && pass "untracked file in a subfolder moved" || fail "untracked subfolder file moved"
[[ -f "$T/untr/main/core/node_modules/x" ]] && pass "ignored file still moved too" || fail "ignored file moved"
check "?? notes.txt
?? scratch/" "$(git -C "$T/untr/main/core" status --porcelain)" "they are still untracked, and nothing else changed"
check "$(git -C "$T/untr/main/core" rev-parse 'HEAD^{tree}')" \
      "$(git -C "$T/untr/main/core" write-tree)" "index still matches HEAD's tree"

step "init --here leaves the repo alone when the answer is no"
mkrepo "$T/untrno"; echo note >"$T/untrno/notes.txt"
printf 'n\n' | ent "$T/untrno" init --here >/dev/null 2>&1
[[ -d "$T/untrno/.git" && ! -e "$T/untrno/.bare" ]] && pass "declining changed nothing" || fail "declining changed nothing"
[[ -f "$T/untrno/notes.txt" ]] && pass "the untracked file stayed put" || fail "untracked file stayed put"

step "init --here will not guess when there is nobody to ask"
mkrepo "$T/untrtty"; echo note >"$T/untrtty/notes.txt"
ent "$T/untrtty" init --here </dev/null >/dev/null 2>&1
[[ -d "$T/untrtty/.git" && ! -e "$T/untrtty/.bare" ]] && pass "no answer means no" || fail "no answer means no"

step "init --here -n lists untracked files and changes nothing"
mkrepo "$T/untrdry"; echo note >"$T/untrdry/notes.txt"
out="$(ent "$T/untrdry" init --here -n 2>&1)"
echo "$out" | grep -q "notes.txt" && pass "dry run names the untracked file" || fail "dry run names the untracked file"
echo "$out" | grep -q "untracked file" && pass "dry run says how many" || fail "dry run says how many"
[[ -d "$T/untrdry/.git" && ! -e "$T/untrdry/.bare" ]] && pass "dry run changed nothing" || fail "dry run changed nothing"

step "tracked changes still stop the conversion"
mkrepo "$T/untrmod"; echo more >>"$T/untrmod/README.md"; echo note >"$T/untrmod/notes.txt"
expect_fail "modified tracked file still refused" "uncommitted changes" ent "$T/untrmod" init --here -y

step "untracked files follow a parked branch"
mkrepo "$T/untrpark" feature/x
echo note >"$T/untrpark/notes.txt"
ent "$T/untrpark" init --here -y >/dev/null 2>&1
[[ -f "$T/untrpark/branches/feature/x/core/notes.txt" ]] && pass "untracked file went with the parked branch" || fail "untracked file parked"
[[ ! -f "$T/untrpark/main/core/notes.txt" ]] && pass "and not into main/core" || fail "untracked file leaked into main/core"

step "drop refuses to delete a worktree holding untracked files"
mkrepo "$T/wtu"
git -C "$T/wtu" worktree add -q "$T/wtu-side" feature/local-only 2>/dev/null
echo keepme >"$T/wtu-side/keepme.txt"
expect_fail "drop refuses when it would delete untracked work" "would delete them" ent "$T/wtu" init --here -y --worktrees drop
[[ -f "$T/wtu-side/keepme.txt" ]] && pass "the untracked file is still there" || fail "untracked file destroyed"
[[ -d "$T/wtu/.git" && ! -e "$T/wtu/.bare" ]] && pass "and the repo is untouched" || fail "repo changed despite refusal"

step "move carries a worktree's untracked files along"
ent "$T/wtu" init --here -y --worktrees move >/dev/null 2>&1
[[ -f "$T/wtu-ent/branches/feature/local-only/core/keepme.txt" ]] && pass "untracked file moved with the worktree" || fail "untracked file moved with the worktree"


# ---------------------------------------------------------------------------
# Round 3: the cloud review findings, navigation, and folderless branches
# ---------------------------------------------------------------------------

step "drop waits for the final yes before removing anything"
# The removals used to run inside the worktree question, so answering no to
# "Convert?" afterwards left the folders already deleted.
mkrepo "$T/dropno"
git -C "$T/dropno" worktree add -q "$T/dropno-side" feature/local-only 2>/dev/null
printf 'd\nn\n' | ent "$T/dropno" init --here >/dev/null 2>&1
[[ -d "$T/dropno-side" ]] && pass "saying no kept the worktree folder" || fail "saying no deleted the worktree folder"
[[ -d "$T/dropno/.git" && ! -e "$T/dropno/.bare" ]] && pass "and the repo is untouched" || fail "repo changed after cancelling"
printf 'd\ny\n' | ent "$T/dropno" init --here >/dev/null 2>&1
[[ ! -d "$T/dropno-side" ]] && pass "saying yes does remove it" || fail "yes did not remove it"
[[ -d "$T/dropno/main/core" ]] && pass "and converts in place" || fail "yes did not convert"

step "a kept worktree on the default branch becomes main/core"
# main/core used to be created while that worktree still held the branch, so
# git refused -- and it failed after the rollback trap was already disarmed.
mkrepo "$T/wtdef" feature/x
git -C "$T/wtdef" worktree add -q "$T/wtdef-main" main 2>/dev/null
ent "$T/wtdef" init --here -y --worktrees move >/dev/null 2>&1
[[ -d "$T/wtdef-ent/main/core" ]] && pass "main/core exists" || fail "main/core exists"
check "main" "$(git -C "$T/wtdef-ent/main/core" branch --show-current 2>/dev/null)" "main/core is on the default branch"
[[ ! -d "$T/wtdef-ent/branches/main" ]] && pass "no branches/main was created" || fail "a second main folder was created"
[[ ! -d "$T/wtdef-main" ]] && pass "the old worktree path is gone" || fail "old worktree path still there"
check "feature/x" "$(git -C "$T/wtdef-ent/branches/feature/x/core" branch --show-current 2>/dev/null)" "the parked branch kept its folder"

step "kept worktrees get the core.bare guard too"
mkrepo "$T/wtsparse"
git -C "$T/wtsparse" worktree add -q "$T/wtsparse-side" feature/local-only 2>/dev/null
(cd "$T/wtsparse" && git sparse-checkout set README.md >/dev/null 2>&1)
ent "$T/wtsparse" init --here -y --worktrees move >/dev/null 2>&1
git -C "$T/wtsparse-ent/branches/feature/local-only/core" status >/dev/null 2>&1 \
  && pass "the moved worktree still works with worktreeConfig on" || fail "moved worktree bricked by worktreeConfig"

step "a worktree inside the repo is refused for move"
mkrepo "$T/wtnest"
git -C "$T/wtnest" worktree add -q "$T/wtnest/sub" feature/local-only 2>/dev/null
expect_fail "move refuses a worktree inside the repo" "inside the repo being converted" \
  ent "$T/wtnest" init --here -y --worktrees move
[[ -d "$T/wtnest/.git" && ! -e "$T/wtnest/.bare" ]] && pass "the repo is untouched" || fail "repo changed despite refusal"
[[ -d "$T/wtnest/sub" ]] && pass "the nested worktree is untouched" || fail "nested worktree changed"
ent "$T/wtnest" init --here -y --worktrees drop >/dev/null 2>&1
[[ -d "$T/wtnest/main/core" ]] && pass "drop still converts it" || fail "drop failed on a nested worktree"

step "cancel does not complain about uncommitted work"
mkrepo "$T/wtcancel2"
git -C "$T/wtcancel2" worktree add -q "$T/wtcancel2-side" feature/local-only 2>/dev/null
echo dirty >>"$T/wtcancel2-side/l.txt"
out="$(printf 'c\n' | ent "$T/wtcancel2" init --here 2>&1)"
echo "$out" | grep -q "Cancelled" && pass "cancel says cancelled" || fail "cancel says cancelled: $(echo "$out" | tail -1)"
echo "$out" | grep -q "uncommitted changes" && fail "cancel still mentions uncommitted changes" || pass "cancel does not mention uncommitted changes"
[[ -d "$T/wtcancel2/.git" && ! -e "$T/wtcancel2/.bare" ]] && pass "cancel changed nothing" || fail "cancel changed something"

step "up and down are no longer dead ends"
check "$(Norm "$T/g1/main/core")" "$(ent "$T/g1" up)" "up from the ent root lands on main/core"
check "$(Norm "$T/g1/main/core")" "$(ent "$T/g1/branches" up)" "up from a bare container lands on main/core"
check "$(Norm "$T/g1")" "$(ent "$T/g1/branches/feature/ok/core" up)" "up from a branch still goes to the ent root"
out="$(ent "$T/g1/branches/feature/ok/core" down 2>&1)"
echo "$out" | grep -q "no children to move down into" && pass "down still says no children" || fail "down wording changed"
echo "$out" | grep -q "ent go" && pass "down points at ent go" || fail "down does not point at ent go"

step "a branch with no worktree is visible, unreachable, and recoverable"
ent "$T/g1" branch feature/lonely >/dev/null 2>&1
# How you actually end up here: the folder goes by hand, and git prunes the
# registration. The branch itself is untouched.
rm -rf "$T/g1/branches/feature/lonely"
git -C "$T/g1" worktree prune
check "1" "$(git -C "$T/g1" show-ref --verify -q refs/heads/feature/lonely && echo 1)" "the branch itself survived"
check "" "$(git -C "$T/g1" worktree list --porcelain | grep -c 'feature/lonely' | sed 's/^0$//')" "its worktree really is gone"
out="$(ent "$T/g1" list 2>/dev/null)"
echo "$out" | grep -q "feature/lonely \[no worktree\]" \
  && pass "list marks it [no worktree]" || fail "list marks it: $(echo "$out" | grep lonely)"
expect_fail "go refuses a branch with no worktree" "has no worktree" ent "$T/g1" go feature/lonely
ent "$T/g1" branch feature/lonely >/dev/null 2>&1
[[ -d "$T/g1/branches/feature/lonely/core" ]] && pass "branch gave it a folder back" || fail "branch did not adopt it"
check "feature/lonely" "$(git -C "$T/g1/branches/feature/lonely/core" branch --show-current 2>/dev/null)" "the folder is on that same branch"
[[ -d "$T/g1/branches/feature/lonely/twigs" ]] && pass "and has a twigs sibling" || fail "no twigs sibling"
out="$(ent "$T/g1" list 2>/dev/null)"
echo "$out" | grep -q "feature/lonely \[no worktree\]" \
  && fail "still marked [no worktree] after adoption" || pass "the mark is gone after adoption"
expect_fail "a branch that still has a worktree is refused" "already exists" ent "$T/g1" branch feature/lonely
step "init --here and the folder your shell is standing in"
# Windows cannot rename a folder a process is sitting in, so --here refuses
# rather than failing halfway. Unix has no such rule, so there it just works.
mkrepo "$T/stand"; mkdir -p "$T/stand/sub"
if windows_only "refuses while standing inside the repo"; then
  expect_fail "refuses while standing inside the repo" "standing in" \
    ent "$T/stand/sub" init --here "$T/stand"
  [[ -d "$T/stand/.git" && ! -e "$T/stand/.bare" ]] && pass "the repo was left alone" || fail "the repo was left alone"
fi
if unix_only "converts while standing inside the repo"; then
  ent "$T/stand/sub" init --here -y "$T/stand" >/dev/null 2>&1
  [[ -d "$T/stand/.bare" && -d "$T/stand/main/core" ]] && pass "converts while standing inside the repo" || fail "converts while standing inside the repo"
fi
step "ent init . points at --here instead of nesting"
mkrepo "$T/nest"
expect_fail "init . refuses to nest inside the source" "ent init --here" ent "$T/nest" init .
echo
if (( bad )); then
  echo "SOME FAILURES ($n checks, $skipped skipped)"
  exit 1
else
  echo "$n checks, $skipped skipped, ALL PASS"
  exit 0
fi
