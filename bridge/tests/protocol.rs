//! End-to-end: a fake Claude Code client over a real WebSocket, a fake editor
//! on the channel side.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use mokh_bridge::{Bridge, Control, AUTH_HEADER};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

struct Harness {
    bridge: Arc<Bridge>,
    from_bridge: UnboundedReceiver<Value>,
    port: u16,
}

async fn start() -> Harness {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = mpsc::unbounded_channel();
    let bridge = Bridge::new("t0k3n".into(), "Helix".into(), vec!["/tmp/proj".into()], tx);
    tokio::spawn(bridge.clone().serve(listener));
    Harness { bridge, from_bridge: rx, port }
}

async fn connect(port: u16, token: Option<&str>) -> Result<Ws, tokio_tungstenite::tungstenite::Error> {
    let mut req = format!("ws://127.0.0.1:{port}").into_client_request().unwrap();
    if let Some(t) = token {
        req.headers_mut().insert(AUTH_HEADER, t.parse().unwrap());
    }
    req.headers_mut().insert("sec-websocket-protocol", "mcp".parse().unwrap());
    connect_async(req).await.map(|(ws, _)| ws)
}

async fn rpc(ws: &mut Ws, id: u64, method: &str, params: Value) -> Value {
    ws.send(Message::Text(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }).to_string().into()))
        .await
        .unwrap();
    recv(ws).await
}

async fn recv(ws: &mut Ws) -> Value {
    let msg = tokio::time::timeout(Duration::from_secs(5), ws.next()).await.expect("timed out").unwrap().unwrap();
    serde_json::from_str(msg.to_text().unwrap()).unwrap()
}

async fn next_editor_message(h: &mut Harness) -> Value {
    tokio::time::timeout(Duration::from_secs(5), h.from_bridge.recv()).await.expect("timed out").unwrap()
}

/// Skip the `connected`/`disconnected` status lines the bridge emits.
async fn next_editor_request(h: &mut Harness) -> Value {
    loop {
        let m = next_editor_message(h).await;
        if m.get("id").is_some() {
            return m;
        }
    }
}

#[tokio::test]
async fn rejects_a_connection_without_the_token() {
    let h = start().await;
    assert!(connect(h.port, None).await.is_err());
    assert!(connect(h.port, Some("wrong")).await.is_err());
    assert!(connect(h.port, Some("t0k3n")).await.is_ok());
}

#[tokio::test]
async fn initialize_and_list_tools() {
    let h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    let init = rpc(&mut ws, 1, "initialize", json!({ "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": { "name": "claude-code" } })).await;
    assert_eq!(init["result"]["serverInfo"]["name"], "mokh.hx");
    assert_eq!(init["result"]["protocolVersion"], "2024-11-05");
    ws.send(Message::Text(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }).to_string().into())).await.unwrap();
    let tools = rpc(&mut ws, 2, "tools/list", json!({})).await;
    let names: Vec<&str> = tools["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert!(names.contains(&"openDiff") && names.contains(&"getWorkspaceFolders") && names.contains(&"close_tab"));
}

#[tokio::test]
async fn workspace_folders_are_answered_locally() {
    let h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    let r = rpc(&mut ws, 3, "tools/call", json!({ "name": "getWorkspaceFolders", "arguments": {} })).await;
    let text: Value = serde_json::from_str(r["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(text["folders"][0]["path"], "/tmp/proj");
    assert_eq!(text["rootPath"], "/tmp/proj");
}

#[tokio::test]
async fn forwarded_tool_round_trips_through_the_editor() {
    let mut h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    ws.send(Message::Text(json!({ "jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": { "name": "openFile", "arguments": { "filePath": "/tmp/proj/a.rs" } } }).to_string().into())).await.unwrap();
    let req = next_editor_request(&mut h).await;
    assert_eq!(req["method"], "openFile");
    assert_eq!(req["params"]["filePath"], "/tmp/proj/a.rs");
    // The editor answers with a float id, as Scheme's JSON would.
    let id = req["id"].as_u64().unwrap() as f64;
    h.bridge.on_editor_message(json!({ "id": id, "result": { "success": true, "filePath": "/tmp/proj/a.rs" } })).await.unwrap();
    let resp = recv(&mut ws).await;
    assert_eq!(resp["id"], 7);
    assert_eq!(resp["result"]["content"][0]["type"], "text");
    let text: Value = serde_json::from_str(resp["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(text["success"], true);
}

#[tokio::test]
async fn open_diff_carries_a_unified_diff_and_passes_content_through() {
    let mut h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    let dir = std::env::temp_dir().join(format!("mokh-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let old = dir.join("x.txt");
    std::fs::write(&old, "one\ntwo\n").unwrap();
    ws.send(Message::Text(json!({ "jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": { "name": "openDiff", "arguments": {
        "old_file_path": old.to_string_lossy(), "new_file_path": old.to_string_lossy(), "new_file_contents": "one\nTWO\n", "tab_name": "✻ [Claude Code] x.txt ⧉" } } }).to_string().into())).await.unwrap();
    let req = next_editor_request(&mut h).await;
    assert_eq!(req["method"], "openDiff");
    let diff = req["params"]["diff"].as_str().unwrap();
    assert!(diff.contains("-two\n") && diff.contains("+TWO\n"), "{diff}");
    assert_eq!(req["params"]["added"], 1);
    assert_eq!(req["params"]["removed"], 1);
    // Editor accepts: it answers with an MCP content list of its own.
    h.bridge.on_editor_message(json!({ "id": req["id"], "result": { "content": [ { "type": "text", "text": "FILE_SAVED" }, { "type": "text", "text": "one\nTWO\n" } ] } })).await.unwrap();
    let resp = recv(&mut ws).await;
    assert_eq!(resp["id"], 9);
    assert_eq!(resp["result"]["content"][0]["text"], "FILE_SAVED");
    assert_eq!(resp["result"]["content"][1]["text"], "one\nTWO\n");
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn editor_errors_become_mcp_errors() {
    let mut h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    ws.send(Message::Text(json!({ "jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": { "name": "saveDocument", "arguments": { "filePath": "/nope" } } }).to_string().into())).await.unwrap();
    let req = next_editor_request(&mut h).await;
    h.bridge.on_editor_message(json!({ "id": req["id"], "error": "not open" })).await.unwrap();
    let resp = recv(&mut ws).await;
    assert_eq!(resp["result"]["isError"], true);
    assert_eq!(resp["result"]["content"][0]["text"], "not open");
}

#[tokio::test]
async fn editor_notifications_reach_claude_and_control_messages_surface() {
    let h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    // Wait until the connection is registered before broadcasting.
    for _ in 0..50 {
        if h.bridge.connections().await == 1 { break; }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let sel = json!({ "text": "foo", "filePath": "/tmp/proj/a.rs", "fileUrl": "file:///tmp/proj/a.rs",
        "selection": { "start": { "line": 1, "character": 0 }, "end": { "line": 1, "character": 3 }, "isEmpty": false } });
    assert_eq!(h.bridge.on_editor_message(json!({ "method": "selection_changed", "params": sel })).await.unwrap(), None);
    let n = recv(&mut ws).await;
    assert_eq!(n["method"], "selection_changed");
    assert_eq!(n["params"]["text"], "foo");
    assert!(n.get("id").is_none());

    assert_eq!(
        h.bridge.on_editor_message(json!({ "method": "workspace", "params": { "folders": ["/tmp/other"] } })).await.unwrap(),
        Some(Control::WorkspaceChanged)
    );
    assert_eq!(h.bridge.workspace().await, vec!["/tmp/other".to_string()]);
    assert_eq!(h.bridge.on_editor_message(json!({ "method": "shutdown" })).await.unwrap(), Some(Control::Shutdown));
}

#[tokio::test]
async fn unknown_tool_and_unsupported_tool_are_reported() {
    let h = start().await;
    let mut ws = connect(h.port, Some("t0k3n")).await.unwrap();
    let r = rpc(&mut ws, 20, "tools/call", json!({ "name": "executeCode", "arguments": { "code": "1" } })).await;
    assert_eq!(r["result"]["isError"], true);
    let r = rpc(&mut ws, 21, "tools/call", json!({ "name": "nope", "arguments": {} })).await;
    assert_eq!(r["error"]["code"], -32601);
}
