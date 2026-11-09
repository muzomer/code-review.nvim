local store = require("code-review.store")
local session = require("code-review.session")
local commits = require("code-review.commits")
local diff = require("code-review.diff")
local sidebar = require("code-review.sidebar")
local ac = require("code-review")

local api = vim.api

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

---Run git in `dir` without the user's config (no signing, fixed identity).
local function git(dir, ...)
  local cmd = { "git", "-C", dir, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
    "-c", "init.defaultBranch=main" }
  vim.list_extend(cmd, { ... })
  local res = vim.system(cmd, { text = true, env = {
    GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1", -- and an identity for git run by `rebase --exec`
    GIT_AUTHOR_NAME = "T", GIT_AUTHOR_EMAIL = "t@example.com", GIT_COMMITTER_NAME = "T", GIT_COMMITTER_EMAIL = "t@example.com",
  } }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. "\n" .. (res.stderr or ""))
  return vim.trim(res.stdout or "")
end

---A repo: main has f.lua; the branch adds two commits on top.
local function repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
  git(dir, "init", "-q")
  vim.fn.writefile({ "one", "two", "three" }, dir .. "/f.lua")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "base")
  git(dir, "checkout", "-q", "-b", "feature")
  vim.fn.writefile({ "one", "TWO", "three" }, dir .. "/f.lua")
  git(dir, "commit", "-q", "-am", "first: shout two", "-m", "Because two matters.")
  vim.fn.writefile({ "one", "TWO", "THREE" }, dir .. "/f.lua")
  vim.fn.writefile({ "new" }, dir .. "/g.lua")
  git(dir, "add", ".")
  git(dir, "commit", "-q", "-m", "second: shout three, add g")
  return dir, git(dir, "rev-parse", "HEAD~1"), git(dir, "rev-parse", "HEAD")
end

local function sidebar_lines()
  local win = sidebar.find_win()
  return win and api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false) or {}
end

local function current(root)
  return session.load(root).current
end

local function reset()
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
end

---Work in `dir`, on one of its files (the review is of the repo around the current file).
local function enter(dir)
  reset()
  vim.cmd.cd(dir)
  vim.cmd.edit(dir .. "/f.lua")
end

describe("commits review", function()
  ac.setup({ notify = false })

  it("lists the commits of a range oldest first; a root commit has every file added", function()
    local dir, c1, c2 = repo()
    local list = commits.list(dir, "main..feature")
    eq(vim.tbl_map(function(c) return c.sha end, list), { c1, c2 })
    eq(list[1].subject, "first: shout two")
    eq(list[1].body, "Because two matters.")
    local files = commits.changed(dir, list[2])
    table.sort(files, function(a, b) return a.path < b.path end)
    eq(vim.tbl_map(function(f) return { f.path, f.status, f.additions, f.deletions } end, files),
      { { "f.lua", "modified", 1, 1 }, { "g.lua", "added", 1, 0 } })
    local all = commits.list(dir, "feature")
    eq(all[1].parent, nil)
    local root_files = commits.changed(dir, all[1])
    eq({ root_files[1].path, root_files[1].status }, { "f.lua", "added" })
  end)

  it("opens the first commit with its files under it in the sidebar", function()
    local dir, c1, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    assert(root, "no review opened")
    eq(current(root), c1)
    -- the diff shows the commit against its parent
    local names = vim.tbl_map(function(w) return api.nvim_buf_get_name(api.nvim_win_get_buf(w)) end, api.nvim_tabpage_list_wins(0))
    local sides = {}
    for _, n in ipairs(names) do
      local r, f, side, sha = session.infer(n)
      if r then
        eq({ r, f, sha }, { root, "f.lua", c1 })
        sides[side] = vim.fn.readfile(n)
      end
    end
    eq(sides, { old = { "one", "two", "three" }, new = { "one", "TWO", "three" } })
    local lines = sidebar_lines()
    assert(lines[1]:find("main..feature · 2 commits · 0/2 reviewed", 1, true), lines[1])
    assert(lines[2]:find("▶", 1, true) and lines[2]:find(c1:sub(1, 7), 1, true) and lines[2]:find("first:", 1, true), lines[2])
    assert(lines[3]:find("f.lua", 1, true), lines[3]) -- its file, under it
    assert(lines[4]:find(c2:sub(1, 7), 1, true) and not lines[4]:find("▶", 1, true), lines[4])
    eq(#lines, 4)
    reset()
  end)

  it("]C / [C step between commits; the end says so", function()
    local dir, c1, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    feed("]C")
    eq(current(root), c2)
    local lines = sidebar_lines()
    assert(lines[3]:find("▶", 1, true) and lines[3]:find(c2:sub(1, 7), 1, true), vim.inspect(lines))
    assert(lines[4]:find("f.lua", 1, true) and lines[5]:find("g.lua", 1, true), vim.inspect(lines))
    local notes, notify = {}, vim.notify
    vim.notify = function(m) notes[#notes + 1] = m end
    commits.step(root, 1)
    vim.notify = notify
    eq(current(root), c2)
    assert(notes[1]:find("last commit", 1, true), vim.inspect(notes))
    feed("[C")
    eq(current(root), c1)
    reset()
  end)

  it("a comment belongs to its commit: not shown on the next one, and opening it goes back", function()
    local dir, c1, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    ac.add(2, 2)
    api.nvim_buf_set_lines(0, 0, -1, false, { "why shout?" })
    feed("<C-s>")
    local t = store.read(root).threads[1]
    eq({ t.commit, t.file, t.range.start }, { c1, "f.lua", 2 })
    eq(session.thread_path(root, t), session.commit_cache(session.load(root), c1) .. "/head/f.lua")
    commits.step(root, 1)
    eq(current(root), c2)
    -- commit 2's f.lua has TWO on line 2 too, but the thread is not about this commit
    local ns = api.nvim_create_namespace("code-review")
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      local b = api.nvim_win_get_buf(w)
      if session.infer(api.nvim_buf_get_name(b)) then
        ac.render(b, true)
        eq(#api.nvim_buf_get_extmarks(b, ns, 0, -1, {}), 0)
      end
    end
    eq(store.read(root).threads[1].status, "open") -- re-anchoring against commit 2 did not touch it
    local lines = sidebar_lines()
    assert(lines[2]:find("✎1", 1, true), lines[2]) -- the count stays on commit 1
    ac.goto_thread(api.nvim_get_current_win(), root, t)
    eq(current(root), c1)
    reset()
  end)

  it("marking the last file of a commit viewed moves on to the next commit", function()
    local dir, c1, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    diff.toggle_viewed(root, "f.lua")
    eq(current(root), c2)
    assert(commits.reviewed(root, session.load(root).commits[1]))
    assert(not commits.reviewed(root, session.load(root).commits[2]))
    -- reopening resumes at the first commit not reviewed yet
    reset()
    session.save(root, vim.tbl_extend("force", session.load(root), { current = nil }))
    commits.open("main..feature")
    eq(current(root), c2)
    reset()
  end)

  it("]f past the last file of a commit goes on to the next commit", function()
    local dir, _, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    diff.step(1)
    eq(current(root), c2)
    reset()
  end)

  it("the pickers list paths that exist under the cache of all commits", function()
    local dir, c1, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    ac.add(2, 2)
    api.nvim_buf_set_lines(0, 0, -1, false, { "why shout?" })
    feed("<C-s>")
    commits.step(root, 1)
    local picker = require("code-review.picker")
    local base = session.load(root).cache_base
    for _, e in ipairs(picker.file_entries(root)) do
      local path = e.text:match("^(.-):1:")
      assert(path:find("^" .. c2), path)
      assert(vim.uv.fs_stat(base .. "/" .. path), path)
    end
    local t = picker.thread_entries(root)[1]
    eq(t.loc, c1 .. "/head/f.lua:2:")
    picker.open(root, t) -- back to the thread's commit
    eq(current(root), c1)
    reset()
  end)

  it("threads and viewed marks follow a commit that was rewritten; U reads the range again", function()
    local dir, c1, c2 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    diff.toggle_viewed(root, "f.lua") -- commit 1 done: on to commit 2
    eq(current(root), c2)
    ac.add(1, 1)
    api.nvim_buf_set_lines(0, 0, -1, false, { "and g?" })
    feed("<C-s>")
    -- rewrite both commits (new shas, same subjects): commit 1 keeps its text, commit 2 changes g.lua
    git(dir, "rebase", "-q", "--exec", "git commit -q --amend --no-edit --date=2001-01-01T00:00:00", "main")
    vim.fn.writefile({ "newer" }, dir .. "/g.lua")
    git(dir, "commit", "-q", "-a", "--amend", "--no-edit")
    local n1, n2 = git(dir, "rev-parse", "HEAD~1"), git(dir, "rev-parse", "HEAD")
    assert(n1 ~= c1 and n2 ~= c2)
    vim.cmd.cd(vim.fn.tempname():match("^(.*)/")) -- U works from anywhere
    local sb = sidebar.find_win()
    api.nvim_set_current_win(sb)
    diff.reload(root)
    local t = store.read(root).threads[1]
    eq(t.commit, n2)
    assert(commits.reviewed(root, session.load(root).commits[1])) -- same text: still reviewed
    -- the thread opens on the new commit
    commits.show(root, n1)
    ac.goto_thread(api.nvim_get_current_win(), root, t)
    eq(current(root), n2)
    reset()
  end)

  it("an empty range says so instead of opening", function()
    local dir = repo()
    enter(dir)
    local notes, notify = {}, vim.notify
    vim.notify = function(m) notes[#notes + 1] = m end
    local root = commits.open("feature..feature")
    vim.notify = notify
    eq(root, nil)
    assert(notes[1]:find("no commits in feature..feature", 1, true), vim.inspect(notes))
  end)

  it("<leader>co opens the branch's commits; on main it asks for a range", function()
    local dir, c1 = repo()
    enter(dir)
    feed("<leader>co")
    local root = session.local_dirs(dir)
    eq(current(root), c1)
    eq(session.load(root).range, "main..HEAD")
    reset()
    git(dir, "checkout", "-q", "main")
    git(dir, "merge", "-q", "--ff-only", "feature")
    enter(dir)
    local input = vim.ui.input
    local asked
    vim.ui.input = function(o, cb)
      asked = o.default
      cb("HEAD~1..HEAD")
    end
    commits.open()
    vim.ui.input = input
    eq(asked, "HEAD~5..HEAD")
    eq(session.load(root).range, "HEAD~1..HEAD")
    reset()
  end)

  it("the agent is told which commit each thread is on, and works in the repo", function()
    local dir, c1 = repo()
    enter(dir)
    local root = commits.open("main..feature")
    ac.add(2, 2)
    api.nvim_buf_set_lines(0, 0, -1, false, { "why shout?" })
    feed("<C-s>")
    local text = require("code-review.prompt").build(root, { cwd = dir })
    assert(text:find("in commit " .. c1:sub(1, 12), 1, true), text)
    assert(text:find("--root", 1, true), text) -- the comments are not in the repo
    assert(not text:find("--fixup", 1, true), text) -- nothing approved: no change to make
    store.update(root, function(d) store.set_approved(d.threads[1], true) end)
    text = require("code-review.prompt").build(root, { cwd = dir, all = true })
    assert(text:find("git commit --fixup=<sha>", 1, true), text)
    eq(session.workdir(root), dir)
    reset()
  end)
end)
