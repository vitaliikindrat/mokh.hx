//! A stand-in for Claude Code: finds the newest lock file, connects like the
//! CLI does, and runs tool calls from the command line. Useful to check an
//! editor integration without burning tokens.
//!
//!   cargo run --example claude-sim -- [--lock-dir DIR] list-tools
//!   cargo run --example claude-sim -- call openFile '{"filePath":"/tmp/x"}' listen 3 call getCurrentSelection '{}'
//!
//! Every response and notification is printed as one JSON line.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use mokh_bridge::{lockfile, AUTH_HEADER};
use serde_json::{json, Value};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

fn newest_lock(dir: &std::path::Path) -> Option<(u16, Value)> {
    let mut best: Option<(std::time::SystemTime, u16, Value)> = None;
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(port) = name.strip_suffix(".lock").and_then(|p| p.parse::<u16>().ok()) else { continue };
        let Ok(meta) = entry.metadata() else { continue };
        let modified = meta.modified().ok()?;
        let Ok(body) = std::fs::read(entry.path()) else { continue };
        let Ok(value) = serde_json::from_slice::<Value>(&body) else { continue };
        if best.as_ref().map(|(t, _, _)| modified > *t).unwrap_or(true) {
            best = Some((modified, port, value));
        }
    }
    best.map(|(_, p, v)| (p, v))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let lock_dir = if args.first().map(String::as_str) == Some("--lock-dir") {
        args.remove(0);
        std::path::PathBuf::from(args.remove(0))
    } else {
        lockfile::default_dir()?
    };
    let (port, lock) = newest_lock(&lock_dir).ok_or_else(|| anyhow::anyhow!("no lock file in {}", lock_dir.display()))?;
    let token = lock["authToken"].as_str().unwrap_or_default().to_string();
    eprintln!("claude-sim: {} on port {port} ({})", lock["ideName"], lock["workspaceFolders"]);

    let mut req = format!("ws://127.0.0.1:{port}").into_client_request()?;
    req.headers_mut().insert(AUTH_HEADER, token.parse()?);
    req.headers_mut().insert("sec-websocket-protocol", "mcp".parse()?);
    let (mut ws, _) = connect_async(req).await?;

    let mut next_id = 1u64;
    let mut call = |method: &str, params: Value| {
        let id = next_id;
        next_id += 1;
        (id, json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }).to_string())
    };

    // Handshake exactly as the CLI does it.
    let (id, init) = call("initialize", json!({ "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": { "name": "claude-sim", "version": "0" } }));
    ws.send(Message::Text(init.into())).await?;
    wait_for(&mut ws, id).await?;
    ws.send(Message::Text(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }).to_string().into())).await?;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "list-tools" => {
                let (id, msg) = call("tools/list", json!({}));
                ws.send(Message::Text(msg.into())).await?;
                let r = wait_for(&mut ws, id).await?;
                let names: Vec<&str> = r["result"]["tools"].as_array().map(|a| a.iter().filter_map(|t| t["name"].as_str()).collect()).unwrap_or_default();
                println!("{}", json!({ "tools": names }));
                i += 1;
            }
            "call" => {
                let name = args.get(i + 1).cloned().unwrap_or_default();
                let params: Value = serde_json::from_str(args.get(i + 2).map(String::as_str).unwrap_or("{}"))?;
                let (id, msg) = call("tools/call", json!({ "name": name, "arguments": params }));
                ws.send(Message::Text(msg.into())).await?;
                let r = wait_for(&mut ws, id).await?;
                println!("{}", json!({ "call": name, "response": r.get("result").or(r.get("error")) }));
                i += 3;
            }
            "listen" => {
                let secs: u64 = args.get(i + 1).and_then(|s| s.parse().ok()).unwrap_or(2);
                let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
                loop {
                    let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                    if remaining.is_zero() { break; }
                    match tokio::time::timeout(remaining, ws.next()).await {
                        Ok(Some(Ok(Message::Text(t)))) => println!("{}", json!({ "notification": serde_json::from_str::<Value>(&t)? })),
                        Ok(Some(Ok(_))) => {}
                        _ => break,
                    }
                }
                i += 2;
            }
            other => anyhow::bail!("unknown command {other}"),
        }
    }
    let _ = ws.close(None).await;
    Ok(())
}

/// Read until the response with `id` arrives; print notifications seen on the way.
async fn wait_for<S>(ws: &mut S, id: u64) -> anyhow::Result<Value>
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(120), ws.next()).await?.ok_or_else(|| anyhow::anyhow!("connection closed"))??;
        if let Message::Text(t) = msg {
            let v: Value = serde_json::from_str(&t)?;
            if v.get("id").and_then(Value::as_u64) == Some(id) {
                return Ok(v);
            }
            if v.get("method").is_some() {
                println!("{}", json!({ "notification": v }));
            }
        }
    }
}
