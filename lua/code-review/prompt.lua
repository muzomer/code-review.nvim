-- The prompt a poke sends: the threads that changed since the last poke, with
-- the commented code and your messages, so the agent can start answering at
-- once instead of listing and reading first.
--
-- What the agent was already sent is kept in <root>/.code-review/poke-seen.json
-- ({ [thread id] = signature }).
local store = require("code-review.store")
local session = require("code-review.session")

local M = {}

M.MAX_CODE_LINES = 6
M.MAX_LINE = 160
M.MAX_MESSAGE = 1200

local function seen_path(root)
  return (store.paths(root)) .. "/poke-seen.json"
end

local function read_seen(root)
  local f = io.open(seen_path(root), "r")
  if not f then
    return {}
  end
  local s = f:read("a")
  f:close()
  local ok, data = pcall(vim.json.decode, s)
  return ok and type(data) == "table" and data or {}
end

---What identifies the state of a thread: its message count, plus the edit time
---of the last message (an edited comment counts as new).
function M.signature(t)
  local last = t.messages[#t.messages]
  local sig = last and last.edited and (#t.messages .. ":" .. last.edited) or tostring(#t.messages)
  return t.approved and (sig .. ":approved") or sig
end

---"discuss": the agent changes code only for threads the reviewer approved;
---"auto": for every thread (config.agent_changes).
function M.changes_mode()
  local cr = package.loaded["code-review"]
  return cr and cr.config and cr.config.agent_changes == "auto" and "auto" or "discuss"
end

---May the agent change code for thread `t`?
function M.may_change(t)
  return M.changes_mode() == "auto" or t.approved == true
end

local function cut(s, max)
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

local function indent(text, prefix)
  local out = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    out[#out + 1] = prefix .. l
  end
  return table.concat(out, "\n")
end

---Your messages since the agent last spoke in the thread (all of them when it never did).
local function your_turn(t)
  local first = #t.messages + 1
  for i = #t.messages, 1, -1 do
    if t.messages[i].author ~= "user" then
      break
    end
    first = i
  end
  local out = {}
  for i = first, #t.messages do
    out[#out + 1] = cut(t.messages[i].body, M.MAX_MESSAGE)
  end
  return out
end

local function code_of(t)
  local lines = (t.anchor and t.anchor.text) or {}
  local out = {}
  for i = 1, math.min(#lines, M.MAX_CODE_LINES) do
    out[#out + 1] = "    > " .. cut(lines[i], M.MAX_LINE)
  end
  if #lines > M.MAX_CODE_LINES then
    out[#out + 1] = string.format("    > … (%d more lines)", #lines - M.MAX_CODE_LINES)
  end
  return table.concat(out, "\n")
end

-- Runs without a terminal cannot ask for permission: steer them to the one
-- form of the command they are allowed to run.
local NOBODY_APPROVES = " Run `code-review` exactly as written here: it is on your PATH and allowed;"
  .. " other forms (`export PATH=...;` or `cd ...;` in front) need an approval nobody can give here."

-- How the agent should work, by where it runs.
M.STYLE = {
  -- typed into an interactive session that should stay small
  subagent = "Handle this in a subagent (Task tool) so this conversation stays small: give it this whole message."
    .. " When it is done, answer here with one line only, e.g. \"answered 3 review threads\".",
  -- a throwaway fork of the main session
  fork = "You are a temporary copy of the conversation above, started only to answer these comments:"
    .. " nothing you say here is kept, so everything the reviewer should read must go into the threads."
    .. NOBODY_APPROVES
    .. " End with one line only, e.g. \"answered 3 review threads\".",
  -- the review's own background session
  background = "You run in the background and nobody watches this output: do not ask questions here,"
    .. " put everything the reviewer should read into the threads." .. NOBODY_APPROVES .. " End with one line only.",
  -- typed into a session as is
  plain = "Your replies are already in the threads, so when you are done answer here with one line only,"
    .. " e.g. \"answered 3 review threads\"; do not repeat them.",
}

---Build the prompt for the threads waiting on the agent.
---@param opts? { style?: "subagent"|"fork"|"background"|"plain", all?: boolean, author?: string, cwd?: string|false }
---all: ignore what was sent before; author: the name the agent signs its replies with;
---cwd: where the agent runs (nil: unknown). Unless that is the project, the
---commands name it with --root: the CLI finds the comments from its directory.
---@return string? text nil when no thread waits on the agent
---@return table sent signatures to record with `M.mark_sent` once the prompt is delivered
---@return { new: integer, followup: integer, waiting: integer } counts
function M.build(root, opts)
  opts = opts or {}
  local ok, data = pcall(store.read, root)
  local seen = opts.all and {} or read_seen(root)
  local s = session.load(root)
  local pr = s and s.kind == "pr" and s or nil
  local commits = s and s.kind == "commits" and s or nil
  local subjects = {}
  for _, c in ipairs(commits and commits.commits or {}) do
    subjects[c.sha] = c.subject
  end
  local ref = pr and string.format("%s/%s#%d", pr.owner, pr.repo, pr.number)
  local cli = ref and ("code-review --pr " .. ref) or "code-review"
  local function same(a, b)
    return a and b and vim.fs.normalize(a):gsub("/$", "") == vim.fs.normalize(b):gsub("/$", "")
  end
  if not ref and not same(opts.cwd, root) then
    local r = root:match("^[%w/._~-]+$") and root or vim.fn.shellescape(root)
    cli = "code-review --root " .. r
  end

  local fresh, older, sent = {}, {}, {}
  local any_approved = false -- any waiting thread (sent before or not) the agent may change code for
  for _, t in ipairs(ok and data.threads or {}) do
    if t.needs == "agent" and t.status ~= "resolved" then
      sent[t.id] = M.signature(t)
      if seen[t.id] ~= sent[t.id] then
        fresh[#fresh + 1] = t
      else
        local approved = not pr and M.changes_mode() == "discuss" and t.approved
        older[#older + 1] = t.id .. (approved and " (change approved)" or "")
        any_approved = any_approved or approved
      end
    end
  end
  table.sort(fresh, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.range.start < b.range.start
  end)
  local counts = { new = 0, followup = 0, waiting = #older }
  if #fresh == 0 and #older == 0 then
    return nil, sent, counts
  end

  local blocks = {}
  local any_general = false
  for _, t in ipairs(fresh) do
    local followup = seen[t.id] ~= nil or vim.iter(t.messages):any(function(m) return m.author ~= "user" end)
    counts[followup and "followup" or "new"] = counts[followup and "followup" or "new"] + 1
    local general = store.is_general(t)
    any_general = any_general or general
    local where = string.format("%s:%d-%d%s", t.file, t.range.start, t.range["end"], t.side == "old" and " (old side, base commit)" or "")
    if general then
      where = commits and string.format("the commits %s as a whole (a conversation, not about a line)", commits.range)
        or pr and string.format('the whole PR "%s" (a conversation, not about a line)', cut(pr.title or "", 80))
        or "the whole change (a conversation, not about a line)"
    elseif commits and t.commit then
      where = where .. string.format(' in commit %s ("%s")', t.commit:sub(1, 12), cut(subjects[t.commit] or "?", 60))
      if t.side == "old" then
        where = where:gsub(" %(old side, base commit%)", " (old side: the commit's parent)")
      end
    end
    local span = require("code-review.anchor").cols(t) and (t.anchor or {}).span
    if span then -- the comment is about this text in those lines
      where = where .. string.format(' on "%s"', cut(span:gsub("\n", "⏎"), M.MAX_LINE))
    end
    local approved = not pr and M.changes_mode() == "discuss" and t.approved
    any_approved = any_approved or approved
    local parts = { string.format("[%s] %s — %s%s", t.id, where, followup and "follow-up" or "new", approved and " · change approved" or "") }
    local code = code_of(t)
    if code ~= "" then
      parts[#parts + 1] = code
    end
    for _, body in ipairs(your_turn(t)) do
      parts[#parts + 1] = indent(body, "    ") :gsub("^    ", "  you: ", 1)
    end
    if followup then
      parts[#parts + 1] = string.format("  (earlier messages: `%s show %s`)", cli, t.id)
    end
    blocks[#blocks + 1] = table.concat(parts, "\n")
  end

  local head
  if #fresh > 0 then
    local bits = {}
    if counts.new > 0 then
      bits[#bits + 1] = counts.new .. " new"
    end
    if counts.followup > 0 then
      bits[#bits + 1] = counts.followup .. (counts.followup == 1 and " follow-up" or " follow-ups")
    end
    head = string.format("Review comments%s waiting for your answer (%s):", ref and (" on PR " .. ref) or "", table.concat(bits, ", "))
  else
    head = string.format("Review comments%s are still waiting for your answer:", ref and (" on PR " .. ref) or "")
  end

  local lines = { head, "" }
  if #blocks > 0 then
    lines[#lines + 1] = table.concat(blocks, "\n\n")
    lines[#lines + 1] = ""
  end
  if any_general then
    lines[#lines + 1] = "The conversation about the whole " .. (commits and "range" or pr and "PR" or "change")
      .. " asks for insight, not a code change: answer from the "
      .. (pr and string.format("description and code (`%s diff` starts with the PR description and lists the snapshots)", cli)
        or commits and "commits (`git log -p` on the range)" or "code")
      .. ", reply in that thread like any other, do not edit files for it and do not resolve it."
  end
  if #older > 0 then
    lines[#lines + 1] = string.format("%s from before: %s (`%s show <id>`).", #fresh > 0 and "Also still open" or "Open",
      table.concat(older, ", "), cli)
  end
  local author = opts.author and (" --author " .. opts.author) or ""
  lines[#lines + 1] = string.format("Reply in each thread with `%s reply <id> \"...\"%s` (or `- ` and the body on stdin for long replies);"
    .. " resolve with `%s resolve <id>` only once the request is settled. `code-review skill` explains the workflow.", cli, author, cli)
  if pr then
    lines[#lines + 1] = string.format("There is no checkout: `%s diff` prints where the base/head snapshots of the changed files are;"
      .. " for any other file run `%s file <path>` and read the path it prints. To find code that is not in"
      .. " the PR (callers, definitions, other uses), search the repository on GitHub: `gh search code \"<query>\" --repo %s/%s`"
      .. " (it searches the default branch, not the PR head). You cannot change the PR,"
      .. " so answer with explanations or suggested code (a ```suggestion block replaces the commented lines).", cli, cli,
      pr.owner, pr.repo)
  elseif commits then
    lines[#lines + 1] = string.format("These comments are on commits of the repository at %s, reviewed one commit at a time;"
      .. " each thread names its commit (`git show <sha>` shows it).", commits.repo)
  end
  local fixup = commits and (vim.uv.fs_stat(commits.repo .. "/.jj")
      and " Put the change into the commit the thread is on with `jj squash --into <sha>`."
      or " Commit the change as a fixup of the commit the thread is on (`git commit --fixup=<sha>`); do not rebase.")
    or ""
  if pr then
    -- answered above: a PR cannot be changed
  elseif M.changes_mode() == "auto" then
    lines[#lines + 1] = "Make the changes the comments ask for in the code, then reply." .. fixup
  else
    local any = any_approved
    if any then
      lines[#lines + 1] = "For the threads marked `change approved`, make the changes they ask for in the code, then reply." .. fixup
    end
    lines[#lines + 1] = (any and "For every other thread, do not edit any file" or "Do not edit any file")
      .. ", even if a comment asks for a change: the reviewer approves changes first. Answer, and when code should"
      .. " change, show it in a ```suggestion block (it replaces the commented lines) or describe it."
  end
  lines[#lines + 1] = M.STYLE[opts.style or "plain"] or M.STYLE.plain
  return table.concat(lines, "\n"), sent, counts
end

---A prompt without thread details: "check the comments" (for copying when none waits yet).
function M.generic(root)
  local s = session.load(root)
  if not (s and s.kind == "pr") then
    local cli = "code-review"
    local intro = "I left review comments on the code for you."
    if s and s.kind == "commits" then
      cli = "code-review --root " .. (root:match("^[%w/._~-]+$") and root or vim.fn.shellescape(root))
      intro = string.format("I am reviewing the commits %s of %s one at a time and left comments on them for you"
        .. " (each thread names its commit).", s.range, s.repo)
    end
    return intro .. " Run `" .. cli .. " list --needs agent` to see them"
      .. " (`code-review skill` explains the workflow). Reply in each thread with `" .. cli .. " reply <id> \"...\"`."
      .. (M.changes_mode() == "auto" and " Make any changes requested,"
        or " Change the code only for threads marked `change approved`; for the others answer and propose changes"
          .. " as a ```suggestion block,")
      .. " and only resolve a thread with `" .. cli .. " resolve <id>` once it is settled."
  end
  local cli = string.format("code-review --pr %s/%s#%d", s.owner, s.repo, s.number)
  return string.format("I am reviewing PR %s/%s#%d in Neovim (no checkout) and left comments for you. Run `%s list --needs agent`"
    .. " to see them and `%s diff` for the changed files and where their base/head snapshots live (`code-review skill`"
    .. " explains the workflow); for any other file run `%s file <path>`. Reply in each thread with `%s reply <id> \"...\"`."
    .. " You cannot change the PR itself, so answer with explanations or suggested code.", s.owner, s.repo, s.number, cli, cli, cli, cli)
end

---Remember that the agent was sent these threads in this state.
function M.mark_sent(root, sent)
  local seen = read_seen(root)
  for tid, sig in pairs(sent) do
    seen[tid] = sig
  end
  store.ensure_dir(root)
  local f = io.open(seen_path(root), "w")
  if f then
    f:write(vim.json.encode(seen), "\n")
    f:close()
  end
end

---Forget what was sent: the next poke sends every waiting thread in full.
function M.reset(root)
  os.remove(seen_path(root))
end

return M
