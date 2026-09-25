# ent architecture refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `ent` to use an explicit JSON-backed node tree for branches/twigs, add logging, cross-ent navigation, better command organization, and the minor UX improvements defined in the spec.

**Architecture:** A new `lib/tree.sh` module owns `.bare/ent.json`. `lib/state.sh` and `lib/paths.sh` are rebuilt on top of it. `lib/core.sh` is split into focused shared modules. Each `lib/cmd/<verb>.sh` gains its own `parse_<verb>_args` function. Shell integration files read the node tree for completion, and `ent go` resolves roots from a shared roots file in the ent installation directory.

**Tech Stack:** bash 3.2+, git 2.20+, POSIX/awk utilities available in the git-for-windows bundle.

**Spec:** `docs/ent-architecture-design.md`

## Global Constraints

- bash 3.2+ compatibility: no associative arrays, no `return` arrays, no `mapfile`.
- No new run-time dependencies such as `jq` or Python; JSON parsing is done with embedded `awk`.
- Works on macOS `/bin/bash`, Linux bash 5, and Git Bash on Windows.
- stdout is reserved for paths the shell wrapper will `cd` into; all user messages go to stderr.
- Any process that mutates `.bare/ent.json` must acquire the advisory lock first.

## Review Focus

1. **Bootstrapping an existing ent without `.bare/ent.json`** — an older ent must load correctly on the first run.
2. **Git Bash path normalization** — paths with `/c/x` vs `C:/x` must not break node matching.
3. **Concurrent commands** — two `ent` processes running at the same time must not corrupt `.bare/ent.json`.
4. **Auto-adoption of a folderless branch** — a branch made by plain git must be usable without manual `ent branch <name>`.
5. **Cross-ent `go` when the roots file is empty** — the user expects sibling-directory discovery to work on first use.

---

## File structure

| File | Responsibility after refactor |
|------|-------------------------------|
| `lib/tree.sh` | Parse, lock, mutate, and query `.bare/ent.json`. |
| `lib/state.sh` | Git state snapshot plus unfinished-operation detection, driven by the node tree. |
| `lib/paths.sh` | Branch/path resolution using the node tree; no `ent_slug`. |
| `lib/log.sh` | Per-ent and global logging with timestamps and `caller` locations. |
| `lib/output.sh` | `say`/`note`/`warn`/`die`/`fmt_cmd` and color setup. |
| `lib/run.sh` | `run`/`runat`/`worktree_bare_guard` and dry-run awareness. |
| `lib/prompt.sh` | `confirm`/`choose`. |
| `lib/args.sh` | Global flag parsing and `arg()`. |
| `lib/core.sh` | Optional aggregator that sources the four modules above, then removes itself in a later cleanup pass. |
| `lib/cmd/<verb>.sh` | Each file defines `help_<verb>`, `parse_<verb>_args`, and `cmd_<verb>`. |
| `git-ent` | Updated loader, dispatches commands, exposes internal helpers for completion. |
| `completions/ent.bash` / `ent.zsh` | Branch/twig completion from `.bare/ent.json`. |
| `ent.test.sh` | Extended test suite. |
| `~/.local/share/git-ent/roots` | Auto-maintained cross-ent roots list. |

---

### Task 1: Cut the feature branch

**Files:**
- Modify: N/A (branch creation only)

**Interfaces:** None.

- [ ] **Step 1: Create and switch to `feature/architecture`**

```bash
git checkout -b feature/architecture
```

- [ ] **Step 2: Commit the approved design spec**

```bash
git add docs/ent-architecture-design.md
git commit -m "docs: architecture redesign spec for feature/architecture"
```

- [ ] **Step 3: Verify branch state**

```bash
git branch --show-current
```

Expected: `feature/architecture`

---

### Task 2: JSON-backed node tree module

**Files:**
- Create: `lib/tree.sh`
- Modify: `git-ent` (source the new module)
- Test: `ent.test.sh` (Task 2 tests)

**Interfaces:**
- Consumes: `lib/output.sh` for warnings.
- Produces: `tree_load`, `tree_canopy`, `tree_parent_of`, `tree_children_of`, `tree_worktree_of`, `tree_node_exists`, `tree_add_node`, `tree_remove_node`, `tree_adopt_if_missing`, `tree_lock`, `tree_unlock`.

- [ ] **Step 1: Write a failing node-tree load test**

In `ent.test.sh`, after the existing setup, add:

```bash
step "node tree loads from .bare/ent.json"
source "$(dirname "$G")/lib/output.sh" >/dev/null 2>&1
source "$(dirname "$G")/lib/tree.sh" >/dev/null 2>&1
ENT="$(Norm "$T/g1")"
cat >"$ENT/.bare/ent.json" <<'JSON'
{
  "canopy": "main",
  "nodes": {
    "main": { "type": "canopy", "parent": null, "children": ["feature/x"], "worktree": "main/core" },
    "feature/x": { "type": "branch", "parent": "main", "children": [], "worktree": "branches/feature/x/core" }
  }
}
JSON
tree_load
[[ "$(tree_canopy)" == "main" ]] && pass "tree_canopy" || fail "tree_canopy"
tree_parent_of "feature/x"; [[ "$REPLY" == "main" ]] && pass "tree_parent_of" || fail "tree_parent_of"
tree_children_of "main"; [[ "${REPLY_LIST[*]}" == "feature/x" ]] && pass "tree_children_of" || fail "tree_children_of"
tree_worktree_of "feature/x"; [[ "$REPLY" == "branches/feature/x/core" ]] && pass "tree_worktree_of" || fail "tree_worktree_of"
```

Run: `bash ent.test.sh`  
Expected: failures because `lib/tree.sh` does not exist yet.

- [ ] **Step 2: Implement `lib/tree.sh`**

Create `lib/tree.sh`.
Requirements:
- Use embedded `awk` scripts (not `jq`) to read and write the restricted JSON schema documented in the spec.
- Keep data in parallel arrays (`T_NAME[]`, `T_TYPE[]`, `T_PARENT[]`, `T_CHILDREN[]`, `T_WORKTREE[]`).
- Lookups set `REPLY` / `REPLY_LIST` instead of printing.
- `tree_add_node` / `tree_remove_node` must lock/unlock around the read-modify-write sequence.
- `tree_adopt_if_missing` checks `has_local` and, if the branch exists but the node does not, creates the worktree and node.

- [ ] **Step 3: Source `lib/tree.sh` from `git-ent`**

Add `tree` to the module source loop in `git-ent`.

- [ ] **Step 4: Run the test suite**

```bash
bash ent.test.sh
```

Expected: Task 2 tests pass and earlier tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/tree.sh git-ent ent.test.sh
git commit -m "feat(lib/tree): add JSON-backed node tree module"
```

---

### Task 3: Advisory lock for `.bare/ent.json`

**Files:**
- Create: `lib/tree.sh` additions (if not done in Task 2)
- Modify: `lib/tree.sh`
- Test: `ent.test.sh`

**Interfaces:**
- Produces: `tree_lock`, `tree_unlock`.

- [ ] **Step 1: Write a concurrent-write test**

In `ent.test.sh`, add:

```bash
step "concurrent writes to ent.json do not corrupt the file"
source "$(dirname "$G")/lib/tree.sh" >/dev/null 2>&1
ENT="$(Norm "$T/g1")"
for i in 1 2 3; do
  (tree_add_node "concurrent$i" branch main "branches/concurrent$i/core" || true) &
done
wait
tree_load
n=0; for x in ${T_NAME[@]+"${T_NAME[@]}"}; do n=$((n+1)); done
(( n >= 3 )) && pass "concurrent writes survived" || fail "concurrent writes corrupted node list"
```

Run: `bash ent.test.sh`  
Expected: fail or be racy before lock is implemented.

- [ ] **Step 2: Implement `tree_lock` / `tree_unlock`**

Use `mkdir "$ENT/.bare/ent.json.lock"` as an atomic advisory lock. If the lock already exists, retry briefly and optionally break a stale lock by checking its age. Release by `rmdir`.

- [ ] **Step 3: Use the lock in every mutating function**

Ensure `tree_add_node`, `tree_remove_node`, and `tree_adopt_if_missing` call `tree_lock` before reading `.bare/ent.json` and `tree_unlock` after writing it.

- [ ] **Step 4: Run tests**

```bash
bash ent.test.sh
```

Expected: lock test passes consistently.

- [ ] **Step 5: Commit**

```bash
git add lib/tree.sh ent.test.sh
git commit -m "feat(lib/tree): add advisory lock for ent.json"
```

---

### Task 4: Rebuild `lib/state.sh` and `lib/paths.sh` on the node tree

**Files:**
- Modify: `lib/state.sh`, `lib/paths.sh`
- Test: `ent.test.sh`

**Interfaces:**
- Consumes: `lib/tree.sh` functions.
- Produces: same public API surface as today (`load_state`, `state_of`, `parent_of`, `children_of`, `wt_path_of`, `ent_root`, `ent_core`, `ent_container`, etc.).

- [ ] **Step 1: Write tests for path and state lookups against the tree**

In `ent.test.sh`, add:

```bash
step "state and paths resolve from the node tree"
ENT="$(Norm "$T/g1")"
cd "$ENT/main/core"
source "$(dirname "$G")/lib/paths.sh" >/dev/null 2>&1
load_state
[[ "$(ent_canopy)" == "main" ]] && pass "ent_canopy" || fail "ent_canopy"
[[ "$(ent_core feature/a)" == "$(Norm "$ENT/branches/feature/a/core")" ]] && pass "ent_core from tree" || fail "ent_core from tree"
```

Run: `bash ent.test.sh`  
Expected: fails because functions are not updated yet.

- [ ] **Step 2: Rebuild `lib/state.sh`**

- Load the node tree via `tree_load`.
- Replace `parent_of`, `children_of`, `wt_path_of`, etc. with tree-backed implementations.
- Keep Git worktree scanning only for:
  - validating that node worktree paths still match `git worktree list`,
  - detecting unfinished operations (merging, rebasing, etc.) only for managed worktrees.
- Keep local/remote branch arrays for `--remote` and validation.

- [ ] **Step 3: Rebuild `lib/paths.sh`**

- Keep `ent_norm`, `ent_abs_path`, `ent_root`, `is_ent_root`.
- Replace `ent_container`, `ent_core`, `ent_parent_core`, `ent_branch_of_cwd`, `ent_branch_of_core` with tree-backed implementations.
- Remove `ent_slug`.
- Keep `ent_twigname` for twig short-name matching.

- [ ] **Step 4: Run tests**

```bash
bash ent.test.sh
```

Expected: existing path/state tests plus new tree-based tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/state.sh lib/paths.sh ent.test.sh
git commit -m "refactor(state,paths): drive state and paths from node tree"
```

---

### Task 5: Rename `ent.main` to `ent.canopy`

**Files:**
- Modify: `lib/tree.sh`, `lib/cmd/init.sh`, `lib/cmd/branch.sh`, `ent.test.sh`
- Test: `ent.test.sh`

**Interfaces:**
- `tree_canopy()` replaces `ent_main()`.
- Config key becomes `ent.canopy`; old `ent.main` is only read during bootstrap.

- [ ] **Step 1: Update all `ent.main` references**

Search and replace in source files:

```bash
grep -R "ent\.main" lib/ git-ent
```

Change writes to use `ent.canopy`. Reads should prefer `ent.canopy` and fall back to `ent.main` only once (during bootstrap in `tree_load`).

- [ ] **Step 2: Add a canopy test**

In `ent.test.sh`:

```bash
step "canopy config key replaces ent.main"
[[ "$(git -C "$T/g1/.bare" config ent.canopy)" == "main" ]] && pass "canopy recorded" || fail "canopy recorded"
[[ -z "$(git -C "$T/g1/.bare" config ent.main 2>/dev/null || true)" ]] && pass "ent.main removed" || fail "ent.main removed"
```

Run: `bash ent.test.sh`  
Expected: the new tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/ git-ent ent.test.sh
git commit -m "refactor: rename ent.main to ent.canopy"
```

---

### Task 6: Add logging (`lib/log.sh`)

**Files:**
- Create: `lib/log.sh`
- Modify: `lib/output.sh` (split from `core.sh`), `git-ent`, `install.sh` (create `~/.config/ent` if needed)
- Test: `ent.test.sh`

**Interfaces:**
- Produces: `log_info`, `log_warn`, `log_error`, `log_global`.

- [ ] **Step 1: Split `lib/core.sh` into modules**

Move output/color functions to `lib/output.sh`, run/dry-run helpers to `lib/run.sh`, prompts to `lib/prompt.sh`, and global parsing to `lib/args.sh`. Update `git-ent` to source these instead of `core.sh`. Keep `lib/core.sh` as a temporary aggregator that sources them all, to avoid breaking external callers.

- [ ] **Step 2: Implement `lib/log.sh`**

- Determine log target:
  - If `ENT` is set: `$ENT/.bare/ent.log`.
  - Else: `~/.config/ent/global.log`.
- Format: `[<ISO-8601>] [<LEVEL>] [<script>:<line>] <message>`.
- `caller` provides script/line in bash functions.

- [ ] **Step 3: Integrate logging**

- `note()` → `log_info`.
- `warn()` → `log_warn`.
- `die()` → `log_error` before exit.

- [ ] **Step 4: Add logging tests**

In `ent.test.sh`:

```bash
step "logging writes to per-ent log"
[[ -f "$T/g1/.bare/ent.log" ]] && pass "per-ent log exists" || fail "per-ent log exists"
grep -q "INFO" "$T/g1/.bare/ent.log" && pass "info entries written" || fail "info entries written"
```

Also test the global log by running `git-ent` outside an ent.

- [ ] **Step 5: Run tests**

```bash
bash ent.test.sh
```

Expected: logging outputs appear where expected.

- [ ] **Step 6: Commit**

```bash
git add lib/log.sh lib/output.sh lib/run.sh lib/prompt.sh lib/args.sh lib/core.sh git-ent ent.test.sh
git commit -m "feat(log): add per-ent and global logging, split core.sh"
```

---

### Task 7: Per-command flag parsing

**Files:**
- Modify: `lib/args.sh`, `lib/cmd/*.sh`, `git-ent`
- Test: `ent.test.sh`

**Interfaces:**
- `parse_globals` handles `-n`, `-v`, `-q`, `-h`, `-y`, `--version`.
- Each `lib/cmd/<verb>.sh` defines `parse_<verb>_args` for its own flags.

- [ ] **Step 1: Reduce `parse_args` to `parse_globals`**

Move command-specific flags (`--from`, `--remote`, `--worktrees`, `--force`, `--recursive`, `--abort`, `--continue`, `--win`, `--here`) out of `lib/args.sh`. After dispatch, `cmd_<verb>` calls `parse_<verb>_args` on the remaining token stream.

- [ ] **Step 2: Add `parse_<verb>_args` to each command file**

For example, in `lib/cmd/branch.sh`:

```bash
parse_branch_args() {
  case "$1" in
    --from) FROM="$2"; shift 2; parse_branch_args "$@" ;;
    --remote) REMOTE="$2"; shift 2; parse_branch_args "$@" ;;
    *) [[ -n "$1" ]] && ARGS+=("$1"); shift; [[ $# -gt 0 ]] && parse_branch_args "$@" ;;
  esac
}
```

Repeat for init/twig/rm/sync/merge/destroy as needed.

- [ ] **Step 3: Add tests**

Add tests that command-specific flags work and that unknown flags produce clear errors.

- [ ] **Step 4: Run tests**

```bash
bash ent.test.sh
```

Expected: all parsing tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ git-ent ent.test.sh
git commit -m "refactor(args): move command-specific flags into per-command parsers"
```

---

### Task 8: Auto-adoption and marker renames

**Files:**
- Modify: `lib/tree.sh`, `lib/cmd/list.sh`, `lib/cmd/go.sh`, `lib/cmd/nav.sh`
- Test: `ent.test.sh`

**Interfaces:**
- `tree_adopt_if_missing` is called by any command that resolves a branch.

- [ ] **Step 1: Implement auto-adoption**

When `wt_path_of` / `ent_core` / navigation functions are asked for a branch that exists in Git but has no node, call `tree_adopt_if_missing` and retry. If adoption fails, `die` with a clear message.

- [ ] **Step 2: Remove `[no worktree]` and rename markers**

In `lib/cmd/list.sh`:
- Delete the `[no worktree]` label.
- Rename `[?]` to `[relocated]`.
- Rename `[!]` to `[orphan]`.

- [ ] **Step 3: Add tests**

```bash
step "folderless branch is auto-adopted"
mkdir -p "$T/auto"; cd "$T/auto" && git init -q -b main .
touch README.md && git add README.md && git commit -qm init
"$BASH" "$G" init --here -y >/dev/null 2>&1
git -C "$T/auto/.bare" branch from-plain-git >/dev/null 2>&1
out=$("$BASH" "$G" list)
echo "$out" | grep -q "from-plain-git" && pass "auto-adopted branch appears" || fail "list auto-adopt"
```

- [ ] **Step 4: Run tests**

```bash
bash ent.test.sh
```

Expected: auto-adoption works and markers display correctly.

- [ ] **Step 5: Commit**

```bash
git add lib/tree.sh lib/cmd/list.sh lib/cmd/go.sh lib/cmd/nav.sh ent.test.sh
git commit -m "feat(tree,list,go): auto-adopt folderless branches, rename markers"
```

---

### Task 9: Cross-ent navigation

**Files:**
- Modify: `lib/cmd/nav.sh`, `install.sh`
- Modify: `lib/tree.sh` or add `lib/roots.sh`
- Test: `ent.test.sh`

**Interfaces:**
- `ensure_root_registered()` appends current root to `~/.local/share/git-ent/roots`.
- `resolve_other_ent <basename>` returns an ent root path in `REPLY`.

- [ ] **Step 1: Create the roots helper**

Functions:
- `roots_register <ent-root>` — append if missing.
- `roots_find <basename>` — scan roots file and sibling directory.

Paths are stored normalized (`ent_norm`) to avoid duplicates across path spellings.

- [ ] **Step 2: Register root on every `ensure_ent`**

Call `roots_register` inside `ensure_ent` after finding the root.

- [ ] **Step 3: Extend `cmd_go`**

If the argument contains `/`, split into basename and branch/twig. Otherwise basename only means target `main/core`. Resolve basename with `roots_find`, then run `git-ent` in the target ent to resolve the inner branch.

- [ ] **Step 4: Add tests**

Create two ents in the temp folder and verify `ent go <other>/<branch>` prints the right path.

- [ ] **Step 5: Run tests**

```bash
bash ent.test.sh
```

Expected: cross-ent navigation passes.

- [ ] **Step 6: Commit**

```bash
git add lib/ git-ent ent.test.sh
git commit -m "feat(nav): cross-ent go with auto-maintained roots list"
```

---

### Task 10: `ent sync` multiple targets

**Files:**
- Modify: `lib/cmd/sync.sh`
- Test: `ent.test.sh`

**Interfaces:**
- `cmd_sync` accepts zero or more names; `sync_main` still runs once; `sync_worktrees` loops over the provided list or all.

- [ ] **Step 1: Update `cmd_sync` to consume remaining positional args as targets**

```bash
local targets=()
if [[ -n "$(arg 1)" ]]; then
  targets=("$(arg 1)" $(arg 2) $(arg 3) ... )
fi
```

In bash 3.2, collect remaining `ARGS` after the verb into `targets`.

- [ ] **Step 2: Update `sync_worktrees` to accept a target list**

If `targets` is empty, use all managed nodes; otherwise loop over the supplied names and verify each exists.

- [ ] **Step 3: Add test**

Create a test that runs `ent sync branch1 branch2` and confirms only those two worktrees receive the merge.

- [ ] **Step 4: Run tests**

```bash
bash ent.test.sh
```

Expected: sync list test passes and existing sync tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd/sync.sh ent.test.sh
git commit -m "feat(sync): allow ent sync to target multiple branches"
```

---

### Task 11: Full-screen viewer always shows tab bar

**Files:**
- Modify: `lib/view.sh`
- Test: `ent.test.sh`

**Interfaces:**
- `_view_tabs` must always render at least the selected tab.

- [ ] **Step 1: Adjust `_view_tabs` for the single-tab case**

Ensure that when `n == 1`, the tab bar still prints the selected tab instead of an empty bar.

- [ ] **Step 2: Add/update viewer test**

The existing `viewer tab bar fits the window` test currently uses multiple tabs. Add a similar check with a single tab.

- [ ] **Step 3: Run tests**

```bash
bash ent.test.sh
```

Expected: tab bar tests pass for 1 and N tabs.

- [ ] **Step 4: Commit**

```bash
git add lib/view.sh ent.test.sh
git commit -m "fix(viewer): always render the tab bar, even for one worktree"
```

---

### Task 12: Tab completion from `.bare/ent.json`

**Files:**
- Modify: `completions/ent.bash`, `completions/ent.zsh`
- Modify: `git-ent` (add `__list` internal verb)
- Test: manual or `ent.test.sh` completion checks

**Interfaces:**
- `git-ent __list` prints managed branch/twig names, one per line.

- [ ] **Step 1: Add `__list` internal verb**

In `git-ent`, dispatch `__list` to a new `cmd_list_internal` that prints node names.

- [ ] **Step 2: Update bash completion**

Change `_git_ent_branches` to use `git-ent __list` when inside an ent, otherwise fall back to `git for-each-ref`.

- [ ] **Step 3: Update zsh completion**

Same pattern: populate `branches` from `git-ent __list`.

- [ ] **Step 4: Test completion**

Add an `expect_ok` test that sources `completions/ent.bash` and verifies the `ent` function and completion function are defined.

- [ ] **Step 5: Commit**

```bash
git add completions/ git-ent ent.test.sh
git commit -m "feat(completion): complete branches and twigs from ent.json"
```

---

### Task 13: Remove `ent_slug` and support twig short names

**Files:**
- Modify: `lib/paths.sh`, `lib/cmd/nav.sh`, `lib/cmd/go.sh`
- Test: `ent.test.sh`

**Interfaces:**
- No `ent_slug` function remains.

- [ ] **Step 1: Remove `ent_slug` from `lib/paths.sh`**

- [ ] **Step 2: Update call sites**

In `go` and `down`, match by full name or twig short name only.

- [ ] **Step 3: Update tests**

- Change any existing test that uses slug shorthand to use the full name.
- Keep tests for twig short names.

- [ ] **Step 4: Commit**

```bash
git add lib/paths.sh lib/cmd/nav.sh lib/cmd/go.sh ent.test.sh
git commit -m "refactor(nav): remove ent_slug shorthand, keep full names and twig short names"
```

---

### Task 14: Integration and CI pass

**Files:**
- All of the above.

- [ ] **Step 1: Run the full test suite locally**

```bash
bash ent.test.sh
```

Expected:

```text
ALL PASS
```

- [ ] **Step 2: Run shellcheck on new/modified scripts**

If `shellcheck` is available:

```bash
shellcheck lib/*.sh lib/cmd/*.sh git-ent
```

Fix any warnings that are real errors. Ignore SC style-only issues that conflict with bash 3.2 compatibility.

- [ ] **Step 3: Push the feature branch**

```bash
git push origin feature/architecture
```

- [ ] **Step 4: Verify CI**

Check the GitHub Actions run for `feature/architecture` and ensure macOS bash 3.2, Linux bash 5, and Windows Git Bash all pass.

---

## Self-review checklist

- [ ] **Spec coverage:** every section of `docs/ent-architecture-design.md` maps to at least one task above.
- [ ] **No placeholders:** the plan contains no TBDs, TODOs, or "handle edge cases" without specification.
- [ ] **Type consistency:** function names (`tree_load`, `tree_children_of`, `ent_canopy`, etc.) match between Task 2 and consuming tasks.
- [ ] **Review Focus tests:** each of the five review-focus items has a test step in the owning task (bootstrap in Task 2, path normalization in Task 4, concurrent writes in Task 3, auto-adoption in Task 8, sibling discovery in Task 9).
