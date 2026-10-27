#!/usr/bin/env bash
# Starts the demo: zellij with hx (left, mokh loaded) and Claude Code (right,
# auto-connected to that hx) in a throwaway project. Used by docs/demo.tape
# (VHS) to render docs/demo.gif; also fine to run by hand.
#
# Needs: a Steel hx on PATH (or $HX) with the virtual-text patch, mokh-bridge
# on PATH, zellij, and a logged-in Claude Code (its credentials are copied
# into an isolated config dir so the demo connects to this hx and not to
# whatever other editors are open). Costs a few Haiku tokens.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${DEMO_DIR:-$(mktemp -d -t mokh-demo.XXXXXX)}
hx=${HX:-hx}
model=${MODEL:-haiku}

mkdir -p "$work"/{proj,cfg/themes,home/cogs,claude-config/ide,diffs}

# the cog, straight from this checkout
ln -sfn "$repo" "$work/home/cogs/mokh"

# helix: the user's config if there is one (theme etc.), plus the Steel files
cfg=${XDG_CONFIG_HOME:-$HOME/.config}/helix
[ -f "$cfg/config.toml" ] && cp "$cfg/config.toml" "$work/cfg/config.toml"
[ -d "$cfg/themes" ] && cp -rL "$cfg/themes/." "$work/cfg/themes/" 2>/dev/null || true
mkdir -p "$work/cfg/themes/yank_flash"
cat > "$work/cfg/helix.scm" <<'EOF'
(provide noop)
(define (noop) void)
EOF
cat > "$work/cfg/init.scm" <<EOF
(require (only-in "helix/keymaps.scm" keymap))
(require "mokh/mokh.scm")
(mokh-configure! #:diff-root "$work/diffs")
(mokh-start)
(keymap (global)
        (normal (space (m (a ":mokh-accept") (r ":mokh-reject") (e ":mokh-edit")
                          (n ":mokh-next-hunk") (p ":mokh-prev-hunk")
                          (s ":mokh-send") (f ":mokh-send-file")))))
EOF

# the project Claude edits
cat > "$work/proj/app.py" <<'EOF'
import json
from pathlib import Path


def load_config(path):
    with open(path) as f:
        return json.load(f)


def greet(name):
    return "Hello, " + name


if __name__ == "__main__":
    cfg = load_config(Path("config.json"))
    print(greet(cfg["user"]))
EOF
echo '{"user": "vitalii"}' > "$work/proj/config.json"
git -C "$work/proj" init -q 2>/dev/null || true
git -C "$work/proj" add . && git -C "$work/proj" -c user.email=demo@mokh -c user.name=demo commit -qm init 2>/dev/null || true

# Claude: isolated config dir with the real credentials, the demo dir
# pre-trusted, no hooks
claude_home=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
cp "$claude_home/.credentials.json" "$work/claude-config/" 2>/dev/null || true
state=$HOME/.claude.json
[ -f "$claude_home/.claude.json" ] && state=$claude_home/.claude.json
if [ -f "$state" ]; then
  jq --arg p "$work/proj" '.projects[$p] = {"allowedTools":[],"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}' \
    "$state" > "$work/claude-config/.claude.json"
fi
printf '{ "permissions": { "allow": ["Read", "Grep", "Glob", "LS"] } }\n' > "$work/claude-config/settings.json"

prompt='In app.py, rename the function greet to welcome (update its call too) and give load_config a one-line docstring. Use the Edit tool, one edit per change, no other changes.'
cat > "$work/layout.kdl" <<EOF
layout {
    pane split_direction="vertical" {
        pane name="hx" focus=true size="55%" command="$hx" {
            args "app.py"
            cwd "$work/proj"
        }
        pane name="claude" command="bash" {
            // let hx start the bridge and write its lock file first, so --ide finds exactly one IDE
            args "-c" "sleep 4; exec claude --ide --model $model --permission-mode default '$prompt'"
            cwd "$work/proj"
        }
    }
}
EOF

export CLAUDE_CONFIG_DIR="$work/claude-config"
export STEEL_HOME="$work/home"
export HELIX_STEEL_CONFIG="$work/cfg"
export XDG_CONFIG_HOME="$work/cfg"
export ZELLIJ_CONFIG_FILE="$here/zellij.kdl"
cd "$work/proj"
exec env -u ZELLIJ -u ZELLIJ_SESSION_NAME -u ZELLIJ_PANE_ID \
  zellij --session "mokh-demo-$$" --new-session-with-layout "$work/layout.kdl"
