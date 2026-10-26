//! Unified diff for `openDiff`. Computed here rather than in Scheme: the
//! editor only has to display it.

use similar::TextDiff;

/// Unified diff between the file at `old_path` (empty when it does not exist
/// yet) and `new_contents`, with git-style `a/` and `b/` headers so Helix's
/// `diff` grammar highlights it.
pub fn unified(old_path: &str, new_contents: &str) -> String {
    let old = std::fs::read_to_string(old_path).unwrap_or_default();
    unified_text(old_path, &old, new_contents)
}

pub fn unified_text(path: &str, old: &str, new: &str) -> String {
    TextDiff::from_lines(old, new)
        .unified_diff()
        .context_radius(3)
        .header(&format!("a/{path}"), &format!("b/{path}"))
        .to_string()
}

/// (added, removed) line counts, for a one-line summary in the editor.
pub fn stats(old: &str, new: &str) -> (usize, usize) {
    let diff = TextDiff::from_lines(old, new);
    let mut added = 0;
    let mut removed = 0;
    for change in diff.iter_all_changes() {
        match change.tag() {
            similar::ChangeTag::Insert => added += 1,
            similar::ChangeTag::Delete => removed += 1,
            similar::ChangeTag::Equal => {}
        }
    }
    (added, removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unified_has_headers_and_markers() {
        let d = unified_text("x.rs", "a\nb\nc\n", "a\nB\nc\n");
        assert!(d.starts_with("--- a/x.rs\n+++ b/x.rs\n"), "{d}");
        assert!(d.contains("-b\n"));
        assert!(d.contains("+B\n"));
    }

    #[test]
    fn missing_old_file_is_an_all_additions_diff() {
        let d = unified("/nonexistent/mokh/file.txt", "one\ntwo\n");
        assert!(d.contains("+one\n") && d.contains("+two\n"));
        assert_eq!(stats("", "one\ntwo\n"), (2, 0));
    }
}
