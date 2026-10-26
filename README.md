# mokh.hx

Claude Code IDE integration for [Helix](https://helix-editor.com), as a
[Steel](https://github.com/mattwparas/steel) plugin. Moss on the forest floor.

Claude Code can attach to an editor the way it attaches to VS Code or
JetBrains: it learns what you have selected, opens files for you, and shows
each edit as a diff you accept or reject before it is written. mokh.hx gives
Helix that protocol. Claude keeps running in its own terminal (a zellij or
tmux pane next to `hx` is the intended setup); only the review loop moves
into the editor.

Status: alpha. The protocol works end to end against a simulated client and
the real CLI; the diff UI is the first, split-based version.

## What you get

- `/ide` in Claude Code lists **Helix** and connects to it.
- Claude knows the file and lines you are looking at (`selection_changed`),
  and `:mokh-send` pushes the current selection as an `@`-mention.
- `openFile` from Claude opens the file in Helix and jumps to the text it
  names.
- `openDiff` opens the unified diff of Claude's proposed change in a vertical
  split. `:mokh-accept` sends it back and Claude writes the file;
  `:mokh-reject` refuses it, and so does closing the buffer. `:mokh-edit`
  opens the proposal as an editable buffer when you want to change it first;
  `:w` there accepts with your edits.
- Open editors, dirty state, save-on-request and diff-tab cleanup, so the
  CLI's bookkeeping works.

## Requirements

- Helix built from the Steel branch
  (`mattwparas/helix`, `steel-event-system`), see its
  [STEEL.md](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md).
- `mokh-bridge` on your `PATH` (or point the plugin at it, see below). It is
  a small Rust program; build it with `cargo build --release` in `bridge/`,
  or `nix build .#mokh-bridge`.
- Claude Code.

## Install

With forge:

```sh
forge pkg install --git https://github.com/vitaliikindrat/mokh.hx.git
```

With Nix, the flake exposes `packages.<system>.mokh` (the cog, with
`passthru.cogName = "mokh"` so
[helix-plugins-nix](https://github.com/maxschipper/helix-plugins-nix) can
install it) and `packages.<system>.mokh-bridge`.

Then in `~/.config/helix/init.scm`:

```scheme
(require "mokh/mokh.scm")

;; Optional. Defaults: "mokh-bridge" from PATH, IDE name "Helix",
;; proposals under /tmp/mokh-hx, selection tracking on.
(mokh-configure! #:bridge "/path/to/mokh-bridge"
                 #:ide-name "Helix"
                 #:track-selection #t)

;; Start on launch, or bind :mokh-start to a key and start on demand.
(mokh-start)

(require (only-in "helix/keymaps.scm" keymap))
(keymap (global)
        (normal (space (m (s ":mokh-send")
                          (a ":mokh-accept")
                          (r ":mokh-reject")
                          (e ":mokh-edit")
                          (i ":mokh-status")))))
```

Restart Helix. In Claude Code, run `/ide` and pick Helix. The status line
reports `mokh: Claude Code connected`.

## Commands

| Command | What it does |
| --- | --- |
| `:mokh-start` | Start the bridge for the current workspace (writes the lock file Claude's `/ide` reads) |
| `:mokh-stop` | Stop it; pending diffs are rejected, the lock file removed |
| `:mokh-status` | Port, attached Claude sessions, pending diffs |
| `:mokh-send` | Send the primary selection to Claude as an `@`-mention (file and line range) |
| `:mokh-accept` | Accept the diff under the cursor (or the only pending one) with the proposal buffer's current text |
| `:mokh-reject` | Reject it |
| `:mokh-edit` | Open the proposal as an editable buffer below the diff; its text is what accept sends |

`:w` inside a proposal buffer accepts, like the VS Code extension.

## How it works

```
Claude Code  <-- WebSocket / MCP -->  mokh-bridge  <-- JSON lines on stdio -->  mokh.scm in hx
   /ide            lock file in                 (Rust, tokio)                 (Steel, UI thread)
                 ~/.claude/ide/
```

- `bridge/` is the Rust sidecar. It writes `~/.claude/ide/<port>.lock`,
  serves the WebSocket with the token check Claude expects, answers the MCP
  handshake and `tools/list`, computes the unified diff for `openDiff`, and
  forwards every editor-facing tool to Helix as one JSON line, pairing the
  reply back to the right request. It exits when the editor goes away and
  removes its lock file.
- `mokh.scm` spawns the bridge, reads its stdout on a native thread, and
  runs each request on the editor thread through `hx.with-context`. It
  answers from editor state and pushes `selection_changed` from the
  `selection-did-change` hook.
- `util.scm` is the pure part: JSON shapes and string helpers, tested with
  plain `steel`.

The protocol is the one the VS Code extension speaks, documented by the
Neovim implementation in
[coder/claudecode.nvim/PROTOCOL.md](https://github.com/coder/claudecode.nvim/blob/main/PROTOCOL.md).
It is unofficial; when Anthropic changes it, this follows.

## Tools

| Tool | Answered by |
| --- | --- |
| `getWorkspaceFolders` | bridge |
| `openFile`, `getCurrentSelection`, `getLatestSelection`, `getOpenEditors`, `checkDocumentDirty`, `saveDocument` | Helix |
| `openDiff`, `close_tab`, `closeAllDiffTabs` | Helix |
| `getDiagnostics` | Helix, but always empty: Steel exposes diagnostic counts only |
| `executeCode` | refused (Jupyter only) |

## Development

```sh
cd bridge && cargo test                 # unit + protocol tests (fake Claude over a real socket)
steel tests/util-test.scm               # pure Scheme tests
nix flake check                         # both
```

`claude-sim` is a stand-in for the CLI: it finds the newest lock file,
connects like Claude does, and runs tool calls from the command line. Start
`hx` with the plugin, then:

```sh
cargo run --example claude-sim -- list-tools \
  call openFile '{"filePath":"/path/to/file","startText":"fn main"}' \
  listen 3 \
  call openDiff '{"old_file_path":"/path/to/file","new_file_path":"/path/to/file","new_file_contents":"...","tab_name":"demo"}'
```

The last call blocks until you `:mokh-accept` or `:mokh-reject` in Helix.

## Roadmap

- Hunk-level accept and reject, with a note back to Claude about what was
  reverted (the odiumuniverse/claudecode.nvim idea).
- Inline rendering: deleted lines as virtual lines inside the real buffer,
  added lines highlighted. Needs a small addition to the Steel fork (a
  virtual-lines decoration exposed to plugins); planned as a patch here
  first, then a PR upstream.
- Review-after-write for auto-accept mode, driven by Claude Code hooks.
- Real diagnostics once the Steel API exposes them.

## License

MIT.
