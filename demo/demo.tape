# Record: demo/record.sh  (builds /tmp/api, then runs this tape)
Output demo/code-review.gif

Set Shell bash
Set FontSize 18
Set Width 1400
Set Height 820
Set Padding 12
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set CursorBlink false
Set Framerate 25
Set PlaybackSpeed 1.0

Hide
Type "cd /tmp/api && clear && nvim --clean -u \"$DEMO_DIR/init.lua\" rate_limiter.py"
Enter
Sleep 1.5s
Show

Sleep 2.5s

# 1. ask about a piece of code
Hide
Type ":Caption 1 · Select the code you want explained, Space c a to ask about it"
Enter
Show
Type "13G"
Sleep 300ms
Type "V4j"
Sleep 700ms
Type " ca"
Sleep 600ms
Type "How does the refill math work?"
Sleep 700ms
Hide
Escape
Type ":Caption 2 · Alt-s asks your agent, which answers in the background"
Enter
Type "A"
Show
Sleep 1.2s
Alt+S
Sleep 6s

# 3. the answer
Hide
Type ":Caption 3 · The answer arrives live, next to the code it explains"
Enter
Show
Sleep 1s
Type "G"
Sleep 5s
Type "q"
Sleep 600ms

# 4. ask now, send later
Hide
Type ":Caption 4 · Ctrl-s only saves: collect your questions, send them together"
Enter
Show
Type "11G"
Sleep 500ms
Type " ca"
Sleep 600ms
Type "Why monotonic() and not time.time()?"
Sleep 600ms
Ctrl+S
Sleep 1.5s

# 5. the thread list
Hide
Type ":Caption 5 · Space c l lists the threads: ● answered, waiting for you · ○ waiting for the agent"
Enter
Show
Type " cl"
Sleep 3.5s

# 6. send from the list
Hide
Type ":Caption 6 · s in the list sends to the agent; the list updates as answers arrive"
Enter
Show
Type "G"
Sleep 600ms
Type "s"
Sleep 6s

# 7. read an answer
Hide
Type ":Caption 7 · Enter opens a thread · x marks it resolved when you are done"
Enter
Show
Type "2G"
Sleep 600ms
Enter
Sleep 1s
Type "G"
Sleep 5s
Type "x"
Sleep 1.5s
Type "q"
Sleep 600ms

# 8. inline
Hide
Type ":Caption 8 · Space c i shows the whole conversations inline, under the code"
Enter
Show
Type " ci"
Sleep 1s
Type "gg"
Sleep 4s

# 9. help
Hide
Type ":Caption 9 · Space c ? lists the keys of where you are; every key is configurable"
Enter
Show
Type " c?"
Sleep 3s
Type "q"
Sleep 500ms

Hide
Type ":Caption code-review.nvim · ask your AI agent about code, right where it is"
Enter
Show
Sleep 3s
