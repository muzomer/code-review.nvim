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

In the thread window: `r` reply, `x` resolve/reopen, `d` delete, `q` close.
In the input window: `<C-s>` (or `<CR>` in normal mode) submits, `q` cancels.

When an agent replies, signs and virtual text update live and you get a
notification. Sign colour shows whose turn it is: warning colour = the agent
replied and waits for you; info colour = waiting on the agent; `◆` marks threads
an agent opened.

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
