//! The MCP surface Claude Code expects from an IDE: tool definitions and the
//! result shapes. Names and schemas follow the VS Code extension as documented
//! by coder/claudecode.nvim; Claude matches on them, so they are not ours to
//! rename.

use serde_json::{json, Value};

pub const PROTOCOL_VERSION: &str = "2024-11-05";
pub const SERVER_NAME: &str = "mokh.hx";

/// Tools the editor answers. Everything except `getWorkspaceFolders` (known
/// to the bridge) and `executeCode` (Jupyter only, refused) is forwarded to
/// Helix verbatim.
pub const FORWARDED: &[&str] = &[
    "openFile",
    "openDiff",
    "getCurrentSelection",
    "getLatestSelection",
    "getOpenEditors",
    "getDiagnostics",
    "checkDocumentDirty",
    "saveDocument",
    "close_tab",
    "closeAllDiffTabs",
];

pub fn is_forwarded(name: &str) -> bool {
    FORWARDED.contains(&name)
}

pub fn initialize_result(params: &Value, ide_name: &str) -> Value {
    let version = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .unwrap_or(PROTOCOL_VERSION);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": { "listChanged": false } },
        "serverInfo": {
            "name": SERVER_NAME,
            "version": env!("CARGO_PKG_VERSION"),
            "ide": ide_name,
        }
    })
}

fn tool(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
            "$schema": "http://json-schema.org/draft-07/schema#",
        }
    })
}

pub fn tools() -> Vec<Value> {
    let s = |d: &str| json!({ "type": "string", "description": d });
    let b = |d: &str| json!({ "type": "boolean", "description": d });
    vec![
        tool(
            "openFile",
            "Open a file in the editor and optionally select a range of text",
            json!({
                "filePath": s("Path to the file to open"),
                "preview": b("Whether to open in preview mode"),
                "startText": s("Text pattern to find the start of the selection"),
                "endText": s("Text pattern to find the end of the selection"),
                "selectToEndOfLine": b("Extend the selection to the end of the line"),
                "makeFrontmost": b("Whether to make the file the frontmost editor"),
            }),
            &["filePath"],
        ),
        tool(
            "openDiff",
            "Open a diff view comparing old file content with new file content; blocks until the user accepts (FILE_SAVED) or rejects (DIFF_REJECTED)",
            json!({
                "old_file_path": s("Path to the original file"),
                "new_file_path": s("Path the new content would be written to"),
                "new_file_contents": s("The proposed content"),
                "tab_name": s("Name identifying this diff"),
            }),
            &["old_file_path", "new_file_path", "new_file_contents", "tab_name"],
        ),
        tool(
            "getCurrentSelection",
            "Get the current text selection in the active editor",
            json!({}),
            &[],
        ),
        tool(
            "getLatestSelection",
            "Get the most recent text selection, even if the editor is no longer active",
            json!({}),
            &[],
        ),
        tool(
            "getOpenEditors",
            "Get information about currently open files",
            json!({}),
            &[],
        ),
        tool(
            "getWorkspaceFolders",
            "Get the workspace folders currently open in the editor",
            json!({}),
            &[],
        ),
        tool(
            "getDiagnostics",
            "Get language diagnostics (errors, warnings) for a file or the whole workspace",
            json!({ "uri": s("File URI to get diagnostics for; all files when omitted") }),
            &[],
        ),
        tool(
            "checkDocumentDirty",
            "Check whether a document has unsaved changes",
            json!({ "filePath": s("Path to the file") }),
            &["filePath"],
        ),
        tool(
            "saveDocument",
            "Save a document with unsaved changes",
            json!({ "filePath": s("Path to the file") }),
            &["filePath"],
        ),
        tool(
            "close_tab",
            "Close a diff view by its tab name",
            json!({ "tab_name": s("Name of the diff tab to close") }),
            &["tab_name"],
        ),
        tool(
            "closeAllDiffTabs",
            "Close all open diff views",
            json!({}),
            &[],
        ),
        tool(
            "executeCode",
            "Execute Python code in the Jupyter kernel of the current notebook (not supported by this editor)",
            json!({ "code": s("Code to execute") }),
            &["code"],
        ),
    ]
}

/// MCP tool results are a `content` list. Helix may already answer with one
/// (openDiff does, so it can say FILE_SAVED and carry the text); anything
/// else is serialized into a single text item, which is what Claude parses.
pub fn wrap_result(result: Value) -> Value {
    if result.get("content").map(Value::is_array).unwrap_or(false) {
        return result;
    }
    let text = match result {
        Value::String(s) => s,
        other => other.to_string(),
    };
    json!({ "content": [ { "type": "text", "text": text } ] })
}

pub fn error_result(message: &str) -> Value {
    json!({ "content": [ { "type": "text", "text": message } ], "isError": true })
}

pub fn workspace_folders_result(folders: &[String]) -> Value {
    let list: Vec<Value> = folders
        .iter()
        .map(|path| {
            let name = std::path::Path::new(path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.clone());
            json!({ "name": name, "uri": format!("file://{path}"), "path": path })
        })
        .collect();
    wrap_result(json!({
        "success": true,
        "folders": list,
        "rootPath": folders.first().cloned().unwrap_or_default(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_forwarded_tool_is_advertised() {
        let names: Vec<String> = tools()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect();
        for f in FORWARDED {
            assert!(names.iter().any(|n| n == f), "{f} missing from tools/list");
        }
        assert!(names.iter().any(|n| n == "getWorkspaceFolders"));
    }

    #[test]
    fn wrap_passes_content_through_and_stringifies_the_rest() {
        let passthrough = json!({ "content": [ { "type": "text", "text": "FILE_SAVED" } ] });
        assert_eq!(wrap_result(passthrough.clone()), passthrough);
        let wrapped = wrap_result(json!({ "isDirty": false }));
        assert_eq!(wrapped["content"][0]["text"], "{\"isDirty\":false}");
        let plain = wrap_result(json!("TAB_CLOSED"));
        assert_eq!(plain["content"][0]["text"], "TAB_CLOSED");
    }

    #[test]
    fn workspace_folders_carry_name_uri_and_path() {
        let r = workspace_folders_result(&["/home/me/proj".into()]);
        let text: Value = serde_json::from_str(r["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(text["folders"][0]["name"], "proj");
        assert_eq!(text["folders"][0]["uri"], "file:///home/me/proj");
        assert_eq!(text["rootPath"], "/home/me/proj");
    }
}
