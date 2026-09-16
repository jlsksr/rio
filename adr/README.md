# Architecture Decision Records

This directory holds rio's architecture decision records (ADRs), in the style
described at [adr.github.io](https://adr.github.io/) and in Michael Nygard's
original template. Each record states one decision: the situation that called
for it, what was decided, and what follows from it.

## How the records relate to AGENTS.md

rio has kept a running decision log in [AGENTS.md](../AGENTS.md) since the first
day of the project. Entries there are numbered D1, D2, … and are edited in place
as decisions are amended. The ADRs here are the formal, one-file-per-decision form
of the same material.

- **ADR-0001 to ADR-0111 correspond one-to-one to D1 to D111.** Source comments
  and documents that cite "D30" refer to the decision recorded in ADR-0030.
- **ADR-0112 onwards** each take the next free number. ADR-0112 to ADR-0117
  record decisions that were settled without a D number of their own: in the
  open-questions section of AGENTS.md, in `spike/`, or as standing project
  policy. From D112 on, a D entry's record is not numbered after it; its
  **Decision log** line names the D number. Dates are the dates the decisions
  were taken, not the dates the records were written.
- AGENTS.md remains the working log and carries the implementation detail (test
  counts, proc names, bug narratives). An ADR carries the decision and its
  reasoning, and should still read correctly once that detail has changed.

## Writing a new record

1. Copy [template.md](template.md) to `NNNN-short-title.md`, using the next free
   number.
2. Record the decision in AGENTS.md as the next D number as well, so the two
   series stay aligned.
3. Add a row to the index below. The row carries the record's own title, status
   and date; `check.tcl` holds the two together.
4. Do not rewrite an accepted record to reflect a later change of mind. Write a
   new record, and update only the **Status** line of the old one
   ("Superseded by ADR-NNNN", "Amended by ADR-NNNN") — and its index row.

## Checking the set

```sh
tclsh adr/check.tcl
```

It must print `ALL PASS`. It holds the index below against the records themselves —
title, status and date, in both directions — and the D numbers in AGENTS.md against the
record numbers, so a record without a row, a row whose status was edited in one place
only, or a D entry nobody wrote up all fail by name. It reads files and nothing else:
no Tk, no display, no network. Run it before committing anything in this directory.

## Statuses

| Status | Meaning |
| ------ | ------- |
| Accepted | In force. |
| Accepted, not implemented | In force as design; no code yet. |
| Amended by ADR-NNNN | In force, with a later record changing part of it. |
| Superseded by ADR-NNNN | Replaced; kept for its reasoning. |
| Rejected | Tried or considered and reversed; kept so it is not proposed again. |

## Index

| ADR | Title | Status | Date |
| --- | ----- | ------ | ---- |
| [0001](0001-three-layers-core-frontends-server.md) | Three layers: core, frontends, optional server | Accepted; amended by 0030 | 2026-06-24 |
| [0002](0002-protocol-first-core-api.md) | The core API is a transport-independent message protocol | Accepted; amended by 0030 | 2026-06-24 |
| [0003](0003-core-owns-the-document.md) | The core owns the document; frontends are views | Accepted | 2026-06-24 |
| [0004](0004-tcl-tk-and-ck.md) | Tcl/Tk for core and GUI, Ck for the TUI | Accepted; the TUI is deferred by 0112 | 2026-06-24 |
| [0005](0005-keyboard-only-tui.md) | The TUI is keyboard-only | Accepted, not implemented (the TUI is deferred, 0112) | 2026-06-24 |
| [0006](0006-windows-tui-via-cygwin.md) | Windows TUI through Cygwin, PDCurses as fallback | Accepted, not implemented (the TUI is deferred, 0112) | 2026-06-24 |
| [0007](0007-git-by-shelling-out.md) | Git by shelling out to `git` | Accepted | 2026-06-24 |
| [0008](0008-llm-provider-interface.md) | LLM access behind a stable provider interface | Accepted | 2026-06-24 |
| [0009](0009-layout-policy-as-shared-function.md) | The responsive layout rule is a shared pure function | Accepted, not implemented (the TUI is deferred, 0112) | 2026-06-24 |
| [0010](0010-async-via-event-loop.md) | Asynchrony through the event loop and coroutines | Accepted | 2026-06-24 |
| [0011](0011-jsonl-wire-protocol.md) | Newline-delimited JSON wire protocol | Accepted; amended by 0113 | 2026-06-24 |
| [0012](0012-document-model-lines.md) | Document model: a list of lines, `line.col` positions | Accepted | 2026-06-24 |
| [0013](0013-layout-regions.md) | Fixed layout regions and a collapsible section stack | Accepted; amended by 0035 | 2026-06-24 |
| [0014](0014-responsive-tiers.md) | Responsive tiers and the unified-diff fallback | Accepted, not implemented (the TUI is deferred, 0112) | 2026-06-24 |
| [0015](0015-no-terminal-pane.md) | No terminal pane; a headless command primitive only | Accepted | 2026-06-25 |
| [0016](0016-plugins-as-protocol-participants.md) | A plugin is a protocol participant | Accepted, not implemented (the general plugin platform is deferred) | 2026-06-24 |
| [0017](0017-contribution-points.md) | Contribution points for extensions | Accepted, not implemented (the general plugin platform is deferred) | 2026-06-24 |
| [0018](0018-declarative-ui-contributions.md) | UI contributions are declarative | Accepted, not implemented (the general plugin platform is deferred) | 2026-06-24 |
| [0019](0019-plugin-manifest-and-permissions.md) | Plugin manifest and permissions; no marketplace platform | Accepted; distribution amended by 0039 | 2026-06-24 |
| [0020](0020-agent-orchestration-in-core.md) | Agent orchestration in the core, providers and tools outside | Accepted | 2026-06-24 |
| [0021](0021-plain-text-config-xdg.md) | Plain-text configuration in XDG locations, never executed | Accepted; session storage amended by 0031 | 2026-06-25 |
| [0022](0022-encoding-line-endings-cursor.md) | Preserve encoding and line endings; cursors are frontend-local | Accepted | 2026-06-25 |
| [0023](0023-keybindings-as-data.md) | Keybindings are data | Accepted | 2026-06-25 |
| [0024](0024-themes-as-role-data.md) | Themes are semantic-role data files | Accepted | 2026-06-25 |
| [0025](0025-shape-aware-json-encoding.md) | JSON encoding is shape-aware, never value-sniffed | Accepted | 2026-06-25 |
| [0026](0026-agent-first-slice-api-key.md) | The agent's first slice, on the official API key only | Accepted; amended by 0034, 0069, 0083, 0104 | 2026-06-27 |
| [0027](0027-monochrome-unicode-icons.md) | Icons are monochrome Unicode glyphs | Accepted | 2026-06-29 |
| [0028](0028-compare-view.md) | A core line diff and a read-only compare view | Accepted | 2026-06-29 |
| [0029](0029-gui-as-socket-client.md) | The GUI can drive a remote core over a socket | Superseded by 0030 | 2026-06-30 |
| [0030](0030-always-a-channel-client.md) | The frontend is always a client over a channel | Accepted; amended by 0096 | 2026-06-30 |
| [0031](0031-sessions-and-preferences.md) | Sessions and preferences, split by owner, out of tree | Accepted | 2026-07-01 |
| [0032](0032-syntax-highlighting-in-frontend.md) | Syntax highlighting: swappable per-line scanners in the frontend | Accepted | 2026-07-01 |
| [0033](0033-two-editor-groups.md) | Two side-by-side editor groups | Accepted | 2026-07-06 |
| [0034](0034-agent-system-prompt.md) | A core-owned, provider-agnostic system prompt | Accepted; amended by 0070, 0079, 0105 | 2026-07-08 |
| [0035](0035-tool-windows-dock-sites.md) | Tool windows live in dock sites, not in the document tabs | Accepted | 2026-07-12 |
| [0036](0036-find-replace-engine-in-core.md) | Find and replace: the engine in the core, a bar in the GUI | Accepted | 2026-07-12 |
| [0037](0037-stale-link-watchdog.md) | Stale-link detection at the protocol layer | Accepted | 2026-07-12 |
| [0038](0038-editing-modes.md) | Editing modes as a bind-tag layer | Accepted; amended by 0041 | 2026-07-12 |
| [0039](0039-extension-repositories.md) | Extension repositories over plain HTTP, apt-sources style | Accepted; amended by 0066, 0107, 0109 | 2026-07-17 |
| [0040](0040-column-editing.md) | Column editing as a GUI-only vertical cursor | Accepted | 2026-07-23 |
| [0041](0041-unbundled-editing-modes.md) | The core ships one editing mode; emacs and vi are extensions | Accepted | 2026-08-03 |
| [0042](0042-files-pane-rich-list.md) | The files pane is a rich list drawn on a text widget | Accepted; amended by 0043, 0087 | 2026-08-06 |
| [0043](0043-shared-rich-list-and-git-flags.md) | A shared rich-list component; git flags in the files pane | Accepted | 2026-08-06 |
| [0044](0044-pane-context-menus-git-writes.md) | Pane context menus and the first git write operations | Accepted | 2026-08-07 |
| [0045](0045-git-commit-bar.md) | Commit from a bar that appears only when something is staged | Accepted; amended by 0081 | 2026-08-07 |
| [0046](0046-highlighters-by-filename.md) | Highlighters can register by file name | Accepted | 2026-08-10 |
| [0047](0047-fs-changed-event.md) | Disk writes are announced with `fs.changed` | Accepted | 2026-08-18 |
| [0048](0048-file-management-actions.md) | File management as core operations | Accepted; target directory rule amended by 0087 | 2026-08-18 |
| [0049](0049-line-number-gutter.md) | A line-number gutter drawn from the text widget's geometry | Accepted | 2026-08-19 |
| [0050](0050-cursor-position-status.md) | Cursor position in the status bar | Accepted | 2026-08-19 |
| [0051](0051-find-in-files.md) | Find in files: a core engine and a bottom results panel | Accepted; scope amended by 0052 | 2026-08-19 |
| [0052](0052-search-panel.md) | One search panel: two engines, three scopes | Accepted | 2026-08-19 |
| [0053](0053-assisted-not-autonomous.md) | LLM integration is assisted, not autonomous | Accepted; amended by 0084 | 2026-08-23 |
| [0054](0054-utf-8-source-encoding.md) | Every entry point pins the source encoding to UTF-8 | Accepted | 2026-09-03 |
| [0055](0055-core-answers-host-questions.md) | Questions about the core's host are answered by the core | Accepted | 2026-09-03 |
| [0056](0056-editor-font-override.md) | The editor font is a user override on the theme font | Accepted | 2026-09-03 |
| [0057](0057-tab-overflow.md) | Tab overflow: page, wrap, or list | Accepted; amended by 0074, 0078 | 2026-09-03 |
| [0058](0058-preferences-window.md) | A Preferences window that owns no state | Accepted; amended by 0085, 0092 | 2026-09-03 |
| [0059](0059-menu-hover-patch-reverted.md) | Patching Tk's menu click behaviour | Rejected (shipped, then reverted) | 2026-09-04 |
| [0060](0060-current-line-highlight.md) | Current-line highlight | Accepted | 2026-09-04 |
| [0061](0061-gutter-line-selection.md) | Click a line number to select the line | Accepted | 2026-09-04 |
| [0062](0062-hide-dotfiles.md) | Hide dotfiles in the files pane by default | Accepted | 2026-09-04 |
| [0063](0063-tooltips.md) | Hover tooltips for glyph controls | Accepted | 2026-09-04 |
| [0064](0064-bounded-view-menu.md) | Menus are kept within screen height by grouping | Accepted | 2026-09-04 |
| [0065](0065-second-provider-contract.md) | A second provider, and hardening the provider contract | Accepted; distribution amended by 0066 | 2026-09-04 |
| [0066](0066-installable-providers.md) | Providers install from repositories, behind a versioned API | Accepted; amended by 0069 | 2026-09-04 |
| [0067](0067-extensions-in-settings.md) | The Extensions window moves to the Settings menu | Accepted | 2026-09-04 |
| [0068](0068-help-text-vs-controls.md) | Static help must look different from controls | Accepted | 2026-09-04 |
| [0069](0069-claude-as-extension.md) | Claude is an installable provider; echo is the only built-in | Accepted | 2026-09-04 |
| [0070](0070-user-and-project-prompts.md) | A defined place for user and project prompts | Accepted; amended by 0079, 0105 | 2026-09-04 |
| [0071](0071-relative-line-numbers.md) | Relative line numbers | Accepted | 2026-09-05 |
| [0072](0072-anonymous-workspace.md) | A session for work with no project open | Accepted | 2026-09-08 |
| [0073](0073-compare-menu.md) | Compare gets its own top-level menu | Accepted | 2026-09-08 |
| [0074](0074-buffer-picker.md) | A bounded buffer picker replaces the Tabs menu | Accepted; generalised by 0092 | 2026-09-08 |
| [0075](0075-find-menu.md) | A top-level Find menu | Accepted | 2026-09-08 |
| [0076](0076-about-build-identity.md) | About rio shows the build's commit identity | Accepted | 2026-09-08 |
| [0077](0077-open-multiple-files.md) | Open several files from the native chooser | Accepted | 2026-09-08 |
| [0078](0078-multi-line-tab-rows.md) | Multi-line tabs flow into packed, justified rows | Accepted | 2026-09-08 |
| [0079](0079-per-provider-prompts.md) | A per-provider prompt layer | Accepted | 2026-09-08 |
| [0080](0080-git-discard.md) | Git discard for everyday use | Accepted; amended by 0093, 0097 | 2026-09-08 |
| [0081](0081-commit-message-body.md) | An optional commit message body | Accepted | 2026-09-08 |
| [0082](0082-agent-busy-indicator.md) | A busy indicator while the agent works | Accepted | 2026-09-09 |
| [0083](0083-agent-run-command.md) | The agent runs commands: gated, asynchronous, time-bounded | Accepted; amended by 0084 | 2026-09-09 |
| [0084](0084-command-allow-list.md) | Human-authored command allow-lists | Accepted | 2026-09-09 |
| [0085](0085-agent-config-in-preferences.md) | Agent configuration lives in Preferences | Accepted | 2026-09-09 |
| [0086](0086-os-file-drop.md) | Drop a file on the window to open it, with optional tkdnd | Accepted | 2026-09-09 |
| [0087](0087-files-tree.md) | The files pane becomes a tree from the project root | Accepted | 2026-09-09 |
| [0088](0088-reopen-last-folder.md) | Reopen the last folder on launch | Accepted; amended by 0089 | 2026-09-09 |
| [0089](0089-remember-tree-shape.md) | Remember the unfolded tree; survive a deleted folder | Accepted | 2026-09-09 |
| [0090](0090-undo-coalescing.md) | Undo coalescing by word, decided in the core | Accepted | 2026-09-10 |
| [0091](0091-in-tree-user-manual.md) | The user manual lives in the source tree | Accepted | 2026-09-10 |
| [0092](0092-theme-picker.md) | The theme menu becomes a bounded picker | Accepted | 2026-09-10 |
| [0093](0093-discard-tree-and-bulk.md) | Discard from the file tree, and discard all | Accepted | 2026-09-10 |
| [0094](0094-stale-buffers.md) | Buffers detect changes to their files | Accepted | 2026-09-10 |
| [0095](0095-headless-never-asks.md) | A headless run never asks a human anything | Accepted | 2026-09-11 |
| [0096](0096-rio-does-not-dial.md) | rio speaks the protocol; it does not dial | Accepted | 2026-09-11 |
| [0097](0097-rename-aware-discard.md) | Discarding a rename restores the old name | Accepted | 2026-09-11 |
| [0098](0098-untracked-folder-files.md) | Files inside an untracked folder can be tracked individually | Accepted | 2026-09-11 |
| [0099](0099-help-viewer.md) | rio shows its own manual | Accepted; amended by 0100 | 2026-09-11 |
| [0100](0100-manual-renderer.md) | The manual is rendered, with working links and search | Accepted | 2026-09-11 |
| [0101](0101-plan-mode.md) | Plan mode: a core tool and a readable plan view | Accepted; amended by 0102, 0103 | 2026-09-11 |
| [0102](0102-plan-approval-policy.md) | The edit policy is chosen when a plan is approved | Accepted | 2026-09-11 |
| [0103](0103-plan-tool-in-every-mode.md) | The plan tool is offered in every mode | Accepted | 2026-09-11 |
| [0104](0104-stop-instead-of-step-cap.md) | No step cap; a Stop button instead | Accepted | 2026-09-11 |
| [0105](0105-shipped-prompt-visible.md) | rio's shipped prompt is complete and visible | Accepted | 2026-09-11 |
| [0106](0106-model-and-effort-options.md) | Model and effort are provider-declared options | Accepted | 2026-09-12 |
| [0107](0107-semver-extension-updates.md) | Extension versions are semver and are compared | Accepted | 2026-09-12 |
| [0108](0108-editor-context-menu.md) | The editor has a context menu built from the Edit menu's table | Accepted | 2026-09-12 |
| [0109](0109-https-repositories.md) | https beside http, trusted from the host's CA store | Accepted; amended by 0110, 0111 | 2026-09-12 |
| [0110](0110-agent-https-hostname-checks.md) | The agent refuses https without host-name checks unless allowed | Accepted | 2026-09-15 |
| [0111](0111-certificate-exceptions.md) | A certificate that fails verification can be accepted by fingerprint | Accepted | 2026-09-15 |
| [0112](0112-tui-deferred.md) | The TUI is deferred after a successful Ck spike | Accepted | 2026-06-27 |
| [0113](0113-error-code-taxonomy.md) | A small, stable error-code taxonomy | Accepted | 2026-06-26 |
| [0114](0114-single-root-project.md) | A project is one root folder held by the core | Accepted | 2026-06-27 |
| [0115](0115-dependency-policy.md) | Hard dependencies are minimal; optional ones must degrade cleanly | Accepted | 2026-09-09 |
| [0116](0116-verification-policy.md) | Verification is automated, offline, and proven against injected faults | Accepted | 2026-09-11 |
| [0117](0117-derived-facts-register.md) | A fact kept in two places must have a guard | Accepted | 2026-09-10 |
| [0118](0118-language-picked-by-hand.md) | A buffer's language can be picked by hand | Accepted | 2026-09-16 |
