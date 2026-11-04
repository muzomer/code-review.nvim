# Record: demo/record-real-pr.sh  (a real public PR, answered by the real claude)
Output demo/code-review-pr.gif

Set Shell bash
Set FontSize 16
Set Width 1400
Set Height 820
Set Padding 12
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set CursorBlink false
Set Framerate 25
Set PlaybackSpeed 1.0

Hide
Type `cd "$DEMO_TMP" && clear && nvim --clean -u "$DEMO_DIR/init.lua"`
Enter
Sleep 1.5s
Type ":Caption 1 · Open any GitHub PR: no clone, no checkout (here a real Neovim PR)"
Enter
Show
Sleep 1s
Type ":CodeReview pr neovim/neovim#42677"
Sleep 600ms
Enter
Wait+Screen@60s /file 1.2/
Sleep 1s

Hide
Type ":Caption 2 · The changed files on the left, a side-by-side diff on the right"
Enter
Type "194Gzz"
Show
Sleep 1.5s

# ask why the fix works
Hide
Type ":Caption 3 · Ask about any line of the PR: Space c a"
Enter
Show
Sleep 500ms
Type " ca"
Sleep 600ms
Type "Why does adding firstline ~= lastline stop the assert from failing?"
Sleep 800ms
Hide
Escape
Type ":Caption 4 · Alt-s sends it to Claude, which reads the PR without a checkout"
Enter
Type "A"
Show
Sleep 1s
Alt+S
Sleep 5s
Hide
Wait+Screen@300s /done in/
Type ":Caption 5 · Claude's answer, in the thread (waiting time cut)"
Enter
Show
Sleep 3.5s
Ctrl+D
Sleep 4.5s
Ctrl+D
Sleep 4.5s
Ctrl+D
Sleep 4s
Type "q"
Sleep 600ms

Hide
Type ":Caption 6 · ]f steps to the next file: the test that comes with the fix"
Enter
Show
Type "]f"
Sleep 1s
Hide
Type "322Gzt"
Show
Sleep 4s

Hide
Type ":Caption 7 · Space c u switches to one unified column, like GitHub"
Enter
Show
Type " cu"
Sleep 3.5s
Type " cu"
Sleep 800ms

Hide
Type ":Caption 8 · Space c d shows the PR description"
Enter
Show
Type " cd"
Sleep 4.5s
Type "q"
Sleep 500ms

Hide
Type ":Caption code-review.nvim · review GitHub PRs with your AI agent, no checkout needed"
Enter
Show
Sleep 3s
