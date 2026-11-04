//! `mokh-bridge`: run by the mokh.hx Steel plugin, talks JSON lines on stdio.
//!
//! Lifecycle: bind, write the lock file, print `ready`, serve until stdin
//! closes (the editor went away), a `shutdown` message arrives, or SIGTERM /
//! Ctrl-C. The lock file is removed on every exit path so Claude's `/ide`
//! never lists a dead editor. On startup it also retires any older bridge
//! the same editor process started (see `lockfile::retire_siblings`).

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use mokh_bridge::{lockfile, Bridge, Control};
use rand::RngCore;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

#[derive(Parser, Debug)]
#[command(name = "mokh-bridge", version, about = "Claude Code IDE bridge for Helix (mokh.hx)")]
struct Args {
    /// Name Claude shows in `/ide`.
    #[arg(long, default_value = "Helix")]
    ide_name: String,
    /// Workspace folder(s) to advertise; repeatable. Defaults to the cwd.
    #[arg(long = "workspace")]
    workspaces: Vec<String>,
    /// Directory for the lock file (default: $CLAUDE_CONFIG_DIR/ide or ~/.claude/ide).
    #[arg(long)]
    lock_dir: Option<PathBuf>,
    /// Port to listen on; 0 picks a free one.
    #[arg(long, default_value_t = 0)]
    port: u16,
}

fn random_token() -> String {
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

enum Exit {
    Normal,
    /// A newer bridge from the same editor asked us to step aside (SIGUSR1).
    Superseded,
}

/// Resolves when a signal asks us to stop. The handlers are installed when
/// this is called, not when the future is first polled.
#[cfg(unix)]
fn stop_signal() -> Result<impl std::future::Future<Output = Exit>> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).context("installing SIGTERM handler")?;
    // SIGHUP arrives when the terminal that started hx goes away;
    // without a handler it would kill us before the lock file is removed.
    let mut hup = signal(SignalKind::hangup()).context("installing SIGHUP handler")?;
    let mut usr1 = signal(SignalKind::user_defined1()).context("installing SIGUSR1 handler")?;
    Ok(async move {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => Exit::Normal,
            _ = term.recv() => Exit::Normal,
            _ = hup.recv() => Exit::Normal,
            _ = usr1.recv() => Exit::Superseded,
        }
    })
}

#[cfg(not(unix))]
fn stop_signal() -> Result<impl std::future::Future<Output = Exit>> {
    Ok(async {
        let _ = tokio::signal::ctrl_c().await;
        Exit::Normal
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let lock_dir = match args.lock_dir {
        Some(d) => d,
        None => lockfile::default_dir()?,
    };
    let workspaces = if args.workspaces.is_empty() {
        vec![std::env::current_dir()?.to_string_lossy().into_owned()]
    } else {
        args.workspaces
    };

    let listener = TcpListener::bind(("127.0.0.1", args.port))
        .await
        .context("binding the websocket port")?;
    let port = listener.local_addr()?.port();
    let token = random_token();

    let (to_editor, mut from_bridge) = mpsc::unbounded_channel::<Value>();
    let stdout_tx = to_editor.clone();
    let bridge = Bridge::new(token.clone(), args.ide_name.clone(), workspaces.clone(), to_editor);

    // Install signal handlers before the lock file exists: a newer bridge
    // finds us through it and may send SIGUSR1 straight away, whose default
    // action would kill us without telling the editor.
    let stop = stop_signal()?;

    for stale in lockfile::sweep_stale(&lock_dir) {
        eprintln!("mokh-bridge: removed stale lock file for port {stale}");
    }
    // Silently: our stderr is the editor's terminal, so printing here would
    // draw over Helix on every :config-reload.
    lockfile::retire_siblings(&lock_dir);
    lockfile::write(&lock_dir, port, &args.ide_name, &token, &workspaces)
        .context("writing the lock file")?;

    bridge.notify_editor("ready", json!({ "port": port, "lockDir": lock_dir.to_string_lossy() }));

    // stdout: everything the bridge wants to tell the editor, one JSON per line.
    let stdout_task = tokio::spawn(async move {
        let mut out = tokio::io::stdout();
        while let Some(value) = from_bridge.recv().await {
            // Null is our own "flush and stop" marker, never a real message.
            if value.is_null() {
                break;
            }
            let mut line = value.to_string();
            line.push('\n');
            if out.write_all(line.as_bytes()).await.is_err() || out.flush().await.is_err() {
                break;
            }
        }
    });

    let server = tokio::spawn(bridge.clone().serve(listener));

    // stdin: the editor's replies and notifications; EOF means the editor is gone.
    let stdin_bridge = bridge.clone();
    let stdin_lock_dir = lock_dir.clone();
    let stdin_token = token.clone();
    let stdin_task = tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.trim().is_empty() {
                continue;
            }
            let value: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("mokh-bridge: bad JSON from editor: {e}: {line}");
                    continue;
                }
            };
            match stdin_bridge.on_editor_message(value).await {
                Ok(Some(Control::Shutdown)) => break,
                Ok(Some(Control::WorkspaceChanged)) => {
                    let folders = stdin_bridge.workspace().await;
                    if let Err(e) = lockfile::write(&stdin_lock_dir, port, &stdin_bridge.ide_name, &stdin_token, &folders) {
                        eprintln!("mokh-bridge: rewriting lock file: {e:#}");
                    }
                }
                Ok(None) => {}
                Err(e) => eprintln!("mokh-bridge: {e:#}"),
            }
        }
    });

    let exit = tokio::select! {
        _ = stdin_task => Exit::Normal,
        e = stop => e,
        r = server => {
            if let Ok(Err(e)) = r { eprintln!("mokh-bridge: server error: {e:#}"); }
            Exit::Normal
        }
    };

    lockfile::remove(&lock_dir, port);
    match exit {
        Exit::Superseded => {
            // Tell the plugin this bridge was replaced, so its reader thread
            // stops without calling back into the editor: after a config
            // reload that thread belongs to a discarded Steel engine, and a
            // callback from it crashes hx. Flush before exiting.
            let _ = stdout_tx.send(json!({ "method": "superseded", "params": {} }));
            let _ = stdout_tx.send(Value::Null);
            let _ = tokio::time::timeout(std::time::Duration::from_secs(1), stdout_task).await;
        }
        Exit::Normal => stdout_task.abort(),
    }
    // Exit now rather than returning: dropping the runtime waits for the
    // blocking thread behind tokio::io::stdin, which only wakes on the next
    // line or EOF. After SIGTERM/SIGHUP the editor may still hold our stdin
    // open, so returning would hang here forever.
    std::process::exit(0)
}
