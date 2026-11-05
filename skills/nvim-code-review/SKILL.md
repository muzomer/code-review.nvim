---
name: nvim-code-review
description: Read and answer code review comments a human left in Neovim (code-review.nvim). Use when the user says "check comments", "address my review comments", or mentions code-review threads.
---

# nvim-code-review

The user leaves review comments on lines of code in Neovim. Each comment is a
**thread** with a stable id like `t_a3f9`. You read the threads, act on them,
and reply in the thread using the `code-review` CLI. Run all commands from
inside the project.

## Workflow

1. List the threads waiting on you:
   `code-review list --needs agent`
   Each thread shows its file, line range, the commented code, and the messages.
   A comment on part of a line also quotes that text (`on "…"`): the comment is
   about that text, not the whole lines.
   Add `--json` for machine-readable output.
2. For each thread:
   - Read the surrounding code in the file. Line numbers are current: the CLI
     re-anchors threads to code that moved before listing them.
   - Change code only for threads marked `change approved` (or when the prompt
     you were given says to make the changes). For any other thread, even one
     that asks for a change, do not edit files: reply with the change you
     propose (a ```suggestion block, or a short description). The reviewer
     approves it in Neovim, and the thread comes back to you marked approved.
     An approval covers that one change: after your reply, the thread is
     discuss-only again until the reviewer approves again.
   - For an approved thread, make the change, then reply saying what you did.
   - If it is a question or you disagree, reply with your answer. Do not resolve.
   - If something is unclear, ask in the thread rather than guessing.
3. Reply:
   `code-review reply t_a3f9 "Renamed to parse_config and updated callers."`
   For long or multi-line replies, pipe the body on stdin:
   `printf '%s' "$BODY" | code-review reply t_a3f9 -`
4. Resolve a thread only when the requested change is fully done:
   `code-review resolve t_a3f9 "Done: extracted helper in utils.lua."`

## Reply format

Replies are GitHub-flavoured markdown, rendered in a small floating window in
the user's editor (about 80-100 columns). Keep them short and put the answer
first.

- Use `inline code` for identifiers, files and commands.
- Use fenced code blocks with a language tag for suggested code, and keep them
  to the relevant lines. Prefer making the change over pasting it.
- To propose a replacement for exactly the commented lines (for example in a PR
  review, where you cannot change the code), use a ```suggestion block holding
  the new lines; the user sees it as a diff against the commented code.
- Short bullet lists are fine. No headings, tables, HTML, or images.
- Say what you changed and where (`utils.lua:40`), not a summary of the diff.

## Rules

- Never resolve a thread that is only a question or a discussion; reply and let
  the user resolve it.
- Threads with status `outdated` point at code that no longer exists. Reply to
  say whether the concern still applies; do not guess a new location.
- You may open a new thread to flag something to the user:
  `code-review add src/foo.lua 42 48 "This loop is O(n^2); ok?"`
- You cannot edit, reopen, or delete threads. Those are the user's.
- `code-review show <id>` prints one thread; `code-review list --all`
  includes resolved ones.

## Reviewing a PR (no checkout)

When the user reviews a GitHub PR in Neovim there is no local checkout: the
changed files are snapshots in a cache directory. Add `--pr <PR URL | owner/repo#n>`
to **every** command, e.g.
`code-review --pr acme/api#12 list --needs agent`.

- `code-review --pr REF diff` starts with the PR **description** (read it first: it says what
  the change is meant to do), then lists the changed files with `old:` (base commit)
  and `new:` (head commit) snapshot paths. **Read code from those paths** with
  your normal file tools; `--json` gives the same data.
- A file that is not in the snapshot (a caller, a helper, config) is fetched on
  demand: `code-review --pr REF file src/utils.py` prints a path you can read.
  `--side old` fetches the base-commit version. `code-review --pr REF ls src/`
  lists a directory at the PR head. You cannot grep the whole repository; say so
  when a question needs it.
- Threads on removed or changed code may be on the **old side** (shown as
  `(OLD side @abc1234)`): their line numbers refer to the base-commit snapshot.
  To open one yourself: `code-review --pr REF add <old path> 12 "..." --side old`.
- You cannot change the PR. Where a thread asks for a fix, reply with the
  explanation and a short suggested snippet; never claim you edited the PR.
