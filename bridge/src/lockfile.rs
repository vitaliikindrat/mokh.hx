//! The discovery file Claude Code reads: `<dir>/<port>.lock`, where `<dir>`
//! is `$CLAUDE_CONFIG_DIR/ide` or `~/.claude/ide`. Claude lists these for
//! `/ide`, connects to the port and presents `authToken` in a header.

use anyhow::{Context, Result};
use serde_json::json;
use std::path::{Path, PathBuf};

pub fn default_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var("CLAUDE_CONFIG_DIR").ok().filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(dir).join("ide"));
    }
    let home = std::env::var("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".claude").join("ide"))
}

pub fn path_for(dir: &Path, port: u16) -> PathBuf {
    dir.join(format!("{port}.lock"))
}

pub fn write(dir: &Path, port: u16, ide_name: &str, token: &str, folders: &[String]) -> Result<PathBuf> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    set_mode(dir, 0o700);
    let body = json!({
        "pid": std::process::id(),
        "editorPid": editor_pid(),
        "workspaceFolders": folders,
        "ideName": ide_name,
        "transport": "ws",
        "authToken": token,
    });
    let path = path_for(dir, port);
    // Write next to the target and rename, so a reader never sees a torn file.
    let tmp = dir.join(format!(".{port}.lock.{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec(&body)?)?;
    set_mode(&tmp, 0o600);
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}

/// The editor that spawned us. Recorded in the lock file so a later bridge
/// from the same editor can find and retire this one.
pub fn editor_pid() -> u32 {
    #[cfg(unix)]
    {
        unsafe { libc::getppid() as u32 }
    }
    #[cfg(not(unix))]
    {
        0
    }
}

/// Retire older bridges started by the same editor process. Steel-enabled
/// Helix rebuilds its scripting engine on `:config-reload` and re-runs
/// init.scm, so the plugin starts a fresh bridge while the old one, owned by
/// the discarded engine, would otherwise live until the editor exits. Each
/// sibling gets SIGUSR1: it tells its plugin it was superseded, removes its
/// own lock file and exits. We remove the lock file too, so `/ide` never
/// lists it in the meantime. Only lock files carrying `editorPid` are
/// considered, so bridges too old to handle SIGUSR1 are left alone. Returns
/// the pids signalled.
pub fn retire_siblings(dir: &Path) -> Vec<u32> {
    let me = std::process::id();
    let editor = editor_pid();
    let mut retired = Vec::new();
    // pid 1 means we were orphaned: every orphan would look like a sibling.
    if editor <= 1 {
        return retired;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return retired;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".lock") {
            continue;
        }
        let Ok(body) = std::fs::read(entry.path()) else { continue };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) else { continue };
        let pid = value.get("pid").and_then(serde_json::Value::as_u64).map(|p| p as u32);
        let owner = value.get("editorPid").and_then(serde_json::Value::as_u64).map(|p| p as u32);
        let (Some(pid), Some(owner)) = (pid, owner) else { continue };
        if owner != editor || pid == me {
            continue;
        }
        if process_alive(pid) {
            supersede(pid);
            retired.push(pid);
        }
        let _ = std::fs::remove_file(entry.path());
    }
    retired
}

#[cfg(unix)]
fn supersede(pid: u32) {
    unsafe {
        libc::kill(pid as i32, libc::SIGUSR1);
    }
}

#[cfg(not(unix))]
fn supersede(_pid: u32) {}

pub fn remove(dir: &Path, port: u16) {
    let _ = std::fs::remove_file(path_for(dir, port));
}

/// Delete lock files whose `pid` is no longer alive, so a bridge that died
/// without cleaning up (SIGKILL, power loss) does not leave a dead "Helix"
/// in Claude's `/ide` list forever. Returns the ports removed.
pub fn sweep_stale(dir: &Path) -> Vec<u16> {
    let mut removed = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return removed;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(port) = name.strip_suffix(".lock").and_then(|p| p.parse::<u16>().ok()) else { continue };
        let Ok(body) = std::fs::read(entry.path()) else { continue };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) else { continue };
        let Some(pid) = value.get("pid").and_then(serde_json::Value::as_u64) else { continue };
        if !process_alive(pid as u32) {
            let _ = std::fs::remove_file(entry.path());
            removed.push(port);
        }
    }
    removed
}

#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    // kill(pid, 0) probes without signalling; EPERM still means it exists.
    let r = unsafe { libc::kill(pid as i32, 0) };
    r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn process_alive(_pid: u32) -> bool {
    true
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_the_fields_claude_reads() {
        let dir = std::env::temp_dir().join(format!("mokh-lock-test-{}", std::process::id()));
        let path = write(&dir, 43210, "Helix", "deadbeef", &["/tmp/proj".into()]).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(v["ideName"], "Helix");
        assert_eq!(v["transport"], "ws");
        assert_eq!(v["authToken"], "deadbeef");
        assert_eq!(v["workspaceFolders"][0], "/tmp/proj");
        assert_eq!(v["pid"], std::process::id());
        assert_eq!(v["editorPid"], editor_pid());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        remove(&dir, 43210);
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn retire_siblings_signals_only_bridges_of_our_editor() {
        let dir = std::env::temp_dir().join(format!("mokh-retire-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let editor = editor_pid();
        // A live sibling from our editor (a child we can signal and reap).
        let mut sibling = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        std::fs::write(
            dir.join("50011.lock"),
            serde_json::to_vec(&json!({"pid": sibling.id(), "editorPid": editor})).unwrap(),
        )
        .unwrap();
        // Another editor's bridge: untouched.
        std::fs::write(
            dir.join("50012.lock"),
            serde_json::to_vec(&json!({"pid": std::process::id(), "editorPid": editor + 1})).unwrap(),
        )
        .unwrap();
        // Our own lock file: untouched.
        write(&dir, 50013, "Helix", "a", &[]).unwrap();
        // An old-format lock without editorPid: untouched.
        std::fs::write(dir.join("50014.lock"), r#"{"pid": 1}"#).unwrap();

        let retired = retire_siblings(&dir);

        assert_eq!(retired, vec![sibling.id()]);
        assert!(!sibling.wait().unwrap().success());
        assert!(!path_for(&dir, 50011).exists());
        assert!(path_for(&dir, 50012).exists());
        assert!(path_for(&dir, 50013).exists());
        assert!(path_for(&dir, 50014).exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn sweep_removes_dead_pids_and_keeps_live_ones() {
        let dir = std::env::temp_dir().join(format!("mokh-sweep-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // Ours: alive. A pid that cannot exist on Linux (> pid_max): dead.
        write(&dir, 50001, "Helix", "a", &[]).unwrap();
        std::fs::write(dir.join("50002.lock"), r#"{"pid": 4194304000, "ideName": "Helix"}"#).unwrap();
        std::fs::write(dir.join("not-a-lock.txt"), "x").unwrap();
        let removed = sweep_stale(&dir);
        assert_eq!(removed, vec![50002]);
        assert!(path_for(&dir, 50001).exists());
        assert!(!path_for(&dir, 50002).exists());
        let _ = std::fs::remove_dir_all(dir);
    }
}
