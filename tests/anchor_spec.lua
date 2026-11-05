local anchor = require("code-review.anchor")

local base = { "a", "b", "target()", "c", "d" }

describe("locate", function()
  it("keeps the stored position when text still matches", function()
    local a = anchor.capture(base, 3, 3)
    eq({ anchor.locate(base, a, { start = 3, ["end"] = 3 }) }, { 3, 3, "exact" })
  end)

  it("follows code that moved", function()
    local a = anchor.capture(base, 3, 3)
    local moved = { "new", "new", "a", "b", "target()", "c", "d" }
    eq({ anchor.locate(moved, a, { start = 3, ["end"] = 3 }) }, { 5, 5, "moved" })
  end)

  it("uses context to pick between duplicate matches", function()
    local lines = { "x", "y", "dup", "z", "a", "b", "dup", "c", "d" }
    local a = anchor.capture({ "a", "b", "dup", "c", "d" }, 3, 3)
    -- stored position 3 points at the wrong duplicate's line? it matches text,
    -- so use a stale position to force a search
    eq({ anchor.locate(lines, a, { start = 1, ["end"] = 1 }) }, { 7, 7, "moved" })
  end)

  it("fuzzy-matches lightly edited code", function()
    local lines = { "a", "b", "local result = compute(x, y)", "c" }
    local a = anchor.capture({ "local result = compute(x)" }, 1, 1)
    local s, e, how = anchor.locate(lines, a, { start = 1, ["end"] = 1 })
    eq({ s, e, how }, { 3, 3, "fuzzy" })
  end)

  it("matches re-indented multi-line blocks", function()
    local a = anchor.capture({ "if x then", "  go()", "end" }, 1, 3)
    local lines = { "do", "    if x then", "      go()", "    end", "end" }
    local s, e = anchor.locate(lines, a, { start = 1, ["end"] = 3 })
    eq({ s, e }, { 2, 4 })
  end)

  it("gives up when the code is gone", function()
    local a = anchor.capture({ "very specific line of code" }, 1, 1)
    eq(anchor.locate({ "totally", "different" }, a, { start = 1, ["end"] = 1 }), nil)
  end)
end)

describe("reanchor_threads", function()
  local function thread(lines, s, e)
    return { status = "open", range = { start = s, ["end"] = e }, anchor = anchor.capture(lines, s, e) }
  end

  it("marks lost threads outdated and restores them later", function()
    local t = thread(base, 3, 3)
    eq(anchor.reanchor_threads({ t }, { "nothing here" }), true)
    eq(t.status, "outdated")
    eq(anchor.reanchor_threads({ t }, base), true)
    eq(t.status, "open")
  end)

  it("marks threads outdated when the file is deleted", function()
    local t = thread(base, 3, 3)
    anchor.reanchor_threads({ t }, nil)
    eq(t.status, "outdated")
  end)

  it("reports no change when nothing moved", function()
    eq(anchor.reanchor_threads({ thread(base, 2, 4) }, base), false)
  end)
end)

describe("threads on selected text", function()
  local code = { "local x = 1", "local delay = retry_delay_ms * attempt", "return delay" }
  local function span_thread(lines, s, e, sc, ec)
    return {
      status = "open",
      range = { start = s, ["end"] = e, start_col = sc, end_col = ec },
      anchor = anchor.capture(lines, s, e, sc, ec),
    }
  end

  it("captures the selected text, across lines too", function()
    eq(anchor.capture(code, 2, 2, 15, 38).span, "retry_delay_ms * attempt")
    eq(anchor.capture(code, 1, 2, 7, 5).span, "x = 1\nlocal")
    eq(anchor.capture(code, 2, 2).span, nil) -- whole lines: no span
  end)

  it("keeps its columns when the code only moved", function()
    local t = span_thread(code, 2, 2, 15, 38)
    local moved = { "-- new", "local x = 1", "local delay = retry_delay_ms * attempt", "return delay" }
    eq(anchor.reanchor_threads({ t }, moved), true)
    eq(t.range, { start = 3, ["end"] = 3, start_col = 15, end_col = 38 })
  end)

  it("finds its text again in a lightly edited line", function()
    local t = span_thread(code, 2, 2, 15, 38)
    local edited = { "local x = 1", "local delay_s = retry_delay_ms * attempt", "return delay" }
    anchor.reanchor_threads({ t }, edited)
    eq(t.range, { start = 2, ["end"] = 2, start_col = 17, end_col = 40 })
    eq(t.anchor.span, "retry_delay_ms * attempt")
    eq(t.status, "open")
  end)

  it("picks the occurrence nearest to where it was", function()
    local lines = { "f(a) + f(a) + f(a)!" }
    local t = span_thread(lines, 1, 1, 15, 18) -- the third f(a)
    anchor.reanchor_threads({ t }, { "f(a) + f(a) + f(a)?" })
    eq({ t.range.start_col, t.range.end_col }, { 15, 18 })
  end)

  it("falls back to the whole lines when its text is gone", function()
    local t = span_thread(code, 2, 2, 15, 38)
    local edited = { "local x = 1", "local delay = retry_ms * attempt", "return delay" }
    anchor.reanchor_threads({ t }, edited)
    eq(t.status, "open")
    eq(t.range, { start = 2, ["end"] = 2 })
    eq(anchor.cols(t), nil)
  end)

  it("a thread without columns is on whole lines", function()
    eq(anchor.cols({ range = { start = 1, ["end"] = 1 } }), nil)
    eq(anchor.cols({ range = { start = 1, ["end"] = 1, start_col = "x", end_col = 2 } }), nil)
    eq({ anchor.cols({ range = { start = 1, ["end"] = 1, start_col = 3, end_col = 4 } }) }, { 3, 4 })
  end)
end)
