# code-review.nvim

Leave review comments on code in Neovim; AI agents read them, reply in threads,
and resolve them through a small CLI. Threads live in a plain JSON file, so any
agent that can run a shell command can take part — no MCP server or daemon.

Inspired by [hunk](https://github.com/modem-dev/hunk) (an agent-facing JSON CLI).

```
  12 ▍ local ok = pcall(load)       ▍ user: why swallow the error here?
  13 │ if not ok then return end
  40 ◆ for _, a in ipairs(xs) do    ◆ claude: this is O(n²) — ok?  (2)
```

## Install

Requires Neovim ≥ 0.10. No dependencies.

```lua
-- lazy.nvim
{ "muzomer/code-review.nvim", opts = {} }

-- vim.pack (Neovim ≥ 0.12)
vim.pack.add({ "https://github.com/muzomer/code-review.nvim" })
require("code-review").setup()
```

For agents running outside Neovim, put `bin/code-review` on your `PATH`. The
plugin directory depends on your plugin manager:

```sh
# lazy.nvim
ln -s ~/.local/share/nvim/lazy/code-review.nvim/bin/code-review ~/.local/bin/
# vim.pack
ln -s ~/.local/share/nvim/site/pack/core/opt/code-review.nvim/bin/code-review ~/.local/bin/
```

Inside Neovim the plugin prepends `bin/` to `$PATH` for you, so agents started
from `:terminal` find it.

## Usage in Neovim

| Key / command                 | Action                                             |
| ----------------------------- | -------------------------------------------------- |
| `<leader>ca` (n / visual)     | comment on the line / selection                    |
| `<leader>cr`                  | open the thread under the cursor                   |
| `<leader>cx`                  | resolve / reopen the thread under the cursor       |
| `]r` / `[r` (`:CodeReview next/prev`) | next / previous thread in the buffer (wraps, takes a count) |
| `<leader>cl` / `<leader>cL`   | open / all (incl. resolved) threads in the project → quickfix |
| `:CodeReview list [all]`   | same as above                                      |
| `:CodeReview copy`         | copy a prompt telling the agent to check comments  |
| `:CodeReview delete`       | delete the thread under the cursor                 |
| `:CodeReview refresh`      | re-anchor and redraw all buffers                   |
| `:CodeReview pr <url\|o/r#n>` | review a GitHub PR without a checkout           |
| `]f` / `[f`                | PR review: next / previous unreviewed file (stops at the ends; works in the sidebar too) |
| `:CodeReview files`        | PR review: show / hide the file sidebar            |
| `]u` / `[u`                | next / previous thread waiting for you (the agent replied), across files |
| `<leader>ci` (`:CodeReview inline`) | show / hide whole conversations under the code |
| `<leader>cp` / `<leader>cP` | poke the agent (herdr) / show its live output     |
| `<leader>c?` (`?` in the sidebar and thread window) | the keys that work where you are |
| `<leader>cu` (`:CodeReview layout [split\|unified]`) | PR review: side-by-side or one unified column (like GitHub) |
| `<leader>cg` / `<leader>ct` (`:CodeReview find` / `threads [all]`) | pick a PR file / a thread, with preview (fzf-lua if installed) |
| `<leader>cd` (`:CodeReview description`) | PR review: show the PR title and description |
| `<leader>cv` (`:CodeReview viewed`) | PR review: mark the file viewed (or clear it) and move to the next unreviewed one |
| `<leader>ce` (`:CodeReview edit`) | edit your last comment of the thread under the cursor, until the agent replies |

In the thread window: `e` edits your last message (until the agent replies). `n` / `p` (or `]r` / `[r`) show the next / previous
thread in the file without closing the window, `N` / `P` do the same across
all files of the project (by file, then line), `r` reply, `x` resolve/reopen,
`d` delete, `q` close.
In the input window: `<C-s>` (or `<CR>` in normal mode) submits, `q` cancels.

When an agent replies, signs and virtual text update live and you get a
notification. Sign colour shows whose turn it is: warning colour = the agent
replied and waits for you; info colour = waiting on the agent; `◆` marks threads
an agent opened.

## Reviewing a PR (no checkout)

Review a GitHub PR from any directory; nothing is cloned or checked out.

```sh
export GH_TOKEN=...                      # or $GITHUB_TOKEN, or `gh auth login`
code-review pr https://github.com/acme/api/pull/12     # opens Neovim in review mode
nvim https://github.com/acme/api/pull/12               # same, if the plugin is installed
:CodeReview pr acme/api#12                             # from inside Neovim
```

The changed files appear in a sidebar on the left, as a folder tree:

```
 acme/api#12 · 3/35 viewed
 ▾ src/auth/
   ▶✓ M jwt.py        +40 -12  ✎2
      A keys.py        +3       ✎1!
```

`▶` is the file in the diff, `✓` a file you marked viewed, `M/A/D/R` its change,
`✎2` its open threads and `!` threads waiting for you. In the sidebar `<CR>` opens
a file (or folds a folder), `v` marks it viewed, `?` lists the keys and `q`
hides it (`:CodeReview files` brings it back). The diff opens side by side,
old on the left, new on the right; each side's winbar says which it is, the
branch and commit, and where you are (`file 4/35 · ✓ viewed`). `]f` / `[f`
step through the files that are not viewed yet. Comment with `<leader>ca` on **either side**.
`<leader>cu` switches to a unified view: one column with old and new lines
interleaved, old/new line numbers and `+`/`-` in the status column, long unchanged
stretches folded (`⋯ 42 unchanged lines`) and `]c` / `[c` between changes;
comments on a removed line go to the old side, on any other line to the new side.
With `<leader>ci` whole conversations show under the code; the other pane gets
blank lines in the same place, so the two sides stay aligned. Once every file
is viewed you get a summary of the review.
Threads on the left are tied to the base commit, so they survive and show up
only on the old text. Comments stay on your machine; nothing is posted to GitHub.

Settings: `diff_layout` (`"split"` or `"unified"`), `icons` (`"auto"`: file-type
icons when nvim-web-devicons is installed), `sidebar_position` (`"left"`, `"right"`, `"bottom"` or `"top"`; move it
while reviewing with `:CodeReview files bottom`), `sidebar_width` for left/right
(default: a quarter of the screen, 24..42 columns), `sidebar_height` for
bottom/top (default: 30% of the screen, 6..15 lines),
`diff_colors` (`true`, `"github-dark"` or `false`), `inline_threads`,
`progress_float` (`"auto"`: the agent's status goes in the winbar during a review,
in a small floating window elsewhere).

Files and state live under `stdpath("cache")` / `stdpath("state")` in
`code-review/<host>/<owner>/<repo>/pr-<n>/`. GitHub Enterprise hosts work with
the full URL.

Agents have no checkout either, so they read the snapshots (`code-review --pr REF diff`
prints the paths) and fetch any other file on demand (`code-review --pr REF file <path>`).
`:CodeReview copy` copies a prompt that already contains the right `--pr REF`.
For the Claude Code hook, start the agent with `NVIM_CODE_REVIEW_PR=acme/api#12 claude`.

## Usage by agents

```sh
code-review list --needs agent         # threads waiting on the agent
code-review show t_a3f9 [--json]
code-review reply t_a3f9 "Done, renamed it."
printf '%s' "$BODY" | code-review reply t_a3f9 -
code-review resolve t_a3f9 "Fixed in utils.lua"
code-review add src/foo.lua 40 44 "This is O(n^2); ok?"
code-review skill                      # instructions for the agent
```

Give your agent the instructions once: copy `skills/nvim-code-review` to
`~/.claude/skills/` (Claude Code), or paste the output of
`code-review skill` into `AGENTS.md`. Then say "check my comments", or use
`:CodeReview copy`.

### Telling Claude Code about new comments automatically

Add a `UserPromptSubmit` hook to `~/.claude/settings.json`. Use the
`bin/code-review` path from [Install](#install), or just `code-review hook` if
it is on your `PATH`:

```json
"hooks": {
  "UserPromptSubmit": [
    { "hooks": [{ "type": "command", "command": "/path/to/code-review.nvim/bin/code-review hook", "timeout": 10 }] }
  ]
}
```

On each prompt (~30 ms) it lists threads waiting on the agent that are new, or
have a new message, since it last told that session, and prints nothing
otherwise. Per-session state lives in `.code-review/hook-seen.json`.

What the agent does with them depends on `NVIM_CODE_REVIEW_HOOK` in the
environment Claude Code was started with:

| Value               | Behaviour                                                        |
| ------------------- | ---------------------------------------------------------------- |
| unset / `mention`   | mention waiting threads; act only when you ask                   |
| `act`               | handle new threads right away: reply, change code, resolve       |
| `off`               | say nothing                                                      |

A dedicated review session: `alias claude-review='NVIM_CODE_REVIEW_HOOK=act claude'`.

Agents use `--author <name>` (default `agent`). They can add threads, reply and
resolve, but cannot post as `user`, reopen, or delete. Those actions are yours.

## How it works

- **Storage**: `<project root>/.code-review/comments.json`, where the root is
  the nearest `.git`/`.jj` or `$NVIM_CODE_REVIEW_ROOT`. The directory contains a
  `.gitignore` of `*`; delete it if you want to commit your comments. Writers take
  a lock file and write atomically, so Neovim and agents can write concurrently.
- **Threads**: `{id, file, range, anchor, status: open|resolved|outdated,
  needs: agent|user|none, messages: [{id, author, ts, body}]}`. `needs` is
  derived from the last message's author.
- **Anchoring**: each thread stores the commented lines plus 2 lines of context.
  In an open buffer, extmarks follow your edits and are saved on write. When a
  file is loaded, or when an agent runs `list`/`show`, threads are relocated:
  stored position → exact text search (context breaks ties) → fuzzy match
  (≥ 0.8 bigram similarity) → otherwise `outdated` (shown dimmed, recovers if
  the code comes back).

## Configuration

```lua
require("code-review").setup({
  keymaps = { -- set a key to false to skip it, or keymaps = false for none
    add = "<leader>ca", open = "<leader>cr", resolve = "<leader>cx",
    list = "<leader>cl", list_all = "<leader>cL", next = "]r", prev = "[r",
  },
  show_resolved = false,
  notify = true,
  add_bin_to_path = true,
  signs = { user = "▍", agent = "◆", resolved = "✓", outdated = "?" },
})
```

Highlights: `CodeReviewNeedsAgent`, `CodeReviewNeedsUser`,
`CodeReviewAgent`, `CodeReviewVirt`, `CodeReviewDim`.

## Development

```sh
make test   # nvim --clean -l tests/run.lua
```

## License

MIT
