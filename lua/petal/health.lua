local M = {}

function M.check()
  local h = vim.health
  local t = require("petal")._t
  local C = t.config()

  h.start("petal")
  if vim.fn.has("nvim-0.12") == 1 then h.ok("Neovim " .. tostring(vim.version())) else h.error("Neovim 0.12+ is required") end
  if vim.fn.executable("git") == 1 then
    h.ok(vim.trim(vim.system({ "git", "--version" }, { text = true }):wait().stdout or "git"))
  else
    h.error("git not found in $PATH")
  end

  h.start("petal: pull requests (optional)")
  if vim.fn.executable("gh") == 0 then
    h.info("gh not found: PR features are off (https://cli.github.com)")
  else
    local r = vim.system({ "gh", "auth", "status" }, { text = true }):wait(10000)
    if r.code == 0 then
      h.ok("gh is logged in")
    else
      h.warn("gh auth status failed: " .. (vim.split(vim.trim((r.stderr or "") .. (r.stdout or "")), "\n")[1] or ""), { "run: gh auth login" })
    end
  end

  h.start("petal: options")
  if pcall(require, "fidget") then h.ok("fidget.nvim found: progress spinners") else h.info("fidget.nvim not found: plain notifications") end
  local cs = C.commit_suggest
  if cs == nil then
    h.info("commit_suggest not set")
  elseif type(cs) ~= "table" or type(cs[1]) ~= "string" then
    h.error("commit_suggest must be an argv list, e.g. { \"claude\", \"-p\", \"...\" }")
  elseif vim.fn.executable(cs[1]) == 0 then
    h.error("commit_suggest: " .. cs[1] .. " is not executable")
  else
    h.ok("commit_suggest: " .. cs[1])
  end
  if type(C.mappings) ~= "table" then return h.error("mappings must be a table") end
  local names, bad = t.actions(), {}
  for key, name in pairs(C.mappings) do
    if name ~= false and not names[name] then bad[#bad + 1] = ("%s = %s"):format(key, vim.inspect(name)) end
  end
  if #bad > 0 then
    h.error("mappings: unknown actions: " .. table.concat(bad, ", "), { "see :h petal-actions" })
  else
    h.ok("mappings")
  end
end

return M
