# Record: demo/record-pr.sh  (an invented PR, served by demo/bin/curl)
Output demo/code-review-pr.gif

Set Shell bash
Set FontSize 16
Set Width 1400
Set Height 820
Set Padding 12
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set CursorBlink false
Set Framerate 25
Set PlaybackSpeed 1.0

Hide
Type `cd "$DEMO_TMP" && clear && nvim --clean -u "$DEMO_DIR/init.lua"`
Enter
Sleep 1.5s
Type ":Caption 1 · Open any GitHub PR: no clone, no checkout"
Enter
Show
Sleep 1s
Type ":CodeReview pr acme/payments#128"
Sleep 600ms
Enter
Sleep 3s

Hide
Type ":Caption 2 · The changed files on the left, a side-by-side diff on the right"
Enter
Show
Sleep 3.5s

Hide
Type ":Caption 3 · ]f steps to the next changed file"
Enter
Show
Type "]f"
Sleep 2.5s

# ask about the code
Hide
Type ":Caption 4 · Ask about any line of the PR: Space c a"
Enter
Show
Type "8G"
Sleep 500ms
Type " ca"
Sleep 600ms
Type "Why a random delay instead of the exact one?"
Sleep 700ms
Hide
Escape
Type ":Caption 5 · Alt-s sends it to your agent: it reads the PR without a checkout and answers"
Enter
Type "A"
Show
Sleep 1s
Alt+S
Sleep 6s
Type "G"
Sleep 5s
Type "q"
Sleep 600ms

Hide
Type ":Caption 6 · Space c u switches to one unified column, like GitHub"
Enter
Show
Type " cu"
Sleep 3.5s
Type " cu"
Sleep 1s

Hide
Type ":Caption 7 · Space c v marks the file viewed and moves on to the next one"
Enter
Show
Type " cv"
Sleep 3s

Hide
Type ":Caption 8 · Space c d shows the PR description"
Enter
Show
Type " cd"
Sleep 3.5s
Type "q"
Sleep 500ms

Hide
Type ":Caption code-review.nvim · review GitHub PRs with your AI agent, no checkout needed"
Enter
Show
Sleep 3s
