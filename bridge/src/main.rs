//! `mokh-bridge`: run by the mokh.hx Steel plugin, talks JSON lines on stdio.
//!
//! Lifecycle: bind, write the lock file, print `ready`, serve until stdin
//! closes (the editor went away), a `shutdown` message arrives, or SIGTERM /
//! Ctrl-C. The lock file is removed on every exit path so Claude's `/ide`
//! never lists a dead editor.

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
    let bridge = Bridge::new(token.clone(), args.ide_name.clone(), workspaces.clone(), to_editor);

    for stale in lockfile::sweep_stale(&lock_dir) {
        eprintln!("mokh-bridge: removed stale lock file for port {stale}");
    }
    lockfile::write(&lock_dir, port, &args.ide_name, &token, &workspaces)
        .context("writing the lock file")?;

    bridge.notify_editor("ready", json!({ "port": port, "lockDir": lock_dir.to_string_lossy() }));

    // stdout: everything the bridge wants to tell the editor, one JSON per line.
    let stdout_task = tokio::spawn(async move {
        let mut out = tokio::io::stdout();
        while let Some(value) = from_bridge.recv().await {
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

    let terminate = async {
        #[cfg(unix)]
        {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("installing SIGTERM handler");
            // SIGHUP arrives when the terminal that started hx goes away;
            // without a handler it would kill us before the lock file is removed.
            let mut hup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())
                .expect("installing SIGHUP handler");
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
                _ = hup.recv() => {}
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
    };

    tokio::select! {
        _ = stdin_task => {}
        _ = terminate => {}
        r = server => {
            if let Ok(Err(e)) = r { eprintln!("mokh-bridge: server error: {e:#}"); }
        }
    }

    lockfile::remove(&lock_dir, port);
    stdout_task.abort();
    Ok(())
}
