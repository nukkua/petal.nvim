-- petal — magit-style git status. setup() only records options: the plugin itself (petal.core)
-- loads on first use (:Petal, a mapping, $GIT_EDITOR's RPC), so calling setup() at startup is free
local M, opts, core = {}, {}, nil
local function load()
  if not core then
    core = require("petal.core")
    core.setup(opts)
  end
  return core
end
function M.setup(o)
  if core then return core.setup(o) end
  opts = vim.tbl_extend("force", opts, o or {}) -- shallow, as core.setup merges
end
return setmetatable(M, { __index = function(_, k) return load()[k] end, __newindex = function(_, k, v) load()[k] = v end })
