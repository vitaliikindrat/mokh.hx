//! The bridge proper: a WebSocket/MCP server towards Claude Code on one side,
//! a channel of JSON values towards the editor on the other.
//!
//! Editor protocol (newline-delimited JSON, both directions):
//!
//! * bridge → editor request: `{"id": N, "method": "<tool>", "params": {...}}`
//!   where `<tool>` is one of [`crate::mcp::FORWARDED`]. `openDiff` params
//!   additionally carry `"diff"`, a unified diff ready to display.
//! * editor → bridge response: `{"id": N, "result": <value>}` or
//!   `{"id": N, "error": "<message>"}`. `result` is wrapped with
//!   [`crate::mcp::wrap_result`] before Claude sees it.
//! * editor → bridge notification: `{"method": "selection_changed" |
//!   "at_mentioned", "params": {...}}` is forwarded to every connected Claude;
//!   `{"method": "workspace", "params": {"folders": [...]}}` replaces the
//!   advertised workspace folders; `{"method": "shutdown"}` ends the bridge.
//! * bridge → editor notification: `ready` (with `port`), `connected`,
//!   `disconnected`, so the editor can show a status.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex, RwLock};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::StatusCode;
use tokio_tungstenite::tungstenite::Message;

use crate::{diff, mcp};

/// Header Claude Code presents on connect; its value is the lock file token.
pub const AUTH_HEADER: &str = "x-claude-code-ide-authorization";

type ConnId = u64;

/// What the editor asked the bridge process to do, surfaced to `main`.
#[derive(Debug, PartialEq, Eq)]
pub enum Control {
    WorkspaceChanged,
    Shutdown,
}

pub struct Bridge {
    pub token: String,
    pub ide_name: String,
    workspace: RwLock<Vec<String>>,
    to_editor: mpsc::UnboundedSender<Value>,
    pending: Mutex<HashMap<u64, (ConnId, Value)>>,
    conns: Mutex<HashMap<ConnId, mpsc::UnboundedSender<Message>>>,
    next_request: AtomicU64,
    next_conn: AtomicU64,
}

impl Bridge {
    pub fn new(
        token: String,
        ide_name: String,
        workspace: Vec<String>,
        to_editor: mpsc::UnboundedSender<Value>,
    ) -> Arc<Self> {
        Arc::new(Self {
            token,
            ide_name,
            workspace: RwLock::new(workspace),
            to_editor,
            pending: Mutex::new(HashMap::new()),
            conns: Mutex::new(HashMap::new()),
            next_request: AtomicU64::new(1),
            next_conn: AtomicU64::new(1),
        })
    }

    pub async fn workspace(&self) -> Vec<String> {
        self.workspace.read().await.clone()
    }

    pub async fn connections(&self) -> usize {
        self.conns.lock().await.len()
    }

    /// Accept Claude connections forever.
    pub async fn serve(self: Arc<Self>, listener: TcpListener) -> Result<()> {
        loop {
            let (stream, _) = listener.accept().await?;
            let bridge = self.clone();
            tokio::spawn(async move {
                if let Err(e) = bridge.handle_connection(stream).await {
                    eprintln!("mokh-bridge: connection ended: {e:#}");
                }
            });
        }
    }

    async fn handle_connection(self: Arc<Self>, stream: TcpStream) -> Result<()> {
        let token = self.token.clone();
        // tungstenite's ErrorResponse is a full http::Response; clippy flags its size.
        #[allow(clippy::result_large_err)]
        let check = move |req: &Request, mut resp: Response| -> std::result::Result<Response, ErrorResponse> {
            let presented = req.headers().get(AUTH_HEADER).and_then(|v| v.to_str().ok());
            if presented != Some(token.as_str()) {
                let mut denied = ErrorResponse::new(Some("unauthorized".to_string()));
                *denied.status_mut() = StatusCode::UNAUTHORIZED;
                return Err(denied);
            }
            // Claude offers the `mcp` subprotocol and expects it echoed.
            let offers_mcp = req
                .headers()
                .get("sec-websocket-protocol")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.split(',').any(|p| p.trim() == "mcp"))
                .unwrap_or(false);
            if offers_mcp {
                resp.headers_mut()
                    .insert("sec-websocket-protocol", "mcp".parse().expect("static header value"));
            }
            Ok(resp)
        };
        let ws = tokio_tungstenite::accept_hdr_async(stream, check).await?;
        let (mut sink, mut source) = ws.split();

        let conn = self.next_conn.fetch_add(1, Ordering::Relaxed);
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        self.conns.lock().await.insert(conn, tx);
        self.notify_editor("connected", json!({ "connection": conn }));

        let writer = tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                if sink.send(msg).await.is_err() {
                    break;
                }
            }
        });

        let outcome: Result<()> = async {
            while let Some(msg) = source.next().await {
                match msg? {
                    Message::Text(text) => {
                        let value: Value = match serde_json::from_str(&text) {
                            Ok(v) => v,
                            Err(e) => {
                                eprintln!("mokh-bridge: bad JSON from claude: {e}");
                                continue;
                            }
                        };
                        if let Some(reply) = self.handle_rpc(conn, value).await {
                            self.send_to(conn, reply).await;
                        }
                    }
                    Message::Ping(_) | Message::Pong(_) | Message::Binary(_) | Message::Frame(_) => {}
                    Message::Close(_) => break,
                }
            }
            Ok(())
        }
        .await;

        self.conns.lock().await.remove(&conn);
        // Requests this Claude was waiting on can never be answered to it;
        // forget them so a late editor reply is dropped instead of misrouted.
        self.pending.lock().await.retain(|_, (c, _)| *c != conn);
        writer.abort();
        self.notify_editor("disconnected", json!({ "connection": conn }));
        outcome
    }

    /// One JSON-RPC message from Claude. Returns the response to send back,
    /// if any (notifications and forwarded tool calls produce none here).
    pub async fn handle_rpc(&self, conn: ConnId, msg: Value) -> Option<Value> {
        let id = msg.get("id").cloned();
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("").to_string();
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));

        let ok = |id: &Option<Value>, result: Value| {
            id.as_ref().map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": result }))
        };
        let err = |id: &Option<Value>, code: i64, message: String| {
            id.as_ref().map(|id| json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }))
        };

        match method.as_str() {
            "initialize" => ok(&id, mcp::initialize_result(&params, &self.ide_name)),
            "ping" => ok(&id, json!({})),
            "tools/list" => ok(&id, json!({ "tools": mcp::tools() })),
            "tools/call" => {
                let name = params.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                let mut args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                match name.as_str() {
                    "getWorkspaceFolders" => {
                        let folders = self.workspace().await;
                        ok(&id, mcp::workspace_folders_result(&folders))
                    }
                    "executeCode" => ok(&id, mcp::error_result("executeCode is not supported by mokh.hx")),
                    n if mcp::is_forwarded(n) => {
                        let Some(rpc_id) = id else { return None };
                        if n == "openDiff" {
                            let old = args.get("old_file_path").and_then(Value::as_str).unwrap_or("");
                            let new = args.get("new_file_contents").and_then(Value::as_str).unwrap_or("");
                            let diff_text = diff::unified(old, new);
                            let (added, removed) = diff::stats(
                                &std::fs::read_to_string(old).unwrap_or_default(),
                                new,
                            );
                            args["diff"] = Value::String(diff_text);
                            args["added"] = json!(added);
                            args["removed"] = json!(removed);
                        }
                        let request = self.next_request.fetch_add(1, Ordering::Relaxed);
                        self.pending.lock().await.insert(request, (conn, rpc_id));
                        let _ = self.to_editor.send(json!({ "id": request, "method": n, "params": args }));
                        None
                    }
                    other => err(&id, -32601, format!("unknown tool: {other}")),
                }
            }
            m if m.starts_with("notifications/") => None,
            other => err(&id, -32601, format!("method not found: {other}")),
        }
    }

    /// One line from the editor.
    pub async fn on_editor_message(&self, msg: Value) -> Result<Option<Control>> {
        // Responses carry our numeric request id. Scheme's JSON turns every
        // number into a float, so accept 7.0 for 7.
        if let Some(request) = msg.get("id").and_then(Value::as_f64) {
            let request = request.round() as u64;
            let Some((conn, rpc_id)) = self.pending.lock().await.remove(&request) else {
                return Err(anyhow!("response for unknown request {request}"));
            };
            let payload = match msg.get("error") {
                Some(e) => mcp::error_result(e.as_str().unwrap_or(&e.to_string())),
                None => mcp::wrap_result(msg.get("result").cloned().unwrap_or(Value::Null)),
            };
            self.send_to(conn, json!({ "jsonrpc": "2.0", "id": rpc_id, "result": payload })).await;
            return Ok(None);
        }
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
        match method {
            "selection_changed" | "at_mentioned" => {
                self.broadcast(json!({ "jsonrpc": "2.0", "method": method, "params": params })).await;
                Ok(None)
            }
            "workspace" => {
                let folders: Vec<String> = params
                    .get("folders")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                    .unwrap_or_default();
                *self.workspace.write().await = folders;
                Ok(Some(Control::WorkspaceChanged))
            }
            "shutdown" => Ok(Some(Control::Shutdown)),
            other => Err(anyhow!("unknown message from editor: {other:?}")),
        }
    }

    pub fn notify_editor(&self, method: &str, params: Value) {
        let _ = self.to_editor.send(json!({ "method": method, "params": params }));
    }

    async fn send_to(&self, conn: ConnId, value: Value) {
        if let Some(tx) = self.conns.lock().await.get(&conn) {
            let _ = tx.send(Message::Text(value.to_string().into()));
        }
    }

    async fn broadcast(&self, value: Value) {
        let text = value.to_string();
        for tx in self.conns.lock().await.values() {
            let _ = tx.send(Message::Text(text.clone().into()));
        }
    }
}
