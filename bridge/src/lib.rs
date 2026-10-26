//! mokh-bridge: the process that makes Helix look like an IDE to Claude Code.
//!
//! Claude Code discovers IDEs through lock files in `~/.claude/ide/` and talks
//! to them over a local WebSocket carrying JSON-RPC 2.0 / MCP. This crate
//! owns that side entirely. Towards the editor it speaks newline-delimited
//! JSON over stdio, which is what a Steel plugin can drive with a pipe and a
//! background thread. The protocol it implements is the one documented by the
//! Neovim implementation (coder/claudecode.nvim, PROTOCOL.md).

pub mod bridge;
pub mod diff;
pub mod lockfile;
pub mod mcp;

pub use bridge::{Bridge, Control, AUTH_HEADER};
