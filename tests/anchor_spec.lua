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
