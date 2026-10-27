# Renders docs/demo-review.gif with VHS (https://github.com/charmbracelet/vhs):
#
#   HX=/path/to/steel/hx vhs docs/demo.tape
#
# A real Claude Code (Haiku) session edits app.py; the review happens in hx.
# Haiku answers within a couple of seconds, so the waits are short; if a
# render catches a slow response the keys land before the diff and the
# status line says "no pending diff here" -- just render again.

Output docs/demo-review.gif

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

# every chord is shown deliberately: `space m` opens the menu with the mokh
# commands and their descriptions, then the letter picks one
Type " m"
Sleep 800ms
Type "n"
Sleep 1.5s
Type " m"
Sleep 800ms
Type "p"
Sleep 1.5s
# accept: Claude writes the file and sends the next edit
Type " m"
Sleep 800ms
Type "a"
Sleep 4s
# reject this one
Type " m"
Sleep 800ms
Type "r"
Sleep 3.5s
