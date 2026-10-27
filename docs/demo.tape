# Renders docs/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#
#   HX=/path/to/steel/hx vhs docs/demo.tape
#
# A real Claude Code (Haiku) session edits app.py; the review happens in hx.
# Haiku answers within a couple of seconds, so the waits are short; if a
# render catches a slow response the keys land before the diff and the
# status line says "no pending diff here" -- just render again.

Output docs/demo.gif

Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 18
Set Width 1300
Set Height 720
Set Padding 8
Set Framerate 20
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"

Hide
Type "bash docs/demo/run.sh"
Enter
# zellij + hx + bridge up, Claude connected and already working
Sleep 9s
Show

# the first edit appears inline, cursor on the change
Sleep 3.5s
Type " mn"
Sleep 1.5s
Type " mp"
Sleep 1.5s
# accept: Claude writes the file and sends the next edit
Type " ma"
Sleep 4s
# reject this one
Type " mr"
Sleep 3.5s
