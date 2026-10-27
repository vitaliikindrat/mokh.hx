# Renders docs/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#
#   HX=/path/to/steel/hx vhs docs/demo.tape
#
# A real Claude Code (Haiku) session edits app.py; the review happens in hx.
# Timings are generous because the model's response time varies.

Output docs/demo.gif

Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 15
Set Width 1400
Set Height 780
Set Padding 10
Set Framerate 20
Set TypingSpeed 80ms
Set Theme "Catppuccin Mocha"

Hide
Type "bash docs/demo/run.sh"
Enter
Sleep 9s
Show

# Claude connects (status: "mokh: Claude Code connected") and sends its first
# edit; it shows up inline in the real buffer, cursor on the change.
Sleep 16s

# next change / previous change, then accept: Claude writes the file.
Type " mn"
Sleep 2s
Type " mp"
Sleep 2s
Type " ma"
Sleep 12s

# the second edit arrives; reject it this time
Type " mr"
Sleep 10s
