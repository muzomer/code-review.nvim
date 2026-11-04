-- Threads already there when the demo starts.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)
local store, anchor = require("code-review.store"), require("code-review.anchor")
local root = "/tmp/api"
local file = "rate_limiter.py"
local lines = vim.fn.readfile(root .. "/" .. file)
local function thread(l1, l2, msgs, status)
  store.update(root, function(d)
    local id = store.add_thread(d, {
      file = file, start = l1, ["end"] = l2, anchor = anchor.capture(lines, l1, l2),
      author = "user", body = msgs[1],
    })
    local t = store.find(d, id)
    for i = 2, #msgs do
      store.add_message(t, i % 2 == 0 and "claude" or "user", msgs[i])
    end
    t.status = status or t.status
  end)
end
thread(10, 10, {
  "Why start the bucket full instead of empty?",
  "So a new client can send a burst right away: up to `capacity` requests at once, then `rate` per second."
    .. " Starting empty would make every client wait `1 / rate` seconds for its very first request.",
})
thread(32, 32, {
  "What do rate=5, capacity=10 mean in practice?",
  "5 requests per second on average, with bursts of up to 10 when the client was idle for 2 seconds.",
}, "resolved")
