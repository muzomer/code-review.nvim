-- Adapters for the coding agents the plugin can run in the background.
--
-- The comments themselves need no adapter: any agent that runs shell commands
-- uses the `code-review` CLI. An adapter only knows how to start an agent
-- without a terminal, continue (or fork) its session, and read its output:
--
--   name       shown in pickers and the status
--   cmd        executable (config.headless.cmd overrides it)
--   preset_id  the session id can be chosen up front (else it is read from the output)
--   fork       a session can be copied, so a poke can answer from a fork of it
--   subagents  the agent can hand work to a subagent (prompt wording)
--   args(o)    the command line; o = { cmd, prompt, cwd, new_id?, resume?, fork?, dirs, cfg, edit? }
--              (edit: a local review, where the agent should change the code)
--   parse(ev)  one decoded JSON line -> { lines?, append?, session_id?, done?, error?, cost? }
--   chat(id)   command line of an interactive terminal on that session
--
-- Claude Code was checked against the real CLI. Codex, OpenCode and Gemini CLI
-- follow their documentation; their output parsing is lenient (anything it
-- does not recognise is skipped, and non-JSON lines are shown as they are).
local M = {}

local function one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

local function text_lines(text)
  text = vim.trim(tostring(text or ""))
  return text ~= "" and vim.split(text, "\n", { plain = true }) or {}
end

local function tool_line(name, input)
  input = type(input) == "table" and input or {}
  local what = input.command or input.cmd or input.file_path or input.filePath or input.path or input.pattern
    or input.description or ""
  if type(what) == "table" then
    what = table.concat(what, " ")
  end
  return string.format("→ %s %s", name or "tool", one_line(what, 120))
end

-- The CLI of this checkout. Background agents get its directory on PATH and
-- may run it by full path too: an agent that saw the path in its session
-- tends to use it, and a call it is not allowed to make cannot be approved by
-- anyone in a background run.
local here = debug.getinfo(1, "S").source:sub(2)
M.BIN = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(here, ":p"))))) .. "/bin"

M.claude = {
  name = "Claude Code",
  cmd = "claude",
  preset_id = true,
  fork = true,
  subagents = true,
  DEFAULT_TOOLS = { "Bash(code-review:*)", "Read", "Grep", "Glob" },
  EDIT_TOOLS = { "Edit", "Write" }, -- added for local reviews (not PRs)
  args = function(o)
    local c = o.cfg
    local args = { o.cmd, "-p", o.prompt, "--output-format", "stream-json", "--verbose" }
    if o.fork then
      vim.list_extend(args, { "--resume", o.fork, "--fork-session" })
    elseif o.resume then
      vim.list_extend(args, { "--resume", o.resume })
    else
      vim.list_extend(args, { "--session-id", o.new_id })
    end
    local tools = c.allowed_tools
    if not tools then
      tools = vim.list_extend(vim.deepcopy(M.claude.DEFAULT_TOOLS), { "Bash(" .. M.BIN .. "/code-review:*)" })
      if o.edit then
        -- the prompt asks for the changes the comments request; Claude only
        -- edits inside its directory and the --add-dir ones
        vim.list_extend(tools, M.claude.EDIT_TOOLS)
      end
    end
    if #tools > 0 then
      args[#args + 1] = "--allowedTools"
      vim.list_extend(args, tools)
    end
    if c.permission_mode then
      vim.list_extend(args, { "--permission-mode", c.permission_mode })
    end
    for _, d in ipairs(o.dirs) do
      vim.list_extend(args, { "--add-dir", d })
    end
    return args
  end,
  parse = function(ev)
    if ev.type == "assistant" and ev.message then
      local out = {}
      for _, c in ipairs(ev.message.content or {}) do
        if c.type == "text" then
          vim.list_extend(out, text_lines(c.text))
        elseif c.type == "tool_use" then
          out[#out + 1] = tool_line(c.name, c.input)
        end
      end
      return { lines = out }
    elseif ev.type == "result" then
      return { done = true, error = ev.is_error and tostring(ev.result or "failed") or nil, cost = ev.total_cost_usd }
    end
  end,
  -- the saved session is gone (deleted, or never written)
  lost_session = function(err)
    return err:lower():find("no conversation found", 1, true) ~= nil
  end,
  chat = function(cmd, id)
    return { cmd, "--resume", id }
  end,
}

M.codex = {
  name = "Codex",
  cmd = "codex",
  args = function(o)
    local c = o.cfg
    -- replies are written to the review's store: the sandbox must allow writes in the cwd
    local args = { o.cmd, "exec", "--json", "--skip-git-repo-check", "--sandbox", c.permission_mode or "workspace-write" }
    if o.resume then
      vim.list_extend(args, { "resume", o.resume })
    end
    args[#args + 1] = o.prompt
    return args
  end,
  parse = function(ev)
    if ev.type == "thread.started" then
      return { session_id = ev.thread_id }
    end
    local item = ev.item
    if ev.type == "item.started" and item and item.type == "command_execution" then
      return { lines = { "→ $ " .. one_line(item.command, 120) } }
    elseif ev.type == "item.completed" and item and item.type == "agent_message" then
      return { lines = text_lines(item.text) }
    elseif ev.type == "turn.completed" then
      return { done = true }
    elseif ev.type == "turn.failed" or ev.type == "error" then
      local e = ev.error
      return { done = ev.type == "turn.failed", error = type(e) == "table" and e.message or ev.message or "failed" }
    end
  end,
  chat = function(cmd, id)
    return { cmd, "resume", id }
  end,
}

M.opencode = {
  name = "OpenCode",
  cmd = "opencode",
  fork = true,
  args = function(o)
    local args = { o.cmd, "run", "--format", "json" }
    local session = o.fork or o.resume
    if session then
      vim.list_extend(args, { "--session", session })
    end
    if o.fork then
      args[#args + 1] = "--fork"
    end
    if o.cfg.permission_mode == "auto" then
      args[#args + 1] = "--auto"
    end
    vim.list_extend(args, { "--dir", o.cwd, o.prompt })
    return args
  end,
  parse = function(ev)
    local part = type(ev.part) == "table" and ev.part or {}
    local res = { session_id = ev.sessionID or ev.session_id or part.sessionID }
    local text = part.type == "text" and part.text or (ev.type == "text" and ev.text)
    if text then
      res.lines = text_lines(text)
    elseif part.type == "tool" or ev.type == "tool_use" then
      res.lines = { tool_line(part.tool or ev.name, (part.state or {}).input or ev.input) }
    elseif ev.type == "error" then
      res.error = one_line(type(ev.error) == "table" and (ev.error.message or vim.inspect(ev.error)) or ev.error or "failed", 200)
    end
    return res
  end,
  chat = function(cmd, id)
    return { cmd, "--session", id }
  end,
}

M.gemini = {
  name = "Gemini CLI",
  cmd = "gemini",
  -- sessions are kept per project directory; a review's runs all start in its root,
  -- so "latest" there is this review's session
  resume_latest = true,
  args = function(o)
    local c = o.cfg
    local args = { o.cmd, "-p", o.prompt, "-o", "stream-json" }
    if o.resume then
      vim.list_extend(args, { "-r", "latest" })
    end
    if c.permission_mode then
      vim.list_extend(args, { "--approval-mode", c.permission_mode })
    end
    for _, d in ipairs(o.dirs) do
      vim.list_extend(args, { "--include-directories", d })
    end
    return args
  end,
  parse = function(ev)
    if ev.type == "init" then
      return { session_id = ev.session_id or ev.sessionId or "latest" }
    elseif ev.type == "message" and ev.role ~= "user" then
      local text = type(ev.content) == "string" and ev.content or ""
      if ev.delta then
        return { append = text }
      end
      return { lines = text_lines(text) }
    elseif ev.type == "tool_use" then
      return { lines = { tool_line(ev.tool_name or ev.name, ev.parameters or ev.args) } }
    elseif ev.type == "error" then
      return { error = one_line(ev.message or ev.error or "error", 200), done = false }
    elseif ev.type == "result" then
      local failed = ev.status == "error" or ev.status == "failure"
      return { done = true, error = failed and one_line(ev.error or ev.status, 200) or nil }
    end
  end,
  chat = function(cmd)
    return { cmd, "-r", "latest" }
  end,
}

M.NAMES = { "claude", "codex", "opencode", "gemini" }

---The adapter for a name (herdr reports "claude", "codex", ...), or nil.
function M.get(name)
  return name and M[name] and type(M[name]) == "table" and M[name].args and M[name] or nil
end

return M
