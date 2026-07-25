# Neovim Plugin Spec: hotlines.nvim

## Overview
A Neovim plugin that highlights every changed line in the current buffer against
a configurable base branch, across the entire feature branch's history — not just
uncommitted changes. Added lines use a full-line fill; modified lines use a
full-line fill plus a stronger changed-text range. It is a visualisation tool
only; it does not render an inline diff view.

## Motivation
Tools like gitsigns show changes since the last commit. This plugin instead shows
all lines changed on the current branch relative to a base branch (e.g. master),
so a developer can see the full footprint of their feature work while editing.

## Terminology
- Base branch: the branch the feature is being compared against (auto-detected by
  default, configurable, changeable at runtime).
- Merge-base comparison: use `git diff <base>...HEAD` semantics so only the
  branch's own changes are shown.

## Requirements

### Functional
1. Apply a distinct full-line background fill to added and modified lines in the
   current buffer, plus a stronger range highlight for changed text in modified
   lines.
2. No inline diff text, gutter signs, or sign-column output.
3. Enable / disable at runtime via user commands.
4. Change the base branch at runtime via a user command.
5. Auto-detect the base branch when none is explicitly configured.
6. Reflect unsaved edits live: highlights update as the user types, not only on
   save.
7. Automatically refresh highlights when:
   - a buffer is opened (BufReadPost)
   - a buffer is saved (BufWritePost)
   - the buffer text changes (TextChanged / TextChangedI, debounced)
   - the base branch is changed
8. Only operate on buffers that are:
   - backed by a real file on disk
   - inside a git work tree

### Non-Functional
- Must not block the UI: run git calls asynchronously (vim.system on Neovim 0.10+,
  fallback to jobstart).
- Text-change refreshes must be debounced (default 200ms) to avoid excessive git
  invocations while typing.
- Highlights must be cleared cleanly when disabled or when the buffer is unloaded.
- No external dependencies beyond git and Neovim >= 0.10.

## Configuration
Provide a setup(opts) entry point (lazy.nvim compatible).

  require("hotlines").setup({
    base = nil,                   -- nil = auto-detect; or set a branch name explicitly
    theme = "flamingo",           -- built-in palette name or "custom"
    highlight = "BranchChanged",  -- highlight group name for modified-line fill
    added_highlight = "BranchAdded", -- highlight group for added-line fill
    changed_text_highlight = "BranchChangedText", -- highlight group for modified text
    deleted_highlight = "BranchDeleted", -- highlight group for virtual deletion lines
    enabled_on_start = true,      -- auto-enable when a buffer loads
    default_bg = "#3b1838",       -- used only if highlight is undefined
    added_default_bg = "#512344", -- used only if added_highlight is undefined
    changed_text_default_bg = "#71335f", -- used only if changed_text_highlight is undefined
    deleted_default_bg = "#1e0c1c", -- used only if deleted_highlight is undefined
    live_update = true,           -- update on text change, not just on save
    debounce_ms = 200,            -- debounce interval for live updates
    diff_style = "unified",       -- "unified" or "split" hunk diff display
    keymaps = {
      toggle = "<leader>ht",
      next = "<leader>hn",
      prev = "<leader>hb",
      diff = "<leader>hd",
      files = "<leader>hf",
    },
  })

- If the highlight groups are not already defined, create them using their default
  backgrounds.
- Users can override by defining `BranchAdded`, `BranchChanged`,
  `BranchChangedText`, or `BranchDeleted` in their colorscheme when using the
  `custom` theme.
- If base is nil, resolve it via the auto-detection routine (see below).

## Base Branch Auto-Detection
When base is nil (or on :HotlinesSetBase with no argument), resolve the origin of
the current local branch using the following procedure:

1. Read `git reflog show --format=%gs refs/heads/<current-branch>` and use its
   oldest `branch: Created from <ref>` entry.
2. If Git recorded `branch: Created from HEAD`, read `git reflog show --format=%gs
   HEAD` and use the oldest `checkout: moving from <ref> to <current-branch>` entry.
3. Resolve the recorded ref as a local branch, remote branch, or fully qualified
   ref. Do not use the configured upstream, `origin/HEAD`, `main`, or `master` as
   a fallback because none identifies the branch origin.
4. If the reflog entry is absent, ambiguous, or no longer resolves, use the current
   branch as the base. Its merge base is HEAD, so working-tree and unsaved edits
   remain visible without highlighting committed branch history. Users can select a
   different base manually via :HotlinesSetBase.

Git does not store a durable branch-parent relationship. The reflog is best-effort
local evidence and can expire or be removed. Explicit bases are session-only.
Cache the resolved origin per repository and current branch. Detection re-runs when
the user clears the base.

## User Commands
- :HotlinesEnable       — enable and render for the current buffer.
- :HotlinesDisable      — clear highlights and stop tracking.
- :HotlinesToggle       — toggle current state.
- :HotlinesSetBase {branch}
      — set the base branch, then refresh all tracked buffers. With no argument,
        re-run auto-detection. Provide command-line completion listing local and
        remote branches.
- :HotlinesTheme {theme} — change the highlight palette for the current Neovim
  session. Flamingo is the default, Classic uses conventional green/blue/red diff
  colors, Sunset uses coral/violet, Aurora uses teal/indigo, Ember uses
  ochre/amber, and Custom uses configured highlight groups.
- :HotlinesRefresh      — force recompute for the current buffer.
- :HotlinesInfo         — show the resolved comparison and current change counts.
- :HotlinesNext         — jump to the next changed hunk, wrapping at the end.
- :HotlinesPrev         — jump to the previous changed hunk, wrapping at the start.
- :HotlinesDiff [style] — open the current hunk in the configured diff style.
                            The default `unified` style is a highlighted floating
                            buffer. Pass `split` for read-only merge-base and
                            current buffers side by side with synchronized native
                            diff mode. Both include three lines of context; press q
                            or the diff mapping to close. A cursor on either
                            adjacent real line opens the diff for a virtual
                            deletion line.
- :HotlinesTouchedFiles — open a centered, dependency-free two-pane picker with
                            touched files and hunks in a flat list or folder tree
                            on the left and a cursor-driven unified file or hunk
                            diff preview on the right. File rows show colored
                            added, deleted, and modified line totals. It supports
                            expansion controls, an embedded live path and
                            hunk-range filter, refresh, opening the selected file
                            or hunk without leaving the picker, optional mini.icons
                            or nvim-web-devicons file icons, best-effort Tree-sitter
                            source highlighting and focus-preserving keyboard
                            scrolling in the diff preview, and direct hunk diffs.

Explicit bases may be local branches, fully qualified refs, or remote branches in
`<remote>/<branch>` form. Base completion lists local and remote branches.

## Implementation Detail

### Getting changed lines
For the current buffer's file, compare the working tree (including unsaved edits,
see below) against the merge-base of the base branch:

  git diff --no-color -U0 <base>... -- <relative_file_path>

The trailing `...` compares the working tree against the merge-base of <base> and
HEAD, so only the branch's own changes are shown (the base moving ahead does not
create noise).

### Reflecting unsaved edits
Neovim buffers may contain unsaved changes that are not on disk, so git cannot see
them directly. To include them:

- On refresh, obtain the current buffer contents via nvim_buf_get_lines.
- Diff those contents against the base merge-base rather than the on-disk file.
  Implement using one of:
    a) Write the buffer contents to a temporary file and diff that temp file
       against the base blob:
         git show <base_merge_base>:<relative_path>  -> base content
         then diff base content vs buffer content (use vim.diff or an external
         diff on the two in-memory/temp texts).
    b) Preferred: use vim.diff(base_text, buffer_text, { result_type = "indices" })
       where base_text is the file content at the merge-base
       (git merge-base <base> HEAD, then git show <mergebase>:<relative_path>)
       and buffer_text is table.concat(nvim_buf_get_lines(...), "\n").
       vim.diff with result_type = "indices" returns hunk ranges directly,
       avoiding hunk-header text parsing entirely.
- Approach (b) is recommended: it needs only one async git call to fetch the base
  blob (cacheable per file + merge-base), and vim.diff runs in-process on the live
  buffer text, giving accurate live results as the user types.

### Merge-base resolution
  git merge-base <base> HEAD
Cache the merge-base per repository, base ref, and HEAD object ID; invalidate on a
manual refresh.

### Parsing hunk ranges
If using vim.diff with result_type = "indices", each returned entry provides
start/count for both sides; use the "new" (buffer) side start and count to mark
lines start .. start + count - 1. When count is 0 (pure deletion) mark nothing for
v1.

If instead parsing git diff -U0 output, parse headers matching:
  @@ -<old_start>[,<old_count>] +<new_start>[,<new_count>] @@
and mark lines new_start .. new_start + new_count - 1.

### Rendering
- Create a namespace: vim.api.nvim_create_namespace("branch_changes").
- Clear the namespace before re-rendering:
    nvim_buf_clear_namespace(buf, ns, 0, -1)
- For each added line:
     vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
       line_hl_group = opts.added_highlight,
     })
- For each modified line, use `line_hl_group = opts.highlight`.
- For changed text in modified lines, add a higher-priority extmark with
  `hl_group = opts.changed_text_highlight` and byte-column bounds.

### Debouncing live updates
- Maintain a per-buffer timer (vim.uv/vim.loop timer).
- On TextChanged / TextChangedI, reset the timer to debounce_ms; on fire, run the
  refresh for that buffer.
- Cancel/close the timer on BufUnload.

### State
- Track per-buffer enabled state, the resolved base branch, cached merge-base,
  cached base blob text, and the debounce timer in a module table.
- On BufUnload, drop buffer state and close timers.

## Autocommands
Register under an augroup "Hotlines":
- BufReadPost, BufWritePost           -> refresh if enabled.
- TextChanged, TextChangedI           -> debounced refresh if enabled and
                                          live_update is true.
- BufUnload                           -> clean up state and timers.

## File Structure
  hotlines.nvim/
  ├── lua/hotlines/
  │   ├── init.lua        -- setup(), public API, command registration
  │   ├── git.lua         -- async git calls, merge-base, base blob fetch, detection
  │   ├── diff.lua        -- vim.diff / hunk parsing -> changed line ranges
  │   ├── highlight.lua   -- namespace, extmark rendering, clearing
  │   └── config.lua      -- defaults + user options merge
  ├── plugin/hotlines.lua  -- command + augroup bootstrap (optional if lazy)
  └── README.md

## lazy.nvim Installation (for README)
  {
    "you/hotlines.nvim",
    event = "BufReadPost",
    opts = {
      -- base auto-detected by default; override if needed:
      -- base = "develop",
    },
  }

## Acceptance Criteria
1. On a feature branch with several commits, opening a file shows all lines
   changed vs the base branch highlighted with a background fill.
2. With no base configured, the plugin detects the current branch's origin from
   its reflog, or uses the current branch to show working-tree changes when that
   evidence is unavailable.
3. Editing a line updates its highlight live (within debounce_ms) without saving.
4. :HotlinesSetBase main re-renders against main.
5. :HotlinesSetBase with no argument re-runs auto-detection.
6. :HotlinesToggle cleanly adds/removes highlights.
7. Saving a file updates the highlights.
8. Opening a file outside a git repo produces no error and no highlights.
9. No sign-column or gutter output is produced.

## Out of Scope (v1)
- Inline/side-by-side diff views.
- Deleted-line indicators.
