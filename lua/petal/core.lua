-- petal — magit-style git status + popups on the git CLI
-- :Petal (or require("petal").open()) opens it, ? lists every key. Every git call is async (vim.system); a refresh is one
-- parallel batch of short processes, toggles re-render from cache, and only changed lines are redrawn.
-- ponytail: no worktree/submodule popups; no credential prompts (use ssh-agent or a credential
-- helper); a ' in a repo path breaks the $EDITOR bridge

local M = {}

local C = {
  reviewers = {},                                      -- offered by PR create (gh); empty = never asks
  base_branches = { "origin/develop", "origin/main" }, -- tried in order for "merged into", then origin/HEAD
  recent = 10,                                         -- commits in the Recent section
  height = 12,                                         -- height of the bottom pickers/popups
  commit_suggest = nil,                                -- argv: staged diff on stdin -> commit message on stdout;
                                                       -- runs when the commit buffer opens, <c-c><c-s> accepts,
                                                       -- <c-c><c-y> accepts and commits
  mappings = {},                                       -- status keys: { [key] = action name | false }, see :h petal-mappings
  watch = true,                                        -- refresh the open status when the repo changes on disk
  simple = false,                                      -- just status + core keys: no PR line, conflict radar,
                                                       -- background fetch, watcher or commit summary, see :h petal-opt-simple
}
local BIND
function M.setup(opts) -- shallow: list options replace, not merge
  C = vim.tbl_extend("force", C, opts or {})
  BIND = nil
end

local S = {
  root = nil, gitdir = nil, buf = nil, prev = nil,
  data = nil, diffs = {}, rows = {}, -- rows[buf][lnum] = item on that line
  fold = {}, open = {},              -- collapsed sections; expanded files ("section:path" -> file)
  switches = {}, history = {},
  fetch = { job = false, at = -math.huge, cbs = {} },
  pr = nil,                          -- "root\0branch" -> PR lines; gh takes seconds, so paint from this disk cache
  pr_at = {},                        -- "root\0branch" -> last gh call (ms); gh runs at most every PR_TTL
  base = nil,                        -- integration branch the conflict radar checks (find_base, cached per repo)
  radar_cache = {},                  -- target -> { key = "HEAD oid target oid", files }: last merge-tree answer
  queue = {},                        -- serialized index/worktree commands, head is running
  seq = 0,                           -- refresh generation: stale async results are dropped
  refreshed = 0,                     -- hrtime() of the last refresh: a watch event older than it is already shown
  watch = {},                        -- dir -> uv fs_event handle while the status is open
  commondir = nil, reftable = false, stash_cache = nil, raw_diff = {},
}
local ns = vim.api.nvim_create_namespace("petal")
local FETCH_TTL = 30000 -- ms: a fetch this fresh is reused instead of hitting the network again
local PR_TTL = 60000    -- ms: gh pr view is ~6s of network; refetched on open, after push/PR actions, else at most this often
local HISTORY_MAX = 100
local LOGFMT = "%h%x1f%D%x1f%s%x1f%an%x1f%at" -- %at: unix time, shown as a short age
local HAS_GH = vim.fn.executable("gh") == 1
local PR_CACHE = vim.fn.stdpath("cache") .. "/petal_pr.json"

-- git asks this nvim to edit COMMIT_EDITMSG / git-rebase-todo / TAG_EDITMSG over RPC and waits
-- until M.edit drops the lock (or nvim is gone). It also passes the index git will commit
-- (-a/--only/paths use a temporary one) and whether the parent git is amending
local EDITOR = [[f(){ case $1 in /*) p=$1;; *) p=$PWD/$1;; esac; i=${GIT_INDEX_FILE:-}; case $i in ""|/*) ;; *) i=$PWD/$i;; esac; a=$(ps -o args= -p $PPID 2>/dev/null | grep -c -e ' --am'); touch "$p.nvlock"; "$NVIM_BIN" --server "$NVIM" --remote-expr "luaeval('require(\"petal\").edit(_A[1], _A[2], _A[3] > 0)', ['$p', '$i', $a])" >/dev/null; while [ -e "$p.nvlock" ] && [ -e "$NVIM" ]; do sleep 0.05; done; }; f]]

-- defaults only (default = true): a colorscheme can set any of these
local HL = {
  GitSectionHeader = "Title", GitBranch = "Identifier", GitBranchHead = "GitBranch",
  GitRemote = "Constant", GitTagName = "Special", GitObjectId = "Comment",
  GitSubtleText = "Comment", GitHunkHeader = "Special",
  GitChangeAdded = "Added", GitChangeNewFile = "Added", GitChangeModified = "Changed",
  GitChangeDeleted = "Removed", GitChangeRenamed = "Changed", GitChangeCopied = "Changed",
  GitChangeUpdated = "Changed", GitChangeUnmerged = "WarningMsg",
  GitDiffAdd = "GitChangeAdded", GitDiffDelete = "GitChangeDeleted",
  GitGraph1 = "Added", GitGraph2 = "Changed", GitGraph3 = "Removed", GitGraph4 = "Constant",
  GitGraph5 = "Identifier", GitGraph6 = "Special", GitGraphCommit = "GitBranch", GitGraphAuthor = "Constant",
  GitOurs = "GitChangeAdded", GitTheirs = "GitRemote", GitBase = "GitSubtleText",
  GitMergeOurs = "DiffAdd", GitMergeTheirs = "DiffChange", GitMergeBase = "DiffText", GitMergeMarker = "GitSubtleText",
  GitKindNew = "GitChangeAdded", GitKindFix = "GitChangeModified", GitKindMerge = "Special", GitKindBranch = "GitBranch",
  GitKindReset = "GitChangeDeleted", GitKindRewrite = "GitChangeUpdated", GitKindChore = "GitSubtleText",
  GitPopupActionKey = "Special", GitPopupSwitchKey = "Special", GitPopupSwitchEnabled = "String",
  GitNotifyError = "DiagnosticError", GitNotifyWarn = "DiagnosticWarn", GitNotifyInfo = "DiagnosticInfo",
  GitNotifySubject = "GitBranch",
}
-- GitHub web (Primer): open green, merged purple, closed red, draft gray
local PR_HL = { PrOpen = "#9ecfa8", PrMerged = "#c3a8d8", PrClosed = "#d98c8c", PrDraft = "#8a8a8a", PrWarn = "#d8b48f", PrBranch = "#ffb6c1" }
local function hl()
  for k, v in pairs(HL) do vim.api.nvim_set_hl(0, k, { link = v, default = true }) end
  for k, fg in pairs(PR_HL) do vim.api.nvim_set_hl(0, k, { fg = fg, default = true }) end
end
hl()
vim.api.nvim_create_autocmd("ColorScheme", { callback = hl })

---------------------------------------------------------------- helpers

local function cat(...)
  local t = {}
  for i = 1, select("#", ...) do vim.list_extend(t, (select(i, ...))) end
  return t
end
local function lines(s)
  if not s or s == "" then return {} end
  local t, i, n = {}, 1, 0
  while true do
    local j = s:find("\n", i, true)
    n = n + 1
    t[n] = j and s:sub(i, j - 1) or s:sub(i)
    if not j then break end
    i = j + 1
  end
  while n > 0 and t[n] == "" do t[n], n = nil, n - 1 end
  local first = 1
  while first <= n and t[first] == "" do first = first + 1 end
  if first > 1 then
    for x = first, n do t[x - first + 1] = t[x] end
    for x = n - first + 2, n do t[x] = nil end
  end
  return t
end
-- lines() streamed: no intermediate table, same trimempty edges and internal blank lines
local function scan_lines(s, fn)
  if not s or s == "" then return end
  local i, pending, seen = 1, 0, false
  while i <= #s do
    local j = s:find("\n", i, true)
    local l = j and s:sub(i, j - 1) or s:sub(i)
    if l == "" then
      pending = pending + 1
    else
      if seen then for _ = 1, pending do fn("") end end
      seen, pending = true, 0
      fn(l)
    end
    if not j then break end
    i = j + 1
  end
end
-- every message is "subject: what happened", extra lines are detail.
-- info goes to fidget (corner, fades out); warnings/errors stay in vim.notify so they're not missed.
-- with the builtin vim.notify they're echoed in color (icon, subject); a notifier plugin gets plain text
local ICON = { [vim.log.levels.ERROR] = { "✗", "GitNotifyError" }, [vim.log.levels.WARN] = { "▲", "GitNotifyWarn" } }
local function notify(msg, lvl)
  lvl = lvl or vim.log.levels.INFO
  local ok, fidget = pcall(require, "fidget")
  if ok and lvl <= vim.log.levels.INFO then return fidget.notify(msg, lvl, { annote = "git" }) end
  if not (debug.getinfo(vim.notify, "S").source or ""):match("^@?vim/") then return vim.notify(msg, lvl, { title = "git" }) end
  local subject, rest = msg:match("^([^%s:]+): (.*)$")
  local first, detail = (rest or msg):match("^([^\n]*)\n?(.*)$")
  local icon = ICON[lvl] or { "●", "GitNotifyInfo" }
  local chunks = { { icon[1] .. " ", icon[2] } }
  if subject then vim.list_extend(chunks, { { subject, "GitNotifySubject" }, { " " } }) end
  chunks[#chunks + 1] = { first, "Normal" }
  if detail ~= "" then chunks[#chunks + 1] = { "\n" .. detail, "GitSubtleText" } end
  vim.api.nvim_echo(chunks, true, { err = lvl >= vim.log.levels.ERROR })
end

-- git's "nothing to do" answers: a warning in plain words, not an error
local QUIET = {
  { "invalid reference: @{%-1}", "no previous branch" },
  { "No configured push destination", "no remote configured (M a adds one)" },
  { "No stash entries found", "no stash entries" },
  { "^nothing to commit" }, { "^nothing added to commit" }, { "^no changes added to commit" },
}
-- login failures: git runs with no tty (see git()), so it can't ask for a username, password or
-- passphrase and prints its internals instead. Say what's wrong and how to fix it; git's line stays as detail
local AUTH = {
  { "terminal prompts disabled",
    "remote needs a login and petal can't prompt for one: switch to an SSH remote (git remote set-url origin git@host:owner/repo.git) or run gh auth setup-git" },
  { "Permission denied %(publickey", "SSH key rejected: load it with ssh-add, or add it to your account on the remote" },
  { "Host key verification failed", "remote's SSH host key isn't trusted yet: run ssh -T git@<host> once in a terminal to accept it" },
  { "Authentication failed for", "saved credentials were rejected (expired token?): run gh auth login, then gh auth setup-git" },
}
-- failed git/gh result -> message, level: hints and (use …) advice dropped, fatal:/error: stripped,
-- at most 6 lines (the rest is in history, $). A failure only on stdout ends in its verdict line
local function failure(r)
  local stderr = vim.trim(r.stderr or "") ~= ""
  local out = {}
  for _, l in ipairs(lines(stderr and r.stderr or r.stdout)) do
    if not (l:match("^hint:") or l:match("^%s*%(use ")) then
      l = vim.trim((l:gsub("^fatal: ", ""):gsub("^error: ", ""):gsub("%s*%(use .-%)$", "")))
      if l ~= "" then out[#out + 1] = l end
    end
  end
  if not stderr then out = { out[#out] } end
  for _, a in ipairs(AUTH) do
    for _, l in ipairs(out) do if l:match(a[1]) then return a[2] .. "\n" .. l, vim.log.levels.ERROR end end
  end
  for _, q in ipairs(QUIET) do
    for _, l in ipairs(out) do if l:match(q[1]) then return q[2] or l, vim.log.levels.WARN end end
  end
  if #out > 6 then out = cat(vim.list_slice(out, 1, 6), { "… full output in history ($)" }) end
  return #out > 0 and table.concat(out, "\n") or ("exited " .. r.code), vim.log.levels.ERROR
end
local function fail(subject, r, spin)
  if spin then spin("failed") end
  local msg, lvl = failure(r)
  notify(subject .. ": " .. msg, lvl)
end
-- fidget spinner for slow (network) work; returns done(msg) which ends it showing msg.
-- without fidget: no spinner, done(msg) is a plain notification. client: the group fidget shows it under
local function progress(title, msg, client)
  local ok, fp = pcall(require, "fidget.progress")
  if not ok then return function(final) notify(title .. ": " .. (final or "done")) end end
  local h = fp.handle.create({ title = title, message = msg, lsp_client = { name = client or "git" } })
  return function(final) h.message = final or "done" h:finish() end
end
local function confirm(msg) return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1 end
-- cb is deferred: with ui2 + cmdheight=0 a prompt opened from inside another prompt's callback never shows
local function input(prompt, default, cb)
  vim.ui.input({ prompt = prompt, default = default }, function(v)
    if v and v ~= "" then vim.schedule(function() cb(v) end) end
  end)
end
local function pick(prompt, items, cb)
  if #items == 0 then return notify(prompt:lower() .. ": nothing to pick", vim.log.levels.WARN) end
  require("petal.select").select(items, { prompt = prompt, height = C.height }, function(c) if c then cb(c) end end)
end

-- run git (or opts.raw argv) in the repo; cb(res) on the main loop
-- detach: no controlling tty, so ssh/https fail instead of prompting over the UI
local BASE_ENV = { GIT_EDITOR = EDITOR, GIT_SEQUENCE_EDITOR = EDITOR, NVIM = vim.v.servername,
  NVIM_BIN = vim.v.progpath, GIT_TERMINAL_PROMPT = "0" }
local function git(args, opts, cb)
  opts = opts or {}
  local cmd = opts.raw or cat({ "git" }, args)
  local env = BASE_ENV
  if BASE_ENV.NVIM ~= vim.v.servername then BASE_ENV.NVIM = vim.v.servername end
  if opts.env then
    env = {}
    for k, v in pairs(BASE_ENV) do env[k] = v end
    for k, v in pairs(opts.env) do env[k] = v end
  end
  local t0 = opts.log and vim.uv.hrtime()
  local on_exit = vim.schedule_wrap(function(r)
      if opts.log then
        table.insert(S.history, 1, { cmd = table.concat(cmd, " "), code = r.code,
          ms = math.floor((vim.uv.hrtime() - t0) / 1e6), out = vim.trim((r.stdout or "") .. (r.stderr or "")) })
        S.history[HISTORY_MAX + 1] = nil
      end
      if cb then cb(r) end
    end)
  -- a missing executable (no gh installed) throws ENOENT here: report it as a normal failed result
  local ok, err = pcall(vim.system, cmd, { cwd = S.root, text = opts.text ~= false, env = env, stdin = opts.stdin, detach = true }, on_exit)
  if not ok then
    local missing = vim.fn.executable(cmd[1]) == 0
    on_exit({ code = 127, signal = 0, stdout = "", stderr = missing
      and (cmd[1] .. " not found" .. (cmd[1] == "gh" and ": install it from https://cli.github.com" or ""))
      or tostring(err) })
  end
end

-- several read-only git commands in ONE process: sh forks them in parallel, each writing its stdout
-- and exit code to a file in a dir nvim made, then Lua reads the files. A spawn costs nvim's main
-- loop ~1ms (fork/exec of a big process) whatever git then does, so a refresh's 8+ spawns were
-- nearly all of its blocking time. The script uses only builtins: no mktemp/cat/wc per command.
-- cb(results): { code, stdout } per command, stdout normalized as text mode does; stderr dropped
-- (no caller reads it). If anything goes wrong, each command falls back to its own spawn
local BATCH_SH = [[
d=$1; shift; i=0
for c in "$@"; do i=$((i+1)); { eval "$c" >"$d/$i" 2>/dev/null; echo "$i $?"; } & done
wait
]]
local function shquote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function slurp_uv(p)
  local fd = vim.uv.fs_open(p, "r", 438)
  if not fd then return nil end
  local st = vim.uv.fs_fstat(fd)
  if not st or st.size == 0 then vim.uv.fs_close(fd); return st and "" or nil end
  local out, off = {}, 0
  while off < st.size do
    local chunk = vim.uv.fs_read(fd, st.size - off, off)
    if not chunk or #chunk == 0 then break end
    out[#out + 1] = chunk
    off = off + #chunk
  end
  vim.uv.fs_close(fd)
  return table.concat(out)
end
local function slurp(p)
  local h = io.open(p, "rb")
  if not h then return nil end
  local v = h:read("*a")
  h:close()
  return v
end
local function git_batch(cmds, cb)
  local function fallback(res)
    local left = #cmds
    for i, args in ipairs(cmds) do
      git(args, nil, function(x)
        res[i], left = x, left - 1
        if left == 0 then cb(res) end
      end)
    end
  end
  local dir = vim.fn.tempname() -- inside nvim's own temp dir, which nvim removes on exit
  if not vim.uv.fs_mkdir(dir, 448) then return fallback({}) end
  local argv = { "sh", "-c", M._batch_sh or BATCH_SH, "petal", dir }
  for _, args in ipairs(cmds) do
    local q = { "git" }
    for _, a in ipairs(args) do q[#q + 1] = shquote(a) end
    argv[#argv + 1] = table.concat(q, " ")
  end
  git(nil, { raw = argv, text = false }, function(r)
    local res = {}
    if r.code ~= 0 then
      for i = 1, #cmds do vim.uv.fs_unlink(dir .. "/" .. i) end
      vim.uv.fs_rmdir(dir)
      return fallback(res)
    end
    local codes = {}
    for i, code in (r.stdout or ""):gmatch("(%d+) (%d+)") do codes[tonumber(i)] = tonumber(code) end
    for i = 1, #cmds do
      local p, code = dir .. "/" .. i, codes[i]
      local out = slurp_uv(p)
      vim.uv.fs_unlink(p)
      if out and out:find("\r", 1, true) then out = out:gsub("\r\n", "\n") end
      if out and code then res[i] = { code = code, stdout = out } end
    end
    vim.uv.fs_rmdir(dir)
    local n = 0
    for _ in pairs(res) do n = n + 1 end
    if n == #cmds then return cb(res) end
    fallback({})
  end)
end

-- read-only buffer in this window; q goes back one step (log -> show -> q -> log, cursor kept)
-- and deletes only the view it leaves. Views are hidden, not wiped, so the one below stays alive
local function scratch(name, ft, text)
  local prev = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, type(text) == "table" and text or lines(text))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = ft
  pcall(vim.api.nvim_buf_set_name, buf, "git://" .. name)
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo[0][0].number = true -- buffer-local in this window: the user's own buffers keep their setting
  vim.keymap.set("n", "q", function()
    local back = vim.api.nvim_buf_is_valid(prev) and prev or S.buf
    if back and vim.api.nvim_buf_is_valid(back) then vim.api.nvim_win_set_buf(0, back) end
    S.rows[buf] = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end, { buffer = buf, nowait = true })
  return buf
end

local function output(out)
  local l = lines(out)
  if #l > 8 then scratch("output", "git", l) else notify(out) end
end

-- index/worktree commands run one at a time: rapid s/x would otherwise race on .git/index.lock.
-- commit/push/fetch stay free (plain commit holds no lock while its editor is open)
local SERIAL = { add = true, apply = true, restore = true, rm = true, reset = true, stash = true, switch = true, checkout = true }

-- user-visible git command: errors are reported, status refreshes after
local function act(args, opts)
  opts = opts or {}
  local Q = S.queue
  local function run(done)
    local spin = opts.msg and progress(opts.msg, table.concat(args or opts.raw, " "))
    git(args, { log = true, raw = opts.raw, stdin = opts.stdin, env = opts.env }, function(r)
      local out = vim.trim((r.stdout or "") .. "\n" .. (r.stderr or ""))
      if r.code ~= 0 then
        fail(args and args[1] or (opts.raw[1] == "gh" and opts.raw[2]) or (opts.raw[#opts.raw]:match("^git%s+([%w-]+)")) or "git", r, spin)
      elseif spin and opts.show and out ~= "" and #lines(out) <= 8 then
        spin(out) -- short output becomes the spinner's success message
      else
        if opts.show and out ~= "" then output(out) end
        if spin then spin() end
      end
      if r.code == 0 and opts.after then opts.after(r) end
      M.refresh() -- after every job, so repeated s on one row hits the file that slid up
      if done then done() end
    end)
  end
  if not (args and SERIAL[args[1]]) then return run() end
  local function next_job()
    table.remove(Q, 1)
    if Q[1] then Q[1](next_job) end
  end
  Q[#Q + 1] = run
  if #Q == 1 then run(next_job) end
end

-- snapshot tracked changes into a stash entry (worktree untouched), then cb(); Z restores it
local function backup(cb)
  git({ "stash", "create" }, nil, function(r)
    local h = vim.trim(r.stdout or "")
    if r.code ~= 0 or h == "" then return cb() end
    git({ "stash", "store", "-m", "petal backup " .. os.date("%H:%M:%S"), h }, { log = true }, function()
      notify("backup: stash@{0} (Z to restore)")
      cb()
    end)
  end)
end

local function describe(ps)
  local t = vim.list_slice(ps, 1, 10)
  if #ps > 10 then t[#t + 1] = ("…and %d more"):format(#ps - 10) end
  return table.concat(t, "\n")
end

local function state()
  local function has(f) return S.gitdir and vim.uv.fs_stat(S.gitdir .. "/" .. f) ~= nil end
  return { rebase = has("rebase-merge") or has("rebase-apply"), merge = has("MERGE_HEAD"),
    pick = has("CHERRY_PICK_HEAD"), revert = has("REVERT_HEAD"), bisect = has("BISECT_LOG") }
end

-- background `fetch --all`; cb runs once it is done (or right away if one finished recently)
local function fetch_bg(cb)
  local F = S.fetch
  if cb then F.cbs[#F.cbs + 1] = cb end
  local function flush()
    local cbs = F.cbs
    F.cbs = {}
    for _, f in ipairs(cbs) do f() end
  end
  if F.job then
    if cb then notify("fetch: waiting for the running fetch…") end
    return
  end
  if vim.uv.now() - F.at < FETCH_TTL then return flush() end
  F.job = true
  git({ "fetch", "--all", "--prune" }, { log = true }, function(r)
    F.job, F.at = false, vim.uv.now()
    if r.code ~= 0 or (r.stderr and r.stderr ~= "") then M.refresh() end
    flush()
  end)
end

local function refs(paths, cb)
  git(cat({ "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)" }, paths), nil, function(r)
    local set, out = S.data and S.data.remoteset or {}, {}
    for _, l in ipairs(lines(r.stdout)) do
      if not l:match("/HEAD$") and not set[l] then out[#out + 1] = l end
    end
    cb(out)
  end)
end

local function remote(cb)
  local rs = S.data and S.data.remotes or {}
  if #rs == 0 then return notify("remote: none configured (M a adds one)", vim.log.levels.WARN) end
  if #rs == 1 or vim.tbl_contains(rs, "origin") then return cb(#rs == 1 and rs[1] or "origin") end
  pick("Remote", rs, cb)
end

local function commits(ctx, cb)
  if #ctx.commits > 0 then return cb(ctx.commits) end
  input("Commit: ", nil, function(c) cb({ c }) end)
end

-- `c^`, or --root when c has no parent
local function base_of(c, cb)
  git({ "rev-parse", "-q", "--verify", c .. "^" }, nil, function(r) cb(r.code == 0 and c .. "^" or "--root") end)
end

---------------------------------------------------------------- parsing

-- record patterns built once, not per status line
local REC1, REC2, RECU = "^1" .. (" %S+"):rep(7) .. " (.*)$", "^2" .. (" %S+"):rep(8) .. " (.*)$", "^u" .. (" %S+"):rep(9) .. " (.*)$"
local function parse_status(out)
  local st = { untracked = {}, unstaged = {}, staged = {} }
  out = out or ""
  local i, len = 1, #out
  while i <= len do
    local j = out:find("\0", i, true) or (len + 1)
    local r, b = out:sub(i, j - 1), out:byte(i)
    if b == 35 then -- #
      local k, v = r:match("^# branch%.(%S+) (.*)$")
      if k then st[k] = v end
    elseif b == 63 then -- ?
      st.untracked[#st.untracked + 1] = { section = "untracked", path = r:sub(3), mode = "?" }
    elseif b == 49 or b == 50 then -- 1 2
      local x, y = r:sub(3, 3), r:sub(4, 4)
      local path = r:match(b == 49 and REC1 or REC2)
      local orig
      if b == 50 and j < len then
        local q = out:find("\0", j + 1, true) or (len + 1)
        orig, j = out:sub(j + 1, q - 1), q
      end
      if x ~= "." then st.staged[#st.staged + 1] = { section = "staged", path = path, mode = x, orig = orig } end
      if y ~= "." then st.unstaged[#st.unstaged + 1] = { section = "unstaged", path = path, mode = y } end
    elseif b == 117 then -- u
      st.unstaged[#st.unstaged + 1] = { section = "unstaged", path = r:match(RECU), mode = "U" }
    end
    i = j + 1
  end
  return st
end

-- one row per line of `git log [--graph] --format=LOGFMT`; graph-only connector lines have no hash
local function parse_log(out, marked)
  local t, n = {}, 0
  out = out or ""
  local i = 1
  while i <= #out do
    local j = out:find("\n", i, true)
    local l = j and out:sub(i, j - 1) or out:sub(i)
    if l ~= "" then
      local m
      if marked then m, l = l:sub(1, 1), l:sub(2) end
      local g, h, refs_, subj, an, ar = l:match("^(.-)(%x+)\31(.-)\31(.-)\31(.-)\31(.*)$")
      n = n + 1
      t[n] = h and { graph = g, hash = h, refs = refs_, subject = subj, author = an, date = ar, mark = m } or { graph = l }
    end
    if not j then break end
    i = j + 1
  end
  return t
end
local function commit_count(list)
  local n = 0
  for _, c in ipairs(list) do if c.hash then n = n + 1 end end
  return n
end

-- out: git's output, or its lines already split (and trimmed, as lines() does)
local function parse_diff(out)
  local d, h = { header = {}, hunks = {} }, nil
  local hn, dn = 0, 0
  local function line(l)
    if l:byte(1) == 64 and l:byte(2) == 64 then
      h = { header = l, lines = {}, new = tonumber(l:match("%+(%d+)")) or 1 }
      dn = dn + 1
      d.hunks[dn] = h
      hn = 0
    elseif h then
      hn = hn + 1
      h.lines[hn] = l
    else
      d.header[#d.header + 1] = l
    end
  end
  if type(out) == "table" then
    for i = 1, #out do line(out[i]) end
  else
    scan_lines(out, line)
  end
  return d
end

-- conflict blocks read straight from the markers in the worktree file (|||||| base part is optional)
local function parse_conflicts(path)
  local data = slurp_uv(path) or slurp(path)
  local out = {}
  if not data or not data:find("<<<<<<<", 1, true) then return out end
  local cur, part, n = nil, nil, 0
  local i, len = 1, #data
  while i <= len do
    local j = data:find("\n", i, true)
    local l = j and data:sub(i, j - 1) or data:sub(i)
    n = n + 1
    local b = l:byte(1)
    if b == 60 and l:match("^<<<<<<<") then cur, part = { line = n, ours = {}, base = {}, theirs = {} }, "ours"
    elseif cur and b == 124 and l:match("^|||||||") then part = "base"
    elseif cur and b == 61 and l:match("^=======$") then part = "theirs"
    elseif cur and b == 62 and l:match("^>>>>>>>") then out[#out + 1], cur = cur, nil
    elseif cur then cur[part][#cur[part] + 1] = l end
    if not j then break end
    i = j + 1
  end
  return out
end

local function diff_args(f)
  if f.section == "untracked" then return { "diff", "--no-index", "--", "/dev/null", f.path } end
  return cat({ "diff" }, f.section == "staged" and { "--cached" } or {}, { "--", f.path, f.orig })
end


-- one batched `git diff` per section, split back per file by its `diff --git` header (a typechange
-- emits two sections with the same header; they concatenate, as a per-file diff would)
local function split_diff(out)
  local by, cur = {}, nil
  scan_lines(out, function(l)
    local b = l:byte(1)
    if b == 100 and l:sub(1, 11) == "diff --git " then cur = l; by[cur] = by[cur] or {}
    -- no file's part: a combined diff (unmerged), "* Unmerged path x", diff.submodule=log's summary
    elseif cur and ((b == 100 and l:sub(1, 5) == "diff ") or (b == 42 and l:sub(1, 16) == "* Unmerged path ") or (b == 83 and l:sub(1, 10) == "Submodule ")) then cur = nil end
    if cur then by[cur][#by[cur] + 1] = l end
  end)
  return by
end

-- raw halves of split_diff: no line table per diff line, so unchanged multi-MB diffs compare as one string
local function split_diff_raw(out)
  local by = {}
  out = out or ""
  local pos
  if out:sub(1, 11) == "diff --git " then
    pos = 1
  else
    local q = out:find("\ndiff --git ", 1, true)
    pos = q and q + 1 or nil
  end
  local nu = out:find("\n* Unmerged path ", 1, true)
  local ns_ = out:find("\nSubmodule ", 1, true)
  while pos do
    local line_end = out:find("\n", pos, true) or (#out + 1)
    local header = out:sub(pos, line_end - 1)
    while nu and nu < line_end do nu = out:find("\n* Unmerged path ", nu + 1, true) end
    while ns_ and ns_ < line_end do ns_ = out:find("\nSubmodule ", ns_ + 1, true) end
    local stop = out:find("\ndiff ", line_end, true)
    if nu and (not stop or nu < stop) then stop = nu end
    if ns_ and (not stop or ns_ < stop) then stop = ns_ end
    local raw = out:sub(pos, (stop or (#out + 1)) - 1)
    while raw:byte(-1) == 10 do raw = raw:sub(1, -2) end
    by[header] = by[header] and (by[header] .. "\n" .. raw) or raw
    local q = out:find("\ndiff --git ", stop or line_end, true)
    pos = q and q + 1 or nil
  end
  return by
end
-- ponytail: paths git would quote ("\ or control chars) can't be matched by header; they get their own diff
local function batchable(f) return not (f.path .. (f.orig or "")):find('[%c"\\]') end
local function diff_header(f) return "diff --git a/" .. (f.orig or f.path) .. " b/" .. f.path end

-- could a .gitattributes (binary, textconv, diff driver) change git's diff of this path?
-- S.attrs: info/attributes or the global attributes file exists (checked on open)
-- cache: dir -> has a .gitattributes, one table per refresh (500 files share a few dirs)
local function attrs_may_apply(path, cache)
  cache = cache or {}
  if S.attrs then return true end
  local dir = path:match("^(.*)/[^/]*$")
  while true do
    local k = dir or ""
    local has = cache[k]
    if has == nil then
      has = vim.uv.fs_stat(S.root .. "/" .. (dir and (dir .. "/") or "") .. ".gitattributes") ~= nil
      cache[k] = has
    end
    if has then return true end
    if not dir then return false end
    dir = dir:match("^(.*)/[^/]*$")
  end
end

-- `git diff --no-index /dev/null <untracked>` built in Lua: an untracked diff is the whole file as +
-- lines, and git can't batch --no-index, so zR over 500 untracked files was 500 spawns per refresh.
-- Same parsed result as git's (binary = a NUL in the first 8000 bytes, as git checks), minus the
-- index line (blob hashes; git apply doesn't need it). nil = let git do it: attributes in play,
-- a path git would quote, or not a regular file/symlink
local function untracked_read(f, full, st)
  local data, mode
  if st.type == "link" then
    data, mode = vim.uv.fs_readlink(full), "120000"
  elseif st.type == "file" then
    local fd = vim.uv.fs_open(full, "r", 438)
    if not fd then return { header = {}, hunks = {} } end
    if st.size == 0 then
      data = ""
    else
      local parts, off = {}, 0
      while off < st.size do
        local chunk = vim.uv.fs_read(fd, st.size - off, off)
        if not chunk or #chunk == 0 then break end
        parts[#parts + 1] = chunk
        off = off + #chunk
      end
      data = table.concat(parts)
    end
    vim.uv.fs_close(fd)
    mode = bit.band(st.mode, 64) ~= 0 and "100755" or "100644"
  end
  if not data then return nil end
  local header = { "diff --git a/" .. f.path .. " b/" .. f.path, "new file mode " .. mode }
  if data == "" then return { header = header, hunks = {} } end
  if data:sub(1, 8000):find("\0", 1, true) then
    header[#header + 1] = "Binary files /dev/null and b/" .. f.path .. " differ"
    return { header = header, hunks = {} }
  end
  -- git ends a name with a space in a tab, so patch tools know where it stops
  vim.list_extend(header, { "--- /dev/null", "+++ b/" .. f.path .. (f.path:find(" ", 1, true) and "\t" or "") })
  if data:find("\r", 1, true) then data = data:gsub("\r\n", "\n") end -- as vim.system's text mode does to git's output
  local nl = data:sub(-1) == "\n"
  local ls, n, i = {}, 0, 1
  local last = nl and #data - 1 or #data
  while i <= last + 1 do
    local j = data:find("\n", i, true)
    j = j and j <= last and j or nil
    n = n + 1
    ls[n] = "+" .. data:sub(i, j and j - 1 or last)
    if not j then break end
    i = j + 1
  end
  if not nl then ls[#ls + 1] = "\\ No newline at end of file" end
  local n = #ls - (nl and 0 or 1)
  return { header = header, hunks = { { header = n == 1 and "@@ -0,0 +1 @@" or ("@@ -0,0 +1," .. n .. " @@"), lines = ls, new = 1 } } }
end

local STAMP = setmetatable({}, { __mode = "k" }) -- diff -> the stat it was read at; weak: dies with the diff
local function untracked_diff(f, cache, old)
  local empty = { header = {}, hunks = {} }
  if f.path:sub(-1) == "/" then return empty end -- git errors on a directory: nothing to show either way
  if not batchable(f) or attrs_may_apply(f.path, cache) then return nil end
  local full = S.root .. "/" .. f.path
  local st = vim.uv.fs_lstat(full)
  if not st then return empty end -- gone since status ran
  -- unchanged on disk: the last result stands, no read/split/compare of the whole file every refresh
  local stamp = st.size .. ":" .. st.mtime.sec .. ":" .. st.mtime.nsec .. ":" .. st.ino .. ":" .. st.mode
  if old and STAMP[old] == stamp then return old end
  local d = untracked_read(f, full, st)
  if d then STAMP[d] = stamp end
  return d
end

local function fkey(f) return f.section .. ":" .. f.path end

local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
-- same parsed diff, line for line (conflict views are rebuilt every time: they're small)
local function same_diff(a, b)
  if a.conflicts or b.conflicts or #a.hunks ~= #b.hunks or not same_list(a.header, b.header) then return false end
  for i, h in ipairs(a.hunks) do
    if h.header ~= b.hunks[i].header or not same_list(h.lines, b.hunks[i].lines) then return false end
  end
  return true
end

-- new status vs the shown one: a file that is still there unchanged keeps its old object (render's
-- cached diff rows check it by identity), and an expanded file that left its section stops being
-- diffed (S.open only grew before: 50 untracked files staged were still read from disk every refresh)
local FILE_SECTIONS = { "untracked", "unstaged", "staged" }
local function settle(st)
  local prev, present = {}, {}
  local old = S.data and S.data.st
  if old then
    for _, sec in ipairs(FILE_SECTIONS) do for _, f in ipairs(old[sec]) do prev[fkey(f)] = f end end
  end
  for _, sec in ipairs(FILE_SECTIONS) do
    local list = st[sec]
    for i, f in ipairs(list) do
      local k = fkey(f)
      local o = prev[k]
      if o and o.mode == f.mode and o.orig == f.orig then list[i] = o end
      present[k] = true
    end
  end
  for k in pairs(S.open) do if not present[k] then S.open[k] = nil end end
end

local function key(it)
  if not it then return nil end
  if it.commit then return (it.section or "") .. "@" .. it.commit end
  if it.stash then return "stash:" .. it.stash end
  if it.conflict then return fkey(it.file) .. ":c" .. it.ci .. ":" .. it.cl end
  if it.header then return "#" .. it.section end
  return fkey(it.file) .. (it.hunk and (":" .. it.hi .. ":" .. it.idx) or "")
end

---------------------------------------------------------------- render

local LABEL = { M = "modified", A = "new file", D = "deleted", R = "renamed", C = "copied", T = "typechange", U = "unmerged" }
local MODE_HL = { M = "GitChangeModified", A = "GitChangeNewFile", D = "GitChangeDeleted",
  R = "GitChangeRenamed", C = "GitChangeCopied", T = "GitChangeUpdated", U = "GitChangeUnmerged" }
local BUSY = { { "rebase", "rebase" }, { "merge", "merge" }, { "pick", "cherry-pick" }, { "revert", "revert" }, { "bisect", "bisect" } }

-- one file's expanded diff as shareable line/highlight arrays plus one span per hunk. Rows in SH are
-- relative to the block start; spans resolve a row to its item lazily, so big diffs allocate no R row tables
local function diff_seg(hunks)
  local SL, SH, spans = {}, {}, {}
  local shn = 0
  for hi, h in ipairs(hunks or {}) do
    local off = #SL + 1
    spans[#spans + 1] = { off = off, len = 1 + #h.lines, hunk = h, hi = hi }
    local n = #SL
    if #h.header > 0 then
      SH[shn + 1], SH[shn + 2], SH[shn + 3] = n, #h.header, "GitHunkHeader"
      shn = shn + 3
    end
    SL[n + 1] = h.header
    for i, l in ipairs(h.lines) do
      -- hot loop (one per diff line): no chunk tables and no sub() string
      local c = l:byte(1)
      n = #SL
      local g = c == 43 and "GitDiffAdd" or c == 45 and "GitDiffDelete" or nil -- + -
      if g then
        SH[shn + 1], SH[shn + 2], SH[shn + 3] = n, #l, g
        shn = shn + 3
      end
      SL[n + 1] = l
    end
  end
  return SL, SH, spans
end

-- diff rows are missing from R until asked: __index maps a 1-based line through the file span, then the hunk span
local function attach_spans(R, file_spans, make_item)
  return setmetatable(R, { __index = function(_, lnum)
    if type(lnum) ~= "number" then return nil end
    local lo, hi, fs = 1, #file_spans, nil
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local x = file_spans[mid]
      if lnum < x.s then hi = mid - 1
      elseif lnum > x.e then lo = mid + 1
      else fs = x break end
    end
    if not fs then return nil end
    local rel = lnum - fs.s + 1
    local spans = fs.spans
    lo, hi = 1, #spans
    local hs
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local x = spans[mid]
      if rel < x.off then hi = mid - 1
      elseif rel >= x.off + x.len then lo = mid + 1
      else hs = x break end
    end
    return hs and make_item(fs, hs, rel - hs.off) or nil
  end })
end

-- write lines/highlights to buf, touching only the lines that changed (keeps the cursor and is cheap)
local function paint(buf, L, H)
  local clear_ns, set_extmark = vim.api.nvim_buf_clear_namespace, vim.api.nvim_buf_set_extmark
  local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local p, s = 0, 0
  while p < #old and p < #L and old[p + 1] == L[p + 1] do p = p + 1 end
  while s < #old - p and s < #L - p and old[#old - s] == L[#L - s] do s = s + 1 end
  if p == #old and p == #L then return end -- identical: keep lines and highlights
  local old_n, new_n, full = #old, #L, p == 0 and s == 0
  -- drop the replaced lines' marks first: deleted lines would pile them onto row p, and moving then
  -- clearing 50k of those (collapsing a big diff) was ~40ms
  if full then clear_ns(buf, ns, 0, -1) elseif p < old_n - s then clear_ns(buf, ns, p, old_n - s) end
  vim.bo[buf].modifiable = true
  local slice = full and L or (p + 1 > new_n - s and {} or vim.list_slice(L, p + 1, new_n - s))
  vim.api.nvim_buf_set_lines(buf, p, old_n - s, false, slice)
  vim.bo[buf].modifiable = false
  -- unchanged lines keep their extmarks (they move with the text); marks of replaced lines collapse
  -- onto row p, so the redone range always includes it
  local e = full and new_n or math.max(new_n - s, p + 1)
  if not full then clear_ns(buf, ns, p, e) end
  local opt = {}
  local first = 1
  if p > 0 then -- H is in row order: skip everything ending above the replaced range
    local lo, hi = 1, #H
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local hm = H[mid]
      if (hm.seg and hm[1] + hm.n or hm[1] + 1) > p then hi = mid - 1 else lo = mid + 1 end
    end
    first = lo
  end
  for x = first, #H do
    local h = H[x]
    if h[1] >= e then break end
    if h.seg then -- a cached diff block: flat marks, rows relative to h[1]; skipped whole when above p
      local base, seg = h[1], h.seg
      if base + h.n > p then
        local start = 1
        if p > base then
          local want = p - base
          local lo, a, b = #seg / 3 + 1, 1, #seg / 3
          while a <= b do
            local mid = math.floor((a + b) / 2)
            if seg[mid * 3 - 2] >= want then lo, b = mid, mid - 1 else a = mid + 1 end
          end
          start = lo <= #seg / 3 and (lo * 3 - 2) or (#seg + 1)
        end
        for i = start, #seg, 3 do
          local row = base + seg[i]
          if row >= e then break end
          opt.end_col, opt.hl_group = seg[i + 1], seg[i + 2]
          set_extmark(buf, ns, row, 0, opt)
        end
      end
    elseif h[1] >= p then
      opt.end_col, opt.hl_group = h[3], h[4]
      set_extmark(buf, ns, h[1], h[2], opt)
    end
  end
end

-- builder: add({ {text, hl?}, ... }, item)
local function builder()
  local L, H, R = {}, {}, {}
  local function add(chunks, item)
    local col = 0
    if #chunks == 1 then
      local c, row = chunks[1], #L
      L[row + 1] = c[1]
      if c[2] and #c[1] > 0 then H[#H + 1] = { row, 0, #c[1], c[2] } end
      R[row + 1] = item
      return
    end
    local t = {}
    for _, c in ipairs(chunks) do
      t[#t + 1] = c[1]
      if c[2] and #c[1] > 0 then H[#H + 1] = { #L, col, col + #c[1], c[2] } end
      col = col + #c[1]
    end
    L[#L + 1] = table.concat(t)
    R[#L] = item
  end
  return add, L, H, R
end

local function refchunks(refs_, ch, set)
  local rs, here = vim.split(refs_ or "", ", ", { plain = true }), {}
  for _, r in ipairs(rs) do here[r:match("^HEAD %-> (.+)$") or r] = true end
  for _, r in ipairs(rs) do
    local head, tag = r:match("^HEAD %-> (.+)$"), r:match("^tag: (.+)$")
    local rem, rest = r:match("^([^/]+)/(.+)$")
    local x
    if head then x = { head, "GitBranchHead" }
    elseif tag then x = { tag, "GitTagName" }
    elseif rem and set[rem] then
      -- origin/HEAD is noise; origin/X on the same commit as X says nothing new
      if rest ~= "HEAD" and not here[rest] then x = { r, "GitRemote" } end
    elseif r ~= "" and r ~= "HEAD" then x = { r, "GitBranch" } end
    if x then ch[#ch + 1], ch[#ch + 2] = x, { " " } end
  end
end

-- unix time -> "now", "20m", "3h", "2d", "5w", "4mo", "2y"
local AGE_UNITS = { { 31536000, "y" }, { 2592000, "mo" }, { 604800, "w" }, { 86400, "d" }, { 3600, "h" }, { 60, "m" } }
local function age(t, now)
  now = now or os.time()
  local d = now - (tonumber(t) or tonumber(tostring(t or ""):match("(%d+)}?$")) or now)
  for _, u in ipairs(AGE_UNITS) do
    if d >= u[1] then return math.floor(d / u[1]) .. u[2] end
  end
  return "now"
end

-- text columns of a window (minus number/sign columns)
local function text_width(win)
  local info = win and win ~= -1 and vim.fn.getwininfo(win)[1]
  return info and (info.width - info.textoff) or vim.o.columns
end

local function strwidth(s) return not s:find("[^\32-\126]") and #s or vim.api.nvim_strwidth(s) end
local function cut(str, n)
  if not str:find("[^\32-\126]") then
    if #str <= n then return str end
    return n < 1 and "" or (str:sub(1, n - 1) .. "…")
  end
  if vim.api.nvim_strwidth(str) <= n then return str end
  if n < 1 then return "" end
  local s = vim.fn.strcharpart(str, 0, n - 1)
  -- by display width, not chars: CJK/emoji take 2 cells
  while vim.api.nvim_strwidth(s) > n - 1 do s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1) end
  return s .. "…"
end

-- one meaning per color, everywhere: new work green, fix rose, integration teal, branch moves sakura,
-- destructive red, history rewrites amber, housekeeping grey (remotes stay lilac, tags gold)
local KIND_HL = { commit = "GitKindNew", amend = "GitKindNew", feat = "GitKindNew", fix = "GitKindFix",
  merge = "GitKindMerge", pull = "GitKindMerge", checkout = "GitKindBranch", reset = "GitKindReset",
  rebase = "GitKindRewrite", ["cherry-pick"] = "GitKindRewrite", revert = "GitKindRewrite" }
local CONVENTIONAL = { feat = true, fix = true, chore = true, docs = true, refactor = true, test = true,
  style = true, perf = true, ci = true, build = true, revert = true }
local function kind_hl(kind) return KIND_HL[(kind or ""):gsub("!$", "")] or "GitKindChore" end

-- subject -> kind + detail, nothing dropped: "fix(api)!: x" -> "fix!", "(api) x"; merges -> "a → b"
local function kind_of(subject)
  local a, b = subject:match("^Merge branch '(.-)' into (.+)$")
  if a then return "merge", a .. " → " .. b end
  a = subject:match("^Merge branch '(.-)'$") or subject:match("^Merge remote%-tracking branch '(.-)'")
  if a then return "merge", a end
  local n, from = subject:match("^Merge pull request (#%d+) from (%S+)")
  if n then
    local owner, branch = from:match("^([^/]+)/(.+)$")
    -- your own org is noise; a fork's owner says whose it is
    if owner and ((S.data or {}).owners or {})[owner:lower()] then from = branch end
    return "merge", n .. " " .. from
  end
  local t, scope, bang, rest = subject:match("^(%a+)(%b())(!?):%s+(.*)$")
  if not t then t, bang, rest = subject:match("^(%a+)(!?):%s+(.*)$") end
  if t and CONVENTIONAL[t:lower()] then return t:lower() .. bang, (scope and (scope .. " ") or "") .. rest end
  return nil, subject
end

-- header lines (Head/Merge/Push): same kind + detail look as the commit lists
local function subject_chunks(subject)
  if not subject or subject == "" then return {} end
  local kind, detail = kind_of(subject)
  if not kind then return { { " " .. subject } } end
  return { { " " }, { kind, kind_hl(kind) }, { " " .. detail } }
end

-- graph columns cycle GitGraph1..6 so parallel branches stay apart; author/age form one aligned column
-- and subjects are cut with … so a row never wraps in `avail` columns
local GRAPH_HL = { "GitGraph1", "GitGraph2", "GitGraph3", "GitGraph4", "GitGraph5", "GitGraph6" }
local function add_commits(add, list, set, k, avail)
  local rows, w, rw, kw, aw = {}, 0, 0, 0, 0
  local now = os.time()
  for _, c in ipairs(list) do
    if c.hash and not c.detail then c.kind, c.detail = kind_of(c.subject) end
    kw = math.max(kw, #(c.kind or ""))
    aw = math.max(aw, strwidth(c.author or ""))
  end
  aw = math.min(aw, 16) -- one long name must not widen every row and squeeze the subjects
  for i, c in ipairs(list) do
    local ch, g, pw = {}, c.graph or "", 0
    local function ap(x, hl)
      ch[#ch + 1] = { x, hl }
      pw = pw + strwidth(x)
    end
    local j = 1
    while j <= #g do
      local x = g:sub(j, j)
      if x == " " then
        local q = j
        while q <= #g and g:sub(q, q) == " " do q = q + 1 end
        ap(g:sub(j, q - 1))
        j = q
      else
        ap(x, x == "*" and "GitGraphCommit" or GRAPH_HL[math.floor((j - 1) / 2) % 6 + 1])
        j = j + 1
      end
    end
    local right
    if c.hash then
      ap(c.hash, "GitObjectId")
      ap(" ")
      if kw > 0 then
        ap(("%-" .. kw .. "s"):format(c.kind or ""), kind_hl(c.kind))
        ap(" ")
      end
      -- refs in git's own (…) so they never read as part of the message
      local rc = {}
      refchunks(c.refs, rc, set)
      if #rc > 0 then
        rc[#rc] = nil
        -- refs get at most a third of the row: long branch names never wrap it
        local left, kept = math.max(math.floor((avail or vim.o.columns) / 3), 12), {}
        for _, x in ipairs(rc) do
          if left <= 0 then break end
          local t = cut(x[1], left)
          kept[#kept + 1], left = { t, x[2] }, left - strwidth(t)
          if t ~= x[1] then break end
        end
        if kept[#kept][1] == " " then kept[#kept] = nil end
        rc = kept
        ap("(", "GitSubtleText")
        for _, x in ipairs(rc) do ap(x[1], x[2]) end
        ap(") ", "GitSubtleText")
      end
      right = (aw > 0 and (" "):rep(aw + 1) or "") .. "   "
      rw = math.max(rw, #right)
    end
    rows[i] = { ch, pw, right }
    if c.hash then w = math.max(w, pw + strwidth(c.detail)) end
  end
  w = math.min(w, 90, (avail or vim.o.columns) - rw - 2) -- column for author/age; never pushed off screen
  for i, c in ipairs(list) do
    local ch, pw = rows[i][1], rows[i][2]
    if c.hash then
      local subj = cut(c.detail, w - pw)
      ch[#ch + 1] = { subj }
      ch[#ch + 1] = { (" "):rep(math.max(w - pw - strwidth(subj), 0) + 2) }
      local a = cut(c.author or "", aw)
      if aw > 0 then
        ch[#ch + 1] = { a, "GitGraphAuthor" }
        ch[#ch + 1] = { (" "):rep(aw - strwidth(a) + 1) }
      end
      ch[#ch + 1] = { ("%3s"):format(age(c.date, now)), "GitSubtleText" }
    end
    add(ch, c.hash and { section = k, commit = c.hash } or nil)
  end
end

-- reflog: kind = what moved HEAD ("checkout: moving from a to b" -> checkout, "a → b")
local function reflog_rows(list)
  for _, c in ipairs(list) do
    if c.hash then
      local action, rest = c.subject:match("^([^:]+):%s*(.*)$")
      action, rest = action or "?", rest or c.subject
      local kind = action:match("^commit %((.-)%)") or action:match("^(%S+)")
      c.kind = kind == "initial" and "commit" or kind
      local from, to = rest:match("^moving from (.-) to (.+)$")
      if from then
        c.detail = from .. " → " .. to
      elseif c.kind == "merge" then
        c.detail = select(2, kind_of(rest))
      else
        c.detail = (rest:gsub("^moving to ", "→ "):gsub("^returning to refs/heads/", "→ "):gsub("^refs/heads/", ""))
      end
    end
  end
  return list
end

local function render(focus)
  local buf, d = S.buf, S.data
  if not (d and buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local win = vim.fn.bufwinid(buf)
  local cur = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  local want = focus or key((S.rows[buf] or {})[cur])
  local add, L, H, R = builder()
  local R_spans = {}
  local width = text_width(win)
  local st, sub = d.st, "GitSubtleText"

  local head = st.head == "(detached)" and (st.oid or ""):sub(1, 7) or (st.head or "?")
  local head_subject = st.oid == "(initial)" and "(no commits yet)" or (d.recent[1] or {}).subject -- --graph: first row is HEAD
  add(cat({ { "Head:     ", sub }, { head, "GitBranch" } }, subject_chunks(head_subject)))
  if st.upstream then add(cat({ { "Merge:    ", sub }, { st.upstream, "GitRemote" } }, subject_chunks(d.up_subject))) end
  if d.push then add(cat({ { "Push:     ", sub }, { d.push, "GitRemote" } }, subject_chunks(d.push_subject))) end
  -- PR status always shown for GitHub-ish repos; "loading…" until the first gh answer is cached
  if not S.pr then
    local f = io.open(PR_CACHE)
    local ok, t = pcall(vim.json.decode, f and f:read("*a") or "")
    if f then f:close() end
    S.pr = ok and type(t) == "table" and t or {}
  end
  local pr = not C.simple and (S.pr[S.root .. "\0" .. head] or (HAS_GH and #d.remotes > 0 and { { { "loading…", "Comment" } } }))
  for i, chunks in ipairs(pr or {}) do add(cat({ { i == 1 and "PR:       " or "          ", sub } }, chunks)) end
  for _, x in ipairs(d.radar or {}) do
    local fs = x.files
    local names = table.concat(vim.list_slice(fs, 1, 3), ", ") .. (#fs > 3 and (" +" .. (#fs - 3)) or "")
    add({ { "Conflict: ", sub }, { x.target, "GitRemote" }, { (" · %d file%s · "):format(#fs, #fs > 1 and "s" or ""), sub },
      { names, "GitChangeUnmerged" } })
  end
  local busy, s = {}, state()
  for _, b in ipairs(BUSY) do if s[b[1]] then busy[#busy + 1] = b[2] end end
  if #busy > 0 then add({ { "State:    ", sub }, { table.concat(busy, ", ") .. " in progress", "GitChangeUnmerged" } }) end
  if s.rebase then
    local function read(f)
      for _, dir in ipairs({ "rebase-merge", "rebase-apply" }) do
        local h = io.open(S.gitdir .. "/" .. dir .. "/" .. f)
        if h then
          local v = vim.trim(h:read("*a"))
          h:close()
          return v
        end
      end
    end
    add({ { "Rebasing: ", sub }, { (read("head-name") or "?"):gsub("^refs/heads/", ""), "GitBranch" },
      { " onto " }, { (read("onto") or "?"):sub(1, 7), "GitObjectId" } })
  end
  add({ { "" } })

  local function section(k, title, list, body, n)
    n = n or #list
    if n == 0 then return end
    add({ { title .. " (" .. n .. ")", "GitSectionHeader" } }, { header = true, section = k })
    if not S.fold[k] then body(list, k) end
    add({ { "" } })
  end
  local function file(f)
    local k = fkey(f)
    local chunks = f.section == "untracked" and { { f.path } }
      or { { ("%-11s"):format(LABEL[f.mode] or f.mode), MODE_HL[f.mode] }, { f.orig and (f.orig .. " -> " .. f.path) or f.path } }
    add(chunks, { section = f.section, file = f })
    local diff = S.open[k] and S.diffs[k]
    if not diff then return end
    S.open[k] = f
    if diff.conflicts then -- one compact block per conflict: where it is, then each side
      local cs = diff.conflicts
      add({ { "  " }, { #cs == 0 and "no markers left · s marks it resolved" or (#cs .. " conflict" .. (#cs > 1 and "s" or "") .. " · e merges in nvim"), "GitSubtleText" } },
        { section = f.section, file = f })
      for ci, c in ipairs(cs) do
        local function row(cl, chunks) add(chunks, { section = f.section, file = f, conflict = c, ci = ci, cl = cl }) end
        row(0, { { "  conflict " .. ci, "GitChangeUnmerged" }, { " · line " .. c.line, "GitSubtleText" } })
        local cl = 0
        for _, side in ipairs({ { "ours  ", c.ours, "GitOurs" }, { "base  ", c.base, "GitBase" }, { "theirs", c.theirs, "GitTheirs" } }) do
          local ls = side[2]
          if side[1] ~= "base  " or #ls > 0 then -- base only exists with diff3/zdiff3
            for i = 1, math.min(#ls, 3) do
              cl = cl + 1
              row(cl, { { i == 1 and ("    " .. side[1] .. "  ") or "            ", side[3] }, { ls[i], side[3] ~= "GitBase" and side[3] or "GitSubtleText" } })
            end
            if #ls == 0 then cl = cl + 1; row(cl, { { "    " .. side[1] .. "  ", side[3] }, { "(empty)", "GitSubtleText" } }) end
            if #ls > 3 then cl = cl + 1; row(cl, { { "            " }, { "… +" .. (#ls - 3) .. " lines", "GitSubtleText" } }) end
          end
        end
      end
      return
    end
    -- a file's diff rows are built once and kept on the diff: refresh hands back the same diff and file
    -- objects while neither changed, so a refresh with 16k expanded lines copies them instead of
    -- allocating two tables per line again
    local seg = diff.seg
    if not (seg and seg.f == f) then
      local SL, SH, spans = diff_seg(diff.hunks)
      seg = { f = f, L = SL, H = SH, spans = spans }
      diff.seg = seg
    end
    local n = #L
    for i, l in ipairs(seg.L) do L[n + i] = l end
    if #seg.L > 0 then R_spans[#R_spans + 1] = { s = n + 1, e = n + #seg.L, f = f, diff = diff, spans = seg.spans } end
    if #seg.H > 0 then H[#H + 1] = { n, seg = seg.H, n = #seg.L } end
  end

  local function files(list) for _, f in ipairs(list) do file(f) end end
  local function commits(list, k) add_commits(add, list, d.remoteset, k, width) end
  section("untracked", "Untracked files", st.untracked, files)
  section("unstaged", "Unstaged changes", st.unstaged, files)
  section("staged", "Staged changes", st.staged, files)
  section("unpulled", "Unpulled from " .. (st.upstream or ""), d.unpulled, commits)
  section("unpushed", "Unmerged into " .. (st.upstream or ""), d.unpushed, commits)
  section("stashes", "Stashes", d.stashes, function(list)
    for _, z in ipairs(list) do add({ { z.ref, "GitObjectId" }, { " " .. z.subject } }, { section = "stashes", stash = z.ref }) end
  end)
  section("recent", "Recent commits", d.recent, commits, commit_count(d.recent))

  if #R_spans > 0 then
    attach_spans(R, R_spans, function(fs, hs, idx)
      return { section = fs.f.section, file = fs.f, diff = fs.diff, hunk = hs.hunk, hi = hs.hi, idx = idx }
    end)
  end
  paint(buf, L, H)
  S.rows[buf] = R
  if win ~= -1 then
    local row = math.min(cur, #L)
    if want and key(R[row]) ~= want then -- usually the item hasn't moved: skip a key() per row
      for r, it in pairs(R) do if key(it) == want then row = r break end end
      if key(R[row]) ~= want and #R_spans > 0 then
        local fk, hi, idx = want:match("^(.*):(%d+):(%d+)$")
        if fk then
          hi, idx = tonumber(hi), tonumber(idx)
          for _, fs in ipairs(R_spans) do
            if fkey(fs.f) == fk then
              local hs = fs.spans[hi]
              if hs and idx < hs.len then row = fs.s + hs.off - 1 + idx end
              break
            end
          end
        end
      end
    end
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

---------------------------------------------------------------- pull requests (gh)

local PR_STATE = { OPEN = "PrOpen", MERGED = "PrMerged", CLOSED = "PrClosed", DRAFT = "PrDraft" }
local function str(v, fb) return (v == nil or v == vim.NIL) and (fb or "") or tostring(v) end
local function pr_state(pr) return pr.isDraft == true and "DRAFT" or str(pr.state, "?") end
local function gh(args, opts, cb) git(nil, { raw = cat({ "gh" }, args), log = opts.log }, cb) end
local function json(r)
  local ok, v = pcall(vim.json.decode, r.stdout or "")
  return ok and type(v) == "table" and v or nil
end

local function ci_summary(rollup)
  local fail, pending = 0, 0
  for _, c in ipairs(type(rollup) == "table" and rollup or {}) do
    if c.conclusion == "FAILURE" or c.conclusion == "TIMED_OUT" or c.conclusion == "CANCELLED"
      or c.state == "FAILURE" or c.state == "ERROR" then
      fail = fail + 1
    elseif c.status ~= "COMPLETED" and c.state ~= "SUCCESS" then
      pending = pending + 1
    end
  end
  if fail > 0 then return fail .. " failing", "PrClosed" end
  if pending > 0 then return pending .. " running", "PrWarn" end
  return "passing", "PrOpen"
end

-- integration base branch: origin/develop, origin/main, else origin/HEAD
local function find_base(cb)
  local candidates = C.base_branches
  local function try(i)
    if i > #candidates then
      return git({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, nil, function(r)
        local b = vim.trim(r.stdout or "")
        cb((r.code == 0 and b ~= "") and b or "origin/develop")
      end)
    end
    git({ "rev-parse", "--verify", "--quiet", candidates[i] }, nil, function(r)
      if r.code == 0 then cb(candidates[i]) else try(i + 1) end
    end)
  end
  try(1)
end

-- PR status under Push: state + title, then mergeable · review · CI (cached per branch, refetched on each refresh)
local function pr_line(branch)
  if not branch or branch == "(detached)" or not HAS_GH then return end
  local root, k = S.root, S.root .. "\0" .. branch
  if vim.uv.now() - (S.pr_at[k] or -math.huge) < PR_TTL then return end
  S.pr_at[k] = vim.uv.now() -- set before the call: refreshes while gh is in flight don't start another
  local function show(...)
    S.pr[k] = { ... }
    local f = io.open(PR_CACHE, "w")
    if f then f:write(vim.json.encode(S.pr)) f:close() end
    render()
  end
  gh({ "pr", "view", "--json", "number,state,isDraft,title,mergeable,reviewDecision,statusCheckRollup" }, {}, function(r)
    local pr = json(r)
    if pr and pr.number then
      local s = pr_state(pr)
      local ci, ci_hl = ci_summary(pr.statusCheckRollup)
      local mergeable = str(pr.mergeable, "?")
      return show(
        { { "#" .. str(pr.number, "?") .. " ", "Comment" }, { s, PR_STATE[s] or "Normal" }, { "  " .. str(pr.title) } },
        { { mergeable:lower(), mergeable == "CONFLICTING" and "PrClosed" or "Comment" },
          { " · review " .. (str(pr.reviewDecision) == "" and "none" or str(pr.reviewDecision):lower()), pr.reviewDecision == "APPROVED" and "PrOpen" or "Comment" },
          { " · CI ", "Comment" }, { ci, ci_hl } })
    end
    find_base(function(base)
      git({ "merge-base", "--is-ancestor", "HEAD", base }, nil, function(m)
        local merged = m.code == 0
        show({ { "no PR · ", "Comment" }, { (merged and "merged into " or "not merged into ") .. base, merged and "PrMerged" or "PrWarn" } })
      end)
    end)
  end)
end

-- conflict radar: would merging the upstream / base branch into HEAD conflict, and where?
-- merge-tree does the whole merge in memory (git 2.38+): no worktree, index or refs touched.
-- out = list of conflicted paths, or nil (clean, missing ref, old git)
local function parse_merge_tree(r)
  local l = lines(r.stdout)
  -- exit 1 is also "not something we can merge"; only a conflict prints the tree oid first
  if r.code == 1 and (l[1] or ""):match("^%x+$") and #l > 1 then return vim.list_slice(l, 2) end
end

-- ponytail: checks a merge, not a replayed rebase (a rebase can conflict per commit where the merge
-- doesn't), and ignores uncommitted changes; a per-commit replay would be the upgrade
local function radar(d)
  local st, seq, out, pending = d.st, S.seq, {}, 1
  if not st.oid or st.oid == "(initial)" then return end
  local function done()
    pending = pending - 1
    if pending > 0 or seq ~= S.seq then return end
    table.sort(out, function(a, b) return a.target < b.target end)
    if vim.deep_equal(out, d.radar or {}) then return end -- the common case: no extra render
    d.radar = out
    render()
  end
  -- a merge depends only on the two commits: while neither moved (oids come with the refresh batch),
  -- the last answer stands and no merge-tree runs
  local function check(target)
    local key = d.oids[target] and (st.oid .. " " .. d.oids[target])
    local hit = key and S.radar_cache[target]
    if hit and hit.key == key then
      if hit.files then out[#out + 1] = { target = target, files = hit.files } end
      return
    end
    pending = pending + 1
    git({ "merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", target }, nil, function(r)
      local fs = parse_merge_tree(r)
      if key then S.radar_cache[target] = { key = key, files = fs } end
      if fs then out[#out + 1] = { target = target, files = fs } end
      done()
    end)
  end
  -- only behind or only ahead is a fast-forward: nothing to conflict
  if st.upstream and #d.unpulled > 0 and #d.unpushed > 0 then check(st.upstream) end
  if #d.remotes == 0 then return done() end
  local function base(b)
    S.base = b
    if b ~= st.upstream then check(b) end
    done()
  end
  if S.base then base(S.base) else find_base(base) end
end

local PR = {}
local show
local move_hunk -- defined with absorb; the commit view maps it

function PR.status()
  local spin = progress("PR", "gh pr view")
  gh({ "pr", "view", "--json", "number,state,title,isDraft,mergeable,reviewDecision,statusCheckRollup,headRefName" }, {}, function(r)
    local pr = json(r)
    if r.code == 127 then return fail("pr", r, spin) end
    spin(pr and pr.number and "done" or "no PR for this branch")
    if not (pr and pr.number) then return end
    local s = pr_state(pr)
    local ci, ci_hl = ci_summary(pr.statusCheckRollup)
    vim.api.nvim_echo({
      { "#" .. str(pr.number, "?") .. " ", "Comment" }, { s, PR_STATE[s] or "Normal" },
      { "  " .. str(pr.title) }, { "  " .. str(pr.headRefName), "PrBranch" },
      { "\n" .. str(pr.mergeable, "?") .. " · review " .. str(pr.reviewDecision, "none") .. " · CI ", "Comment" },
      { ci, ci_hl },
    }, true, {})
  end)
end

local function pr_pick(prompt, cb)
  local spin = progress("PRs", "gh pr list")
  gh({ "pr", "list", "--limit", "30", "--json", "number,title,author,headRefName,isDraft,state,reviewDecision,statusCheckRollup,url" }, {}, function(r)
    local prs = json(r)
    if r.code ~= 0 then return fail("pr", r, spin) end
    spin(prs and #prs > 0 and (#prs .. " PRs") or "no PRs")
    if not prs or #prs == 0 then return end
    require("petal.select").select(prs, { prompt = prompt, height = C.height, format_item = function(pr)
      local s = pr_state(pr)
      local ci, ci_hl = ci_summary(pr.statusCheckRollup)
      local login = type(pr.author) == "table" and str(pr.author.login, "?") or "?"
      return {
        { "#" .. str(pr.number, "?") .. " ", "Comment" }, { s, PR_STATE[s] or "Normal" },
        { "  " .. str(pr.title) }, { "  " .. str(pr.headRefName), "PrBranch" }, { "  @" .. login, "Comment" },
        { " · " .. str(pr.reviewDecision, "no review"), "Comment" }, { " · " .. ci, ci_hl },
      }
    end }, function(pr) if pr then cb(pr) end end)
  end)
end

function PR.list()
  pr_pick("PRs", function(pr)
    vim.fn.setreg("+", str(pr.url))
    notify("pr: url copied\n" .. str(pr.url))
  end)
end

function PR.checkout()
  pr_pick("Checkout PR", function(pr)
    local n = str(pr.number)
    act(nil, { raw = { "gh", "pr", "checkout", n }, msg = "Checking out #" .. n, after = function() S.pr_at = {} end })
  end)
end

local CHECK_HL = { pass = "PrOpen", fail = "PrClosed", cancel = "PrClosed", pending = "PrWarn", skipping = "Comment" }

function PR.checks()
  local spin = progress("PR", "gh pr checks")
  gh({ "pr", "checks", "--json", "name,workflow,bucket,link" }, {}, function(r)
    local cs = json(r) -- exit code is non-zero whenever a check fails or is pending
    if not cs then return fail("pr", r, spin) end
    spin(#cs .. " checks")
    if #cs == 0 then return end
    local function rank(c) return c.bucket == "fail" and 0 or c.bucket == "pending" and 1 or 2 end
    table.sort(cs, function(a, b) return rank(a) < rank(b) end)
    require("petal.select").select(cs, { prompt = "Checks", height = C.height, format_item = function(c)
      local wf = str(c.workflow)
      return { { ("%-8s"):format(str(c.bucket, "?")), CHECK_HL[c.bucket] or "Comment" },
        { "  " .. (wf ~= "" and (wf .. " / ") or "") .. str(c.name) } }
    end }, function(c)
      if not c then return end
      local link = str(c.link)
      local job, run = link:match("/job/(%d+)"), link:match("/actions/runs/(%d+)")
      if c.bucket ~= "fail" or not (job or run) then
        if link ~= "" then vim.ui.open(link) end
        return
      end
      local lspin = progress("CI", "gh run view --log-failed")
      gh(cat({ "run", "view" }, job and { "--job", job } or { run }, { "--log-failed" }), {}, function(lr)
        if lr.code ~= 0 then return fail("ci", lr, lspin) end
        if vim.trim(lr.stdout or "") == "" then
          lspin("no log yet, opening the page")
          return vim.ui.open(link)
        end
        lspin()
        scratch("ci " .. str(c.name), "", lr.stdout)
      end)
    end)
  end)
end

local NO_REVIEWER = "(no reviewer)"

-- reviewers come from C.reviewers via a multi-select picker; picking only NO_REVIEWER = PR without one
local function ask_reviewers(cb)
  if #C.reviewers == 0 then return cb({}) end
  require("petal.select").select(cat({ NO_REVIEWER }, C.reviewers),
    { prompt = "Reviewers (<Tab> marks, <CR> confirms)", height = C.height, multi = true }, function(picked)
      if not picked then return end
      cb(vim.tbl_filter(function(x) return x ~= NO_REVIEWER end, picked))
    end)
end

function PR.create()
  ask_reviewers(function(reviewers)
    local spin = progress("PR", "gh pr create")
    gh(cat({ "pr", "create", "--fill" }, #reviewers > 0 and { "--reviewer", table.concat(reviewers, ",") } or {}), { log = true }, function(r)
      S.pr_at = {}
      -- gh fails with "a pull request for branch ... already exists:\n<url>"
      local existing = r.code ~= 0 and (r.stderr or ""):match("already exists:%s*(https://%S+)")
      if r.code ~= 0 and not existing then return fail("pr", r, spin) end
      local url = existing or vim.trim(r.stdout)
      vim.fn.setreg("+", url)
      spin((existing and "PR already exists" or "PR created") .. ", URL copied: " .. url)
      M.refresh()
    end)
  end)
end

function PR.open()
  local spin = progress("PR", "gh pr view")
  gh({ "pr", "view", "--json", "url", "--jq", ".url" }, {}, function(r)
    if r.code ~= 0 then return fail("pr", r, spin) end
    local url = vim.trim(r.stdout)
    vim.fn.setreg("+", url)
    vim.ui.open(url)
    spin("URL copied: " .. url)
  end)
end

function PR.diff()
  show("pull request", { diff = { "gh", "pr", "diff", "--color=never" }, msg = "PR" })
end

function PR.close()
  if not confirm("Close the PR for this branch?") then return end
  local spin = progress("PR", "gh pr close")
  gh({ "pr", "close" }, { log = true }, function(r)
    S.pr_at = {}
    if r.code ~= 0 then return fail("pr", r, spin) end
    spin("PR closed")
    M.refresh()
  end)
end

---------------------------------------------------------------- refresh

-- --graph (Recent, log views) forces a topo walk of ALL history unless a commit-graph exists:
-- 200k commits, 670ms vs 5ms on every refresh. Fresh clones have none until gc runs.
-- Objects live in the common dir: a linked worktree's gitdir points there through its commondir file
local function has_commit_graph()
  local common = S.commondir
  if not common then
    local h
    common, h = S.gitdir, io.open(S.gitdir .. "/commondir")
    if h then
      local c = vim.trim(h:read("*a"))
      h:close()
      common = c:sub(1, 1) == "/" and c or (S.gitdir .. "/" .. c)
    end
  end
  local info = common .. "/objects/info/"
  return vim.uv.fs_stat(info .. "commit-graph") ~= nil or vim.uv.fs_stat(info .. "commit-graphs/commit-graph-chain") ~= nil
end

local RAW = setmetatable({}, { __mode = "k" }) -- parsed diff -> the exact raw diff it came from

-- `git diff -- <paths>` matches every path against every index entry: 300 open files of a 30k-file
-- repo took 121ms, the whole diff 40ms. With most of a section open (zR) diff all of it and keep the
-- open files' parts. --no-renames, and only when status paired nothing in the section: then each
-- file's header is its own path, as the lookup expects, whatever diff.renames says
local WHOLE_MIN = 8
local function whole_section(sec, n)
  local list = S.data and S.data.st[sec]
  if not list or n < WHOLE_MIN or 2 * n < #list then return false end
  for _, f in ipairs(list) do if f.orig or f.mode == "R" or f.mode == "C" then return false end end
  return true
end

function M.refresh()
  local buf = S.buf
  if not (S.root and buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local root = S.root
  S.seq, S.refreshed = S.seq + 1, vim.uv.hrtime()
  local seq, d, diffs, steps = S.seq, { oids = {} }, {}, {}
  local function step(args, fn) steps[#steps + 1] = { args, fn } end
  local function ok(r) return r.code == 0 and vim.trim(r.stdout) or nil end
  step({ "--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z" }, function(r) d.st = parse_status(r.stdout) end)
  step({ "log", "--graph", "-n", tostring(C.recent), "--format=" .. LOGFMT }, function(r) d.recent = parse_log(r.stdout) end)
  step({ "log", "-n", "256", "--left-right", "--format=%m" .. LOGFMT, "HEAD...@{upstream}" }, function(r)
    d.unpulled, d.unpushed = {}, {}
    for _, c in ipairs(parse_log(r.stdout, true)) do table.insert(c.mark == ">" and d.unpulled or d.unpushed, c) end
  end)
  step({ "show", "-s", "--format=%H%x1f%s", "@{upstream}" }, function(r)
    local oid, subject = (ok(r) or ""):match("^(%x+)\31(.*)$")
    d.up_subject = subject
    if oid and d.st.upstream then d.oids[d.st.upstream] = oid end -- for the radar's cache
  end)
  local base = not C.simple and S.base
  if base then
    step({ "rev-parse", "--verify", "-q", base .. "^{commit}" }, function(r) d.oids[base] = ok(r) end)
  end
  step({ "rev-parse", "--abbrev-ref", "@{push}" }, function(r) d.push = ok(r) end)
  step({ "show", "-s", "--format=%s", "@{push}" }, function(r) d.push_subject = ok(r) end)
  local stash_step, stash_stamp = true, nil
  if not S.reftable and S.commondir then
    local logst = vim.uv.fs_stat(S.commondir .. "/logs/refs/stash")
    if not logst then
      d.stashes, stash_step = {}, false
    else
      local refst = vim.uv.fs_stat(S.commondir .. "/refs/stash") or vim.uv.fs_stat(S.commondir .. "/packed-refs")
      local function stamp(x) return x and (x.size .. ":" .. x.mtime.sec .. ":" .. x.mtime.nsec .. ":" .. x.ino) or "-" end
      stash_stamp = stamp(logst) .. "/" .. stamp(refst)
      if S.stash_cache and S.stash_cache.stamp == stash_stamp then
        d.stashes, stash_step = S.stash_cache.list, false
      end
    end
  end
  if stash_step then
    step({ "stash", "list", "--format=%gd%x1f%gs" }, function(r)
      d.stashes = {}
      for _, l in ipairs(lines(r.stdout)) do
        local ref, subj = l:match("^(.-)\31(.*)$")
        if ref then d.stashes[#d.stashes + 1] = { ref = ref, subject = subj } end
      end
      if stash_stamp then S.stash_cache = { stamp = stash_stamp, list = d.stashes } end
    end)
  end
  step({ "remote", "-v" }, function(r)
    d.remotes, d.remoteset, d.owners = {}, {}, {}
    for _, l in ipairs(lines(r.stdout)) do
      local name, url = l:match("^(%S+)%s+(%S+)")
      if name and not d.remoteset[name] then d.remotes[#d.remotes + 1], d.remoteset[name] = name, true end
      local owner = url and url:gsub("/+$", ""):match("[:/]([^/:]+)/[^/:]+$")
      if owner then d.owners[owner:lower()] = true end
    end
  end)
  if S.attrs_check then
    local root, gitdir = S.root, S.gitdir
    step({ "config", "--path", "--get", "core.attributesFile" }, function(r)
      if S.root ~= root then return end
      local af = vim.trim(r.stdout or "")
      if af == "" then af = (vim.env.XDG_CONFIG_HOME or (vim.uv.os_homedir() .. "/.config")) .. "/git/attributes" end
      S.attrs = vim.uv.fs_stat(gitdir .. "/info/attributes") ~= nil or vim.uv.fs_stat(af) ~= nil
      S.attrs_check = nil
    end)
  end
  -- one diff per section, not one process per open file: zR on 200 files was 200 spawns every refresh.
  -- a diff that didn't change keeps its old object, and with it the rows render built for it
  local function keep(k, new)
    local old = S.diffs[k]
    return old and (old == new or same_diff(old, new)) and old or new
  end
  local batch, attr_cache = { unstaged = {}, staged = {} }, {}
  for k, f in pairs(S.open) do
    local native = f.section == "untracked" and untracked_diff(f, attr_cache, S.diffs[k])
    if f.mode == "U" then
      diffs[k] = { conflicts = parse_conflicts(S.root .. "/" .. f.path) }
    elseif native then
      diffs[k] = keep(k, native)
    elseif batch[f.section] and batchable(f) then
      table.insert(batch[f.section], { k, f })
    else
      step(diff_args(f), function(r)
        local old = S.diffs[k]
        if old and RAW[old] == r.stdout then
          diffs[k] = old
        else
          local parsed = keep(k, parse_diff(r.stdout))
          RAW[parsed] = r.stdout
          diffs[k] = parsed
        end
      end)
    end
  end
  for sec, fs in pairs(batch) do
    if #fs > 0 then
      local whole = whole_section(sec, #fs)
      local args = cat({ "-c", "core.quotePath=false", "diff", "--src-prefix=a/", "--dst-prefix=b/" },
        sec == "staged" and { "--cached" } or {}, whole and { "--no-renames" } or { "--" })
      if not whole then for _, e in ipairs(fs) do vim.list_extend(args, { e[2].path, e[2].orig }) end end
      local keys = {}
      for i, e in ipairs(fs) do keys[i] = e[1] end
      local sig = table.concat(keys, "\0")
      step(args, function(r)
        local prev = S.raw_diff[sec]
        if prev and prev.raw == r.stdout and prev.sig == sig then
          local fresh = true
          for _, e in ipairs(fs) do
            local old = S.diffs[e[1]]
            if not (old and RAW[old]) then fresh = false break end
          end
          if fresh then
            for _, e in ipairs(fs) do diffs[e[1]] = S.diffs[e[1]] end
            return
          end
        end
        S.raw_diff[sec] = { raw = r.stdout, sig = sig }
        local by = split_diff_raw(r.stdout)
        for _, e in ipairs(fs) do
          local raw = by[diff_header(e[2])] or ""
          local old = S.diffs[e[1]]
          if old and RAW[old] == raw then
            diffs[e[1]] = old
          else
            local parsed = keep(e[1], parse_diff(raw))
            RAW[parsed] = raw
            diffs[e[1]] = parsed
          end
        end
      end)
    end
  end
  git_batch(vim.tbl_map(function(s) return s[1] end, steps), function(res)
    -- a newer refresh is on its way: drop this one, unless nothing is shown yet (first open: the
    -- refresh after a quick fetch, or any other, would make the first paint wait for its batch)
    if root ~= S.root or (seq ~= S.seq and S.data) then return end
    for i, s in ipairs(steps) do s[2](res[i]) end
    if res[1].code == 0 then settle(d.st) end
    d.radar = S.data and S.data.radar -- shown until the new check answers: no flicker
    S.data, S.diffs = d, diffs
    render()
    if seq ~= S.seq then return end -- shown early: the newer refresh runs PR line and radar
    if C.simple then return end
    if #d.remotes > 0 then pr_line(d.st.head) end
    radar(d)
  end)
end

---------------------------------------------------------------- applying changes

-- items under the cursor, or under the visual selection (which is ended)
local function context()
  local rows = S.rows[vim.api.nvim_get_current_buf()] or {}
  local s, e = vim.fn.line("."), vim.fn.line(".")
  local visual = vim.fn.mode():match("^[vV\22]") ~= nil
  if visual then
    s = vim.fn.line("v")
    if s > e then s, e = e, s end
    vim.api.nvim_feedkeys(vim.keycode("<esc>"), "nx", false)
  end
  local ctx = { items = {}, commits = {}, visual = visual }
  for r = s, e do
    local it = rows[r]
    if it then
      ctx.items[#ctx.items + 1] = it
      if it.commit and it.commit ~= ctx.commits[#ctx.commits] then ctx.commits[#ctx.commits + 1] = it.commit end
    end
  end
  ctx.item = visual and ctx.items[1] or rows[s]
  ctx.commit = ctx.commits[1]
  return ctx
end

-- files in the selection; a section header means every file in it
local function files(ctx)
  local out, seen = {}, {}
  for _, it in ipairs(ctx.items) do
    local list = it.header and S.data.st[it.section] or (it.file and not it.hunk and { it.file }) or {}
    for _, f in ipairs(list) do
      if not seen[fkey(f)] then seen[fkey(f)], out[#out + 1] = true, f end
    end
  end
  return out
end
local function paths(fs, pred)
  local t = {}
  for _, f in ipairs(fs) do
    if not pred or pred(f) then
      t[#t + 1] = f.path
      if f.orig then t[#t + 1] = f.orig end
    end
  end
  return t
end

-- patch for the hunk under the cursor; a visual selection inside it keeps only the selected lines.
-- reverse: the patch will be applied with -R (unstage/discard)
local function patch(ctx, reverse)
  local it, sel = ctx.item, nil
  if ctx.visual then
    sel = {}
    for _, x in ipairs(ctx.items) do if x.hunk == it.hunk and x.idx > 0 then sel[x.idx] = true end end
    if not next(sel) then sel = nil end
  end
  local out, dropped = vim.list_extend({}, it.diff.header), false
  out[#out + 1] = it.hunk.header
  for i, l in ipairs(it.hunk.lines) do
    local c = l:sub(1, 1)
    if not sel or sel[i] or c == " " then
      out[#out + 1], dropped = l, false
    elseif c == "\\" then
      if not dropped then out[#out + 1] = l end
    elseif (c == "+") == reverse then
      out[#out + 1], dropped = " " .. l:sub(2), false -- unselected: keep as context
    else
      dropped = true
    end
  end
  return table.concat(out, "\n") .. "\n"
end
local function apply(ctx, flags, reverse)
  act(cat({ "apply", "--recount" }, flags, { "-" }), { stdin = patch(ctx, reverse) })
end

local function stage(ctx)
  local it = ctx.item
  if not it or it.section == "staged" or it.commit then return end
  if it.hunk then return apply(ctx, { "--cached" }, false) end
  if it.header and it.section == "unstaged" then return act({ "add", "-u" }) end
  local fs = files(ctx)
  if #fs > 0 then act(cat({ "add", "--" }, paths(fs, function(f) return f.section ~= "staged" end))) end
end

local function unstage_all()
  if S.data and S.data.st.oid == "(initial)" then return act({ "rm", "-r", "-q", "--cached", "--", "." }) end
  act({ "reset", "-q" })
end

local function unstage(ctx)
  local it = ctx.item
  if not it or it.section ~= "staged" then return end
  if it.hunk then return apply(ctx, { "--cached", "--reverse" }, true) end
  if it.header then return unstage_all() end
  local ps = paths(files(ctx), function(f) return f.section == "staged" end)
  if #ps == 0 then return end
  if S.data.st.oid == "(initial)" then return act(cat({ "rm", "-q", "--cached", "--" }, ps)) end
  act(cat({ "restore", "--staged", "--" }, ps))
end

-- nothing is lost: tracked changes go to a backup stash first, untracked files move to .git/petal-trash/
local function discard(ctx)
  local it = ctx.item
  if not it or it.commit then return end
  if it.stash then
    if confirm("Drop " .. it.stash .. "?\n" .. it.stash) then act({ "stash", "drop", it.stash }) end
    return
  end
  if it.hunk and it.section ~= "untracked" then
    if not confirm("Discard hunk in " .. it.file.path .. "?") then return end
    return backup(function() apply(ctx, it.section == "staged" and { "--reverse", "--index" } or { "--reverse" }, true) end)
  end
  local fs = files(ctx)
  if #fs == 0 or not confirm(("Discard %d file(s)?\n%s"):format(#fs, describe(paths(fs)))) then return end
  local trash = S.gitdir .. "/petal-trash/" .. os.date("%Y%m%d-%H%M%S")
  local moved = 0
  for _, f in ipairs(fs) do
    if f.section == "untracked" then
      local dst = trash .. "/" .. f.path:gsub("/$", "")
      vim.fn.mkdir(vim.fs.dirname(dst), "p")
      local ok, err = os.rename(S.root .. "/" .. f.path:gsub("/$", ""), dst)
      if ok then moved = moved + 1 else notify("discard: kept " .. f.path .. "\n" .. tostring(err), vim.log.levels.ERROR) end
    end
  end
  if moved > 0 then notify(("discard: moved %d untracked to %s"):format(moved, vim.fn.fnamemodify(trash, ":~:."))) end
  local tracked = vim.tbl_filter(function(f) return f.section ~= "untracked" end, fs)
  if #tracked == 0 then return M.refresh() end
  backup(function()
    local function run(args, pred)
      local ps = paths(tracked, pred)
      if #ps > 0 then act(cat(args, ps)) end
    end
    run({ "restore", "--" }, function(f) return f.section == "unstaged" end)
    run({ "rm", "-f", "-q", "--" }, function(f) return f.section == "staged" and f.mode == "A" end)
    run({ "restore", "--staged", "--worktree", "--source=HEAD", "--" }, function(f) return f.section == "staged" and f.mode ~= "A" end)
  end)
end

local function untrack(ctx)
  local ps = paths(files(ctx), function(f) return f.section ~= "untracked" end)
  if #ps > 0 then act(cat({ "rm", "-r", "-q", "--cached", "--" }, ps)) end
end

---------------------------------------------------------------- views

-- multi-file patch -> { path, orig, mode, header, hunks, add, del, binary }
local function parse_files(out)
  local files, cur, h = {}, nil, nil
  scan_lines(out, function(l)
    local b = l:byte(1)
    local a, bb
    if b == 100 then a, bb = l:match("^diff %-%-git a/(.-) b/(.+)$") end
    if a then
      cur, h = { path = bb, orig = a ~= bb and a or nil, mode = "M", header = { l }, hunks = {}, add = 0, del = 0 }, nil
      files[#files + 1] = cur
    elseif cur and b == 64 and l:byte(2) == 64 then
      h = { header = l, lines = {}, new = tonumber(l:match("%+(%d+)")) or 1 }
      cur.hunks[#cur.hunks + 1] = h
    elseif h then
      h.lines[#h.lines + 1] = l
      if b == 43 then cur.add = cur.add + 1 elseif b == 45 then cur.del = cur.del + 1 end
    elseif cur then
      cur.header[#cur.header + 1] = l
      if b == 110 and l:match("^new file") then cur.mode = "A"
      elseif b == 100 and l:match("^deleted file") then cur.mode = "D"
      elseif b == 114 and l:match("^rename from") then cur.mode = "R"
      elseif b == 66 and l:match("^Binary files") then cur.binary = true end
    end
  end)
  return files
end

-- one commit (or stash), same look as the status: header, kind-colored message, files with
-- +/− and foldable diffs (za zo zc zR zM). <cr>: parent -> that commit, diff line -> file at that line.
-- Popups (A v X r b …) act on this commit from any row. Merges diff against their first parent.
-- opts.diff = argv printing a patch: the same view for a range/PR diff, titled rev, with no commit header
-- opts.win: open in that window instead of the current one (focus stays where it is); opts.summary: files start folded
function show(rev, opts)
  opts = opts or {}
  local hdr, files, pending = nil, nil, (opts.diff or not opts.stash) and 1 or 2
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    if opts.win then
      if not vim.api.nvim_win_is_valid(opts.win) then return end
      local win = opts.win
      opts.win, pending = nil, 1
      return vim.api.nvim_win_call(win, done)
    end
    if opts.diff then
      if not files then return end
      if #files == 0 then return notify("diff: no changes in " .. rev) end
    elseif not hdr then
      return notify("show: " .. rev .. " not found", vim.log.levels.WARN)
    end
    local buf = scratch((opts.stash and "stash " or opts.diff and "diff " or "show ") .. rev, "GitCommit", {})
    local total, open = 0, {}
    for _, f in ipairs(files) do for _, h in ipairs(f.hunks) do total = total + #h.lines end end
    for i, f in ipairs(files) do open[i] = opts.focus and f.path == opts.focus or (not opts.focus and not opts.summary and total <= 400) end
    local base = opts.stash and { stash = rev } or opts.diff and {} or { commit = hdr.short }
    -- base and extra never share keys; a plain copy, not tbl_extend: this runs once per row
    local function item(extra)
      local t = extra or {}
      for k, v in pairs(base) do t[k] = v end
      return t
    end
    local file_row = {}

    local function draw()
      local add, L, H, R = builder()
      local R_spans = {}
      local sub = "GitSubtleText"
      if opts.diff then
        add({ { "Diff     ", sub }, { rev, "GitObjectId" } }, item())
      else
        local head = { { "Commit   ", sub }, { hdr.short, "GitObjectId" }, { " " } }
        local rc = {}
        if not opts.stash then refchunks(hdr.refs, rc, S.data and S.data.remoteset or {}) end -- refs/stash is noise
        if #rc > 0 then
          rc[#rc] = nil
          head[#head + 1] = { "(", sub }
          vim.list_extend(head, rc)
          head[#head + 1] = { ")", sub }
        end
        add(head, item())
        add({ { "Author   ", sub }, { hdr.author, "GitGraphAuthor" }, { " <" .. hdr.email .. ">", sub },
          { " · " .. age(hdr.at) .. " · " .. os.date("%Y-%m-%d %H:%M", tonumber(hdr.at)), sub } }, item())
        if #hdr.parents > 1 and not opts.stash then
          local ch = { { "Merge    ", sub } }
          for _, par in ipairs(hdr.parents) do vim.list_extend(ch, { { par:sub(1, 7), "GitObjectId" }, { " " } }) end
          ch[#ch + 1] = { " diff vs first parent", sub }
          add(ch, item({ parents = hdr.parents }))
        end
        add({ { "" } }, item())
        local subject, on = hdr.subject, nil
        if opts.stash then -- "On main: msg" / "WIP on main: abc msg" -> msg · on main
          on, subject = subject:match("^%a+ on (.-): (.*)$")
          if not on then on, subject = hdr.subject:match("^On (.-): (.*)$") end
          subject = subject or hdr.subject
        end
        local kind, detail = kind_of(subject)
        add(cat(kind and { { kind, kind_hl(kind) }, { " " .. detail } } or { { detail } }, on and { { " · on " .. on, sub } } or {}), item())
        for _, l in ipairs(hdr.body) do add({ { l } }, item()) end
      end
      add({ { "" } }, item())

      local A, D, pw = 0, 0, 0
      for _, f in ipairs(files) do
        A, D = A + f.add, D + f.del
        pw = math.max(pw, vim.api.nvim_strwidth(f.orig and (f.orig .. " -> " .. f.path) or f.path))
      end
      add({ { "Files (" .. #files .. ")", "GitSectionHeader" }, { "  +" .. A, "GitChangeAdded" }, { " −" .. D, "GitChangeDeleted" } }, item())
      for i, f in ipairs(files) do
        local name = f.orig and (f.orig .. " -> " .. f.path) or f.path
        local stats = f.binary and { { "binary", sub } } or { { "+" .. f.add, "GitChangeAdded" }, { " −" .. f.del, "GitChangeDeleted" } }
        add(cat({ { ("%-11s"):format(LABEL[f.mode] or f.mode), MODE_HL[f.mode] }, { name }, { (" "):rep(pw - vim.api.nvim_strwidth(name) + 2) } }, stats),
          item({ vfile = i }))
        file_row[i] = #L
        if open[i] then
          if not f.seg then
            local SL, SH, spans = diff_seg(f.hunks)
            f.seg = { L = SL, H = SH, spans = spans }
          end
          local seg, n = f.seg, #L
          for x, l in ipairs(seg.L) do L[n + x] = l end
          if #seg.L > 0 then R_spans[#R_spans + 1] = { s = n + 1, e = n + #seg.L, vfile = i, spans = seg.spans } end
          if #seg.H > 0 then H[#H + 1] = { n, seg = seg.H, n = #seg.L } end
        end
      end
      if #R_spans > 0 then
        attach_spans(R, R_spans, function(fs, hs, idx) return item({ vfile = fs.vfile, hunk = hs.hunk, idx = idx }) end)
      end
      paint(buf, L, H)
      S.rows[buf] = R
    end
    draw()
    if opts.focus then
      for i, f in ipairs(files) do if f.path == opts.focus then pcall(vim.api.nvim_win_set_cursor, 0, { file_row[i], 0 }) end end
    end

    local function cur() return (S.rows[buf] or {})[vim.fn.line(".")] or {} end
    local function fold(op)
      local i = cur().vfile
      if not i then return end
      open[i] = op == "o" or (op == "a" and not open[i])
      draw()
      vim.api.nvim_win_set_cursor(0, { file_row[i], 0 })
    end
    local function all(v)
      for i in ipairs(files) do open[i] = v end
      draw()
    end
    local function go()
      local it = cur()
      if it.parents then
        local w = vim.fn.expand("<cword>")
        for _, par in ipairs(it.parents) do if w ~= "" and vim.startswith(par, w) then return show(par) end end
        return show(it.parents[1])
      end
      local f = it.vfile and files[it.vfile]
      if not f then return end
      local abs = S.root .. "/" .. f.path
      if vim.fn.filereadable(abs) == 0 then return notify("goto: " .. f.path .. " no longer exists in the worktree", vim.log.levels.WARN) end
      local lnum
      if it.hunk then
        lnum = it.hunk.new
        for j = 1, it.idx - 1 do if it.hunk.lines[j]:sub(1, 1) ~= "-" then lnum = lnum + 1 end end
      end
      vim.cmd.edit(vim.fn.fnameescape(abs))
      if lnum then pcall(vim.api.nvim_win_set_cursor, 0, { math.max(lnum, 1), 0 }) end
    end
    local function move()
      local it, f = cur(), files[cur().vfile or 0]
      if not (f and base.commit) then return notify("move: put the cursor on a hunk or file of a commit", vim.log.levels.WARN) end
      if #f.hunks == 0 then return notify("move: " .. f.path .. " has no hunks to move", vim.log.levels.WARN) end
      move_hunk(base.commit, f, it.hunk and { it.hunk } or f.hunks)
    end
    M.maps(buf, true, { ["goto"] = go, toggle_fold = function() fold("a") end, open_fold = function() fold("o") end,
      close_fold = function() fold("c") end, open_all = function() all(true) end, close_all = function() all(false) end,
      move_hunk = move })
  end
  local function parse_hdr(out)
    local t = vim.split(out or "", "\31", { plain = true })
    if #t >= 8 then
      local msg = vim.split(vim.trim(table.concat(vim.list_slice(t, 8), "\31")), "\n", { plain = true })
      local body = vim.list_slice(msg, 2)
      while body[1] == "" do table.remove(body, 1) end
      hdr = { short = t[2], refs = t[3], author = t[4], email = t[5], at = t[6], parents = vim.split(t[7], " ", { trimempty = true }),
        subject = msg[1] or "", body = body }
    end
  end
  if not opts.diff and not opts.stash then -- regular commits: header and patch in one git show
    git({ "show", "--format=%H%x1f%h%x1f%D%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%B%x1e", "--patch", "--diff-merges=first-parent", rev }, nil, function(r)
      if r.code == 0 then
        local sep = (r.stdout or ""):find("\30", 1, true)
        parse_hdr(sep and r.stdout:sub(1, sep - 1) or r.stdout)
        files = parse_files(sep and r.stdout:sub(sep + 1) or "")
      end
      done()
    end)
    return
  end
  local spin = opts.msg and progress(opts.msg, rev)
  if not opts.diff then
    git({ "log", "-1", "--format=%H%x1f%h%x1f%D%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%B", rev }, nil, function(r)
      if r.code == 0 then parse_hdr(r.stdout) end
      done()
    end)
  end
  git(nil, { raw = opts.diff or { "git", "stash", "show", "-p", "--include-untracked", rev } }, function(r)
    if opts.diff and r.code ~= 0 then
      fail("diff", r, spin)
    else
      if spin then spin() end
      files = parse_files(r.stdout)
    end
    done()
  end)
end

---------------------------------------------------------------- absorb

-- the commit a -U0 hunk belongs to: every old line it replaces was last changed by the same own commit.
-- A pure insertion (-a,0) has no old lines: the lines around it (a, a+1) decide. owner[n] = sha of line n
-- in HEAD, own[sha] = rewritable. nil = no single owner, the hunk stays staged
local function hunk_owner(header, owner, own)
  local a, b = header:match("^@@ %-(%d+),?(%d*)")
  a, b = tonumber(a), b == "" and 1 or tonumber(b)
  local from, to = a, a + b - 1
  if b == 0 then from, to = math.max(a, 1), math.min(a + 1, #owner) end
  local c
  for n = from, to do
    local o = owner[n]
    if not (o and own[o]) or (c and o ~= c) then return nil end
    c = o
  end
  return c
end

-- a: each staged hunk becomes a fixup of the unpushed commit that last touched its lines (git blame),
-- then one autosquash rebase folds them in. Fixups are built in a temporary index, so the real index
-- and worktree are untouched until the rebase; what has no single owner stays staged.
-- ponytail: plain text modifications only (new/deleted/renamed/binary/mode-change files stay staged)
-- history edits written as straight-line code: fn(run, raw, wait) runs in a coroutine, each git call
-- yields until it answers. run = stdout or error with git's message, raw = the whole result.
-- wait(start) pauses on a callback API (a picker): start(resume). Any error ends the job and
-- removes tmp (the scratch index); HEAD only moves on the job's last write, so nothing is half done
local function job(name, tmp, fn)
  local co
  local function resume(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then os.remove(tmp); notify(name .. ": " .. tostring(err), vim.log.levels.ERROR) end
  end
  local function raw(args, env, stdin)
    git(args, { env = env, stdin = stdin }, resume)
    return coroutine.yield()
  end
  local function run(args, env, stdin)
    local r = raw(args, env, stdin)
    if r.code ~= 0 then error(failure(r), 0) end
    return r.stdout
  end
  -- a picker may answer synchronously, while this coroutine is still running: resume on the next tick
  local function wait(start)
    start(function(...) local a = { ... } vim.schedule(function() resume(unpack(a)) end) end)
    return coroutine.yield()
  end
  co = coroutine.create(function() fn(run, raw, wait) os.remove(tmp) end)
  resume()
end

-- the guards every history edit shares; returns st or nil (and says why)
local function editable(name)
  local st = S.data and S.data.st
  if not st or st.oid == "(initial)" then return notify(name .. ": no commits yet", vim.log.levels.WARN) end
  local s = state()
  if s.rebase or s.merge or s.pick or s.revert then return notify(name .. ": finish the operation in progress first", vim.log.levels.WARN) end
  return st
end

local function absorb()
  local st = editable("absorb")
  if not st then return end
  if #st.staged == 0 then return notify("absorb: nothing staged", vim.log.levels.WARN) end
  local tmp = S.gitdir .. "/petal-absorb-index"
  job("absorb", tmp, function(run, raw, wait)
    -- rewritable = on no remote: pushed history is never rewritten. One log gives HEAD,
    -- ownership, subjects, parents and merges (a space in %P) of the whole unpushed stack
    local own, subj, parent_of, list = {}, {}, {}, {}
    local merge = false
    for _, l in ipairs(lines(run({ "log", "--format=%H%x1f%P%x1f%h %s", "HEAD", "--not", "--remotes" }))) do
      local sha, parents, subject = l:match("^(%x+)\31(.-)\31(.*)$")
      if sha then
        list[#list + 1] = sha
        own[sha], subj[sha] = #list, subject -- i: 1 = newest
        parent_of[sha] = parents:match("^(%x+)")
        merge = merge or parents:find(" ", 1, true) ~= nil
      end
    end
    if #list == 0 then return notify("absorb: every commit is pushed, nothing to absorb into", vim.log.levels.WARN) end
    if merge then return notify("absorb: unpushed history has merges, a rebase would flatten them", vim.log.levels.WARN) end
    local head = list[1]
    -- blame stops at the unpushed range: older lines show as its boundary (not own, so refused) instead
    -- of git walking the whole history per file (86ms -> 7ms on a 10k-commit file)
    local oldest_parent = parent_of[list[#list]]
    local range = oldest_parent and (oldest_parent .. "..HEAD") or "HEAD"
    local files = parse_files(run({ "diff", "--cached", "-U0", "--no-renames", "--no-color", "--no-ext-diff",
      "--src-prefix=a/", "--dst-prefix=b/" }))
    local plain_files, plain = {}, {}
    local groups, by, kept = {}, {}, 0 -- groups in first-seen order; hunk.group = its index
    for _, f in ipairs(files) do
      local ok = f.mode == "M" and not f.binary
      for _, l in ipairs(f.header) do if l:match("^old mode") then ok = false end end
      if not ok then
        kept = kept + math.max(#f.hunks, 1)
      else
        plain_files[#plain_files + 1], plain[f.path] = f, {}
      end
    end
    local function blame_out(i, out)
      local owner = {}
      for _, l in ipairs(lines(out)) do owner[#owner + 1] = l:match("^%^?(%x+)") end
      plain[plain_files[i].path] = owner
    end
    if #plain_files > 1 then
      local cmds = {}
      for _, f in ipairs(plain_files) do cmds[#cmds + 1] = { "blame", "-l", "-s", range, "--", f.path } end
      local res = wait(function(done) git_batch(cmds, done) end)
      for i, r in ipairs(res) do
        if r.code ~= 0 then error(failure(r), 0) end
        blame_out(i, r.stdout)
      end
    elseif #plain_files == 1 then
      blame_out(1, run({ "blame", "-l", "-s", range, "--", plain_files[1].path }))
    end
    for _, f in ipairs(plain_files) do
      local owner = plain[f.path]
      for _, h in ipairs(f.hunks) do
        local c = hunk_owner(h.header, owner, own)
        if not c then
          kept = kept + 1
        else
          if not by[c] then
            by[c] = { sha = c, files = {}, n = 0 }
            groups[#groups + 1] = by[c]
            by[c].i = #groups
          end
          h.group, h.sha, by[c].n = by[c].i, c, by[c].n + 1
          by[c].files[f.path] = true
        end
      end
    end
    if #groups == 0 then return notify(("absorb: no staged hunk has a single unpushed owner (%d stay staged)"):format(kept), vim.log.levels.WARN) end

    -- oldest first, as in the rebase todo; tree building only needs some fixed order
    table.sort(groups, function(x, y) return own[x.sha] > own[y.sha] end)
    for i, g in ipairs(groups) do g.i = i end
    for _, f in ipairs(files) do for _, h in ipairs(f.hunks) do if h.group then h.group = by[h.sha].i end end end
    local preview = {}
    for _, g in ipairs(groups) do
      g.subject = subj[g.sha]
      preview[#preview + 1] = ("%s  ← %d hunk%s in %s"):format(g.subject, g.n, g.n > 1 and "s" or "", table.concat(vim.tbl_keys(g.files), ", "))
    end
    if kept > 0 then preview[#preview + 1] = kept == 1 and "1 hunk stays staged (no single unpushed owner)"
      or (kept .. " hunks stay staged (no single unpushed owner)") end
    if not confirm("Absorb into " .. #groups .. " commit(s)?\n" .. table.concat(preview, "\n")) then return end

    -- fixup i's tree = HEAD + groups 1..i: every patch is relative to HEAD, so no line offsets shift
    local env, parent = { GIT_INDEX_FILE = tmp }, head
    for i, g in ipairs(groups) do
      local p = {}
      for _, f in ipairs(files) do
        local hs = vim.tbl_filter(function(h) return h.group and h.group <= i end, f.hunks)
        if #hs > 0 then
          vim.list_extend(p, f.header)
          for _, h in ipairs(hs) do vim.list_extend(p, cat({ h.header }, h.lines)) end
        end
      end
      run({ "read-tree", head }, env)
      run({ "apply", "--cached", "--unidiff-zero", "-" }, env, table.concat(p, "\n") .. "\n")
      local tree = vim.trim(run({ "write-tree" }, env))
      parent = vim.trim(run({ "commit-tree", tree, "-p", parent, "-m", "fixup! " .. g.sha }))
    end
    -- HEAD moves onto the fixups; the real index still holds every staged change, so what wasn't
    -- absorbed is exactly what stays staged
    run({ "update-ref", "-m", "petal: absorb", "HEAD", parent, head })
    -- --autostash brings staged changes back unstaged; autosquash keeps HEAD's final tree, so the
    -- saved index tree is still exactly what was staged
    local index = vim.trim(run({ "write-tree" }))
    local first = groups[1].sha
    act({ "rebase", "-i", "--autosquash", "--autostash", parent_of[first] and (first .. "^") or "--root" }, { env = { GIT_SEQUENCE_EDITOR = "true" },
      after = function()
        act({ "read-tree", index }, { after = function()
          notify(("absorb: %d commit(s) fixed up, was %s (reflog)"):format(#groups, head:sub(1, 7)))
        end })
      end })
  end)
end

-- o in a commit view: move the hunk (or the file's hunks) under the cursor out of that commit into
-- another unpushed commit, or into a new commit right after it. The unpushed stack is replayed in
-- memory (merge-tree as cherry-pick, git 2.40+); no rebase, worktree or index is touched, and HEAD
-- moves only if every commit replays cleanly and the final tree is identical to HEAD's
-- ponytail: plain text modifications only, linear unpushed history, whole hunks (not single lines)
move_hunk = function(commit, f, hunks)
  if not editable("move") then return end
  if f.mode ~= "M" or f.binary then return notify("move: only changes to existing text files can move", vim.log.levels.WARN) end
  local p = vim.list_extend({}, f.header)
  for _, h in ipairs(hunks) do vim.list_extend(p, cat({ h.header }, h.lines)) end
  local patch = table.concat(p, "\n") .. "\n"
  local tmp = S.gitdir .. "/petal-move-index"
  local env = { GIT_INDEX_FILE = tmp }
  job("move", tmp, function(run, raw, wait)
    -- the unpushed stack, oldest first, with everything the replay needs in one call (not 2 per commit)
    local chain, pos = {}, {}
    local log = run({ "log", "--reverse", "--date=raw", "--format=%H%x1f%T%x1f%P%x1f%h %s%x1f%an%x1f%ae%x1f%ad%x1f%B%x1e", "HEAD", "--not", "--remotes" })
    for rec in vim.gsplit(log, "\30", { plain = true }) do
      local f = vim.split(rec:gsub("^\n", ""), "\31", { plain = true })
      if #f >= 8 then
        chain[#chain + 1] = { sha = f[1], tree = f[2], parents = vim.split(f[3], " ", { trimempty = true }), title = f[4],
          an = f[5], ae = f[6], ad = f[7], msg = table.concat(vim.list_slice(f, 8), "\31") }
        pos[f[1]] = #chain
      end
    end
    if #chain == 0 then return notify("move: " .. commit .. " is pushed (or not on this branch), it can't be rewritten", vim.log.levels.WARN) end
    local head, head_tree = chain[#chain].sha, chain[#chain].tree
    local X
    if commit:match("^%x+$") then
      local n = 0
      for _, c in ipairs(chain) do
        if vim.startswith(c.sha, commit) then X, n = c.sha, n + 1 end
      end
      if n ~= 1 then X = nil end
    end
    X = X or vim.trim(run({ "rev-parse", commit }))
    if not pos[X] then return notify("move: " .. commit .. " is pushed (or not on this branch), it can't be rewritten", vim.log.levels.WARN) end
    for _, c in ipairs(chain) do
      if #c.parents > 1 then return notify("move: unpushed history has merges", vim.log.levels.WARN) end
    end
    local NEW = "+ new commit right after " .. chain[pos[X]].title
    local items = { NEW }
    for i = #chain, 1, -1 do if i ~= pos[X] then items[#items + 1] = chain[i].title end end
    local pick_ = wait(function(done) pick("Move " .. #hunks .. " hunk(s) of " .. f.path .. " to", items, done) end)
    local Y, msg
    if pick_ == NEW then
      msg = wait(function(done) input("New commit message: ", nil, done) end)
    else
      for _, c in ipairs(chain) do if c.title == pick_ then Y = c.sha end end
    end
    local forward = not Y or pos[Y] > pos[X] -- X loses the hunk before it reappears
    local lo = math.min(pos[X], Y and pos[Y] or pos[X])
    local p1 = chain[lo].parents[1]
    if not p1 then return notify("move: can't rewrite the root commit", vim.log.levels.WARN) end

    local function patched(tree, reverse, at)
      run({ "read-tree", tree }, env)
      local r = raw(cat({ "apply", "--cached" }, reverse and { "-R" } or {}, { "-" }), env, patch)
      if r.code ~= 0 then error("the hunk doesn't apply on " .. at .. " (it depends on lines from other commits)", 0) end
      return vim.trim(run({ "write-tree" }, env))
    end
    local function commit_tree(tree, parent, c) -- keeps author, date and message; you become committer, as in a rebase
      return vim.trim(run({ "commit-tree", tree, "-p", parent, "-F", "-" },
        { GIT_AUTHOR_NAME = c.an, GIT_AUTHOR_EMAIL = c.ae, GIT_AUTHOR_DATE = c.ad }, c.msg))
    end

    local parent, orig = p1, p1
    local ptree, dropped = vim.trim(run({ "rev-parse", parent .. "^{tree}" })), {}
    for i = lo, #chain do
      local c = chain[i]
      local own_tree = c.tree
      local tree = own_tree
      if parent ~= orig then -- parent was rewritten: cherry-pick c onto it, in memory
        local r = raw({ "merge-tree", "--write-tree", "--merge-base", orig, parent, c.sha })
        if r.code ~= 0 then error(("moving it makes \"%s\" conflict, nothing changed"):format(c.title), 0) end
        tree = lines(r.stdout)[1]
      end
      if c.sha == X and forward then tree = patched(tree, true, c.title) end
      if c.sha == Y then tree = patched(tree, false, c.title) end
      local new
      if parent == orig and tree == own_tree then
        new = c.sha -- untouched: reused as is
      elseif tree == ptree then
        new, dropped[#dropped + 1] = parent, c.title -- nothing left in it: dropped, as a rebase does
      else
        new = commit_tree(tree, parent, c)
      end
      if c.sha == X and not Y then
        tree = patched(tree, false, "the new commit")
        new = vim.trim(run({ "commit-tree", tree, "-p", new, "-m", msg }))
      end
      parent, orig, ptree = new, c.sha, tree
    end
    -- moving changes which commit holds the hunk, never the end result
    if vim.trim(run({ "rev-parse", parent .. "^{tree}" })) ~= head_tree then
      error("the result would differ from HEAD, nothing changed", 0)
    end
    run({ "update-ref", "-m", "petal: move hunk", "HEAD", parent, head })
    notify(("move: %s → %s, was %s (reflog)%s"):format(f.path, Y and chain[pos[Y]].title:gsub("^%x+ ", "") or msg, head:sub(1, 7),
      #dropped > 0 and ("\nnow empty, dropped: " .. table.concat(dropped, ", ")) or ""))
    M.refresh()
  end)
end

local function history()
  local L = {}
  for _, h in ipairs(S.history) do
    L[#L + 1] = ("%s %5dms  %s"):format(h.code == 0 and " " or "!", h.ms, h.cmd)
    for _, l in ipairs(lines(h.out)) do L[#L + 1] = "      " .. l end
  end
  scratch("history", "git", #L > 0 and L or { "no commands yet" })
end

local function goto_item()
  local it = (S.rows[vim.api.nvim_get_current_buf()] or {})[vim.fn.line(".")]
  if not it then return end
  if it.commit then return show(it.commit, { focus = vim.b.git_file }) end -- file history: open on that file
  if it.stash then return show(it.stash, { stash = true }) end
  if not it.file then return end
  local lnum = it.conflict and it.conflict.line
  if it.hunk then
    lnum = it.hunk.new
    for i = 1, it.idx - 1 do if it.hunk.lines[i]:sub(1, 1) ~= "-" then lnum = lnum + 1 end end
  end
  vim.cmd.edit(vim.fn.fnameescape(S.root .. "/" .. it.file.path))
  if lnum then pcall(vim.api.nvim_win_set_cursor, 0, { math.max(lnum, 1), 0 }) end
end

local function load(f, k)
  if f.mode == "U" then
    S.diffs[k] = { conflicts = parse_conflicts(S.root .. "/" .. f.path) }
    return render()
  end
  local native = f.section == "untracked" and untracked_diff(f)
  if native then
    S.diffs[k] = native
    return render()
  end
  git(diff_args(f), nil, function(r)
    S.diffs[k] = parse_diff(r.stdout)
    render()
  end)
end

-- vim-style folds: za toggle, zo open, zc close (on a closed file: its section), zR/zM everything
local function fold(op)
  local it = (S.rows[S.buf] or {})[vim.fn.line(".")]
  if not it then return end
  if it.header then
    S.fold[it.section] = (op == "c" or (op == "a" and not S.fold[it.section])) or nil
    return render()
  end
  local f = it.file
  if not f or f.path:sub(-1) == "/" then return end
  local k = fkey(f)
  local open = S.open[k] ~= nil
  if op == "o" or (op == "a" and not open) then
    if open then return end
    S.open[k] = f
    return load(f, k)
  end
  if not open then -- zc on a closed file folds the section around it
    S.fold[f.section] = true
    return render("#" .. f.section)
  end
  S.open[k] = nil
  render(k)
end

local function fold_all(open)
  S.fold, S.open = {}, {}
  if not S.data then return end
  for _, sec in ipairs({ "untracked", "unstaged", "staged" }) do
    for _, f in ipairs(S.data.st[sec]) do
      if open and f.path:sub(-1) ~= "/" then S.open[fkey(f)] = f end
    end
  end
  if not open then
    for _, sec in ipairs({ "untracked", "unstaged", "staged", "unpulled", "unpushed", "stashes", "recent" }) do S.fold[sec] = true end
    return render()
  end
  M.refresh() -- one parallel batch fetches every diff
end

---------------------------------------------------------------- merge mode

-- e on a conflicted file: new tab, ours | theirs on top (diffed; under 160 columns or 36 lines the file
-- opens alone and cp shows/hides the panes), the real file below with its conflict blocks colored and the
-- marker lines labelled. co/ct/cb/c0 keep ours/theirs/both/none, cO/cT take ours/theirs for every block (on a marker line only, elsewhere they stay Vim's), ZZ saves and returns, ZQ drops unsaved edits and returns (q stays free for macros)
-- (staging the file when no markers are left). ]c [c jump conflicts here, Vim's diff jump once none is left that way
local mns = vim.api.nvim_create_namespace("petal_merge")

local function blocks(buf)
  local out, cur = {}, nil
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local b = l:byte(1)
    if b == 60 and l:match("^<<<<<<<") then cur = { s = i }
    elseif cur and b == 124 and l:match("^|||||||") then cur.b = i
    elseif cur and b == 61 and l:match("^=======$") then cur.m = i
    elseif cur and b == 62 and l:match("^>>>>>>>") and cur.m then cur.e = i; out[#out + 1], cur = cur, nil end
  end
  return out
end

local function paint_merge(buf, labels)
  vim.api.nvim_buf_clear_namespace(buf, mns, 0, -1)
  local opt = {}
  for _, c in ipairs(blocks(buf)) do
    local function hl(a, b, g)
      opt.line_hl_group, opt.virt_text, opt.virt_text_pos = g, nil, nil
      for r = a, b do vim.api.nvim_buf_set_extmark(buf, mns, r - 1, 0, opt) end
    end
    for _, r in ipairs({ c.s, c.b, c.m, c.e }) do hl(r, r, "GitMergeMarker") end
    hl(c.s + 1, (c.b or c.m) - 1, "GitMergeOurs")
    if c.b then hl(c.b + 1, c.m - 1, "GitMergeBase") end
    hl(c.m + 1, c.e - 1, "GitMergeTheirs")
    if labels then
      opt.line_hl_group, opt.virt_text_pos = nil, "eol"
      opt.virt_text = { { labels.ours, "Comment" } }
      vim.api.nvim_buf_set_extmark(buf, mns, c.s - 1, 0, opt)
      opt.virt_text = { { labels.theirs, "Comment" } }
      vim.api.nvim_buf_set_extmark(buf, mns, c.e - 1, 0, opt)
    end
  end
end

local function merge_compact() return vim.o.columns < 160 or vim.o.lines < 36 end

-- who ours/theirs really are: in a rebase HEAD is the upstream and theirs is your commit being replayed.
-- Both git calls run at once, async, and never walk history (for-each-ref --points-at, not name-rev).
-- cb(op, ours label, theirs label)
local function merge_sides(cb)
  local function file(f)
    local h = io.open(S.gitdir .. "/" .. f)
    if not h then return nil end
    local v = vim.trim(h:read("*a"))
    h:close()
    return v
  end
  local st, op, o, t, rev, named = state(), nil, nil, "incoming", nil, nil
  if st.rebase then op, t, rev, named = "rebase", "your commit", "REBASE_HEAD", file("rebase-merge/onto") or file("rebase-apply/onto")
  elseif st.merge then op, rev, named = "merge", "MERGE_HEAD", "MERGE_HEAD"
  elseif st.pick then op, t, rev = "pick", "picked commit", "CHERRY_PICK_HEAD"
  elseif st.revert then op, t, rev = "revert", "reverted commit", "REVERT_HEAD" end
  local res, left = {}, named and 2 or 1
  local function finish()
    local info = res.info
    -- "abc1234 3 days ago" -> "3d", "2 months ago" -> "2mo"
    local function age(i) return info[i] and (info[i]:gsub("^%S+ (%d+) (%a+).*", function(n, u) return n .. (u:match("^mo") and "mo" or u:sub(1, 1)) end)) end
    if named then
      local ref = vim.tbl_filter(function(l) return l ~= "" end, res.refs)[1] or (st.rebase and named:sub(1, 7) or (info[2] or "?"):match("^%S+"))
      if st.rebase then o = ref .. " (upstream)" else t = ref end
    end
    o = o or (file("HEAD") or ""):match("^ref: refs/heads/(.+)") or "HEAD"
    local function side(label, who, i) return label .. "  " .. who .. (age(i) and (" · " .. age(i)) or "") end
    cb(op, side("ours", o, 1), side("theirs", t, 2))
  end
  local function got(name)
    return function(r)
      res[name], left = r.code == 0 and lines(r.stdout) or {}, left - 1
      if left == 0 then finish() end
    end
  end
  if named then
    git({ "for-each-ref", "--points-at=" .. named, "--format=%(if)%(symref)%(then)%(else)%(refname:short)%(end)", "refs/heads", "refs/remotes" }, nil, got("refs"))
  end
  git({ "show", "-s", "--format=%h %ar", "HEAD", rev }, nil, got("info"))
end

local function merge_mode()
  local it = (S.rows[S.buf] or {})[vim.fn.line(".")]
  local f = it and it.file
  if not (f and f.mode == "U") then return notify("merge: not a conflicted file", vim.log.levels.WARN) end
  local rel, abs = f.path, S.root .. "/" .. f.path
  local line = it.conflict and it.conflict.line
  vim.cmd.tabnew(vim.fn.fnameescape(abs))
  local mwin, mbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local ft, compact = vim.bo.filetype, merge_compact()
  -- the ours | theirs panes open lazily (right away on a big screen, cp toggles them otherwise):
  -- the stage contents load on first open and are cached for the next
  local stages, swins, loading, wanted = {}, {}, false, false
  merge_sides(function(op, olabel, tlabel)
    -- tab closed meanwhile: nothing to build into
    if not (vim.api.nvim_win_is_valid(mwin) and vim.api.nvim_win_get_buf(mwin) == mbuf) then return end
    local done, toggle
    local function build()
      if not (vim.api.nvim_win_is_valid(mwin) and vim.api.nvim_win_get_buf(mwin) == mbuf) then return end
      local pos, prev = vim.api.nvim_win_get_cursor(mwin), vim.api.nvim_get_current_win()
      local function side(stage, label, split)
        vim.cmd(split)
        local r = stages[stage]
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, lines(r.stdout))
        vim.bo[b].bufhidden, vim.bo[b].modifiable, vim.bo[b].filetype = "wipe", false, ft
        pcall(vim.api.nvim_buf_set_name, b, label .. ":" .. rel)
        vim.api.nvim_win_set_buf(0, b)
        vim.cmd("diffthis")
        vim.wo.winbar = "%#Comment# " .. label:gsub("%%", "%%%%") .. " %*"
        return b
      end
      vim.api.nvim_set_current_win(mwin)
      local ours = side(2, olabel, "aboveleft split")
      swins[1] = vim.api.nvim_get_current_win()
      local theirs = side(3, tlabel, "rightbelow vsplit")
      swins[2] = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_height(swins[2], math.min(math.floor(vim.o.lines / 3), 15))
      -- built while the user was in another tab: they stay there
      vim.api.nvim_set_current_win(vim.api.nvim_win_get_tabpage(prev) == vim.api.nvim_win_get_tabpage(mwin) and mwin or prev)
      vim.api.nvim_win_set_cursor(mwin, pos)
      for _, b in ipairs({ ours, theirs }) do
        vim.keymap.set("n", "ZZ", function() done(true) end, { buffer = b, nowait = true })
        vim.keymap.set("n", "ZQ", function() done(false) end, { buffer = b, nowait = true })
        vim.keymap.set("n", "cp", toggle, { buffer = b, nowait = true })
      end
    end
    local function open_sides()
      if loading then return end
      if stages[2] and stages[3] then return build() end
      loading, wanted = true, true
      local left = 2
      for _, stage in ipairs({ 2, 3 }) do
        git({ "show", ":" .. stage .. ":" .. rel }, nil, function(r)
          stages[stage], left = r, left - 1
          if left == 0 then
            loading = false
            if wanted then build() end
          end
        end)
      end
    end
    local function close_sides()
      for _, w in ipairs(swins) do if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end end
      if vim.api.nvim_win_is_valid(mwin) then vim.api.nvim_set_current_win(mwin) end
    end
    function toggle()
      for _, w in ipairs(swins) do if vim.api.nvim_win_is_valid(w) then return close_sides() end end
      if loading then wanted = not wanted else open_sides() end -- pressed again before the panes arrived: they stay closed
    end
    vim.wo[mwin].winbar = "%#Comment# " .. (op and (op .. "  ") or "") .. "on a marker: co ct cb c0  cO cT  ·  ]c [c  cp  ZZ ZQ %*"

    local aug = vim.api.nvim_create_augroup("petal_merge", { clear = true })
    local labels = { ours = olabel, theirs = tlabel }
    paint_merge(mbuf, labels)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = aug, buffer = mbuf, callback = function() paint_merge(mbuf, labels) end })

    local function jump(dir)
      local cur, list = vim.fn.line("."), blocks(mbuf)
      for i = dir > 0 and 1 or #list, dir > 0 and #list or 1, dir do
        if (dir > 0 and list[i].s > cur) or (dir < 0 and list[i].s < cur) then return vim.api.nvim_win_set_cursor(0, { list[i].s, 0 }) end
      end
    end
    local function resolve(c, which)
      local L = vim.api.nvim_buf_get_lines(mbuf, c.s - 1, c.e, false)
      local function part(a, b) return vim.list_slice(L, a - c.s + 1, b - c.s + 1) end
      local o, t = part(c.s + 1, (c.b or c.m) - 1), part(c.m + 1, c.e - 1)
      local keep = which == "o" and o or which == "t" and t or which == "b" and vim.list_extend(o, t) or {}
      vim.api.nvim_buf_set_lines(mbuf, c.s - 1, c.e, false, keep)
    end
    -- every conflict block at once; bottom-up so earlier line numbers stay valid
    local function take_all(which)
      local list = blocks(mbuf)
      if #list == 0 then return notify("merge: no conflicts left", vim.log.levels.WARN) end
      for i = #list, 1, -1 do resolve(list[i], which) end
      notify(("merge: %d conflict(s) resolved with %s"):format(#list, which == "o" and "ours" or "theirs"))
    end
    local function take(which)
      local cur = vim.fn.line(".")
      for _, c in ipairs(blocks(mbuf)) do
        if cur >= c.s and cur <= c.e then
          resolve(c, which)
          vim.api.nvim_win_set_cursor(0, { math.min(c.s, vim.api.nvim_buf_line_count(mbuf)), 0 })
          return jump(1)
        end
      end
      notify("merge: cursor is not inside a conflict", vim.log.levels.WARN)
    end
    function done(save)
      if vim.bo[mbuf].modified then vim.api.nvim_buf_call(mbuf, function() vim.cmd(save and "silent write" or "silent edit!") end) end
      local left = #blocks(mbuf)
      vim.api.nvim_del_augroup_by_id(aug)
      vim.api.nvim_buf_clear_namespace(mbuf, mns, 0, -1)
      for _, k in ipairs({ "co", "ct", "cb", "c0", "cO", "cT", "]c", "[c", "cp", "ZZ", "ZQ" }) do pcall(vim.keymap.del, "n", k, { buffer = mbuf }) end
      if vim.api.nvim_win_is_valid(mwin) then vim.wo[mwin].winbar = "" end -- or it comes back whenever the file is shown again
      vim.cmd("diffoff! | tabclose")
      if left == 0 then
        act({ "add", "--", rel }, { after = function() notify("merge: " .. rel .. " resolved and staged") end })
      else
        notify(("merge: %s has %d conflict(s) left"):format(rel, left), vim.log.levels.WARN)
        M.refresh()
      end
    end
    -- the keys act only where Vim's own meaning is useless, otherwise they stay Vim's (ct, cb, c0, cT, ]c, [c).
    -- expr so the fallback keeps its count and register; the action is scheduled (expr maps can't edit text)
    local function map(lhs, here, fn)
      vim.keymap.set("n", lhs, function()
        if not here() then return lhs end
        vim.schedule(fn)
        return "<Cmd><CR>" -- ends the command so a count typed before it is dropped (<Ignore> would leak it)
      end, { buffer = mbuf, expr = true })
    end
    local function on_marker()
      local cur = vim.fn.line(".")
      for _, c in ipairs(blocks(mbuf)) do
        if cur == c.s or cur == c.b or cur == c.m or cur == c.e then return true end
      end
    end
    local function ahead(dir)
      return function()
        local cur = vim.fn.line(".")
        for _, c in ipairs(blocks(mbuf)) do
          if (dir > 0 and c.s > cur) or (dir < 0 and c.s < cur) then return true end
        end
      end
    end
    map("co", on_marker, function() take("o") end)
    map("ct", on_marker, function() take("t") end)
    map("cb", on_marker, function() take("b") end)
    map("c0", on_marker, function() take("0") end)
    map("cO", on_marker, function() take_all("o") end)
    map("cT", on_marker, function() take_all("t") end)
    map("]c", ahead(1), function() jump(1) end)
    map("[c", ahead(-1), function() jump(-1) end)
    local o = { buffer = mbuf, nowait = true }
    vim.keymap.set("n", "cp", toggle, o)
    vim.keymap.set("n", "ZZ", function() done(true) end, o)
    vim.keymap.set("n", "ZQ", function() done(false) end, o)
    if line then vim.api.nvim_win_set_cursor(mwin, { line, 0 }) else vim.api.nvim_win_set_cursor(mwin, { 1, 0 }); jump(1) end
    if not compact then open_sides() end
  end)
end

local function log_view(args, name, file)
  git(args, nil, function(r)
    if vim.trim(r.stdout or "") == "" then return notify("log: " .. name .. " has no history", vim.log.levels.WARN) end
    local add, L, H, R = builder()
    local list = parse_log(r.stdout)
    if name == "reflog" then reflog_rows(list) end
    add_commits(add, list, S.data and S.data.remoteset or {}, "log", text_width(vim.api.nvim_get_current_win()))
    local buf = scratch(name, "GitLog", {})
    vim.b[buf].git_file = file
    paint(buf, L, H)
    S.rows[buf] = R
    M.maps(buf, true)
  end)
end

function M.command(cmd)
  local function go(c) act(nil, { raw = { "sh", "-c", "git " .. c }, show = true }) end
  if cmd and cmd ~= "" then return go(cmd) end
  input("git ", nil, go)
end

-- d: plain vimdiff of the file under the cursor vs HEAD, no plugins
-- ponytail: untracked files have no HEAD to diff, so they warn
local vimdiff_open
local function vimdiff()
  local it = (S.rows[S.buf] or {})[vim.fn.line(".")]
  if not (it and it.file) then return notify("diff: no file under cursor", vim.log.levels.WARN) end
  if it.file.mode == "U" then return merge_mode() end -- HEAD alone says nothing about a conflict
  local root, rel = S.root, it.file.path
  -- one async process: a failed show is the "not in HEAD" check
  git({ "show", "HEAD:" .. rel }, nil, function(r)
    if r.code ~= 0 then return notify("diff: untracked, nothing in HEAD to diff against", vim.log.levels.WARN) end
    if S.root ~= root then return end
    local head = vim.split(r.stdout or "", "\n", { plain = true })
    if head[#head] == "" then head[#head] = nil end -- the final newline, as systemlist drops it
    vimdiff_open(root, rel, head)
  end)
end

-- closes the d diff: save true writes the working file if modified (ZZ), false drops its unsaved edits (ZQ), nil leaves it.
-- reload before diffoff!: a failed write keeps the diff open, like Vim's ZZ (maps survive edit!/write, so they are deleted here)
local function diff_close(save)
  local bufs = vim.tbl_filter(function(b) return vim.b[b].git_work_diff or vim.b[b].git_head_scratch end, vim.api.nvim_list_bufs())
  for _, b in ipairs(bufs) do -- nofile (deleted in the worktree): nothing to write or reload
    if save ~= nil and vim.b[b].git_work_diff and vim.bo[b].buftype == "" and vim.bo[b].modified then
      vim.api.nvim_buf_call(b, function() vim.cmd(save and "silent write" or "silent edit!") end)
    end
  end
  vim.cmd("diffoff!")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.b[b].git_work_diff or vim.b[b].git_head_scratch then vim.api.nvim_set_option_value("winbar", "", { win = w }) end
  end
  for _, b in ipairs(bufs) do
    for _, k in ipairs({ "ZZ", "ZQ" }) do pcall(vim.keymap.del, "n", k, { buffer = b }) end
    if vim.b[b].git_head_scratch then vim.api.nvim_buf_delete(b, { force = true }) else vim.b[b].git_work_diff = nil end
  end
  return #bufs > 0
end

function vimdiff_open(root, rel, head)
  -- ponytail: one diff at a time; repeat-d replaces instead of stacking splits
  diff_close()
  local abs = root .. "/" .. rel
  if vim.fn.filereadable(abs) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  else
    vim.cmd("enew") -- deleted in worktree: empty side still diffs vs HEAD
    vim.bo.buftype = "nofile"
  end
  vim.b.git_work_diff = true
  local work_win, work_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local ft = vim.bo.filetype
  vim.cmd("diffthis")
  vim.api.nvim_set_option_value("winbar", "%#Comment# working %*", { win = work_win })
  vim.cmd("vnew")
  local head_win, head_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, head)
  pcall(vim.api.nvim_buf_set_name, 0, "HEAD:" .. rel)
  vim.bo.filetype = ft
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.buflisted = false
  vim.bo.swapfile = false
  vim.bo.readonly = true
  vim.bo.modifiable = false
  vim.b.git_head_scratch = true
  vim.cmd("diffthis")
  vim.api.nvim_set_option_value("winbar", "%#Comment# head %*", { win = head_win })
  local function close(save) return function() diff_close(save); M.open() end end
  for _, b in ipairs({ work_buf, head_buf }) do
    vim.keymap.set("n", "ZZ", close(true), { buffer = b, nowait = true })
    vim.keymap.set("n", "ZQ", close(false), { buffer = b, nowait = true })
  end
end

-- :DiffOff closes the diff (HEAD split + labels) and goes back to the status; ZZ/ZQ in the diff do the same after saving/dropping the edits
function M.diff_off() if diff_close() then M.open() end end
vim.api.nvim_create_user_command("DiffOff", M.diff_off, { desc = "Close diff, back to git status" })

---------------------------------------------------------------- popups

-- def = { title, args = { {key, flag, desc} }, groups = { {title, { {key, desc, fn(args, ctx)} }} } }
-- -<key> toggles an argument (remembered per popup), q/<esc> closes
local function popup(def)
  local ctx = context()
  local on = S.switches[def.title] or {}
  S.switches[def.title] = on
  local src = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local groups = vim.tbl_filter(function(g) return #g[2] > 0 end, def.groups)
  local win

  local function draw()
    local L, H = {}, {}
    if def.args and #def.args > 0 then
      L[1] = " Arguments"
      H[1] = { 0, 1, 10, "GitSectionHeader" }
      for _, a in ipairs(def.args) do
        local head = " -" .. a[1] .. " " .. a[3] .. " "
        L[#L + 1] = head .. "(" .. a[2] .. ")"
        H[#H + 1] = { #L - 1, 1, 3, "GitPopupSwitchKey" }
        H[#H + 1] = { #L - 1, #head, #L[#L], on[a[2]] and "GitPopupSwitchEnabled" or "GitSubtleText" }
      end
      L[#L + 1] = ""
    end
    local top, x = #L, 1
    for _, g in ipairs(groups) do
      local w = #g[1]
      for i = 0, #g[2] do
        local a = g[2][i]
        local cell = a and (a[1] .. " " .. a[2]) or g[1]
        local r = top + i + 1
        L[r] = L[r] or ""
        L[r] = L[r] .. (" "):rep(x - #L[r]) .. cell
        H[#H + 1] = { r - 1, x, x + (a and #a[1] or #g[1]), a and "GitPopupActionKey" or "GitSectionHeader" }
        w = math.max(w, #cell)
      end
      x = x + w + 4
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, L)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(H) do vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] }) end
    return #L
  end

  draw()
  win = vim.api.nvim_open_win(buf, true, { split = "below", win = -1, height = C.height })
  for o, v in pairs({ number = true, relativenumber = false, signcolumn = "no", cursorline = false,
    winfixheight = true, list = false, foldcolumn = "0" }) do
    vim.wo[win][o] = v
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(src) then vim.api.nvim_set_current_win(src) end
  end
  local o = { buffer = buf, nowait = true }
  for _, g in ipairs(groups) do
    for _, a in ipairs(g[2]) do
      vim.keymap.set("n", a[1], function()
        local t = {}
        for _, s in ipairs(def.args or {}) do if on[s[2]] then t[#t + 1] = s[2] end end
        close()
        a[3](t, ctx)
      end, o)
    end
  end
  vim.keymap.set("n", "-", function()
    local c = vim.fn.getcharstr()
    for _, s in ipairs(def.args or {}) do if s[1] == c then on[s[2]] = not on[s[2]] or nil end end
    draw()
  end, o)
  for _, k in ipairs({ "q", "<esc>" }) do vim.keymap.set("n", k, close, o) end
end

local P = {}

local function sequencer(cmd, key) -- continue/skip/abort group for an in-progress operation
  return { "Sequencer", {
    { key, "Continue", function() act({ cmd, "--continue" }) end },
    { "s", "Skip", function() act({ cmd, "--skip" }) end },
    { "a", "Abort", function() act({ cmd, "--abort" }) end },
  } }
end

function P.commit()
  local function fix(kind)
    return function(_, ctx) commits(ctx, function(cs) act({ "commit", "--" .. kind .. "=" .. cs[1] }) end) end
  end
  popup({ title = "Commit",
    args = { { "a", "--all", "Stage all modified and deleted files" }, { "e", "--allow-empty", "Allow empty commit" },
      { "v", "--verbose", "Show diff of changes to be committed" }, { "n", "--no-verify", "Disable hooks" } },
    groups = {
      { "Create", { { "c", "Commit", function(a) act(cat({ "commit" }, a)) end } } },
      { "Edit HEAD", {
        { "e", "Extend", function(a) act(cat({ "commit", "--amend", "--no-edit" }, a)) end },
        { "a", "Amend", function(a) act(cat({ "commit", "--amend" }, a)) end },
        { "w", "Reword", function(a) act(cat({ "commit", "--amend", "--only" }, a)) end },
      } },
      { "Edit", {
        { "f", "Fixup", fix("fixup") },
        { "s", "Squash", fix("squash") },
        { "F", "Instant fixup", function(_, ctx)
          commits(ctx, function(cs)
            act({ "commit", "--fixup=" .. cs[1] }, { after = function()
              base_of(cs[1], function(base)
                act({ "rebase", "-i", "--autosquash", "--autostash", base }, { env = { GIT_SEQUENCE_EDITOR = "true" } })
              end)
            end })
          end)
        end },
      } },
    } })
end

-- local branch buffer (oil-style): each line is "/<id> <name>", the concealed id says which branch
-- it came from, so dd deletes, yy+p copies, editing the name renames, a new line creates at HEAD
-- pure: buffer lines vs the branches they were loaded from -> ops (deletes, renames, creates), or
-- nil + why. set: remote names, refused as prefixes so origin/x never means two things
local function branch_plan(orig, buf_lines, set)
  local kept, news, seen = {}, {}, {}
  for _, o in ipairs(orig) do kept[o.id] = {} end
  for i, l in ipairs(buf_lines) do
    local id, name = l:match("^/(%d+) (.*)$")
    if not id and l:match("^/%d") then return nil, "line " .. i .. ": its hidden id was edited, undo with u" end
    name = vim.trim(name or l)
    if name ~= "" then
      if seen[name] then return nil, name .. " is listed twice" end
      seen[name] = true
      if not id then news[#news + 1] = name
      elseif kept[tonumber(id)] then table.insert(kept[tonumber(id)], name)
      else return nil, "line " .. i .. ": unknown id /" .. id end
    end
  end
  local byname, dels, renames, creates = {}, {}, {}, {}
  for _, o in ipairs(orig) do byname[o.name] = o end
  for _, o in ipairs(orig) do
    local stays, copies = false, {}
    for _, n in ipairs(kept[o.id]) do
      if n == o.name then stays = true else copies[#copies + 1] = n end
    end
    if not stays and #copies == 0 then
      if o.head then return nil, "can't delete " .. o.name .. ": it is checked out" end
      dels[#dels + 1] = { op = "delete", src = o }
    elseif not stays then renames[#renames + 1] = { op = "rename", src = o, to = table.remove(copies, 1) } end
    for _, n in ipairs(copies) do creates[#creates + 1] = { op = "create", src = o, to = n } end
  end
  for _, n in ipairs(news) do creates[#creates + 1] = { op = "create", to = n } end
  local freed = {}
  for _, d in ipairs(dels) do freed[d.src.name] = true end
  for _, op in ipairs(cat(renames, creates)) do
    local r = op.to:match("^([^/]+)/")
    if r and set[r] then return nil, op.to .. " looks like a remote branch (remote branches: b R)" end
    if byname[op.to] and not freed[op.to] then return nil, op.to .. " already exists (swap names in two saves)" end
  end
  return cat(dels, renames, creates)
end

local function plan_line(op)
  if op.op == "delete" then return "delete  " .. op.src.name end
  if op.op == "rename" then return "rename  " .. op.src.name .. " → " .. op.to end
  return "create  " .. op.to .. " from " .. (op.src and op.src.name or "HEAD")
end

-- rename or create; deletes run batched in save(). false stops the rest
local function branch_op(op, raw)
  local o = op.src
  local r = op.op == "rename" and raw({ "branch", "-m", o.name, op.to }) -- -m keeps reflog and upstream
    or raw({ "branch", op.to, o and o.sha or "HEAD" }) -- copies use the sha loaded: order-proof
  if r.code ~= 0 then fail(plan_line(op), r) end
  return r.code == 0
end

-- PR per head branch name from one `gh pr list` (newest first), cached PR_TTL like the PR line
local function branch_prs(cb)
  if C.simple or not HAS_GH or not (S.data and #S.data.remotes > 0) then return end
  local c = S.branch_prs
  if c and c.root == S.root and vim.uv.now() - c.at < PR_TTL then return end -- the caller drew the cached map
  S.branch_prs = { root = S.root, at = vim.uv.now(), map = c and c.map or {} } -- one gh call in flight
  gh({ "pr", "list", "--state", "all", "--limit", "200", "--json", "number,state,isDraft,headRefName" }, {}, function(r)
    local map = {}
    for _, pr in ipairs(json(r) or {}) do
      local h = str(pr.headRefName)
      map[h] = map[h] or pr
    end
    S.branch_prs = { root = S.root, at = vim.uv.now(), map = map }
    cb(map)
  end)
end

-- remote list: a line may go only when its PR merged and nothing local still has it. nil = safe
-- shortcut: PRs are matched by head name only, so a merged fork PR with the same name counts; check the remote if that matters
local function remote_unsafe(o, pr)
  if not pr or pr_state(pr) ~= "MERGED" then return o.name .. " has no merged PR" end
  if o.has_local then return o.name .. " still has a local branch (delete it in b l first)" end
  if o.default then return o.name .. " is the remote's default or a base branch" end
end

-- bottom list of branches, same look for both kinds, oil-style: each line "/<id> <name>" (the
-- concealed id says which branch it came from; :w applies). "remote": only deletes of merged ones
local function branches(kind)
  local set, edit = S.data and S.data.remoteset or {}, kind == "local"
  local buf, orig = S.branch_buf, {}
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 and vim.b[buf].petal_kind == kind then return vim.api.nvim_set_current_win(win) end
    if vim.bo[buf].modified and not confirm("Discard branch edits?") then return end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  local src = vim.api.nvim_get_current_win()
  buf = vim.api.nvim_create_buf(false, true)
  S.branch_buf, vim.b[buf].petal_kind = buf, kind
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "acwrite", "hide", "petalbranches"
  pcall(vim.api.nvim_buf_set_name, buf, "git://branches/" .. kind)
  local win = vim.api.nvim_open_win(buf, true, { split = "below", win = -1, height = C.height })
  local w = vim.wo[win][0]
  w.number, w.conceallevel, w.concealcursor, w.winfixheight = true, 3, "nvic", true
  w.statusline = edit and " Local branches  %m  (:w applies)" or " Remote branches  %m  (dd/X merged ones, :w deletes)"
  vim.cmd([[syntax match PetalBranchId /^\/\d\+ / conceal]])
  local bns = vim.api.nvim_create_namespace("petal.branches")

  local function decorate(prs)
    vim.api.nvim_buf_clear_namespace(buf, bns, 0, -1)
    local width = 0
    for _, o in ipairs(orig) do o.w = o.w or vim.api.nvim_strwidth(o.name); width = math.max(width, o.w) end
    for i, o in ipairs(orig) do
      local pr = prs and prs[o.pr_key]
      local s = pr and pr_state(pr)
      -- tag column: blanks carry no highlight (an underlined Head group would draw them as __)
      local tag = o.current and (edit and "● current" or "● upstream") or ""
      local vt = { { (" "):rep(width - o.w + 2) },
        { tag, "GitBranchHead" }, { (" "):rep(12 - vim.api.nvim_strwidth(tag)) }, { ("%-4s "):format(o.age), "GitSubtleText" } }
      if pr then vt[#vt + 1] = { "#" .. str(pr.number, "?") .. " " .. s:lower() .. " ", PR_STATE[s] or "Comment" } end
      vt[#vt + 1] = { o.subject, "GitSubtleText" }
      local p = #("/" .. o.id .. " ")
      vim.api.nvim_buf_set_extmark(buf, bns, i - 1, 0, { invalidate = true, undo_restore = false, virt_text = vt,
        end_col = o.current and p + #o.name or nil, hl_group = o.current and "GitBranchHead" or nil })
    end
  end

  local first
  local function load()
    -- the remote list reads refs/heads too: which remote branches a local one still has
    git(cat({ "for-each-ref", "--sort=-committerdate", "refs/heads" }, edit and {} or { "refs/remotes" },
      { "--format=%(refname:short)%09%(objectname)%09%(HEAD)%09%(committerdate:unix)%09%(upstream:short)%09"
        .. "%(upstream:remotename)%09%(upstream:remoteref)%09%(refname)%09%(symref:short)%09%(contents:subject)" }), nil, function(r)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      orig = {}
      local L, locals, defaults = {}, {}, {}
      local now = os.time()
      for _, l in ipairs(lines(r.stdout)) do
        local f = vim.split(l, "\t", { plain = true })
        local name = f[1]
        local rem, short = name:match("^([^/]+)/(.+)$")
        if #f < 10 then -- malformed line: skip
        elseif not edit and f[8]:match("^refs/heads/") then
          locals[name] = true
          if f[5] ~= "" then locals[f[5]] = true end
        elseif not edit and short == "HEAD" then defaults[f[9]] = true
        -- remote list: only configured remotes, never <remote>/HEAD
        elseif edit or (rem and set[rem]) then
          local up = f[5] ~= "" and f[5] or nil
          local o = { id = #orig + 1, name = name, short = short, sha = f[2], head = f[3] == "*", age = age(f[4], now), upstream = up,
            up_remote = f[6], up_ref = f[7], subject = table.concat(f, "\t", 10) }
          -- a PR's head is the branch on the remote: the upstream's name when there is one
          o.pr_key = edit and (up and f[7]:gsub("^refs/heads/", "") or name) or short
          -- current: the checked-out branch, or in the remote list its upstream
          o.current = edit and o.head or (not edit and S.data and S.data.st.upstream == name)
          orig[#orig + 1] = o
          L[#L + 1] = "/" .. o.id .. " " .. name
        end
      end
      for _, o in ipairs(edit and {} or orig) do
        o.has_local = locals[o.name] or locals[o.short]
        o.default = defaults[o.name] or vim.tbl_contains(C.base_branches, o.name)
      end
      local cur = vim.api.nvim_win_get_buf(0) == buf and vim.api.nvim_win_get_cursor(0)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, L)
      vim.bo[buf].modified = false
      decorate(S.branch_prs and S.branch_prs.root == S.root and S.branch_prs.map)
      branch_prs(function(prs) if vim.api.nvim_buf_is_valid(buf) then decorate(prs) end end)
      if not first and cur then -- first load: start on the current branch
        for i, o in ipairs(orig) do if o.current then cur = { i, 0 } end end
      end
      first = true
      if cur then pcall(vim.api.nvim_win_set_cursor, 0, cur) end
    end)
  end

  local function save()
    local plan, why = branch_plan(orig, vim.api.nvim_buf_get_lines(buf, 0, -1, false), set)
    if not plan then return notify("branches: " .. why, vim.log.levels.WARN) end
    if #plan == 0 then vim.bo[buf].modified = false; return end
    -- an upstream another kept branch still tracks is never offered for deletion
    local gone, used = {}, {}
    for _, op in ipairs(plan) do if op.op == "delete" then gone[op.src.id] = true end end
    for _, o in ipairs(orig) do if not gone[o.id] and o.upstream then used[o.upstream] = true end end
    for _, op in ipairs(plan) do if op.op == "delete" then op.shared = used[op.src.upstream] end end
    -- every question up front in one dialog, then local work in one go and one push per remote
    job("branches", "", function(_, raw) -- no temp file: os.remove("") is a no-op
      local text, dels, remote, defaults = {}, {}, {}, {}
      for _, op in ipairs(plan) do
        if op.to and raw({ "check-ref-format", "--branch", op.to }).code ~= 0 then
          return notify("branches: not a valid branch name: " .. op.to, vim.log.levels.WARN)
        end
        local line, o = plan_line(op), op.src
        if op.op == "delete" then
          dels[#dels + 1] = o.name
          -- git branch -d's rule: merged into the upstream if it has one, else into HEAD.
          -- no %(upstream:track) in the list for [gone]: it counts ahead/behind per branch, far slower
          -- than this. A gone upstream is a bad ref: exit 128 (not merged is 1)
          local m = o.upstream and raw({ "merge-base", "--is-ancestor", o.sha, o.upstream })
          o.gone = m and m.code == 128
          if not m or o.gone then m = raw({ "merge-base", "--is-ancestor", o.sha, "HEAD" }) end
          if m.code ~= 0 then line = line .. "  (not merged: its commits will be lost)" end
          -- its upstream too: never the remote's default or a base branch, nor one still tracked
          local rm = o.up_remote
          if o.upstream and rm ~= "." and not o.gone and not op.shared then
            defaults[rm] = defaults[rm] or vim.trim(raw({ "symbolic-ref", "-q", "--short", "refs/remotes/" .. rm .. "/HEAD" }).stdout or "")
            if o.upstream ~= defaults[rm] and not vim.tbl_contains(C.base_branches, o.upstream) then
              remote[rm] = remote[rm] or {}
              table.insert(remote[rm], (o.up_ref:gsub("^refs/heads/", "")))
            end
          end
        end
        text[#text + 1] = line
      end
      local rms = vim.tbl_keys(remote)
      table.sort(rms)
      for i, rm in ipairs(rms) do
        text[#text + 1] = (i == 1 and "\n" or "") .. "on " .. rm .. " also delete: " .. table.concat(remote[rm], ", ")
      end
      local choice = vim.fn.confirm(table.concat(text, "\n"),
        #rms > 0 and "&Apply + remote\n&Local only\n&Cancel" or "&Apply\n&Cancel", #rms > 0 and 3 or 2)
      if not (choice == 1 or (#rms > 0 and choice == 2)) then return end
      local r = #dels > 0 and raw(cat({ "branch", "-D" }, dels)) -- merge state was shown above: force
      if r and r.code ~= 0 then fail("delete", r)
      else
        for _, op in ipairs(plan) do if op.op ~= "delete" and not branch_op(op, raw) then break end end
        -- network last, in the background: the list is usable while it pushes
        if choice == 1 then
          for _, rm in ipairs(rms) do act(cat({ "push", rm, "--delete" }, remote[rm]), { msg = "Deleting on " .. rm }) end
        end
      end
      load()
      M.refresh()
    end)
  end

  local function prs() return S.branch_prs and S.branch_prs.root == S.root and S.branch_prs.map or {} end
  -- remote: only deletes, each one safe (remote_unsafe), all asked in one dialog, one push per remote
  local function save_remote()
    local plan, why = branch_plan(orig, vim.api.nvim_buf_get_lines(buf, 0, -1, false), {})
    if not plan then return notify("remote branches: " .. why, vim.log.levels.WARN) end
    if #plan == 0 then vim.bo[buf].modified = false; return end
    local by, text = {}, {}
    for _, op in ipairs(plan) do
      if op.op ~= "delete" then return notify("remote branches: only deletes (dd), undo the other edits with u", vim.log.levels.WARN) end
      local o = op.src
      local no = remote_unsafe(o, prs()[o.pr_key])
      if no then return notify("remote branches: " .. no .. ", undo with u", vim.log.levels.WARN) end
      local rm = o.name:match("^([^/]+)/")
      by[rm] = by[rm] or {}
      table.insert(by[rm], o.short)
      text[#text + 1] = "delete  " .. o.name
    end
    if not confirm("Delete on the remote (PR merged, no local branch)?\n" .. table.concat(text, "\n")) then return end
    for rm, names in pairs(by) do act(cat({ "push", rm, "--delete" }, names), { msg = "Deleting on " .. rm, after = load }) end
  end

  local function close()
    S.branch_buf = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true }) -- closes the split too
    if vim.api.nvim_win_is_valid(src) then vim.api.nvim_set_current_win(src) end
  end
  local o = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", function()
    if vim.bo[buf].modified and not confirm("Discard branch edits?") then return end
    close()
  end, o)
  vim.keymap.set("n", "<CR>", function()
    local row = vim.fn.line(".")
    if vim.bo[buf].modified then return notify("branches: save (:w) or undo first", vim.log.levels.WARN) end
    local b = orig[row]
    if not b then return end
    -- remote: switch to (or DWIM-create) the local tracking branch
    act({ "switch", edit and b.name or (b.name:gsub("^[^/]+/", "")) })
    close()
  end, o)
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = edit and save or save_remote })
  if not edit then
    -- the cleanup in one key: drop every line that is safe to delete, then :w
    vim.keymap.set("n", "X", function()
      local n = 0
      local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local kept = {}
      for _, l in ipairs(all) do
        local b = orig[tonumber(l:match("^/(%d+) ") or "")]
        if b and l == "/" .. b.id .. " " .. b.name and not remote_unsafe(b, prs()[b.pr_key]) then
          n = n + 1
        else
          kept[#kept + 1] = l
        end
      end
      if n > 0 then vim.api.nvim_buf_set_lines(buf, 0, -1, false, kept) end
      notify(n > 0 and ("remote branches: " .. n .. " merged, :w deletes them") or "remote branches: nothing merged to clean")
    end, o)
  end
  do
    -- keep the cursor off the hidden id, so cw/I/0 edit the name only
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { buffer = buf, callback = function()
      local r, col = unpack(vim.api.nvim_win_get_cursor(0))
      local p = #(vim.api.nvim_get_current_line():match("^/%d+ ") or "")
      if col < p then vim.api.nvim_win_set_cursor(0, { r, p }) end
    end })
    for _, k in ipairs({ "cc", "S" }) do -- change the name, keep the id: cc is the natural rename
      vim.keymap.set("n", k, function()
        vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), #(vim.api.nvim_get_current_line():match("^/%d+ ") or "") })
        vim.api.nvim_feedkeys("C", "n", false)
      end, o)
    end
  end
  load()
end

function P.branch()
  local function at(ctx) return ctx.commit and { ctx.commit } or {} end
  popup({ title = "Branch", groups = {
    { "Checkout", {
      { "b", "Branch/revision", function()
        refs({ "refs/heads", "refs/remotes" }, function(l)
          pick("Checkout", l, function(b)
            local r, rest = b:match("^([^/]+)/(.+)$")
            -- remote ref: switch to (or DWIM-create) the local tracking branch
            act({ "switch", (r and S.data.remoteset[r]) and rest or b })
          end)
        end)
      end },
      { "r", "Recent (previous branch)", function() act({ "switch", "-" }) end },
      { "l", "Local branches (edit)", function() branches("local") end },
      { "R", "Remote branches", function() branches("remote") end },
      { "c", "New branch", function(_, ctx) input("New branch: ", nil, function(n) act(cat({ "switch", "-c", n }, at(ctx))) end) end },
    } },
    { "Create", {
      { "n", "New branch", function(_, ctx) input("Create branch: ", nil, function(n) act(cat({ "branch", n }, at(ctx))) end) end },
    } },
    { "Do", {
      { "m", "Rename", function()
        refs({ "refs/heads" }, function(l)
          pick("Rename", l, function(b) input("Rename " .. b .. " to: ", b, function(n) act({ "branch", "-m", b, n }) end) end)
        end)
      end },
      { "u", "Set upstream", function()
        refs({ "refs/remotes" }, function(l) pick("Upstream", l, function(u) act({ "branch", "-u", u }) end) end)
      end },
    } },
  } })
end

function P.bisect()
  local s = state()
  popup({ title = "Bisect", groups = s.bisect and {
    { "Bisect", {
      { "g", "Good", function() act({ "bisect", "good" }, { show = true }) end },
      { "b", "Bad", function() act({ "bisect", "bad" }, { show = true }) end },
      { "s", "Skip", function() act({ "bisect", "skip" }, { show = true }) end },
      { "R", "Run script", function() input("Run: ", nil, function(c) act({ "bisect", "run", "sh", "-c", c }, { show = true, msg = "Bisecting" }) end) end },
      { "r", "Reset", function() act({ "bisect", "reset" }) end },
    } },
  } or {
    { "Bisect", {
      { "B", "Start (HEAD bad)", function(_, ctx)
        local function go(good) act({ "bisect", "start", "HEAD", good }, { show = true }) end
        if ctx.commit then go(ctx.commit) else input("Good commit: ", nil, go) end
      end },
    } },
  } })
end

function P.cherry()
  local s = state()
  local function go(extra)
    return function(a, ctx)
      commits(ctx, function(cs) act(cat({ "cherry-pick" }, extra, a, vim.fn.reverse(cs))) end) -- oldest first
    end
  end
  popup({ title = "Cherry Pick",
    args = { { "x", "-x", "Reference cherry in commit message" }, { "e", "--edit", "Edit commit message" }, { "f", "--ff", "Fast-forward when possible" } },
    groups = s.pick and { sequencer("cherry-pick", "A") } or {
      { "Apply here", { { "A", "Pick", go({}) }, { "a", "Apply (no commit)", go({ "--no-commit" }) } } },
    } })
end

function P.revert()
  local s = state()
  local function go(extra)
    return function(a, ctx) commits(ctx, function(cs) act(cat({ "revert" }, extra, a, cs)) end) end
  end
  popup({ title = "Revert",
    args = { { "e", "--edit", "Edit commit message" } },
    groups = s.revert and { sequencer("revert", "v") } or {
      { "Revert", { { "v", "Commit(s)", go({}) }, { "V", "Changes (no commit)", go({ "--no-commit" }) } } },
    } })
end

function P.fetch()
  local up = S.data and S.data.st.upstream and S.data.st.upstream:match("^[^/]+")
  -- manual fetch: always recheck the PR (refresh skips gh for PR_TTL otherwise)
  local fetched = { msg = "Fetching", show = true, after = function() S.pr_at, S.branch_prs = {}, nil end }
  popup({ title = "Fetch",
    args = { { "p", "--prune", "Prune deleted branches" }, { "t", "--tags", "Fetch all tags" } },
    groups = { { "Fetch from", {
      { "u", up or "upstream", function(a) if up then act(cat({ "fetch" }, a, { up }), fetched) end end },
      { "a", "All remotes", function(a) act(cat({ "fetch", "--all" }, a), fetched) end },
      { "e", "Elsewhere", function(a)
        pick("Fetch", S.data.remotes, function(r) act(cat({ "fetch" }, a, { r }), fetched) end)
      end },
    } },
    -- big repos: hourly prefetch + commit-graph, so the auto-fetch and log --graph stay instant
    { "Repo", { { "m", "Maintenance start", function() act({ "maintenance", "start" }, { msg = "Registering maintenance" }) end } } },
  } })
end

function P.remote()
  popup({ title = "Remote",
    args = { { "f", "-f", "Fetch after add" } },
    groups = { { "Remote", {
      { "a", "Add", function(a)
        input("Remote name: ", #S.data.remotes == 0 and "origin" or nil, function(n)
          input("URL: ", nil, function(u) act(cat({ "remote", "add" }, a, { n, u })) end)
        end)
      end },
      { "r", "Rename", function()
        pick("Rename remote", S.data.remotes, function(r) input("Rename " .. r .. " to: ", r, function(n) act({ "remote", "rename", r, n }) end) end)
      end },
      { "u", "Set URL", function()
        if #S.data.remotes == 0 then -- no remote yet: set-url means "add origin"
          return input("URL for origin: ", nil, function(u) act({ "remote", "add", "origin", u }) end)
        end
        pick("Remote", S.data.remotes, function(r) input("URL: ", nil, function(u) act({ "remote", "set-url", r, u }) end) end)
      end },
      { "x", "Remove", function()
        pick("Remove remote", S.data.remotes, function(r) if confirm("Remove remote " .. r .. "?") then act({ "remote", "remove", r }) end end)
      end },
    } } } })
end

function P.merge()
  fetch_bg()
  local function go(extra)
    return function(a)
      fetch_bg(function()
        refs({ "refs/heads", "refs/remotes" }, function(l) pick("Merge", l, function(b) act(cat({ "merge" }, extra, a, { b })) end) end)
      end)
    end
  end
  popup({ title = "Merge",
    args = { { "f", "--ff-only", "Fast-forward only" }, { "n", "--no-ff", "No fast-forward" } },
    groups = state().merge and {
      { "Actions", { { "m", "Commit merge", function() act({ "commit", "--no-edit" }) end }, { "a", "Abort", function() act({ "merge", "--abort" }) end } } },
    } or {
      { "Actions", {
        { "m", "Merge", go({ "--no-edit" }) },
        { "e", "Merge, edit message", go({ "--edit", "--no-ff" }) },
        { "n", "Merge, don't commit", go({ "--no-commit", "--no-ff" }) },
        { "s", "Squash merge", go({ "--squash" }) },
      } },
    } })
end

-- pull, then show what came in as the commit view's file summary (+/−, za expands one)
-- instead of git's diffstat; nothing new (or an unborn HEAD) keeps git's own message
local function pull(args)
  git({ "rev-parse", "-q", "--verify", "HEAD" }, nil, function(h)
    local old = h.code == 0 and vim.trim(h.stdout or "") or nil
    act(args, { msg = "Pulling", after = function(r)
      git({ "rev-parse", "-q", "--verify", "HEAD" }, nil, function(n)
        local new = n.code == 0 and vim.trim(n.stdout or "") or nil
        if old and new and old ~= new then
          notify(("pulled %s..%s"):format(old:sub(1, 7), new:sub(1, 7)))
          return show(old:sub(1, 7) .. ".." .. new:sub(1, 7), { diff = { "git", "diff", old, new }, summary = true })
        end
        local out = vim.trim((r.stdout or "") .. "\n" .. (r.stderr or ""))
        if out ~= "" then output(out) end
      end)
    end })
  end)
end

function P.pull()
  fetch_bg()
  local up = S.data and S.data.st.upstream
  local function elsewhere(a)
    refs({ "refs/remotes" }, function(l)
      pick("Pull from", l, function(b)
        local r, br = b:match("^([^/]+)/(.+)$")
        pull(cat({ "pull" }, a, { r, br }))
      end)
    end)
  end
  popup({ title = "Pull",
    args = { { "r", "--rebase", "Rebase local commits" }, { "f", "--ff-only", "Fast-forward only" }, { "a", "--autostash", "Autostash" } },
    groups = { { "Pull into " .. (S.data and S.data.st.head or "HEAD") .. " from", {
      { "p", up or "upstream (pick)", function(a)
        fetch_bg(function()
          if up then pull(cat({ "pull" }, a)) else elsewhere(a) end
        end)
      end },
      { "e", "Elsewhere", function(a) fetch_bg(function() elsewhere(a) end) end },
    } } } })
end

-- --force, or a lease onto a shared branch, asks first
local function push_ok(a, target)
  local force, lease = vim.tbl_contains(a, "--force"), vim.tbl_contains(a, "--force-with-lease")
  local shared = (target or ""):match("[/:]?main$") or (target or ""):match("master$") or (target or ""):match("develop$")
  if force then return confirm("Force push to " .. (target or "remote") .. "? This overwrites remote commits.") end
  if lease and shared then return confirm("Force (lease) push to shared branch " .. target .. "?") end
  return true
end

function P.push()
  fetch_bg()
  local d = S.data or { st = {} }
  local function tags(cb) git({ "tag", "--sort=-creatordate" }, nil, function(r) pick("Tag", lines(r.stdout), cb) end) end
  popup({ title = "Push",
    args = { { "f", "--force-with-lease", "Force with lease" }, { "F", "--force", "Force" },
      { "u", "--set-upstream", "Set upstream" }, { "h", "--no-verify", "Disable hooks" }, { "n", "--dry-run", "Dry run" } },
    groups = {
      { "Push " .. (d.st.head or "HEAD") .. " to", {
        { "p", d.push or d.st.upstream or "remote (sets upstream)", function(a)
          fetch_bg(function()
            if not push_ok(a, d.push or d.st.upstream) then return end
            local function pushed() S.pr_at = {} end
            if d.st.upstream then return act(cat({ "push" }, a), { msg = "Pushing", show = true, after = pushed }) end
            remote(function(r) act(cat({ "push", "-u" }, a, { r, "HEAD" }), { msg = "Pushing", show = true, after = pushed }) end)
          end)
        end },
        { "e", "Elsewhere", function(a)
          fetch_bg(function()
            refs({ "refs/remotes" }, function(l)
              pick("Push to", l, function(b)
                local r, br = b:match("^([^/]+)/(.+)$")
                if push_ok(a, b) then act(cat({ "push" }, a, { r, "HEAD:refs/heads/" .. br }), { msg = "Pushing", show = true }) end
              end)
            end)
          end)
        end },
      } },
      { "Push", {
        { "t", "All tags", function(a) remote(function(r) act(cat({ "push" }, a, { r, "--tags" }), { msg = "Pushing tags", show = true }) end) end },
        { "T", "A tag", function(a)
          tags(function(t) remote(function(r) act(cat({ "push" }, a, { r, "refs/tags/" .. t }), { msg = "Pushing " .. t, show = true }) end) end)
        end },
      } },
    } })
end

function P.rebase()
  local up = S.data and S.data.st.upstream
  popup({ title = "Rebase",
    args = { { "a", "--autostash", "Autostash" }, { "k", "--keep-empty", "Keep empty commits" } },
    groups = state().rebase and {
      { "Actions", {
        { "r", "Continue", function() act({ "rebase", "--continue" }) end },
        { "s", "Skip", function() act({ "rebase", "--skip" }) end },
        { "e", "Edit todo", function() act({ "rebase", "--edit-todo" }) end },
        { "a", "Abort", function() act({ "rebase", "--abort" }) end },
      } },
    } or {
      { "Rebase " .. (S.data and S.data.st.head or "HEAD") .. " onto", {
        { "u", up or "upstream", function(a) if up then act(cat({ "rebase" }, a, { up })) end end },
        { "e", "Elsewhere", function(a)
          refs({ "refs/heads", "refs/remotes" }, function(l) pick("Rebase onto", l, function(b) act(cat({ "rebase" }, a, { b })) end) end)
        end },
      } },
      { "Rebase", {
        { "i", "Interactively", function(a, ctx)
          commits(ctx, function(cs) base_of(cs[1], function(base) act(cat({ "rebase", "-i" }, a, { base })) end) end)
        end },
        { "f", "Autosquash", function(a, ctx)
          commits(ctx, function(cs) base_of(cs[1], function(base) act(cat({ "rebase", "-i", "--autosquash" }, a, { base })) end) end)
        end },
      } },
    } })
end

function P.tag()
  fetch_bg()
  popup({ title = "Tag",
    args = { { "a", "--annotate", "Annotate (opens editor)" }, { "f", "--force", "Force" } },
    groups = { { "Tag", {
      { "t", "Create", function(a, ctx)
        input("Tag name: ", nil, function(n) act(cat({ "tag" }, a, { n, ctx.commit })) end)
      end },
      { "x", "Delete", function()
        fetch_bg(function()
          git({ "tag", "--sort=-creatordate" }, nil, function(r)
            pick("Delete tag", lines(r.stdout), function(t)
              act({ "tag", "-d", t }, { after = function()
                remote(function(rm)
                  if confirm("Also delete " .. t .. " on " .. rm .. "?") then act({ "push", rm, ":refs/tags/" .. t }, { msg = "Deleting remote tag" }) end
                end)
              end })
            end)
          end)
        end)
      end },
    } } } })
end

function P.log()
  local f = "--format=" .. LOGFMT
  popup({ title = "Log", groups = { { "Log", {
    { "l", "Current branch", function() log_view({ "log", "--graph", "-n", "256", f }, "log") end },
    { "a", "All branches", function() log_view({ "log", "--graph", "--all", "-n", "256", f }, "log --all") end },
    -- the file under the cursor, else the buffer the status was opened from; --follow keeps history across renames
    { "f", "Current file", function(_, ctx)
      local path = ctx.item and ctx.item.file and ctx.item.file.path
      if not path and S.prev and vim.api.nvim_buf_is_valid(S.prev) then
        local name = vim.api.nvim_buf_get_name(S.prev)
        if vim.startswith(name, S.root .. "/") then path = name:sub(#S.root + 2) end
      end
      if not path then return notify("log: no file under cursor or in the previous buffer", vim.log.levels.WARN) end
      log_view({ "log", "--follow", "-n", "256", f, "--", path }, "log " .. path, path)
    end },
    -- every place HEAD has been: the undo list for rebase/reset/amend. %gs = what moved it,
    -- %gd with --date=unix = when it moved (not the commit's date); no author, it's always you
    { "r", "Reflog (undo)", function()
      log_view({ "reflog", "-n", "256", "--date=unix", "--format=%h%x1f%x1f%gs%x1f%x1f%gd" }, "reflog")
    end },
  } } } })
end

function P.reset()
  local function go(mode)
    return function(_, ctx)
      local function run(c)
        if mode ~= "--hard" then return act({ "reset", mode, c }) end
        if not confirm("Hard reset to " .. c .. "? Uncommitted changes go to a backup stash.") then return end
        backup(function() act({ "reset", "--hard", c }) end)
      end
      if ctx.commit then run(ctx.commit) else input("Reset to: ", "HEAD", run) end
    end
  end
  popup({ title = "Reset", groups = { { "Reset HEAD to commit at cursor", {
    { "s", "Soft (keep changes staged)", go("--soft") },
    { "m", "Mixed (keep changes unstaged)", go("--mixed") },
    { "k", "Keep (refuse if it would lose changes)", go("--keep") },
    { "h", "Hard (backup stash first)", go("--hard") },
  } } } })
end

function P.stash()
  local function target(ctx, cb)
    if ctx.item and ctx.item.stash then return cb(ctx.item.stash) end
    local list = {}
    for _, z in ipairs(S.data and S.data.stashes or {}) do list[#list + 1] = z.ref .. " " .. z.subject end
    pick("Stash", list, function(c) cb(c:match("^%S+")) end)
  end
  popup({ title = "Stash",
    args = { { "u", "--include-untracked", "Include untracked files" }, { "k", "--keep-index", "Keep staged changes" } },
    groups = {
      { "Stash", {
        { "z", "Both", function(a) act(cat({ "stash", "push" }, a)) end },
        { "i", "Index only", function() act({ "stash", "push", "--staged" }) end },
        { "m", "With message", function(a) input("Stash message: ", nil, function(m) act(cat({ "stash", "push" }, a, { "-m", m })) end) end },
      } },
      { "Use", {
        { "p", "Pop", function(_, ctx) target(ctx, function(z) act({ "stash", "pop", "--index", z }) end) end },
        { "a", "Apply", function(_, ctx) target(ctx, function(z) act({ "stash", "apply", "--index", z }) end) end },
        { "d", "Drop", function(_, ctx) target(ctx, function(z) if confirm("Drop " .. z .. "?") then act({ "stash", "drop", z }) end end) end },
        -- new branch at the commit the stash was made on, so it applies cleanly; drops the stash on success
        { "b", "Branch", function(_, ctx)
          target(ctx, function(z) input("Branch name: ", nil, function(n) act({ "stash", "branch", n, z }) end) end)
        end },
      } },
    } })
end

function P.pr()
  popup({ title = "PRs", groups = {
    { "Pull request", {
      { "p", "Status", PR.status },
      { "l", "List", PR.list },
      { "o", "Open + copy URL", PR.open },
    } },
    { "Review", {
      { "c", "Checkout", PR.checkout },
      { "d", "Diff", PR.diff },
      { "k", "Checks / CI log", PR.checks },
    } },
    { "Do", {
      { "n", "Create (reviewer)", PR.create },
      { "x", "Close", PR.close },
    } },
  } })
end

function P.diff()
  local function range(r) show(r, { diff = cat({ "git", "diff" }, vim.split(r, "%s+", { trimempty = true })) }) end
  popup({ title = "Diff", groups = { { "Diff", {
    { "b", "Branch vs base", function() find_base(function(b) range(b .. "...HEAD") end) end },
    { "r", "Branch vs ref", function()
      refs({ "refs/heads", "refs/remotes" }, function(l) pick("Diff against", l, function(b) range(b .. "...HEAD") end) end)
    end },
    { "c", "Range", function(_, ctx) input("Diff range: ", ctx.commit and (ctx.commit .. "..HEAD") or nil, range) end },
  } } } })
end

---------------------------------------------------------------- keys

local function close()
  if S.prev and S.prev ~= S.buf and vim.api.nvim_buf_is_valid(S.prev) then
    vim.api.nvim_win_set_buf(0, S.prev)
  else
    vim.cmd.enew()
  end
end

local function with(fn) return function() fn(context()) end end
-- header lines (Head/Merge/Push/PR) and blanks carry no item: the key does nothing there, like s
local function on_item(fn) return function() if (S.rows[S.buf] or {})[vim.fn.line(".")] then fn() end end end

local KEYS
-- the default keys simple mode keeps; any other action can still be bound through C.mappings
local SIMPLE = { commit = true, branch = true, fetch = true, pull = true, push = true, log = true, stash = true,
  stage = true, stage_all = true, stage_unstaged = true, unstage = true, unstage_all = true, discard = true,
  diff = true, merge_mode = true, refresh = true, ["goto"] = true, toggle_fold = true, open_fold = true,
  close_fold = true, open_all = true, close_all = true, help = true, close = true }

-- KEYS with C.mappings applied: { key = false } drops a key, { key = "action" } binds it (replacing its default)
local function bindings()
  if BIND then return BIND end
  local map, by = C.mappings or {}, {}
  BIND = {}
  for gi, g in ipairs(KEYS) do
    local list = {}
    for _, k in ipairs(g[2]) do
      by[k[2]] = gi
      if map[k[1]] == nil and (not C.simple or SIMPLE[k[2]]) then list[#list + 1] = k end
    end
    BIND[gi] = { g[1], list }
  end
  local keys = vim.tbl_keys(map)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local name = map[key]
    local gi = by[name]
    if gi then
      for _, k in ipairs(KEYS[gi][2]) do
        if k[2] == name then table.insert(BIND[gi][2], { key, k[2], k[3], k[4], k[5] }) end
      end
    elseif name ~= false then
      notify(("mappings: %q has unknown action %q (see :h petal-actions)"):format(key, tostring(name)), vim.log.levels.WARN)
    end
  end
  return BIND
end

local function help()
  local groups = {}
  for _, g in ipairs(bindings()) do
    local acts = {}
    for _, k in ipairs(g[2]) do acts[#acts + 1] = { k[1], k[3], function() k[4]() end } end
    groups[#groups + 1] = { g[1], acts }
  end
  popup({ title = "Help", groups = groups })
end

-- { key, action, desc, fn, visual? }
KEYS = {
  { "Commands", {
    { "$", "history", "History", history }, { "A", "cherry_pick", "Cherry Pick", P.cherry, true },
    { "b", "branch", "Branch", P.branch }, { "B", "bisect", "Bisect", P.bisect }, { "c", "commit", "Commit", P.commit },
    { "D", "diff_range", "Diff (branch/range)", P.diff }, { "f", "fetch", "Fetch", P.fetch },
    { "l", "log", "Log / reflog", P.log }, { "M", "remote", "Remote", P.remote }, { "m", "merge", "Merge", P.merge },
  } },
  { "", {
    { "O", "pr", "PRs", P.pr }, { "p", "pull", "Pull", P.pull }, { "P", "push", "Push", P.push },
    { "Q", "command", "Command", M.command }, { "r", "rebase", "Rebase", P.rebase }, { "t", "tag", "Tag", P.tag },
    { "v", "revert", "Revert", P.revert, true }, { "X", "reset", "Reset", P.reset }, { "Z", "stash", "Stash", P.stash },
  } },
  { "Applying changes", {
    { "<c-s>", "stage_all", "Stage all", function() act({ "add", "-A" }) end },
    { "K", "untrack", "Untrack", with(untrack), true },
    { "s", "stage", "Stage", with(stage), true },
    { "S", "stage_unstaged", "Stage unstaged", function() act({ "add", "-u" }) end },
    { "u", "unstage", "Unstage", with(unstage), true }, { "U", "unstage_all", "Unstage all", unstage_all },
    { "x", "discard", "Discard", with(discard), true },
    { "a", "absorb", "Absorb staged into unpushed commits", on_item(absorb) },
    { "o", "move_hunk", "Move hunk to another commit (in a commit view)", function()
      notify("move: open a commit (<cr> on it), then o on a hunk or file", vim.log.levels.WARN)
    end },
    { "d", "diff", "Diff mode (against HEAD)", on_item(vimdiff) }, { "e", "merge_mode", "Merge mode (conflict)", on_item(merge_mode) },
  } },
  { "Essential commands", {
    { "<c-r>", "refresh", "Refresh", M.refresh }, { "<cr>", "goto", "Go to file", goto_item },
    { "za", "toggle_fold", "Toggle fold", function() fold("a") end },
    { "zo", "open_fold", "Open fold", function() fold("o") end },
    { "zc", "close_fold", "Close fold", function() fold("c") end },
    { "zR", "open_all", "Open all", function() fold_all(true) end },
    { "zM", "close_all", "Close all", function() fold_all(false) end },
    { "?", "help", "Help", help }, { "q", "close", "Close", close },
  } },
}

-- log/show views get the commands + goto/help (applying keys mean nothing there);
-- over[action] = fn replaces that action's fn and maps it there too
function M.maps(buf, log, over)
  over = over or {}
  for gi, g in ipairs(bindings()) do
    for _, k in ipairs(g[2]) do
      if not log or gi <= 2 or over[k[2]] or k[2] == "goto" or k[2] == "help" then
        vim.keymap.set(k[5] and { "n", "x" } or "n", k[1], over[k[2]] or k[4], { buffer = buf, nowait = true, desc = k[3] })
      end
    end
  end
end

---------------------------------------------------------------- watch

-- refresh on changes made outside nvim (another terminal, an agent, a git GUI). libuv fs_event is not
-- recursive on Linux, so every directory holding a tracked or untracked file gets its own watch, plus
-- the git dir (index, HEAD) and refs. Status runs with --no-optional-locks, so a refresh doesn't
-- rewrite the index and trigger itself
local WATCH_MAX = 1000 -- dirs; past this (huge monorepo) only the git dir is watched
local WATCH_DELAY = 300 -- ms: a burst of writes (checkout, :wa, a build) becomes one refresh
local watch_sync
local watch_timer, watch_at, watch_dirs = nil, 0, false

local function unwatch(dir)
  local h = S.watch[dir]
  if h and not h:is_closing() then h:stop() h:close() end
  S.watch[dir] = nil
end
local function unwatch_all() for dir in pairs(S.watch) do unwatch(dir) end end

-- only a directory appearing or going away changes what is watched: a plain edit ("change", or a
-- "rename" of a file) skips watch_sync's ls-files, which walks every untracked dir of the worktree
local function changes_dirs(dir, name, events)
  if not (events and events.rename) then return false end
  if dir == S.gitdir or dir:sub(1, #S.gitdir + 1) == S.gitdir .. "/" then return false end
  local st = name and vim.uv.fs_stat(dir .. "/" .. name)
  return not st or st.type == "directory" -- gone: may have been a directory
end

local function on_change(dir, name, events)
  if not S.watch[dir] then return end -- queued before an unwatch (repo switched, dir gone)
  if name and name:match("%.lock$") then return end -- git's lock dance: the rename to the real name follows
  watch_dirs = watch_dirs or changes_dirs(dir, name, events)
  -- the latest event, not the first: a refresh that started mid-burst may predate the later writes.
  -- hrtime, not uv.now(): that is the loop's cached time, a refresh started earlier can share it
  watch_at = vim.uv.hrtime()
  if watch_timer then return end
  watch_timer = vim.defer_fn(function()
    watch_timer = nil
    local at = watch_at
    if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return unwatch_all() end
    if vim.fn.bufwinid(S.buf) == -1 then return end -- hidden: BufWinEnter refreshes on the way back
    if watch_dirs then watch_dirs = false; watch_sync() end -- new directories, deleted ones
    if S.refreshed < at then M.refresh() end -- our own action (or :w) already refreshed after it
  end, WATCH_DELAY)
end

local function watch(dir)
  if S.watch[dir] then return end
  local h = vim.uv.new_fs_event()
  if not h then return end
  local ok = h:start(dir, {}, function(err, name, events)
    if not err then vim.schedule(function() on_change(dir, name, events) end) end
  end)
  if ok then S.watch[dir] = h else h:close() end -- ENOSPC (inotify limit) or a dir gone already
end

function watch_sync()
  if not C.watch or C.simple or not S.root then return unwatch_all() end
  local root, gitdir = S.root, S.gitdir
  git({ "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--directory" }, nil, function(r)
    if root ~= S.root or r.code ~= 0 then return end
    local want = { [gitdir] = true, [gitdir .. "/refs"] = true, [gitdir .. "/refs/heads"] = true, [root] = true }
    local n = 0
    local out, i, prev = r.stdout or "", 1, nil
    local seen = {}
    -- byte scan, no split/match per path (30k paths: 22ms -> 2ms); ls-files is sorted, so a path in
    -- the same dir as the one before is skipped outright
    while n < WATCH_MAX do
      local j = out:find("\0", i, true)
      if not j then break end
      local k = j - 1 -- dir = up to the last "/" ("dir/" is an untracked dir: watch it)
      if out:byte(k) ~= 47 then
        k = k - 1
        while k >= i and out:byte(k) ~= 47 do k = k - 1 end
      end
      local dir = k >= i and out:sub(i, k - 1) or nil
      i = j + 1
      if dir ~= prev then
        prev = dir
        while dir and n < WATCH_MAX do
          if seen[dir] then break end
          seen[dir] = true
          local abs = root .. "/" .. dir
          if want[abs] then break end
          want[abs], n = true, n + 1
          dir = dir:match("^(.*)/[^/]*$")
        end
      end
    end
    if n >= WATCH_MAX then want = { [gitdir] = true, [gitdir .. "/refs"] = true, [gitdir .. "/refs/heads"] = true } end
    for dir in pairs(S.watch) do if not want[dir] then unwatch(dir) end end
    for dir in pairs(want) do watch(dir) end
  end)
end

---------------------------------------------------------------- open / editor

-- cwd -> { root, gitdir }: reopening skips rev-parse's blocking spawn while its answer still holds
-- (git dir still there, no repo made between cwd and root since). GIT_DIR/GIT_WORK_TREE: always ask
local ROOTS = {}
local function cached_root(cwd)
  local c = ROOTS[cwd]
  if not c or vim.env.GIT_DIR or vim.env.GIT_WORK_TREE then return end
  local root, gitdir = c[1], c[2]
  if not (vim.uv.fs_stat(gitdir .. "/HEAD") and vim.uv.fs_stat(root .. "/.git")) then return end
  local d = cwd
  while d ~= root do
    if vim.uv.fs_stat(d .. "/.git") then return end
    local up = vim.fs.dirname(d)
    if up == d then return end
    d = up
  end
  return root, gitdir
end

-- ~ is a dotfiles repo: a non-repo subdir must not fall back to it, offer git init instead
function M.open()
  local cwd, home = vim.uv.cwd(), vim.uv.os_homedir()
  local root, gitdir = cached_root(cwd)
  if not root then
    local r = vim.system({ "git", "rev-parse", "--show-toplevel", "--absolute-git-dir" }, { cwd = cwd, text = true }):wait()
    root, gitdir = unpack(lines(r.stdout))
    if r.code ~= 0 or (root == home and cwd ~= home) then
      if not confirm("Not a git repo. git init in " .. cwd .. "?") then return end
      vim.system({ "git", "init", cwd }):wait()
      root, gitdir = cwd, cwd .. "/.git"
    else
      ROOTS[cwd] = { root, gitdir }
    end
  end
  local same = root == S.root
  if not same then
    S.open, S.diffs, S.data, S.fetch.at, S.base, S.radar_cache, S.stash_cache, S.raw_diff = {}, {}, nil, -math.huge, nil, {}, nil, {}
    unwatch_all()
  end
  S.root, S.gitdir = root, gitdir
  if not same then
    local common, h = gitdir, io.open(gitdir .. "/commondir")
    if h then
      local c = vim.trim(h:read("*a"))
      h:close()
      common = c:sub(1, 1) == "/" and c or (gitdir .. "/" .. c)
    end
    S.commondir = common
    S.reftable = vim.uv.fs_stat(common .. "/reftable") ~= nil
  end
  -- repo-wide attribute files: when one exists, untracked diffs go through git (attrs_may_apply).
  -- the lookup rides along with the next refresh's batch; until it answers untracked diffs take the
  -- (always right) git path
  if vim.uv.fs_stat(gitdir .. "/info/attributes") ~= nil then S.attrs, S.attrs_check = true, nil
  else S.attrs, S.attrs_check = true, true end
  S.pr_at = {} -- opening always rechecks the PR
  -- git's own cache file (what gc writes): ~1s once in the background, and later commits stay fast
  if S.graph_root ~= root and not has_commit_graph() then
    S.graph_root = root
    git({ "commit-graph", "write", "--reachable", "--no-progress" })
  end

  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then
    S.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(S.buf, "git://status")
    vim.bo[S.buf].filetype = "GitStatus"
    vim.bo[S.buf].modifiable = false
    M.maps(S.buf)
    -- BufWinEnter, not BufEnter: coming back from a popup/picker window is not a reason to refresh
    vim.api.nvim_create_autocmd("BufWinEnter", { buffer = S.buf, callback = function()
      vim.wo[0][0].number = true
      M.refresh()
    end })
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = S.buf, callback = unwatch_all })
    -- group cleared: a wiped and recreated status buffer must not stack another set of global handlers
    local aug, queued = vim.api.nvim_create_augroup("petal_status", { clear = true }), false
    local function visible() return S.buf and vim.fn.bufwinid(S.buf) ~= -1 end
    -- :wa fires BufWritePost once per buffer in one tick; queue a single refresh instead of 8 git processes each
    vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, { group = aug, callback = function()
      if queued or not visible() then return end
      queued = true
      vim.schedule(function() queued = false; if visible() then M.refresh() end end)
    end })
    -- subjects re-fit to the width; WinResized fires for any split anywhere, and a height change
    -- or another window's resize changes nothing here
    local width
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { group = aug, callback = function()
      local win = S.buf and vim.fn.bufwinid(S.buf) or -1
      if win == -1 then return end
      local w = text_width(win)
      if w ~= width then width = w; render() end
    end })
  end
  local cur = vim.api.nvim_get_current_buf()
  if cur ~= S.buf then
    S.prev = cur
    vim.api.nvim_win_set_buf(0, S.buf) -- BufWinEnter refreshes
  else
    M.refresh()
  end
  -- reopening the same repo: watchers are live and new dirs arrive as events (watch_dirs), so no
  -- repo-wide ls-files per open (it walks every untracked dir)
  if not (same and next(S.watch) and not watch_dirs) then watch_sync() end
  if not C.simple then fetch_bg() end
end

-- runs C.commit_suggest on the staged diff as soon as the commit buffer opens; the result shows as
-- ghost text while the message is empty, and the returned accept() writes it above the # comments
-- (if still running, it is written when it arrives)
local function suggest(buf, diff)
  local gns = vim.api.nvim_create_namespace("petal.suggest")
  local msg, want, job
  local tool = vim.fs.basename(C.commit_suggest[1]) -- "claude", "pi": who is thinking, not "git"
  local spin = progress("Commit", "suggesting message", tool)
  local function region() -- message lines = everything above the first # comment
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:match("^#") then return i - 1 end
    end
    return vim.api.nvim_buf_line_count(buf)
  end
  local function ghost()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, gns, 0, -1)
    local cur = vim.api.nvim_buf_get_lines(buf, 0, region(), false)
    if not msg or vim.trim(table.concat(cur, "")) ~= "" then return end
    local rest = {}
    for k = 2, #msg do rest[#rest + 1] = { { msg[k], "Comment" } } end
    vim.api.nvim_buf_set_extmark(buf, gns, 0, 0, { virt_text = { { msg[1], "Comment" } }, virt_text_pos = "inline",
      virt_lines = #rest > 0 and rest or nil })
  end
  local function accept(commit)
    if not msg then
      want = commit and "commit" or true
      return notify(job and "suggest: still thinking, it goes in when ready" or "suggest: no suggestion")
    end
    local stop = region()
    if commit and vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, stop, false), "")) ~= "" then
      return notify("suggest: message already written, <c-c><c-c> commits it", vim.log.levels.WARN) -- never overwrite typed text
    end
    vim.api.nvim_buf_clear_namespace(buf, gns, 0, -1)
    vim.api.nvim_buf_set_lines(buf, 0, stop, false, stop < vim.api.nvim_buf_line_count(buf) and cat(msg, { "" }) or msg)
    if commit then return vim.cmd("stopinsert | write | bwipeout") end
    vim.api.nvim_win_set_cursor(0, { 1, #msg[1] })
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = ghost })
  vim.api.nvim_create_autocmd("BufUnload", { buffer = buf, once = true, callback = function()
    if job then pcall(job.kill, job, 15) end -- closed before the agent answered: don't leave it running
  end })
  git(nil, { raw = diff }, function(d)
    if vim.trim(d.stdout or "") == "" then return spin("nothing staged") end
    job = vim.system(C.commit_suggest, { stdin = d.stdout, text = true, cwd = S.root }, vim.schedule_wrap(function(r)
      job = nil
      if not vim.api.nvim_buf_is_valid(buf) then return spin("cancelled") end
      if r.code ~= 0 then return fail(tool, r, spin) end
      msg = lines(vim.trim((r.stdout or ""):gsub("^%s*```%w*\n", ""):gsub("\n```%s*$", ""))) -- models like fences
      if #msg == 0 then msg = nil return spin("empty suggestion") end
      spin("ready: <c-c><c-s> accepts, <c-c><c-y> commits")
      if want and vim.api.nvim_get_current_buf() == buf then accept(want == "commit") else ghost() end
    end))
  end)
  return accept
end

-- called by $GIT_EDITOR over RPC: edit the file here; closing the buffer lets git continue.
-- closed without :w (or <c-c><c-k>) -> the file is emptied, which makes git abort
function M.edit(path, index, amend)
  vim.schedule(function()
    local win = S.buf and vim.fn.bufwinid(S.buf) or -1
    if win ~= -1 then vim.api.nvim_set_current_win(win) end
    local below, under = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    -- split, so :wq closes just the editor and lands back on the status
    vim.cmd("aboveleft split " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].bufhidden = "wipe"
    local is_commit = path:match("COMMIT_EDITMSG$")
    local diff
    if is_commit then
      -- amending: diff against HEAD^, or the empty tree when HEAD is the root commit. Resolved inside
      -- the (async) diff process, not with two blocking git calls before the editor shows
      local env = index and index ~= "" and { "env", "GIT_INDEX_FILE=" .. index } or {}
      diff = amend and cat(env, { "sh", "-c", 'git diff --cached "$(git rev-parse -q --verify HEAD^ || git hash-object -t tree /dev/null)"' })
        or cat(env, { "git", "diff", "--cached" })
    end
    -- the changes being committed go in the window below: a summary of the files (+/−), za expands one
    if diff and not C.simple then show("to commit", { diff = diff, win = below, summary = true }) end
    local written = false
    vim.api.nvim_create_autocmd("BufWritePost", { buffer = buf, callback = function() written = true end })
    vim.api.nvim_create_autocmd("BufUnload", { buffer = buf, once = true, callback = function()
      if diff and vim.api.nvim_win_is_valid(below) then
        local b = vim.api.nvim_win_get_buf(below)
        if vim.api.nvim_buf_get_name(b):match("git://diff to commit$") then
          if vim.api.nvim_buf_is_valid(under) then vim.api.nvim_win_set_buf(below, under) end
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
      if not written then
        local f = io.open(path, "w")
        if f then f:close() end
      end
      os.remove(path .. ".nvlock")
    end })
    local o = { buffer = buf }
    vim.keymap.set({ "n", "i" }, "<c-c><c-c>", function() vim.cmd("stopinsert | write | bwipeout") end, o)
    vim.keymap.set({ "n", "i" }, "<c-c><c-k>", function() written = false; vim.cmd("stopinsert | bwipeout!") end, o)
    if C.commit_suggest and is_commit then
      local accept = suggest(buf, diff)
      vim.keymap.set({ "n", "i" }, "<c-c><c-s>", function() accept() end, vim.tbl_extend("force", o, { desc = "Accept suggested commit message" }))
      vim.keymap.set({ "n", "i" }, "<c-c><c-y>", function() accept(true) end, vim.tbl_extend("force", o, { desc = "Commit with the suggested message" }))
    end
    if vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then vim.cmd.startinsert() end
  end)
end

-- for tests and :checkhealth
M._t = {
  config = function() return C end,
  actions = function()
    local t = {}
    for _, g in ipairs(KEYS) do for _, k in ipairs(g[2]) do t[k[2]] = true end end
    return t
  end,
  bindings = bindings, parse_status = parse_status, parse_diff = parse_diff, split_diff = split_diff, parse_merge_tree = parse_merge_tree, git_batch = git_batch, paint = paint, ns = ns, untracked_diff = untracked_diff, hunk_owner = hunk_owner, parse_conflicts = parse_conflicts,
  parse_files = parse_files, split_diff_raw = split_diff_raw, patch = patch, branch_plan = branch_plan, branches = branches, remote_unsafe = remote_unsafe, kind_of = kind_of, ci_summary = ci_summary, failure = failure, cut = cut, refchunks = refchunks, show = show, S = S,
}

return M
