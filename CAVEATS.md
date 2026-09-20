# rio — caveats & limitations

A running list of rio's **rough edges worth remembering** — split into two kinds:

1. **Cross-platform behaviour differences** — the *same* rio code behaving differently on
   one OS / window manager / toolkit than on another. These are usually traits of Tk or the
   surrounding environment rather than bugs in rio's own code.
2. **Behavioural limitations** — deliberate simplifications in rio's *own* design that hold
   the same on every platform: a documented trade-off where a fuller behaviour was
   consciously deferred, not a bug.

Each entry records the **symptom**, the **cause**, **where it's fine**, rio's current
**mitigation**, and any **planned** work (with a pointer to [ROADMAP.md](ROADMAP.md) /
[AGENTS.md](AGENTS.md)). When you hit a new "works here, not there" quirk, or notice a
design limit that surprises, append it to the matching section.

---

## Cross-platform behaviour differences

### Over-tall menus close on hover (X11)

- **Symptom.** A menu posted **taller than the screen space below it** can **unpost the
  moment the pointer hovers an item in the middle** of the list. Seen on X11 under xfwm4;
  the View menu was the one that reached this size.
- **Cause.** Tk's Unix menu widget tries to reposition a too-tall menu to fit and then
  scroll it (it has native scroll arrows in the C widget), but that reposition/scroll
  machinery interacts badly with the pointer grab on some window managers. It is a
  long-standing rough edge in Tk's X11 menu code, not a knob we can switch to "reliable".
- **Where it's fine.** **Windows and macOS.** There Tk renders the menubar with the
  **native OS menu**, and the OS scrolls tall menus correctly — so this class of glitch
  never appears off X11. (That is exactly why it is X11-only.)
- **Mitigation in rio.** Keep menus **short enough to fit** by grouping less-used items
  into submenus (AGENTS.md **D64** — the View menu dropped from ~30 rows to ~18). We do
  **not** patch Tk's menu grab/post/scroll internals: an earlier attempt to (AGENTS.md
  **D59**) caused its own intermittent click misfires and was reverted.
- **At scale — settled.** Grouping bounds the *fixed* menus; the two menus that were
  **data-driven and unbounded** (they grew with your data, so no amount of grouping could
  cap them) are both gone. Each became a bounded **picker dialog** — a listbox that scrolls
  inside a fixed frame instead of a menu that posts screen-tall: the per-buffer **Tabs**
  cascade in **D74** (now **View ▸ Switch to Tab…**), and the **Theme** cascade in **D92**
  (now **View ▸ Theme…**, with the Preferences dropdown onto the same dialog). No menu in
  rio is unbounded today, and a new one should not be: a list that grows with installed
  extensions, open buffers or project contents belongs in `pick_dialog`, not a cascade.

### A killed command's exit code differs on Windows (there are no signals)

- **Symptom.** When the agent's `run_command` tool **times out** and rio kills the child, the
  exit code in the result is **-1 on unix but 1 on Windows**. The same happens for any other
  killed child.
- **Cause.** `rio::exec::_kill` has no portable primitive to reach for (Tcl 8.6), so it shells
  out: `kill -TERM` on unix, `taskkill /F /T` on Windows. Unix then reports the death as a
  **signal** — Tcl surfaces `CHILDKILLED`, which rio maps to -1. Windows **has no signals**:
  a force-terminated process simply *exits*, with code 1, which arrives as an ordinary
  `CHILDSTATUS`. There is no Windows exit code that means "was killed".
- **Where it's fine.** **Everywhere, in practice** — because nothing reads that number to
  decide what happened. The `timedout` flag carries the meaning, and
  `rio::agent::tools::format_exec` checks it *before* it ever looks at the exit code, so a
  timed-out command is reported to the model as a timeout on both platforms.
- **Mitigation in rio.** Treat `timedout` as the signal and the exit code as data. The test
  (`rio-core/tests/exec.test`, `exec-start-timeout`) asserts `timedout` and *non-zero*
  rather than pinning a platform-specific number.
- **Planned.** Nothing. Windows cannot distinguish "killed" from "exited 1", so this is a
  property of the platform, not a gap to close.

### "Open Folder…" needs a double-click to enter the folder (X11)

- **Symptom.** In the local **Open Folder…** dialog on Linux, a **single click** on a folder
  highlights it but pressing **Open** does not open it — you must **double-click into** the
  folder first (so it becomes the dialog's current directory) and then press Open.
- **Cause.** rio's local folder chooser is Tk's **native `tk_chooseDirectory`**. On X11 that is
  Tk's own scripted dialog, whose OK/Open button returns the directory you have **entered**, not
  the one merely highlighted in the list — a long-standing behaviour of that dialog with no
  option flag to change it. It is not rio code, so we can't fix it from our side without
  replacing the dialog.
- **Where it's fine.** **Windows and macOS**, where `tk_chooseDirectory` renders the **native
  OS folder dialog** and single-click-then-Open works as expected. And **remote mode on every
  platform**: there the native choosers browse the wrong (client) disk, so rio substitutes its
  **own** `fs.list` browser (`remote_browse_dialog`), whose Open **does** open the highlighted
  folder (AGENTS.md D29/D30).
- **Mitigation in rio.** Keeping the **native** dialog locally is a deliberate choice (jka) for
  the native look and feel, accepting this wart as the trade. Every other way to open a project
  is unaffected — a folder on the command line, or double-clicking into it in the dialog.
- **Planned.** None. Routing local Open Folder through rio's own `fs.list` browser (as remote
  mode already does) would fix it but drop the OS-native chooser; that swap was considered and
  **declined** in favour of the native dialog.

### A core with tcltls older than 1.8 can't fully verify https

- **Symptom.** On a core whose `tcltls` is older than 1.8:
  - A **hosted agent provider** (Claude, ChatGPT) fails its first turn with a refusal
    naming the ways out.
  - An **`https://` extension repository** is refused the same way.
  - **Accept the Risk and Continue** for a certificate that doesn't verify is not offered.

  The same rio works on a core with a newer `tcltls`.
- **Cause.** Before 1.8, `tcltls` checks that a certificate chains to a trusted CA but
  **never compares its name with the host** it came from. Any valid certificate for *any*
  domain would pass as the server's. rio refuses to treat that as verified (D109, D110, D114);
  certificate exceptions are keyed on a verification that version cannot do (D111).
- **Where it's fine.** Any core with `tcltls` 1.8 or newer. Also, **everything over plain
  `http://`**, on any `tcltls`: a local model server (Ollama, llama-server) and http
  repositories.

  **Only the core's host counts** (D30): a GUI attached with `--connect` to a core that has
  1.8+ has none of these limits, whatever `tcltls` the GUI's own machine has or lacks.
- **Mitigation in rio.** Refuse by default, and say why and what to do. From cleanest:
  1. **Run the core on a host with `tcltls` 1.8+,** and attach to it from the other
     machine.
  2. **Install a 1.8+ `tcltls`** on that host (building it against the host's OpenSSL if
     the package manager lags). Its updates are then yours to track.
  3. *Preferences ▸ Network ▸ "Allow https without host-name checks"*
     (`unchecked_hostnames = allow` in the core's `tls.conf`). One switch for the agent and
     https repositories alike (D114).
     - With it on, someone who can intercept the core's traffic (hostile Wi-Fi, DNS or ARP
       spoofing) can present a valid certificate for their own domain. They can then read
       the API key, the prompts and the code sent, or serve a repository's extensions.
     - That is no worse than a plain **http** repository, which never had a certificate
       to check.
     - Use it only on a network you trust.
  4. **Stay on http:** a local model and http repositories. A **signed** http repository
     (D118) has integrity without a certificate — the publisher's key vouches for the
     files whatever the transport did to them. An unsigned one has none.
- **Planned.** Nothing in rio: the gap closes as hosts ship `tcltls` 1.8+. Repository
  signing (D118) closed the http-repository half of it.

---

### An OpenSSH older than 8.0 can't check a repository signature

- **Symptom.** On a core whose host has `ssh-keygen` from OpenSSH **older than 8.0** — or
  none at all — a signed extension repository whose key rio already trusts lists as
  *can't check the signature* and installs nothing. The same rio works against the same
  repository from a core on a newer host.

  The most likely host is **Windows 10 1809**, the first to ship OpenSSH: that build is
  7.7. Windows 10 1903+ and Windows 11 ship 8.1 or newer; every current Linux and BSD is
  well past 8.0.
- **Cause.** `ssh-keygen -Y sign` / `-Y verify` arrived in OpenSSH 8.0. Before it there is
  no way to verify a detached signature with `ssh-keygen` at all. rio reports that as the
  version problem it is, never as a bad signature (D118).
- **Where it's fine.** A repository nobody has trusted a key for simply lists as
  *unsigned*, exactly as it did before signing existed — the tool is only needed to check
  a signature rio is expecting.

  Fingerprints are a separate question: `ssh-keygen -lf` long predates 8.0, so a 7.7 host
  still shows one for every key in *Preferences ▸ Extensions ▸ Repository signing keys…*
  and only the verifying fails. Where there is **no** `ssh-keygen` at all, that window has
  no fingerprint to compute and names each key by its type and the start of its base64.

  **Only the core's host counts** (D30), as with `tcltls`.
- **Mitigation in rio.** Refuse by default, and say which package to install. If that is
  not possible, *Preferences ▸ Extensions ▸ "Use repositories rio can't check"* lets the
  repository through marked **unverified** — never *signed* — and named as such in the
  install consent. It does not excuse a signature that fails, a key that changed, or a
  file that doesn't match: those are refused either way.
- **Planned.** Nothing: the gap closes with the host's OpenSSH.

---

## Behavioural limitations

### Drag-to-open needs the optional tkdnd extension, and a local core

- **Symptom.** Dragging a file from the OS file manager onto the rio-gui window does
  **nothing** — no tab opens. Or: it works for a locally-launched rio but not when the GUI is
  attached to a remote core.
- **Cause.** Two separate reasons. (1) **Plain Tk cannot receive an OS file drop at all** — that
  capability lives only in the external **tkdnd** extension (AGENTS.md **D86**), which rio loads
  *optionally* (`catch {package require tkdnd}`): where it isn't installed, there is simply
  nothing listening for the drop. (2) A dropped path is a path on the **GUI's own machine**, but
  the *core* performs the file open; with a **remote** core that path is meaningless, so rio
  registers drop targets only for a **local** core — a remote drop is refused with the native
  "no-drop" cursor.
- **Where it's fine.** A **local** rio with **tkdnd installed** (the Magicsplat Tcl/Tk
  distribution bundles it on Windows; Linux/BSD install the `tkdnd` package). Drag one or several
  files — or a folder — onto the editor, a dock, or the tab strip and they open.
- **Mitigation in rio.** The feature degrades cleanly: without tkdnd rio-gui runs exactly as
  before, and **every other way to open a file** (File ▸ Open…, the file pane, `argv`) is
  unaffected. Install tkdnd to turn drag-to-open on — see [INSTALL.md](INSTALL.md) /
  [WINDOWS.md](WINDOWS.md).
- **Planned.** Uploading a dropped *local* file's bytes to a **remote** core (so drag-to-open
  works over the wire too) is a deliberate follow-up, noted out-of-scope in AGENTS.md **D86**,
  not yet scheduled.

### Two no-project windows share one anonymous session

- **Symptom.** Run **two rio instances that both have no folder open** (the loose "daily
  workspace" case) and their open-tab sets **overwrite each other**: whichever saves last
  wins, so a later launch resumes only one of the two sets rather than both.
- **Cause.** The resume session for the **no-project** state is a *single* file
  (`sessions/anonymous.json`, AGENTS.md **D72**): with no project root there is nothing to
  key it by, so every no-project instance shares the one file, and `session_save` (fired on
  each tab change and on quit) rewrites it.
- **Where it's fine.** The intended **one-daily-instance** workflow — a single always-open
  no-project window resumes perfectly. And **any window with a folder open is unaffected**:
  project sessions are keyed by their root (D31), so multiple *project* windows stay
  isolated from each other and from the anonymous one.
- **Mitigation in rio.** None automatic today. If you want two independent loose sessions,
  **open a folder** in one of the windows (even a throwaway root) so it gets its own
  per-root session instead of the shared anonymous one.
- **Planned.** A per-instance or last-folder resume pointer would let several no-project
  windows resume independently; noted as the deferred follow-up in AGENTS.md **D72**, not
  yet scheduled.

### A file you open anyway is still slow, and "binary" is judged from the first 8 KB

- **Symptom.** Two halves of the same trade (AGENTS.md **D125**). (1) rio asks before
  opening a file over 8 MB or one that looks binary — and if you answer **Open it
  anyway**, it is *still* slow: a very large file takes seconds to appear and the core
  answers nothing else while it works (in remote mode, that includes any other frontend
  on the same core). (2) A file whose first 8 KB are clean but which turns binary later
  is **not** caught, so it opens without a question.
- **Cause.** `rio::fs::read` reads and decodes the whole file — the UTF-8
  well-formedness pass alone costs roughly 150 ms per megabyte, in interpreted Tcl —
  and the core is single-threaded. The guard in front of it (`rio::fs::classify`) is a
  *cheap look*: one stat plus at most 8 KB off the front, because it runs before every
  open and cannot afford to read the file it is deciding about. That is git's rule, for
  git's reason, and it buys its speed with exactly this inexactness.
- **Where it's fine.** Ordinary editing, which is what the numbers were chosen around:
  rio's own largest source file is half a megabyte, and nothing under 8 MB is ever
  asked about. A real binary is caught — object files, archives, images and databases
  all carry a NUL within the first few bytes, let alone the first 8 KB.
- **Mitigation in rio.** The question is the mitigation: the cost is stated in the
  dialog (*"…is 1.2 GB — large enough that opening it may make rio slow to respond"*)
  before you pay it, and a forced open starts as **Plain Text** so the highlighter
  doesn't add its share — *View ▸ Language…* turns it back on. For the deep-NUL case,
  the same menu sets the buffer to Plain Text by hand.
- **Planned.** Making the forced path itself fast is a **deliberate non-goal for now**:
  capping the well-formedness pass at a prefix would break D22's guarantee that unknown
  bytes round-trip intact. Chunking that pass so it can bail out early *without*
  materialising the whole file as a byte list would be exact and is on
  [ROADMAP.md](ROADMAP.md); lazy / windowed loading of a huge file stays out of scope.

### A same-second, same-length rewrite can go unnoticed

- **Symptom.** A file rewritten under an open tab is normally noticed and reloaded (or asked
  about — see *When a file changes underneath you* in [docs/editor.md](docs/editor.md)). In one
  narrow case it is not: the rewrite lands **within the same second** as the version rio last
  read **and** leaves the file **exactly the same length**. The tab keeps showing the old text.
- **Cause.** rio identifies a file's on-disk version by its **modification time plus its size**
  (AGENTS.md **D94**). Size alone misses a length-preserving edit; mtime alone is coarse —
  some filesystems (and network mounts) record whole seconds only, so two writes a few
  milliseconds apart are indistinguishable by time. Together they miss only the intersection:
  same second *and* same length.
- **Where it's fine.** Ordinary editing never hits it — a human edit changes the length, and
  a `git pull`, a build, or a discard is separated from your last read by far more than a
  second. It is reachable mainly by a script rewriting a fixed-width file in a tight loop.
- **Mitigation in rio.** Re-open the tab, which always re-reads. On a filesystem with
  sub-second timestamps (ext4, APFS, NTFS) the window is milliseconds wide, not a second.
- **Planned.** Comparing a **content hash** instead of the mtime/size pair closes it
  completely; named as the upgrade path in **D94**, deliberately not paid for up front since
  it costs a full re-read of every open file on every check.
