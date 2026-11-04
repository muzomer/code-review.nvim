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
| `<leader>cl` / `<leader>cL` (`:CodeReview list [all\|yours]`) | threads → quickfix, those waiting for you first (`● waiting for you` / `○ waiting for agent`); `all` adds resolved ones, `yours` shows only yours. `<CR>` or a click on a thread jumps to it and opens its conversation |
| `:CodeReview copy`         | copy a prompt telling the agent to check comments  |
| `:CodeReview delete`       | delete the thread under the cursor                 |
| `:CodeReview refresh`      | re-anchor and redraw all buffers                   |
| `:CodeReview pr <url\|o/r#n>` | review a GitHub PR without a checkout           |
| `]f` / `[f`                | PR review: next / previous unreviewed file (stops at the ends; works in the sidebar too) |
| `:CodeReview files`        | PR review: show / hide the file sidebar            |
| `]u` / `[u`                | next / previous thread waiting for you (the agent replied), across files |
| `<leader>ci` (`:CodeReview inline`) | show / hide whole conversations under the code |
| `<leader>cp` / `<leader>cP` | poke the agent / show its live output (see [Poking the agent](#poking-the-agent)) |
| `:CodeReview chat`         | open this review's background agent conversation in a terminal |
| `:CodeReview stop`         | stop following the agent (and stop the background agent) |
| `<leader>c?` (`?` in the sidebar and thread window) | the keys that work where you are |
| `<leader>cu` (`:CodeReview layout [split\|unified]`) | PR review: side-by-side or one unified column (like GitHub) |
| `<leader>cg` / `<leader>ct` (`:CodeReview find` / `threads [all]`) | pick a PR file / a thread, with preview (fzf-lua if installed) |
| `<leader>cR` (`:CodeReview recent`) | resume a recent PR review from its snapshots (no network) |
| `:CodeReview reload` (`U` in the sidebar) | fetch the PR again after new commits; your last version is kept |
| `:CodeReview since` (`S` in the sidebar) | what changed since your last review (previous head → current head) |
| `<leader>cc` (`:CodeReview panel`) | threads in a float or in a docked conversation panel (`<C-s>` send, `<M-s>` send + poke) |
| `<leader>cd` (`:CodeReview description`) | PR review: show the PR title and description |
| `<leader>cv` (`:CodeReview viewed`) | PR review: mark the file viewed (or clear it) and move to the next unreviewed one |
| `<leader>ce` (`:CodeReview edit`) | edit your last comment of the thread under the cursor, until the agent replies |

In the thread window: `e` edits your last message (until the agent replies). `n` / `p` (or `]r` / `[r`) show the next / previous
thread in the file without closing the window, `N` / `P` do the same across
all files of the project (by file, then line), `r` reply, `x` resolve/reopen,
`d` delete, `q` close.
In the input window: `<C-s>` (or `<CR>` in normal mode) saves, `<M-s>` saves
and sends the comment to the agent right away (a new comment then opens its
thread, so you see the reply arrive), `q` cancels. With `auto_poke = true` (or
after `<leader>cA` / `:CodeReview autopoke`) the two swap: `<C-s>` sends,
`<M-s>` only saves. The box footer shows which is which.

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

Opening a PR does not block: a PR you reviewed before opens at once from its
snapshots (and is checked for new commits in the background; a banner says so);
a new one opens as soon as its file list arrives and files fill in as they land.
In the sidebar `f` filters (unviewed / with threads / waiting for you / changed since
your last review). Jumps flash the line they land on; replies arriving together
are announced together; a click on a thread's sign opens it. When an agent answers
with a ```` ```suggestion ```` block it is shown as a diff against the commented code.

For lualine: `lualine_x = { require("code-review").lualine }` shows the PR, how far
you are and what waits for you.

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

### Poking the agent

`<leader>cp` (or `<M-s>` when writing a comment) tells an agent to check your
comments. Which agent:

- **A Claude Code (or other) session running in [herdr](https://herdr.dev)**:
  you pick it once per review and it is remembered. The prompt is typed into its
  pane, so it must be open.
- **The review's background agent**: `claude -p`, started without a terminal.
  It is used when herdr is not there, when no agent runs in it, or when you pick
  "claude (background)" in the list. The first poke starts a new Claude Code
  session; later pokes `--resume` it, so the agent keeps what it learned about
  the PR between pokes, even across Neovim restarts. The session id is in
  `.code-review/headless.json` and runs start in the review root (Claude Code
  files sessions by directory). A poke while it works is queued and runs when
  it finishes. `<leader>cP` shows its output, `:CodeReview chat` opens the same
  conversation interactively (`claude --resume <id>`).

By default the background agent may only run the `code-review` CLI and read
files (`Read`, `Grep`, `Glob`); it cannot change code. Widen that with
`headless.allowed_tools` / `headless.permission_mode`.

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

Every option with its default. Pass only the ones you change.

```lua
require("code-review").setup({
  -- Keys. Set one to false to skip it, or `keymaps = false` for none.
  keymaps = {
    add = "<leader>ca",         -- comment on the line (normal) / selection (visual)
    open = "<leader>cr",        -- open the thread under the cursor
    edit = "<leader>ce",        -- edit your last comment, until the agent replies
    resolve = "<leader>cx",     -- resolve / reopen
    list = "<leader>cl",        -- open threads → quickfix
    list_all = "<leader>cL",    -- all threads, resolved too → quickfix
    next = "]r", prev = "[r",   -- next / previous thread in the buffer
    next_yours = "]u", prev_yours = "[u", -- next / previous thread waiting for you
    inline = "<leader>ci",      -- show / hide conversations under the code
    panel = "<leader>cc",       -- threads in a float / in the conversation panel
    find_file = "<leader>cg",   -- pick a PR file (fzf-lua if installed)
    find_thread = "<leader>ct", -- pick a thread
    poke = "<leader>cp",        -- tell the agent to check your comments
    auto_poke = "<leader>cA",   -- toggle: <C-s> also sends to the agent
    output = "<leader>cP",      -- show / hide the agent's live output
    help = "<leader>c?",        -- the keys that work where you are
    -- PR reviews
    next_file = "]f", prev_file = "[f", -- next / previous unreviewed file
    viewed = "<leader>cv",      -- mark the file viewed and move on
    description = "<leader>cd", -- PR title and description
    layout = "<leader>cu",      -- split / unified diff
    recent = "<leader>cR",      -- resume a recent PR review
  },

  -- Threads
  show_resolved = false,        -- show resolved threads in the code
  signs = { user = "▍", agent = "◆", resolved = "✓", outdated = "?" },
  conversation = "float",       -- open threads in a "float" or a docked "panel"
  panel_width = nil,            -- panel width (default: ~35% of the screen, 40..70)
  inline_threads = false,       -- whole conversations under the code (toggle: keymaps.inline)
  inline_max_lines = 12,        -- longest inline conversation before it is cut
  mouse = true,                 -- click a sign, a thread in the quickfix list or a file in the sidebar to open it
  flash_ms = 350,               -- highlight where a jump lands (0 / false: off)
  notify = true,                -- notify when the agent replies
  notify_group_ms = 1500,       -- replies within this window become one notification

  -- Sending to the agent (see "Poking the agent")
  agent = "auto",               -- "auto" (herdr agent, else background claude), "herdr", "headless"
  auto_poke = false,            -- <C-s> also sends to the agent, <M-s> only saves
  open_after_send = true,       -- a new comment sent to the agent opens its thread
  headless = {                  -- the background agent
    cmd = "claude",
    allowed_tools = nil,        -- default { "Bash(code-review:*)", "Read", "Grep", "Glob" }
    permission_mode = nil,      -- e.g. "acceptEdits" (with "Edit" allowed, for local reviews)
    args = {},                  -- extra arguments for every run
  },
  progress = true,              -- show the agent's state after a poke (working / done / waiting)
  progress_float = "auto",      -- true: floating window, false: winbar / statusline only,
                                -- "auto": float only outside a PR review
  progress_output = false,      -- also open the live output window on each poke
  add_bin_to_path = true,       -- put bin/ on $PATH so agents started inside Neovim find the CLI

  -- PR reviews
  diff_layout = "split",        -- "split" (side by side) or "unified" (one column)
  diff_colors = true,           -- true / "auto": from your colorscheme, "github-dark", false: Neovim's own
  icons = "auto",               -- file-type icons: "auto" (with nvim-web-devicons), true, false
  sidebar_position = "left",    -- "left", "right", "bottom", "top" (or :CodeReview files bottom)
  sidebar_width = nil,          -- left / right (default: a quarter of the screen, 24..42)
  sidebar_height = nil,         -- bottom / top (default: 30% of the screen, 6..15)
})
```

Highlights are defined with `default = true`, so your colorscheme or your own
`nvim_set_hl` wins. The ones you are most likely to change:

| Group | Used for |
| --- | --- |
| `CodeReviewNeedsAgent` / `CodeReviewNeedsUser` | signs: waiting on the agent / on you |
| `CodeReviewAgent`, `CodeReviewVirt`, `CodeReviewDim`, `CodeReviewOutdated` | agent threads, virtual text, resolved, outdated |
| `CodeReviewAuthorYou` / `CodeReviewAuthorAgent` | names in conversations |
| `CodeReviewDiffAdded` / `CodeReviewDiffRemoved` (+ `…Text`) | changed lines (and the changed part) in PR diffs |
| `CodeReviewProgressWorking` / `…Done` / `…Blocked` | the agent's status after a poke |
| `CodeReviewQfCurrent` | the open file in the sidebar |

## Development

```sh
make test   # nvim --clean -l tests/run.lua
```

## License

MIT
