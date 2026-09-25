# `ent` architecture redesign

**Date:** 2026-09-25  
**Branch:** `feature/architecture`  
**Status:** design spec pending review  

This document captures the design for the `feature/architecture` refactor of `ent`. It is driven by the review feedback on the existing architecture (see `ent-architecture.md`) and by design decisions confirmed by the project owner.

---

## Goals

- Make ent aware of only ent-managed branches/twigs rather than scanning all Git worktrees.
- Represent the ent structure as an explicit node tree with parent/child relationships.
- Improve code organization so that commands, output, argument parsing, etc. live in focused modules.
- Add error/info logging so terminal malfunctions can be diagnosed later.
- Add cross-ent navigation so a user can jump between ent trees from one shell.
- Preserve the bash 3.2 + git 2.20+ portability target.

## Non-goals

- Replace bash with another language.
- Change the visible disk layout (`main/core`, `branches/<b>/core`, `twigs/...`).
- Add external run-time dependencies such as `jq` or Python.
- Backward compatibility with previous metadata formats; the owner will update all existing ents.

---

## 1. Disk layout (unchanged)

The on-disk layout remains the same:

```text
my-app/
  .bare/                          # bare Git database
  .git                            # pointer: gitdir: ./.bare
  main/core/                      # canopy worktree
  branches/
    feature/
      x/
        core/                     # branch worktree
        twigs/
          db/
            core/                 # twig worktree
```

The internal metadata that describes this tree changes (see below).

---

## 2. The node tree

### 2.1 Data store: `.bare/ent.json`

A single JSON file under `.bare/` becomes the source of truth for the ent-managed tree.

```json
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
      "children": ["twigs/feature/x/db"],
      "worktree": "branches/feature/x/core"
    },
    "twigs/feature/x/db": {
      "type": "twig",
      "parent": "feature/x",
      "children": [],
      "worktree": "branches/feature/x/twigs/db/core"
    }
  }
}
```

Field definitions:

- `canopy` — the default branch name. Replaces the old `ent.main` config key.
- `nodes` — map of branch/twig name → node.
  - `type`: `canopy`, `branch`, or `twig`.
  - `parent`: the ent parent (`null` for canopy).
  - `children`: ordered list of ent children.
  - `worktree`: path relative to the ent root where the worktree lives.

There is no `version` field and no per-ent `roots` list. The roots list for cross-ent navigation lives in the ent installation folder (see §7).

### 2.2 Why a single JSON file

The owner selected a single JSON file because it is a clean, inspectable format and keeps all ent metadata in one place. To avoid adding a dependency on `jq`, we will read and write this file with an embedded `awk` script that understands the restricted schema above. The schema is flat enough that this is straightforward.

### 2.3 Node lifecycle

- **Create branch/twig:** `ent branch` and `ent twig` add a node, compute the relative worktree path, and update the parent’s `children` list.
- **Remove branch/twig:** `ent rm` and `ent branch merge` remove the node, remove the node from the parent’s `children`, and follow standard node-deletion rules for trees (a parent cannot be removed until its children are removed).
- **Adopt foreign branch:** if a local Git branch exists but has no node, the first ent command that touches it calls `tree_adopt_if_missing()`, creates the ent folder and node automatically, and continues.
- **Move/rename worktree:** operations that move a worktree (e.g., `init --here` keeping existing worktrees) update the node’s `worktree` path.

### 2.4 In-memory representation and the `REPLY` convention

`lib/tree.sh` loads `.bare/ent.json` into parallel arrays (bash 3.2 compatible):

- `T_NAME[]`     — node names, in file order.
- `T_TYPE[]`     — `canopy`/`branch`/`twig`.
- `T_PARENT[]`   — parent name or empty.
- `T_CHILDREN[]` — space-separated children names.
- `T_WORKTREE[]` — relative worktree path.

The codebase already uses a `REPLY` / `REPLY_LIST` convention: a function that returns a scalar writes it to the global `REPLY` variable, and a function that returns a list writes it to `REPLY_LIST`. This avoids `$(...)` subshells, which are slow on Git Bash for Windows. The node tree helpers will follow the same convention.

For example:

```bash
parent_of "feature/x"    # sets REPLY
children_of "feature/x"  # sets REPLY_LIST
```

Public functions (names TBD):

- `tree_load()` — reads `.bare/ent.json` into the arrays.
- `tree_canopy()` — prints canopy branch.
- `tree_parent_of <branch>` — sets `REPLY`.
- `tree_children_of <branch>` — sets `REPLY_LIST`.
- `tree_worktree_of <branch>` — sets `REPLY` (relative path).
- `tree_node_exists <branch>` — true/false.
- `tree_add_node <branch> <type> <parent> <worktree>` — mutates and saves.
- `tree_remove_node <branch>` — mutates and saves.
- `tree_adopt_if_missing <branch>` — auto-adopt foreign branches.
- `tree_lock()` / `tree_unlock()` — advisory lock around writes (see §13.2).

---

## 3. State module rewrite

`lib/state.sh` will be rebuilt on top of `lib/tree.sh`.

### 3.1 What still comes from Git

- Local branch names and remote-tracking names (for validation and `--remote` support).
- The actual worktree list is still used to sanity-check node `worktree` paths and to detect externally-moved worktrees.
- Unfinished operation state (`MERGE_HEAD`, `rebase-merge`, etc.) is still detected by inspecting `.bare/worktrees/<id>`. However, we will use the `worktree` path stored in the node to narrow the scan.

### 3.2 What comes from the tree

- Parent/child relationships.
- Which branches/twigs ent manages.
- Worktree paths (relative, resolvable against `ENT`).
- The canopy branch name.

### 3.3 Bootstrapping the file

If `.bare/ent.json` is missing, `load_state` will build it once from the current Git state:

1. Read the old `ent.main` value and write it as `canopy`.
2. Scan local branches and `branch.*.entParent` entries to build parent/child relationships.
3. Use `git worktree list --porcelain` to map each ent-managed branch to its worktree path.
4. Write `.bare/ent.json`, then continue loading from it.

After this one-time bootstrap, `ent.main` is no longer consulted. If it is still present, it is ignored.

---

## 4. Path module rewrite

`lib/paths.sh` will be rebuilt on top of `lib/tree.sh`.

### 4.1 Naming helpers kept

- `ent_norm()` stays, including Git Bash path handling.
- `ent_abs_path()` stays.
- `ent_root()` / `is_ent_root()` stay, since root detection still depends on `.bare` + `.git` pointer.

### 4.2 Path helpers now use the tree

- `ent_container()` — computed from the node’s `worktree` path by stripping `/core`.
- `ent_core()` — `ent_container()/core`.
- `ent_parent_core()` — resolve parent node’s worktree.
- `ent_branch_of_cwd()` — walk up from cwd and match against node worktree paths.

Helpers like `ent_slug()` will be removed because the owner wants `feature-foo` shorthand gone.

---

## 5. Logging

### 5.1 New module: `lib/log.sh`

Responsibilities:

- Determine where to write:
  - If inside an ent: `<ent-root>/.bare/ent.log`.
  - Otherwise: `~/.config/ent/global.log`.
- Provide:
  - `log_info <message>`
  - `log_warn <message>`
  - `log_error <message>`
- Each line:

```text
[<ISO-8601>] [<LEVEL>] [<script>:<line>] <message>
```

Level mapping:

- `log_info` → writes `INFO`.
- `log_warn` and `warn()` → writes `WARN`.
- `die()` → writes `ERROR` before exiting.

### 5.2 Integration points

- `note()` will call `log_info`.
- `warn()` will call `log_warn`.
- `die()` will call `log_error` before printing to stderr and exiting.
- Capturing `script:line` uses `caller` in bash.

### 5.3 Global log

The global log lives at `~/.config/ent/global.log`. It captures messages that occur before an ent is found (e.g., `ent go` outside an ent, launcher issues, failures to find a library). This helps diagnose terminal/UI malfunctions when no ent context exists.

---

## 6. Command module reorganization

### 6.1 Split `lib/core.sh`

`lib/core.sh` currently mixes output, execution, prompts, and argument parsing. It will be split into focused modules:

- `lib/output.sh` — `say`, `note`, `warn`, `die`, `fmt_cmd`, color setup.
- `lib/run.sh` — `run`, `runat`, `worktree_bare_guard`.
- `lib/prompt.sh` — `confirm`, `choose`.
- `lib/args.sh` — truly global flag parsing and `arg()`.

`lib/core.sh` can become a thin aggregator that sources the above, or it can be removed after `git-ent` is updated to source them directly.

### 6.2 Keep commands as single files, with per-command parsing

We will keep the existing flat command files (`lib/cmd/<verb>.sh`) rather than splitting every command into its own folder. Splitting each command into `main.sh`/`parse.sh`/`help.sh` would create many tiny files without much gain.

Instead, each `lib/cmd/<verb>.sh` will define three functions:

- `help_<verb>()` — usage text.
- `parse_<verb>_args()` — command-specific flags.
- `cmd_<verb>()` — the command logic.

`git-ent` continues to source `lib/cmd/*.sh`. After dispatch, `cmd_<verb>` calls `parse_<verb>_args` to handle its own flags.

### 6.3 Argument parsing flow

1. `parse_globals()` extracts global flags and builds the positional `ARGS[]` list.
2. The verb is determined from `ARGS[0]` (with `branch merge` treated as `merge`).
3. `cmd_<verb>` calls `parse_<verb>_args` to process command-specific flags from the remaining tokens.

This gives clear ownership: each command owns its flags, but the shared infrastructure stays in focused shared modules.

---

## 7. Cross-ent navigation

### 7.1 User-facing syntax

Extend `ent go` to accept:

```text
ent go other-ent                # go to other-ent/main/core
ent go other-ent/branch         # go to other-ent/branches/branch/core
ent go other-ent/twig           # go to other-ent/.../twigs/<twig>/core
```

`other-ent` is the basename of an ent root directory.

### 7.2 Discovering other ents

The list of known ent roots lives in the ent installation folder:

```text
~/.local/share/git-ent/roots
```

Each line is an absolute ent root path.

- On every successful `ensure_ent`, the current root is appended if missing.
- When resolving a cross-ent target, `ent go`:
  1. Checks the parent directory of the current ent root for a sibling directory named `<target>` that is an ent root. If found, it is added to the roots file.
  2. Falls back to scanning `~/.local/share/git-ent/roots` for a path whose basename matches `<target>`.
  3. If not found, reports the error.

This satisfies the requirement that ent maintain the list itself rather than requiring the user to manage it.

### 7.3 Failure modes

- Missing target ent → clear error.
- Branch/twig not found in target ent → error from target ent’s normal resolution.
- Roots file missing → created lazily on first `ensure_ent`.

---

## 8. Auto-adoption and markers

### 8.1 Auto-adoption on first mention

Whenever an ent command needs a local Git branch but that branch has no ent node, `tree_adopt_if_missing()` is called. If the branch exists in Git, ent will automatically create the ent folder and node for it, exactly as if the user had run `ent branch <name>` on a pre-existing branch. No manual step is required.

As a result, the `[no worktree]` marker disappears from `ent list`.

### 8.2 Marker renames

- `[?]` (checked out somewhere other than its ent folder) → `[relocated]`.
- `[!]` (parent branch no longer exists) → `[orphan]`.

These still appear in `ent list` when applicable because they represent real conditions, but they are renamed for clarity.

---

## 9. `ent sync` enhancements

### 9.1 Multiple targets

`ent sync` will accept zero or more branch/twig names:

```text
ent sync                       # sync everything
ent sync feature/x             # sync one
ent sync feature/x feature/y   # sync a list
```

Each named branch must be an ent-managed local branch. Sync skips missing names with a warning.

### 9.2 Remote-to-local only

`ent sync` will not push deletions to `origin`. It will continue to:

- fetch and fast-forward the canopy,
- offer to remove local merged branches/twigs,
- merge the canopy into specified (or all) local worktrees.

This is unchanged in semantics; only the multiple-target form is new.

---

## 10. Full-screen viewer

The tab bar in `ent status` / `ent log` will always render, even when there is only one worktree. This makes the UI consistent and prevents the "single option drops the tab" behavior.

---

## 11. Tab completion

Completions (`completions/ent.bash` and `completions/ent.zsh`) will read branch/twig names from `.bare/ent.json` so that:

- Canopy, branches, and twigs all complete correctly.
- Names containing `/` complete correctly.
- Twig short names are not needed; completion uses the full managed node list.

The completion scripts can call a small helper exposed by `git-ent` (e.g., `git-ent __list`) or parse the JSON themselves with the same embedded `awk` script used by `lib/tree.sh`. The exact plumbing is left to implementation.

---

## 12. Remove `ent_slug`

The `feature-foo → feature/foo` shorthand is unnecessary. `ent go` and `ent down` will match by:

- Full branch name.
- Twig short name (last path segment).

`ent_slug()` and its call sites will be removed.

---

## 13. Security and edge cases

### 13.1 `.bare/ent.json` corruption

- Writes are atomic: write to `.bare/ent.json.tmp` then `mv` it over the real file.
- If parsing fails, fall back to rebuilding the tree from Git state (same as bootstrap) and warn the user.

### 13.2 Concurrent writes

A simple advisory lock file will be used: `.bare/ent.json.lock`. Any process that writes the file acquires the lock with `mkdir` (atomic on all supported platforms) and releases it by removing the directory. If a lock is stale, the next writer breaks it after a short timeout.

### 13.3 Guard against non-ent worktrees

Only nodes listed in `.bare/ent.json` are considered ent-managed. Plain Git worktrees created outside ent are ignored, which addresses the concern about worktrees becoming large and unwieldy.

---

## 14. Branch target

All implementation work will happen on branch `feature/architecture`, cut from the current canopy. The design spec file lives on that branch alongside the code changes.

---

## 15. Testing

Extend `ent.test.sh` to cover:

- Node tree bootstrap from old `ent.main`/`branch.*.entParent` metadata.
- Reading/writing `.bare/ent.json`.
- Auto-adoption of a folderless branch.
- Cross-ent `go` using cached roots.
- Logging output in `.bare/ent.log` and global log.
- Per-command flag parsing (e.g., `--from` only recognized by `branch`/`twig`, `--worktrees` only by `init --here`).
- `ent sync` with multiple branch arguments.
- Marker output `[relocated]` and `[orphan]`.
- Single-worktree viewer still shows the tab bar.

The existing GitHub Actions CI matrix (macOS bash 3.2, Linux bash 5, Windows Git Bash) remains the validation gate.

---

## 16. Summary of file changes

| Create / modify | Purpose |
|-----------------|---------|
| `docs/ent-architecture-design.md` | This design spec. |
| `lib/tree.sh` | Node tree load/lookup/mutation/lock. |
| `lib/state.sh` | Rebuild on top of `lib/tree.sh`. |
| `lib/paths.sh` | Rebuild on top of `lib/tree.sh`; remove `ent_slug`. |
| `lib/log.sh` | Logging to per-ent and global logs. |
| `lib/output.sh`, `lib/run.sh`, `lib/prompt.sh`, `lib/args.sh` | Split of `lib/core.sh`. |
| `lib/core.sh` | Either removed or becomes an aggregator. |
| `lib/cmd/<verb>.sh` | Each file gains `parse_<verb>_args` and `help_<verb>`. |
| `git-ent` | Updated loader for split modules. |
| `completions/ent.bash`, `completions/ent.zsh` | Use `.bare/ent.json` for branch/twig completion. |
| `ent.test.sh` | New tests for node tree, logging, cross-ent, sync list, markers, viewer. |
| `~/.local/share/git-ent/roots` | Auto-maintained cross-ent roots list. |

---

## 17. Design decisions resolved

| Topic | Decision |
|-------|----------|
| Marker names | `[relocated]` and `[orphan]`. |
| `ent sync` remote deletion | None; sync is remote-to-local only. |
| `feature/architecture` branch | Created by the implementer as the first implementation step. |
| Node metadata store | Single `.bare/ent.json`, parsed with embedded `awk`. |
| Cross-ent roots list | Stored in `~/.local/share/git-ent/roots`, maintained automatically by `ensure_ent`. |
| Logging | Per-ent `.bare/ent.log` and global `~/.config/ent/global.log`; levels INFO/WARN/ERROR. |
| Flag grouping | Shared infrastructure split out; each `lib/cmd/<verb>.sh` owns its own `parse_<verb>_args`. |
| Foreign branches | Auto-adopt on first mention; `[no worktree]` removed. |
| Tab completion | Reads from `.bare/ent.json`. |
| Concurrency | Advisory lock file for `.bare/ent.json`. |
| Backward compatibility | None; one-time bootstrap only. |
