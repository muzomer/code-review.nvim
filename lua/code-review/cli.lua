-- Agent-facing CLI. Run via bin/code-review (`nvim --clean -l`).
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")
local github = require("code-review.github")
local ghcomments = require("code-review.ghcomments")
local uv = vim.uv

local M = {}

local USAGE = [[
code-review - read and answer review comments left in Neovim

Usage:
  code-review list [--all | --status S] [--needs agent|user] [--file F] [--json]
  code-review show <id> [--json]
  code-review reply <id> <body | -> [--author NAME]
  code-review resolve <id> [body | -] [--author NAME]
  code-review add <file> <start> [end] <body | -> [--author NAME] [--side old|new]
  code-review fetch <PR URL | owner/repo#n>   download a PR (no checkout needed)
  code-review diff [--json]                   PR review: changed files and snapshot paths
  code-review file <path> [--side old|new]    PR review: print a file's snapshot path (fetches it if needed)
  code-review ls [dir]                        PR review: list a directory of the PR head
  code-review github [--all] [--cached] [--json]
                                              PR review: comments others left on GitHub (read-only)
  code-review skill        print agent instructions

`list` shows unresolved threads by default. A body of "-" is read from stdin.
--author defaults to "agent". Agents cannot edit, reopen or delete threads.
Options: --root DIR (default: $NVIM_CODE_REVIEW_ROOT or the git/jj root of cwd)
         --pr REF  review a PR opened with `:CodeReview pr REF` instead of a project
Needs a GitHub token for PRs: $GH_TOKEN, $GITHUB_TOKEN, or `gh auth login`.]]

local BOOL = { json = true, all = true, help = true, ["no-reanchor"] = true, cached = true }

local function parse(argv)
  local pos, flags = {}, {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      for j = i + 1, #argv do
        pos[#pos + 1] = argv[j]
      end
      break
    elseif a == "-h" then
      flags.help = true
    elseif a:match("^%-%-.") then
      local k, v = a:match("^%-%-([%w%-]+)=(.*)$")
      if k then
        flags[k] = v
      else
        k = a:sub(3)
        if BOOL[k] then
          flags[k] = true
        else
          flags[k] = argv[i + 1]
          i = i + 1
        end
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, flags
end

local function out(s)
  io.stdout:write(s, "\n")
end

local function body_from(parts)
  local body = table.concat(parts, " ")
  if body == "-" then
    body = io.read("a") or ""
  end
  body = vim.trim(body)
  return body ~= "" and body or nil
end

local function indent(text, prefix)
  return prefix .. text:gsub("\n", "\n" .. prefix)
end

local function format_thread(t)
  local r = t.range
  local loc = r.start == r["end"] and tostring(r.start) or (r.start .. "-" .. r["end"])
  local where = t.file
  if t.side == "old" then
    where = where .. " (OLD side" .. (t.base and (" @" .. t.base:sub(1, 7)) or "") .. ")"
  end
  if store.is_general(t) then
    where, loc = "(the whole review: a conversation, not about a line)", nil
  end
  local span = require("code-review.anchor").cols(t) and (t.anchor or {}).span
  local lines = {
    string.format("%s  [%s, needs %s%s]  %s%s%s", t.id, t.status, t.needs, t.approved and ", change approved" or "", where, loc and (":" .. loc) or "",
      span and string.format(' on "%s"', span:gsub("\n", "⏎")) or ""),
  }
  for i, l in ipairs((t.anchor or {}).text or {}) do
    lines[#lines + 1] = string.format("  %5d | %s", r.start + i - 1, l)
  end
  for _, m in ipairs(t.messages) do
    lines[#lines + 1] = string.format("  - %s (%s) %s%s:", m.id, m.author, m.ts, m.edited and (" [edited " .. m.edited .. "]") or "")
    lines[#lines + 1] = indent(m.body, "      ")
  end
  return table.concat(lines, "\n")
end

local function emit(flags, value, text)
  if flags.json then
    out(store.encode(value))
  else
    out(text)
  end
end

local function to_rel(root, file)
  local abs = file:sub(1, 1) == "/" and file or (vim.uv.cwd() .. "/" .. file)
  abs = vim.fs.normalize(vim.fn.fnamemodify(abs, ":p"))
  local rel = store.relpath(root, abs)
  if not rel then
    error("file is outside the project root " .. root, 0)
  end
  return rel, abs
end

local function with_thread(root, id, fn)
  return store.update(root, function(data)
    local t = store.find(data, id)
    if not t then
      error("no thread " .. tostring(id), 0)
    end
    return fn(t, data)
  end)
end

---Repo-relative path for `file` in a PR review: accepts a repo path or one of
---the snapshot paths printed by `code-review diff`.
local function pr_rel(root, file)
  local sroot, sfile = session.infer(vim.fn.fnamemodify(file, ":p"))
  if sroot == root then
    return sfile
  end
  return (file:gsub("^%./", ""):gsub("^/+", ""))
end

local cmds = {}

function cmds.list(root, pos, flags)
  if not flags["no-reanchor"] then
    anchor.reanchor_root(root)
  end
  local data = store.read(root)
  local res = {}
  for _, t in ipairs(data.threads) do
    local ok = true
    if flags.status then
      ok = t.status == flags.status
    elseif not flags.all then
      ok = t.status ~= "resolved"
    end
    if flags.needs and t.needs ~= flags.needs then
      ok = false
    end
    if flags.file and t.file ~= to_rel(root, flags.file) then
      ok = false
    end
    if ok then
      res[#res + 1] = t
    end
  end
  local text = {}
  for _, t in ipairs(res) do
    text[#text + 1] = format_thread(t)
  end
  emit(flags, res, #res == 0 and "No matching threads." or table.concat(text, "\n\n"))
end

function cmds.show(root, pos, flags)
  if not flags["no-reanchor"] then
    anchor.reanchor_root(root)
  end
  local t = store.find(store.read(root), pos[1])
  if not t then
    error("no thread " .. tostring(pos[1]), 0)
  end
  emit(flags, t, format_thread(t))
end

function cmds.reply(root, pos, flags)
  local id = table.remove(pos, 1)
  local body = body_from(pos)
  if not id or not body then
    error("usage: code-review reply <id> <body | ->", 0)
  end
  local msg = with_thread(root, id, function(t)
    return store.add_message(t, flags.author or "agent", body)
  end)
  emit(flags, msg, "Replied " .. msg.id)
end

function cmds.resolve(root, pos, flags)
  local id = table.remove(pos, 1)
  if not id then
    error("usage: code-review resolve <id> [body | -]", 0)
  end
  local body = body_from(pos)
  with_thread(root, id, function(t)
    if body then
      store.add_message(t, flags.author or "agent", body)
    end
    t.status = "resolved"
  end)
  emit(flags, { id = id, status = "resolved" }, "Resolved " .. id)
end

function cmds.add(root, pos, flags)
  local function line_no(v) -- 1.5 or 0x2 are not line numbers
    return v and v:match("^%d+$") and tonumber(v) or nil
  end
  local file, s = pos[1], line_no(pos[2])
  if not file or not s then
    error("usage: code-review add <file> <start> [end] <body | ->", 0)
  end
  local rest = 3
  local e = line_no(pos[3])
  if e and pos[4] then
    rest = 4
  else
    e = s
  end
  local body = body_from({ unpack(pos, rest) })
  if not body then
    error("comment body is empty", 0)
  end
  local pr = session.load(root)
  local rel, lines, side, base, commit
  if pr and pr.kind == "pr" then
    side = flags.side == "old" and "old" or nil
    if flags.side and flags.side ~= "old" and flags.side ~= "new" then
      error("--side must be old or new", 0)
    end
    rel = pr_rel(root, file)
    if not session.lines(root, rel, { side = side }) then
      local path, err = github.ensure_file(root, rel, side)
      if not path then
        error(err, 0)
      end
    end
    lines = session.lines(root, rel, { side = side })
    base = side == "old" and pr.base_sha or nil
  elseif pr and pr.kind == "commits" then
    side = flags.side == "old" and "old" or nil
    rel = pr_rel(root, file)
    commit = pr.current
    lines = session.lines(root, rel, { side = side, commit = commit })
    if not lines then
      error(string.format("%s is not changed in the commit under review (%s)", rel, tostring(commit):sub(1, 7)), 0)
    end
  else
    local abs
    rel, abs = to_rel(root, file)
    if vim.fn.filereadable(abs) == 0 then
      error("cannot read " .. abs, 0)
    end
    lines = vim.fn.readfile(abs)
  end
  if s < 1 or e < s or e > #lines then
    error(string.format("line range %d-%d is outside %s (%d lines)", s, e, rel, #lines), 0)
  end
  local id = store.update(root, function(data)
    return store.add_thread(data, {
      file = rel,
      side = side,
      base = base,
      start = s,
      ["end"] = e,
      anchor = anchor.capture(lines, s, e),
      author = flags.author or "agent",
      body = body,
      commit = commit,
    })
  end)
  emit(flags, { id = id }, "Created " .. id)
end

-- PR reviews --------------------------------------------------------------------

local function need_pr(root)
  local s = session.load(root)
  if not s or s.kind ~= "pr" then
    error("not a PR review: pass --pr <PR URL | owner/repo#n> (open it first with `:CodeReview pr` or `code-review fetch`)", 0)
  end
  return s
end

function cmds.fetch(root, pos, flags)
  local ref, err = github.parse_ref(pos[1] or "")
  if not ref then
    error(err, 0)
  end
  local r, ferr = github.open_pr(ref)
  if not r then
    error(ferr, 0)
  end
  ghcomments.fetch(r) -- best effort: `github` says when they could not be loaded
  local s = session.load(r)
  emit(flags, { root = r, files = #s.files }, string.format("Fetched %s/%s#%d: %d changed files. Use --pr %s/%s#%d", ref.owner, ref.repo, ref.number, #s.files, ref.owner, ref.repo, ref.number))
end

function cmds.diff(root, pos, flags)
  local s = need_pr(root)
  local files, viewed = {}, session.viewed_map(root)
  for _, f in ipairs(s.files) do
    files[#files + 1] = {
      path = f.path,
      viewed = viewed[f.path] or false,
      old_path = f.old_path,
      status = f.status,
      additions = f.additions,
      deletions = f.deletions,
      old = f.status ~= "added" and session.snapshot_path(root, f.path, "old") or nil,
      new = f.status ~= "removed" and session.snapshot_path(root, f.path, "new") or nil,
    }
  end
  local value = {
    pr = string.format("%s/%s#%d", s.owner, s.repo, s.number),
    title = s.title,
    url = s.url,
    author = s.author,
    state = s.state,
    draft = s.draft,
    labels = s.labels,
    description = s.body or "",
    base = { ref = s.base_ref, sha = s.base_sha },
    head = { ref = s.head_ref, sha = s.head_sha },
    files = files,
  }
  local lines = {
    string.format("PR %s: %s", value.pr, s.title or ""),
    string.format("base %s @%s -> head %s @%s", s.base_ref, (s.base_sha or ""):sub(1, 7), s.head_ref, (s.head_sha or ""):sub(1, 7)),
    "",
    "Description" .. (s.author and (" (by @" .. s.author .. ")") or "") .. ":",
    indent(vim.trim(s.body or "") ~= "" and vim.trim(s.body) or "(none)", "  "),
    "",
  }
  for _, f in ipairs(files) do
    lines[#lines + 1] = string.format("%-9s +%-4d -%-4d %s%s", f.status, f.additions or 0, f.deletions or 0, f.path, f.viewed and "   [viewed by the user]" or "")
    if f.old then
      lines[#lines + 1] = "    old: " .. f.old
    end
    if f.new then
      lines[#lines + 1] = "    new: " .. f.new
    end
  end
  local gh = ghcomments.load(root)
  if gh then
    local c = ghcomments.counts(root, gh)
    value.github_comments = c
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "Review comments on GitHub: %d open, %d outdated, %d resolved (read them: code-review --pr <ref> github)",
      c.open, c.outdated, c.resolved)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Other files: code-review --pr <ref> file <path>; comment on removed code with --side old."
  emit(flags, value, table.concat(lines, "\n"))
end

function cmds.github(root, pos, flags)
  need_pr(root)
  local data, err
  if not flags.cached then
    data, err = ghcomments.fetch(root)
  end
  if not data then
    data = ghcomments.load(root)
    if not data then
      error("could not load the review comments from GitHub: " .. tostring(err), 0)
    end
    if err then
      io.stderr:write(string.format("code-review: could not refresh them (%s); showing the copy from %s\n", err, data.fetched_at or "?"))
    end
  end
  local shown = vim.tbl_filter(function(t) return flags.all or t.status ~= "resolved" end, data.threads)
  local c = ghcomments.counts(root, data)
  local head = {
    string.format("Review comments on GitHub: %d open, %d outdated, %d resolved%s.", c.open, c.outdated, c.resolved,
      flags.all and "" or " (resolved ones: --all)"),
    "Read-only: you cannot answer or resolve them. Line numbers are in the snapshots (`diff`).",
    "",
  }
  if (data.total or 0) > #data.threads then
    table.insert(head, 2, string.format("Only the first %d of %d threads were fetched.", #data.threads, data.total))
  end
  local value = vim.tbl_map(function(t) -- the status and lines as shown: no line for a thread not on it any more
    local v = vim.deepcopy(t)
    v.status = ghcomments.state(root, t)
    if not ghcomments.placed(t, session.lines(root, t.file, { side = t.side })) then
      v.start, v["end"] = nil, nil
    end
    return v
  end, shown)
  emit(flags, value, table.concat(vim.list_extend(head, ghcomments.text(root, { threads = shown }, true)), "\n"))
end

function cmds.file(root, pos, flags)
  need_pr(root)
  local path = pos[1]
  if not path then
    error("usage: code-review file <path> [--side old|new]", 0)
  end
  local side = flags.side == "old" and "old" or nil
  local abs, err = github.ensure_file(root, pr_rel(root, path), side)
  if not abs then
    error(err, 0)
  end
  emit(flags, { path = abs }, abs)
end

function cmds.ls(root, pos, flags)
  local s = need_pr(root)
  local entries, err = github.list_dir(s, pos[1] or "", s.head_sha)
  if not entries then
    error(err, 0)
  end
  local names = {}
  for _, e in ipairs(entries) do
    names[#names + 1] = e.type == "dir" and (e.name .. "/") or e.name
  end
  table.sort(names)
  emit(flags, names, table.concat(names, "\n"))
end

function cmds.skill()
  local path = vim.fs.dirname(require("code-review.agents").BIN) .. "/skills/nvim-code-review/SKILL.md"
  local f = assert(io.open(path, "r"))
  io.stdout:write(f:read("a"))
  f:close()
end

---@return integer exit code
function M.run(argv)
  local pos, flags = parse(argv)
  local cmd = table.remove(pos, 1)
  if not cmd or flags.help or cmd == "help" then
    out(USAGE)
    return cmd and 0 or 1
  end
  local fn = cmds[cmd]
  if not fn then
    io.stderr:write("code-review: unknown command '" .. cmd .. "'\n\n" .. USAGE .. "\n")
    return 1
  end
  if flags.author == "user" or flags.author == "" then
    io.stderr:write("code-review: --author cannot be '" .. flags.author .. "'; \"user\" is reserved for the human\n")
    return 1
  end
  local root = flags.root and vim.fs.normalize(vim.fn.fnamemodify(flags.root, ":p")):gsub("/$", "")
  if flags.pr then
    local ref, perr = github.parse_ref(flags.pr)
    if not ref then
      io.stderr:write("code-review: " .. perr .. "\n")
      return 1
    end
    root = session.dirs(ref)
    if cmd ~= "fetch" and not session.load(root) then
      io.stderr:write(string.format("code-review: PR %s/%s#%d is not fetched yet; run `code-review fetch %s` or open it in Neovim\n", ref.owner, ref.repo, ref.number, flags.pr))
      return 1
    end
  end
  if root and not flags.pr and vim.fn.isdirectory(root) == 0 then -- a typo would make the directory
    io.stderr:write("code-review: --root " .. flags.root .. " does not exist\n")
    return 1
  end
  local ok, err = pcall(function()
    if not uv.cwd() and not root then
      error("the current directory no longer exists; cd somewhere else or pass --root", 0)
    end
    return fn(root or store.find_root(), pos, flags)
  end)
  if not ok then
    io.stderr:write("code-review: " .. tostring(err) .. "\n")
    return 1
  end
  return 0
end

return M
