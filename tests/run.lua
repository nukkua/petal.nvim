-- nvim -l tests/run.lua  (from the repo root)
vim.opt.rtp:prepend(vim.fn.getcwd())
local petal = require("petal")
local t = petal._t

local fails, n = 0, 0
local function test(name, fn)
  n = n + 1
  local ok, err = pcall(fn)
  if not ok then
    fails = fails + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
end
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then error((msg or "") .. "\n  expected: " .. vim.inspect(b) .. "\n  got: " .. vim.inspect(a), 2) end
end

-- throwaway repo; -c keeps the user's signing/hooks config out of it
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function git(args, stdin)
  local r = vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
    "-c", "core.hooksPath=/dev/null" }, args), { cwd = dir, text = true, stdin = stdin }):wait()
  assert(r.code == 0, table.concat(args, " ") .. ": " .. (r.stderr or ""))
  return r.stdout
end
local function write(name, lines) vim.fn.writefile(lines, dir .. "/" .. name) end

test("setup(): the core loads on first use, options set before it merge", function()
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    "vim.opt.rtp:prepend(" .. string.format("%q", vim.fn.getcwd()) .. ")",
    "local petal = require('petal')",
    "petal.setup({ recent = 3 })",
    "petal.setup({ height = 5 })",
    "print('loaded after setup: ' .. tostring(package.loaded['petal.core'] ~= nil))",
    "local C = petal._t.config()",
    "print('recent: ' .. C.recent .. ' height: ' .. C.height)",
    "print('loaded after use: ' .. tostring(package.loaded['petal.core'] ~= nil))",
  }, script)
  local r = vim.system({ vim.v.progpath, "--clean", "--headless", "-l", script }, { text = true }):wait()
  eq(r.code, 0, (r.stderr or "") .. (r.stdout or ""))
  local out = (r.stdout or "") .. (r.stderr or "") -- headless print goes to stderr
  assert(out:find("loaded after setup: false", 1, true), out)
  assert(out:find("recent: 3 height: 5", 1, true), out)
  assert(out:find("loaded after use: true", 1, true), out)
end)

---------------------------------------------------------------- parsers

test("parse_status", function()
  local out = table.concat({
    "# branch.oid abc123", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +1 -2",
    "1 MM N... 100644 100644 100644 aaa bbb a file.txt",
    "1 A. N... 000000 100644 100644 000 ccc new.lua",
    "2 R. N... 100644 100644 100644 ddd ddd R100 to.lua", "from.lua",
    "u UU N... 100644 100644 100644 100644 e1 e2 e3 conflict.lua",
    "? untracked dir/",
    "",
  }, "\0")
  local st = t.parse_status(out)
  eq(st.head, "main")
  eq(st.upstream, "origin/main")
  eq(st.oid, "abc123")
  eq(st.untracked, { { section = "untracked", path = "untracked dir/", mode = "?" } })
  eq(st.staged, {
    { section = "staged", path = "a file.txt", mode = "M" },
    { section = "staged", path = "new.lua", mode = "A" },
    { section = "staged", path = "to.lua", mode = "R", orig = "from.lua" },
  })
  eq(st.unstaged, {
    { section = "unstaged", path = "a file.txt", mode = "M" },
    { section = "unstaged", path = "conflict.lua", mode = "U" },
  })
end)

test("parse_diff", function()
  local d = t.parse_diff(table.concat({
    "diff --git a/x b/x", "index 1..2 100644", "--- a/x", "+++ b/x",
    "@@ -1,2 +1,2 @@", "-a", "+b", " c",
    "@@ -10 +10,2 @@ fn()", " d", "+e",
  }, "\n"))
  eq(#d.header, 4)
  eq(#d.hunks, 2)
  eq(d.hunks[1].new, 1)
  eq(d.hunks[2].new, 10)
  eq(d.hunks[2].header, "@@ -10 +10,2 @@ fn()")
  eq(d.hunks[1].lines, { "-a", "+b", " c" })
end)

test("parse_conflicts", function()
  write("conf.txt", { "top", "<<<<<<< HEAD", "ours", "||||||| base", "base", "=======", "theirs", "t2", ">>>>>>> other",
    "mid", "<<<<<<< HEAD", "=======", "only theirs", ">>>>>>> other" })
  local cs = t.parse_conflicts(dir .. "/conf.txt")
  eq(#cs, 2)
  eq(cs[1], { line = 2, ours = { "ours" }, base = { "base" }, theirs = { "theirs", "t2" } })
  eq(cs[2], { line = 11, ours = {}, base = {}, theirs = { "only theirs" } })
  eq(t.parse_conflicts(dir .. "/missing"), {})

  local h = assert(io.open(dir .. "/conf-empty.txt", "wb")) -- empty lines everywhere, no trailing newline
  h:write("\n<<<<<<< HEAD\n\nours\n=======\n\ntheirs\n>>>>>>> other")
  h:close()
  eq(t.parse_conflicts(dir .. "/conf-empty.txt"), {
    { line = 2, ours = { "", "ours" }, base = {}, theirs = { "", "theirs" } },
  })
  h = assert(io.open(dir .. "/conf-crlf.txt", "wb")) -- CRLF content; git's own marker lines end in LF
  h:write("top\r\n<<<<<<< HEAD\nours\r\n=======\ntheirs\r\n>>>>>>> other\n")
  h:close()
  eq(t.parse_conflicts(dir .. "/conf-crlf.txt"), {
    { line = 2, ours = { "ours\r" }, base = {}, theirs = { "theirs\r" } },
  })
  h = assert(io.open(dir .. "/plain-crlf.txt", "wb")); h:write("a\r\nb\r\n"); h:close()
  eq(t.parse_conflicts(dir .. "/plain-crlf.txt"), {})
end)

test("parse_files", function()
  local fs = t.parse_files(table.concat({
    "diff --git a/old.lua b/new.lua", "similarity index 90%", "rename from old.lua", "rename to new.lua",
    "@@ -1 +1 @@", "-x", "+y",
    "diff --git a/add.txt b/add.txt", "new file mode 100644", "@@ -0,0 +1,2 @@", "+1", "+2",
    "diff --git a/img.png b/img.png", "Binary files a/img.png and b/img.png differ",
    "diff --git a/gone b/gone", "deleted file mode 100644", "@@ -1 +0,0 @@", "-z",
  }, "\n"))
  eq(#fs, 4)
  eq({ fs[1].path, fs[1].orig, fs[1].mode, fs[1].add, fs[1].del }, { "new.lua", "old.lua", "R", 1, 1 })
  eq({ fs[2].path, fs[2].orig, fs[2].mode, fs[2].add, fs[2].del }, { "add.txt", nil, "A", 2, 0 })
  eq({ fs[3].mode, fs[3].binary }, { "M", true })
  eq({ fs[4].mode, fs[4].del }, { "D", 1 })
end)

test("kind_of", function()
  eq({ t.kind_of("fix(api)!: drop v1") }, { "fix!", "(api) drop v1" })
  eq({ t.kind_of("Feat: x") }, { "feat", "x" })
  eq({ t.kind_of("Merge branch 'a' into b") }, { "merge", "a → b" })
  eq({ t.kind_of("Merge pull request #12 from me/x") }, { "merge", "#12 me/x" })
  eq({ t.kind_of("wip: not conventional") }, { nil, "wip: not conventional" })
end)

test("ci_summary", function()
  eq({ t.ci_summary({ { status = "COMPLETED", conclusion = "SUCCESS" } }) }, { "passing", "PrOpen" })
  eq({ t.ci_summary({ { status = "IN_PROGRESS" }, { status = "COMPLETED", conclusion = "SUCCESS" } }) }, { "1 running", "PrWarn" })
  eq({ t.ci_summary({ { status = "COMPLETED", conclusion = "FAILURE" }, { status = "IN_PROGRESS" } }) }, { "1 failing", "PrClosed" })
  eq({ t.ci_summary({ { state = "SUCCESS" } }) }, { "passing", "PrOpen" })
  eq({ t.ci_summary(vim.NIL) }, { "passing", "PrOpen" })
end)

---------------------------------------------------------------- patch: applied for real

git({ "init", "-q" })
write("f.txt", { "1", "2", "3", "4", "5" })
git({ "add", "f.txt" })
git({ "commit", "-q", "-m", "init" })

-- ctx for the hunk of `diff`, selecting hunk lines by index (nil = whole hunk, like s on the header)
local function ctx(diff, sel)
  local h = diff.hunks[1]
  local items = {}
  for _, i in ipairs(sel or {}) do items[#items + 1] = { diff = diff, hunk = h, idx = i } end
  return { item = items[1] or { diff = diff, hunk = h, idx = 0 }, items = items, visual = sel ~= nil }
end
local function apply(p, flags)
  git(vim.list_extend(vim.list_extend({ "apply", "--recount" }, flags), { "-" }), p)
end
local function staged() return vim.split(git({ "show", ":f.txt" }), "\n", { trimempty = true }) end

test("patch: whole hunk stages everything", function()
  write("f.txt", { "1", "two", "3", "4", "5", "6" })
  local d = t.parse_diff(git({ "diff", "--", "f.txt" }))
  apply(t.patch(ctx(d), false), { "--cached" })
  eq(staged(), { "1", "two", "3", "4", "5", "6" })
  git({ "reset", "-q" })
end)

test("patch: stage selected lines only", function()
  write("f.txt", { "1", "two", "3", "4", "5", "6" })
  local d = t.parse_diff(git({ "diff", "-U5", "--", "f.txt" }))
  local h = d.hunks[1].lines
  local plus2 = vim.fn.index(h, "+two") + 1
  apply(t.patch(ctx(d, { plus2 }), false), { "--cached" }) -- +two without -2: an insertion, 2 stays
  eq(staged(), { "1", "2", "two", "3", "4", "5" })
  git({ "reset", "-q" })
end)

test("patch: unstage selected lines (reverse)", function()
  write("f.txt", { "1", "two", "3", "4", "5", "6" })
  git({ "add", "f.txt" })
  local d = t.parse_diff(git({ "diff", "--cached", "-U5", "--", "f.txt" }))
  local six = vim.fn.index(d.hunks[1].lines, "+6") + 1
  apply(t.patch(ctx(d, { six }), true), { "--cached", "--reverse" })
  eq(staged(), { "1", "two", "3", "4", "5" })
  git({ "reset", "-q" })
end)

test("patch: no newline at end of file", function()
  vim.fn.writefile({ "1", "2", "3", "4", "5", "x" }, dir .. "/f.txt", "b") -- "b" without trailing "" = no final newline
  local d = t.parse_diff(git({ "diff", "--", "f.txt" }))
  assert(vim.tbl_contains(d.hunks[1].lines, "\\ No newline at end of file"), "fixture has no marker")
  apply(t.patch(ctx(d), false), { "--cached" })
  eq(git({ "show", ":f.txt" }), "1\n2\n3\n4\n5\nx")
  git({ "reset", "-q" })
  git({ "checkout", "--", "f.txt" })
end)

test("split_diff: batched diff matches per-file diffs", function()
  write("a b.txt", { "1" }); write("gone.txt", { "1" }); write("old.txt", { "1", "2", "3" })
  git({ "add", "." }); git({ "commit", "-qm", "split" })
  write("a b.txt", { "2" }); vim.fn.delete(dir .. "/gone.txt")
  git({ "mv", "old.txt", "new.txt" }); write("new.txt", { "1", "2", "3", "4" }); git({ "add", "new.txt" })
  local by = t.split_diff(git({ "diff", "--src-prefix=a/", "--dst-prefix=b/", "--" , "a b.txt", "gone.txt" }))
  for _, p in ipairs({ "a b.txt", "gone.txt" }) do
    eq(table.concat(by["diff --git a/" .. p .. " b/" .. p], "\n") .. "\n", git({ "diff", "--", p }), p)
  end
  by = t.split_diff(git({ "diff", "--cached", "--src-prefix=a/", "--dst-prefix=b/", "--", "new.txt", "old.txt" }))
  eq(table.concat(by["diff --git a/old.txt b/new.txt"], "\n") .. "\n", git({ "diff", "--cached", "--", "new.txt", "old.txt" }))
  git({ "reset", "-q", "--hard" })
end)

test("split_diff: parts of a whole diff that belong to no file glue onto nothing", function()
  local by = t.split_diff(table.concat({
    "diff --git a/a b/a", "index 1..2 100644", "--- a/a", "+++ b/a", "@@ -1 +1 @@", "-1", "+2",
    "* Unmerged path u",
    "diff --cc u", "index 1,2..3", "--- a/u", "+++ b/u", "@@@ -1 -1 +1 @@@", "++<<<<<<< HEAD",
    "Submodule s 1111111..2222222:", "  > subject",
    "diff --git a/b b/b", "index 1..2 100644", "--- a/b", "+++ b/b", "@@ -1 +1 @@", "-x", "+y",
  }, "\n"))
  eq(by["diff --git a/a b/a"], { "diff --git a/a b/a", "index 1..2 100644", "--- a/a", "+++ b/a", "@@ -1 +1 @@", "-1", "+2" })
  eq(by["diff --git a/b b/b"], { "diff --git a/b b/b", "index 1..2 100644", "--- a/b", "+++ b/b", "@@ -1 +1 @@", "-x", "+y" })
  eq(vim.tbl_count(by), 2)
end)

test("parse_merge_tree: conflicts, clean, missing ref", function()
  write("r.txt", { "base" }); git({ "add", "r.txt" }); git({ "commit", "-qm", "radar base" })
  git({ "switch", "-qc", "radar" }); write("r.txt", { "ours" }); git({ "commit", "-qam", "ours" })
  git({ "switch", "-q", "-" }); write("r.txt", { "theirs" }); git({ "commit", "-qam", "theirs" })
  local function mt(a, b)
    local r = vim.system({ "git", "merge-tree", "--write-tree", "--name-only", "--no-messages", a, b }, { cwd = dir, text = true }):wait()
    return t.parse_merge_tree(r)
  end
  eq(mt("radar", "HEAD"), { "r.txt" })
  eq(mt("radar", "radar~1"), nil) -- ancestor: clean
  eq(mt("radar", "nope"), nil)    -- exit 1 too, but no tree oid: not a conflict
  git({ "branch", "-qD", "radar" })
end)

test("hunk_owner: single unpushed owner or nothing", function()
  local owner, own = { "c1", "c1", "c2", "c2", "pushed" }, { c1 = 1, c2 = 2 }
  eq(t.hunk_owner("@@ -1,2 +1,2 @@", owner, own), "c1")      -- both replaced lines are c1's
  eq(t.hunk_owner("@@ -3 +3 @@", owner, own), "c2")          -- no count = 1 line
  eq(t.hunk_owner("@@ -2,2 +2,2 @@", owner, own), nil)       -- c1 and c2: ambiguous
  eq(t.hunk_owner("@@ -5 +5 @@", owner, own), nil)           -- pushed commit: never rewritten
  eq(t.hunk_owner("@@ -3,0 +4 @@", owner, own), "c2")        -- insert between c2 lines 3 and 4
  eq(t.hunk_owner("@@ -2,0 +3 @@", owner, own), nil)         -- insert between c1 and c2
  eq(t.hunk_owner("@@ -0,0 +1 @@", owner, own), "c1")        -- insert at the top: line 1 decides
end)

---------------------------------------------------------------- mappings

test("mappings: default, drop, add, rebind", function()
  petal.setup({ mappings = { x = false, ["<leader>x"] = "discard", s = "unstage" } })
  local keys = {}
  for _, g in ipairs(t.bindings()) do for _, k in ipairs(g[2]) do keys[k[1]] = k[2] end end
  eq(keys.x, nil)
  eq(keys["<leader>x"], "discard")
  eq(keys.s, "unstage")
  eq(keys.u, "unstage")
  eq(keys.c, "commit")
  petal.setup({ mappings = {} })
  keys = {}
  for _, g in ipairs(t.bindings()) do for _, k in ipairs(g[2]) do keys[k[1]] = k[2] end end
  eq(keys.x, "discard")
end)

test("simple: core keys only, mappings can add the rest back", function()
  local function keys()
    local t_ = {}
    for _, g in ipairs(t.bindings()) do for _, k in ipairs(g[2]) do t_[k[1]] = k[2] end end
    return t_
  end
  petal.setup({ simple = true })
  local k = keys()
  eq(k.c, "commit")
  eq(k.s, "stage")
  eq(k.P, "push")
  eq(k.O, nil)
  eq(k.a, nil)
  eq(k.r, nil)
  petal.setup({ simple = true, mappings = { r = "rebase" } })
  eq(keys().r, "rebase")
  petal.setup({ simple = false, mappings = {} })
  eq(keys().O, "pr")
end)

test("mappings: every action name is unique", function()
  local seen = {}
  for _, g in ipairs(t.bindings()) do
    for _, k in ipairs(g[2]) do
      assert(not seen[k[2]], "duplicate action " .. k[2])
      seen[k[2]] = true
    end
  end
end)

---------------------------------------------------------------- errors

test("refchunks: local+remote twins collapse, remote HEAD hidden", function()
  local function names(refs)
    local ch = {}
    t.refchunks(refs, ch, { origin = true })
    return vim.tbl_map(function(c) return c[1] end, vim.tbl_filter(function(c) return c[1] ~= " " end, ch))
  end
  eq(names("HEAD -> develop, origin/develop, origin/HEAD"), { "develop" })
  eq(names("origin/feat/x, feat/x"), { "feat/x" })
  eq(names("origin/feat/x"), { "origin/feat/x" }) -- not pushed/pulled: both matter
  eq(names("feat/x, tag: v1"), { "feat/x", "v1" })
end)

test("kind_of: own org dropped from PR merges, forks keep owner", function()
  local saved = t.S.data
  t.S.data = { owners = { klubomobi = true } }
  eq({ t.kind_of("Merge pull request #597 from KLUBOMOBI/payment-method") }, { "merge", "#597 payment-method" })
  eq({ t.kind_of("Merge pull request #5 from someone/fix/x") }, { "merge", "#5 someone/fix/x" })
  t.S.data = saved
  eq({ t.kind_of("Merge pull request #12 from me/x") }, { "merge", "#12 me/x" }) -- no remotes known
end)

test("cut: fits display width, wide chars included", function()
  eq(t.cut("nukkua", 16), "nukkua")
  eq(t.cut("María Fernanda Gutiérrez", 16), "María Fernanda …")
  eq(t.cut("日本語の名前", 6), "日本…") -- 2-cell chars: 4 cells + …
  eq(vim.api.nvim_strwidth(t.cut("日本語の名前", 7)) <= 7, true) -- odd width: never overflows
  eq(t.cut("abc", 0), "")
end)

test("failure: real git output -> short message + level", function()
  local W, E = vim.log.levels.WARN, vim.log.levels.ERROR
  local function f(cmd)
    local r = vim.system(cmd, { cwd = dir, text = true }):wait()
    assert(r.code ~= 0, table.concat(cmd, " ") .. " should fail")
    return { t.failure(r) }
  end
  eq(f({ "git", "switch", "-" }), { "no previous branch", W })
  eq(f({ "git", "stash", "pop" }), { "no stash entries", W })
  eq(f({ "git", "push" }), { "no remote configured (M a adds one)", W })
  write("u.txt", { "u" })
  eq(f({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit" }), { "nothing added to commit but untracked files present", W })
  vim.fn.delete(dir .. "/u.txt")
  eq(f({ "git", "switch", "nope" }), { "invalid reference: nope", E })
  eq(t.failure({ code = 1, stderr = "error: a\nhint: b\nhint: c\n" }), "a")
  eq(t.failure({ code = 3, stderr = "", stdout = "" }), "exited 3")
end)

test("failure: login errors -> cause and fix, git's line as detail", function()
  local function hint(stderr)
    local msg, lvl = t.failure({ code = 128, stderr = stderr })
    eq(lvl, vim.log.levels.ERROR)
    return msg
  end
  local m = hint("fatal: could not read Username for 'https://github.com': terminal prompts disabled\n")
  eq(m:match("^remote needs a login") ~= nil, true, m)
  eq(m:match("\ncould not read Username for 'https://github.com': terminal prompts disabled$") ~= nil, true, m)
  eq(hint("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n")
    :match("^SSH key rejected") ~= nil, true)
  eq(hint("Host key verification failed.\nfatal: Could not read from remote repository.\n")
    :match("^remote's SSH host key") ~= nil, true)
  eq(hint("remote: Invalid username or token.\nfatal: Authentication failed for 'https://github.com/a/b.git/'\n")
    :match("^saved credentials were rejected") ~= nil, true)
end)

test("paint: incremental repaints end with the same lines and highlights as a fresh paint", function()
  math.randomseed(7)
  local function marks(b)
    return vim.tbl_map(function(m) return { m[2], m[3], m[4].end_col, m[4].hl_group } end,
      vim.api.nvim_buf_get_extmarks(b, t.ns, 0, -1, { details = true }))
  end
  local function frame()
    local L, H = {}, {}
    local pool = { "Head: main", "", "Unstaged (2)", "modified a", "+x", "-y", " ctx", "@@ -1 +1 @@", "Recent" }
    for i = 1, math.random(0, 60) do
      local l = pool[math.random(#pool)]
      if math.random() < 0.2 then l = string.rep("+big", 1) .. i end -- some unique rows
      L[i] = l
      -- paint's contract: a line's highlight follows from its text (render works that way), so an
      -- unchanged line keeps its marks. Same text -> same highlight here too
      local hl = ({ ["+"] = "GitDiffAdd", ["-"] = "GitDiffDelete", U = "Title", m = "GitChangeModified" })[l:sub(1, 1)]
      if hl then H[#H + 1] = { i - 1, 0, #l, hl } end
    end
    return L, H
  end
  local buf = vim.api.nvim_create_buf(false, true)
  for step = 1, 300 do
    local L, H = frame()
    if step % 7 == 0 then L, H = {}, {} end -- collapse everything
    t.paint(buf, L, H)
    local fresh = vim.api.nvim_create_buf(false, true)
    t.paint(fresh, L, H)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.api.nvim_buf_get_lines(fresh, 0, -1, false), "lines at step " .. step)
    local want = marks(fresh)
    eq(marks(buf), want, "marks at step " .. step)
    vim.api.nvim_buf_delete(fresh, { force = true })
    if step % 5 == 0 then t.paint(buf, L, H) eq(marks(buf), want, "identical repaint " .. step) end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("git_batch: one process, same results as one spawn per command", function()
  local gdir = vim.fn.tempname()
  vim.fn.mkdir(gdir, "p")
  local function g(args, o) return vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args), vim.tbl_extend("force", { cwd = gdir, text = true }, o or {})):wait() end
  g({ "init", "-q" })
  local h = assert(io.open(gdir .. "/crlf", "wb")); h:write("a\r\nb\r\n"); h:close()
  h = assert(io.open(gdir .. "/big", "wb")); h:write(string.rep("0123456789abcdef\n", 60000)); h:close()
  g({ "add", "." }); g({ "commit", "-qm", "it's \"quoted\" $HOME `x`" })
  vim.fn.writefile({ "x" }, gdir .. "/new file")
  local cmds = {
    { "--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z" }, -- NULs
    { "log", "--format=%h%x1f%s" },                                          -- quotes, $, backticks in output
    { "show", "HEAD:crlf" },                                                 -- CRLF
    { "show", "HEAD:big" },                                                  -- ~1MB, past any pipe buffer
    { "show", "-s", "--format=%s", "@{upstream}" },                          -- fails (no upstream)
    { "log", "--format=it's %s", "-1" },                                     -- ' in an argument
    { "stash", "list" },                                                     -- empty
  }
  local root = t.S.root
  t.S.root = gdir
  local function run(script)
    petal._batch_sh = script
    local res
    t.git_batch(cmds, function(r) res = r end)
    assert(vim.wait(10000, function() return res ~= nil end, 5), "git_batch never answered")
    petal._batch_sh = nil
    return res
  end
  for _, mode in ipairs({ "batched", "fallback" }) do
    local res = run(mode == "fallback" and "exit 3" or nil) -- the batch failing -> one spawn per command
    for i, args in ipairs(cmds) do
      local want = vim.system(vim.list_extend({ "git" }, args), { cwd = gdir, text = true }):wait()
      eq(res[i].code, want.code, mode .. " code " .. args[1])
      eq(res[i].stdout, want.stdout, mode .. " stdout " .. table.concat(args, " "))
    end
  end
  local partial = run([[printf 'partial' >"$1/1"; printf '1 0\n']])
  eq(#partial, #cmds, "an incomplete batch should rerun every command")
  eq(partial[1].stdout, g(cmds[1]).stdout, "fallback should discard partial batch output")
  t.S.root = root
  vim.fn.delete(gdir, "rf")
end)

test("git_batch: 20 concurrent commands all come back in order", function()
  local gdir = vim.fn.tempname()
  vim.fn.mkdir(gdir, "p")
  local function g(args) return vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args), { cwd = gdir, text = true }):wait() end
  g({ "init", "-q" })
  for i = 1, 4 do
    vim.fn.writefile({ tostring(i) }, gdir .. "/x")
    g({ "add", "x" }); g({ "commit", "-qm", "c" .. i })
  end
  local cmds, want = {}, {}
  for i = 1, 20 do
    local rev = "HEAD~" .. ((i - 1) % 4)
    cmds[i] = { "show", "-s", "--format=%h %s", rev }
    want[i] = vim.system(vim.list_extend({ "git" }, cmds[i]), { cwd = gdir, text = true }):wait().stdout
  end
  local root = t.S.root
  t.S.root = gdir
  local res
  t.git_batch(cmds, function(r) res = r end)
  assert(vim.wait(10000, function() return res ~= nil end, 5), "git_batch stress never answered")
  t.S.root = root
  for i = 1, 20 do
    eq(res[i].code, 0, "code " .. i)
    eq(res[i].stdout, want[i], "stdout " .. i)
  end
  vim.fn.delete(gdir, "rf")
end)

test("parse_diff: split lines give the same result as the joined text", function()
  local bdir = vim.fn.tempname()
  vim.fn.mkdir(bdir, "p")
  local function bgit(args) return vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args), { cwd = bdir, text = true }):wait().stdout end
  local function put(name, data) local h = assert(io.open(bdir .. "/" .. name, "wb")); h:write(data); h:close() end
  bgit({ "init", "-q" })
  put("a", "1\n\n2\n\n"); put("b", "x\r\ny\r\n"); put("c", "p\nq")
  bgit({ "add", "." }); bgit({ "commit", "-qm", "i" })
  put("a", "1\n\n3\n\n\n"); put("b", "x\r\nz\r\n"); put("c", "p\nr")
  for _, extra in ipairs({ {}, { "-c", "diff.suppressBlankEmpty=true" } }) do
    local out = bgit(vim.list_extend(vim.list_extend({}, extra), { "diff", "--src-prefix=a/", "--dst-prefix=b/" }))
    local by, rawby = t.split_diff(out), t.split_diff_raw(out)
    for _, p in ipairs({ "a", "b", "c" }) do
      local ls = by["diff --git a/" .. p .. " b/" .. p]
      local old = t.parse_diff(table.concat(ls, "\n"))
      local copy = vim.list_extend({}, ls)
      while copy[#copy] == "" do copy[#copy] = nil end
      eq(t.parse_diff(copy), old, p .. " " .. table.concat(extra, " "))
      eq(t.parse_diff(rawby["diff --git a/" .. p .. " b/" .. p]), old, p .. " raw " .. table.concat(extra, " "))
    end
  end
  vim.fn.delete(bdir, "rf")
end)

test("untracked_diff: same result as git diff --no-index", function()
  local udir = vim.fn.tempname()
  vim.fn.mkdir(udir .. "/d", "p")
  local function put(name, data) local h = assert(io.open(udir .. "/" .. name, "wb")); h:write(data); h:close() end
  put("text", "a\nb\n"); put("nonl", "a\nb"); put("one", "x\n"); put("bin", "x\0y"); put("empty", "")
  put("crlf", "a\r\nb\r\n"); put("blank", "\n\n"); put("a b", "sp\n"); put("é", "u\n"); put("d/q", "q\n")
  put("exe", "run\n"); vim.uv.fs_chmod(udir .. "/exe", tonumber("755", 8))
  vim.uv.fs_symlink("text", udir .. "/link")
  local root, attrs = t.S.root, t.S.attrs
  t.S.root, t.S.attrs = udir, false
  local function via_git(path)
    local r = vim.system({ "git", "-c", "core.quotePath=false", "diff", "--no-index", "--", "/dev/null", path }, { cwd = udir, text = true }):wait()
    local d = t.parse_diff(r.stdout)
    d.header = vim.tbl_filter(function(l) return not l:match("^index ") end, d.header)
    return d
  end
  for _, p in ipairs({ "text", "nonl", "one", "bin", "empty", "crlf", "blank", "a b", "é", "d/q", "exe", "link" }) do
    eq(t.untracked_diff({ section = "untracked", path = p }), via_git(p), p)
  end
  -- unchanged on disk: the same object back (no re-read); rewritten: read again
  local f1 = { section = "untracked", path = "one" }
  local d1 = t.untracked_diff(f1)
  assert(t.untracked_diff(f1, nil, d1) == d1, "unchanged file was re-read")
  put("one", "y\n")
  eq(t.untracked_diff(f1, nil, d1).hunks[1].lines, { "+y" }, "rewritten file kept the old diff")
  eq(t.untracked_diff({ section = "untracked", path = "d/" }), { header = {}, hunks = {} }, "dir")
  eq(t.untracked_diff({ section = "untracked", path = 'q"uote' }), nil, "path git would quote -> git")
  put(".gitattributes", "*.txt diff=x\n")
  eq(t.untracked_diff({ section = "untracked", path = "d/q" }), nil, "attributes in play -> git")
  vim.fn.delete(udir .. "/.gitattributes")
  t.S.attrs = true
  eq(t.untracked_diff({ section = "untracked", path = "text" }), nil, "global attributes -> git")
  -- the header without its index line still stages: first line only, through patch() like s does
  t.S.attrs = false
  vim.system({ "git", "init", "-q" }, { cwd = udir }):wait()
  local d = t.untracked_diff({ section = "untracked", path = "text" })
  local items = { { hunk = d.hunks[1], idx = 1 } }
  local p = t.patch({ item = { diff = d, hunk = d.hunks[1] }, visual = true, items = items }, false)
  local r = vim.system({ "git", "apply", "--recount", "--cached", "-" }, { cwd = udir, stdin = p, text = true }):wait()
  eq(r.code, 0, r.stderr)
  eq(vim.system({ "git", "show", ":text" }, { cwd = udir, text = true }):wait().stdout, "a\n")
  t.S.root, t.S.attrs = root, attrs
  vim.fn.delete(udir, "rf")
end)

-- end to end through the UI (last: it opens the status in its own repo)
test("move_hunk: hunk moves to a later commit, end result unchanged", function()
  local mdir = vim.fn.tempname()
  vim.fn.mkdir(mdir, "p")
  local function mgit(args) local r = vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args), { cwd = mdir, text = true }):wait(); assert(r.code == 0, r.stderr); return r.stdout end
  local L = {}
  for i = 1, 12 do L[i] = "line " .. i end
  local function set(i, v) L[i] = v vim.fn.writefile(L, mdir .. "/app.lua") end
  mgit({ "init", "-q", "-b", "main" })
  -- in the repo's own config, not -c: petal's commit-tree calls must see it too (CI has no global identity)
  for k, v in pairs({ ["user.name"] = "t", ["user.email"] = "t@t", ["commit.gpgsign"] = "false" }) do mgit({ "config", k, v }) end
  set(1, "line 1"); mgit({ "add", "." }); mgit({ "commit", "-qm", "base" })
  set(2, "cache = {}"); set(10, "cache.ttl = 60"); mgit({ "commit", "-qam", "feat: add cache" })
  set(6, "log('hit')"); mgit({ "commit", "-qam", "fix: logging" })
  local tree = mgit({ "rev-parse", "HEAD^{tree}" })
  local real = package.loaded["petal.select"]
  package.loaded["petal.select"] = { select = function(items, _, cb) for _, it in ipairs(items) do if it:find("fix: logging", 1, true) then return cb(it) end end end }
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(mdir)
  petal.open()
  vim.wait(5000, function() return vim.fn.search("Recent", "nw") > 0 end, 10)
  vim.fn.search("^\\* \\x\\+ .*add cache")
  vim.api.nvim_feedkeys(vim.keycode("<cr>"), "x", false)
  vim.wait(3000, function() return vim.fn.search("^+cache.ttl", "w") > 0 end, 10)
  vim.api.nvim_feedkeys("o", "x", false)
  vim.wait(5000, function() return mgit({ "log", "-1", "--format=%s", "HEAD~1" }) == "feat: add cache\n" and not mgit({ "show", "HEAD~1" }):find("cache.ttl") end, 20)
  package.loaded["petal.select"] = real
  vim.cmd.cd(cwd)
  eq(mgit({ "show", "--format=", "-U0", "HEAD~1" }):match("\n(%+cache[^\n]*)"), "+cache = {}")
  assert(mgit({ "show", "HEAD" }):find("+cache.ttl = 60", 1, true), "ttl hunk should now be in fix: logging")
  eq(mgit({ "rev-parse", "HEAD^{tree}" }), tree)
  vim.fn.delete(mdir, "rf")
end)

test("watch: changes made outside nvim refresh the open status", function()
  local wdir = vim.fn.tempname()
  vim.fn.mkdir(wdir .. "/sub", "p")
  local function wgit(args) local r = vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args), { cwd = wdir, text = true }):wait(); assert(r.code == 0, r.stderr); return r.stdout end
  wgit({ "init", "-q", "-b", "main" })
  vim.fn.writefile({ "a" }, wdir .. "/sub/a.txt")
  wgit({ "add", "." }); wgit({ "commit", "-qm", "base" })
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(wdir)
  petal.open()
  local function shows(pat) return vim.wait(3000, function() return vim.fn.search(pat, "nw") > 0 end, 20) end
  assert(shows("Recent"), "status never rendered")
  vim.wait(500, function() return vim.tbl_count(t.S.watch) >= 4 end, 10) -- gitdir, refs, refs/heads, root, sub
  -- writefile is no BufWritePost and there's no FocusGained: only the watcher can notice these
  vim.fn.writefile({ "b" }, wdir .. "/sub/a.txt")
  assert(shows("sub/a.txt"), "edit in a subdirectory not picked up")
  vim.fn.mkdir(wdir .. "/new", "p")
  vim.fn.writefile({ "x" }, wdir .. "/new/x.txt")
  assert(shows("new/"), "new untracked directory not picked up")
  wgit({ "commit", "-qam", "outside commit" })
  assert(shows("outside commit"), "commit from another terminal not picked up")
  vim.cmd.cd(cwd)
  vim.fn.delete(wdir, "rf")
end)

-- performance guards: what a refresh must NOT redo. spawned() counts git processes by subcommand
local function repo(name)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  local function g(args)
    local r = vim.system(vim.list_extend({ "git" }, args), { cwd = d, text = true }):wait()
    assert(r.code == 0, table.concat(args, " ") .. ": " .. (r.stderr or ""))
    return r.stdout
  end
  g({ "init", "-q", "-b", "main" })
  for k, v in pairs({ ["user.name"] = "t", ["user.email"] = "t@t", ["commit.gpgsign"] = "false", ["core.hooksPath"] = "/dev/null" }) do g({ "config", k, v }) end
  return d, g
end
local function spy()
  local counts, real = {}, vim.system
  vim.system = function(cmd, ...)
    local s = table.concat(cmd, " ")
    for _, w in ipairs({ "merge-tree", "ls-files" }) do if s:find(w, 1, true) then counts[w] = (counts[w] or 0) + 1 end end
    return real(cmd, ...)
  end
  return counts, function() vim.system = real end
end
local function settled(ms) -- refreshes and their follow-ups done
  local seq = t.S.seq
  vim.wait(ms or 400, function() return false end, 20)
  return seq
end
local function shown(pat) return vim.wait(3000, function() return vim.fn.search(pat, "nw") > 0 end, 10) end

test("refresh: an unchanged diff keeps its object and rows; a file that left its section stops being diffed", function()
  local rdir, g = repo()
  vim.fn.writefile({ "a1", "a2" }, rdir .. "/a.txt")
  vim.fn.writefile({ "b1" }, rdir .. "/b.txt")
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(vim.wait(3000, function() return t.S.data and #t.S.data.st.untracked == 2 end, 10), "status never rendered")
  for _, f in ipairs(t.S.data.st.untracked) do t.S.open["untracked:" .. f.path] = f end
  petal.refresh()
  assert(shown("^+a2$") and shown("^+b1$"), "diffs not expanded")
  local a = t.S.diffs["untracked:a.txt"]
  assert(a.seg, "render cached no rows for a.txt")
  vim.fn.writefile({ "b1", "b2" }, rdir .. "/b.txt")
  petal.refresh()
  assert(shown("^+b2$"), "changed diff not redrawn")
  assert(t.S.diffs["untracked:a.txt"] == a, "unchanged diff was rebuilt")
  -- highlights of the copied rows still land on the right lines
  local row = vim.fn.search("^+b2$", "nw") - 1
  local marks = vim.api.nvim_buf_get_extmarks(t.S.buf, t.ns, { row, 0 }, { row, -1 }, { details = true })
  eq(marks[1] and marks[1][4].hl_group, "GitDiffAdd")
  g({ "add", "a.txt" })
  petal.refresh()
  assert(shown("^Staged"), "staged section missing")
  settled()
  eq(t.S.open["untracked:a.txt"], nil, "a.txt left Untracked but is still expanded there")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("refresh: a mostly-open section diffs whole (--no-renames); unmerged lines glue onto nothing", function()
  local rdir, g = repo()
  for i = 1, 10 do
    vim.fn.writefile({ "a" .. i }, rdir .. "/a" .. i .. ".txt")
    vim.fn.writefile({ "f" .. i }, rdir .. "/f" .. i .. ".txt")
  end
  vim.fn.writefile({ "base" }, rdir .. "/m.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  g({ "switch", "-qc", "other" }); vim.fn.writefile({ "theirs" }, rdir .. "/m.txt"); g({ "commit", "-qam", "theirs" })
  g({ "switch", "-q", "main" }); vim.fn.writefile({ "ours" }, rdir .. "/m.txt"); g({ "commit", "-qam", "ours" })
  vim.system({ "git", "merge", "other" }, { cwd = rdir }):wait() -- conflicts on m.txt, exit 1
  local stage = { "add" }
  for i = 1, 10 do
    vim.fn.writefile({ "a" .. i, "x" }, rdir .. "/a" .. i .. ".txt")
    vim.fn.writefile({ "f" .. i, "x" }, rdir .. "/f" .. i .. ".txt")
    stage[#stage + 1] = "a" .. i .. ".txt"
  end
  g(stage)
  local real, no_renames = vim.system, false
  vim.system = function(cmd, ...)
    if table.concat(cmd, " "):find("--no-renames", 1, true) then no_renames = true end
    return real(cmd, ...)
  end
  local cwd = vim.fn.getcwd()
  local ok, err = pcall(function()
    vim.cmd.cd(rdir)
    petal.open()
    assert(vim.wait(3000, function()
      return t.S.data and #t.S.data.st.staged == 10 and #t.S.data.st.unstaged == 11
    end, 10), "status never rendered")
    vim.fn.maparg("zR", "n", false, true).callback()
    assert(vim.wait(3000, function()
      return t.S.diffs["unstaged:f1.txt"] and t.S.diffs["staged:a1.txt"]
    end, 10), "diffs never landed")
    assert(no_renames, "--no-renames never used")
    for i = 1, 10 do
      local f, a = "f" .. i .. ".txt", "a" .. i .. ".txt"
      local uf = t.parse_diff(vim.system({ "git", "diff", "--", f }, { cwd = rdir, text = true }):wait().stdout)
      local sa = t.parse_diff(vim.system({ "git", "diff", "--cached", "--", a }, { cwd = rdir, text = true }):wait().stdout)
      eq({ t.S.diffs["unstaged:" .. f].header, t.S.diffs["unstaged:" .. f].hunks }, { uf.header, uf.hunks }, f)
      eq({ t.S.diffs["staged:" .. a].header, t.S.diffs["staged:" .. a].hunks }, { sa.header, sa.hunks }, a)
    end
    assert(t.S.diffs["unstaged:m.txt"].conflicts, "unmerged m.txt got no conflicts")
  end)
  vim.system = real
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("open: rev-parse is cached per cwd; a new repo between cwd and root wins", function()
  local rdir, g = repo()
  vim.fn.mkdir(rdir .. "/sub", "p")
  vim.fn.writefile({ "x" }, rdir .. "/x.txt")
  g({ "add", "." }); g({ "commit", "-qm", "x" })
  local real, spawned = vim.system, 0
  vim.system = function(cmd, ...)
    if table.concat(cmd, " "):find("--show-toplevel", 1, true) then spawned = spawned + 1 end
    return real(cmd, ...)
  end
  local cwd = vim.fn.getcwd()
  local ok, err = pcall(function()
    vim.cmd.cd(rdir .. "/sub")
    petal.open()
    assert(vim.wait(3000, function() return t.S.data end, 10), "status never rendered")
    eq(vim.uv.fs_realpath(t.S.root), vim.uv.fs_realpath(rdir))
    petal.open() -- same cwd: the cached answer holds
    eq(spawned, 1, "reopen ran rev-parse")
    vim.system({ "git", "init", "-q" }, { cwd = rdir .. "/sub" }):wait()
    petal.open()
    eq(vim.uv.fs_realpath(t.S.root), vim.uv.fs_realpath(rdir .. "/sub"), "inner repo not found")
    eq(spawned, 2, "new repo below cwd did not re-run rev-parse")
  end)
  vim.system = real
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("attrs: the attributes-file check rides the refresh batch", function()
  local rdir, g = repo()
  vim.fn.writefile({ "x" }, rdir .. "/x.txt")
  g({ "add", "." }); g({ "commit", "-qm", "x" })
  g({ "config", "core.attributesFile", rdir .. "/no-such-attributes" }) -- the machine's global file stays out
  local cwd = vim.fn.getcwd()
  local ok, err = pcall(function()
    vim.cmd.cd(rdir)
    petal.open()
    assert(vim.wait(3000, function() return t.S.data and t.S.attrs_check == nil end, 10), "attrs check never landed")
    eq(t.S.attrs, false) -- no info/attributes, the configured file is missing
    vim.fn.writefile({ "*.bin binary" }, rdir .. "/.git/info/attributes")
    petal.open()
    assert(vim.wait(3000, function() return t.S.attrs == true end, 10), "info/attributes not picked up")
  end)
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("refresh: a stale batch still paints when nothing is shown yet", function()
  local rdir, g = repo()
  vim.fn.writefile({ "x" }, rdir .. "/x.txt")
  g({ "add", "." }); g({ "commit", "-qm", "x" })
  local real, batches = vim.system, 0
  vim.system = function(cmd, o, cb) -- every refresh batch but the first answers ~1.5s late
    if cmd[1] == "sh" and cmd[4] == "petal" and cb then
      batches = batches + 1
      if batches > 1 then
        local orig = cb
        cb = function(r) vim.defer_fn(function() orig(r) end, 1500) end
      end
    end
    return real(cmd, o, cb)
  end
  local cwd = vim.fn.getcwd()
  local ok, err = pcall(function()
    vim.cmd.cd(rdir)
    petal.open()
    petal.refresh() -- bumps seq: the first batch lands stale, but nothing is shown yet
    assert(vim.wait(700, function() return t.S.data ~= nil end, 10), "first paint waited for the newer batch")
    vim.wait(2000, function() return false end, 50) -- let the delayed batches land
    assert(vim.fn.search("Recent", "nw") > 0 or vim.fn.search("x.txt", "nw") > 0, "status not rendered")
  end)
  vim.system = real
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("radar: merge-tree runs again only when HEAD or the target moved", function()
  local rdir, g = repo()
  vim.fn.writefile({ "base" }, rdir .. "/r.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  g({ "branch", "up" })
  vim.fn.writefile({ "ours" }, rdir .. "/r.txt"); g({ "commit", "-qam", "ours" })
  g({ "switch", "-q", "up" }); vim.fn.writefile({ "theirs" }, rdir .. "/r.txt"); g({ "commit", "-qam", "theirs" })
  g({ "switch", "-q", "main" }); g({ "branch", "-q", "-u", "up" })
  local counts, restore = spy()
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  local ok, err = pcall(function()
    petal.open()
    assert(shown("^Conflict: up"), "radar never reported the conflict")
    settled()
    local n = counts["merge-tree"]
    petal.refresh(); settled(); petal.refresh(); settled()
    eq(counts["merge-tree"], n, "merge-tree reran with HEAD and up unchanged")
    assert(shown("^Conflict: up"), "cached conflict not shown")
    vim.fn.writefile({ "ours 2" }, rdir .. "/r.txt"); g({ "commit", "-qam", "ours 2" })
    petal.refresh(); settled()
    eq(counts["merge-tree"], n + 1, "HEAD moved: merge-tree should rerun")
  end)
  restore()
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("watch: a plain edit refreshes without re-listing directories", function()
  local rdir, g = repo()
  vim.fn.mkdir(rdir .. "/sub", "p")
  vim.fn.writefile({ "a" }, rdir .. "/sub/a.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  local counts, restore = spy()
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  local ok, err = pcall(function()
    petal.open()
    assert(shown("Recent"), "status never rendered")
    vim.wait(1000, function() return t.S.watch[rdir .. "/sub"] ~= nil end, 10)
    settled(600)
    local n = counts["ls-files"]
    vim.fn.writefile({ "b" }, rdir .. "/sub/a.txt")
    assert(shown("sub/a.txt"), "edit not picked up")
    settled(600)
    eq(counts["ls-files"], n, "an edit re-listed the worktree")
    vim.fn.mkdir(rdir .. "/new", "p")
    vim.fn.writefile({ "x" }, rdir .. "/new/x.txt")
    assert(shown("new/"), "new directory not picked up")
    vim.wait(1000, function() return counts["ls-files"] > n end, 10)
    assert(counts["ls-files"] > n, "a new directory should re-list")
  end)
  restore()
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("resize: only a width change of the status window re-renders", function()
  local rdir, g = repo()
  vim.fn.writefile({ "a" }, rdir .. "/a.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(shown("Recent"), "status never rendered")
  settled()
  local renders, real = 0, vim.api.nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(b, ...) if b == t.S.buf then renders = renders + 1 end return real(b, ...) end
  local ok, err = pcall(function()
    vim.api.nvim_exec_autocmds("WinResized", {}) -- first event sets the width
    local n = renders
    vim.cmd("split | wincmd p | resize 5") -- a height change, and another window
    vim.api.nvim_exec_autocmds("WinResized", {})
    eq(renders, n, "height change re-rendered")
    vim.cmd("only | vsplit")
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert(renders > n, "width change did not re-render")
    vim.cmd("only")
  end)
  vim.api.nvim_buf_get_lines = real
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
  assert(ok, err)
end)

test("amend summary: diffs against HEAD^, or the empty tree on the root commit", function()
  local rdir, g = repo()
  vim.fn.writefile({ "a" }, rdir .. "/root.txt")
  g({ "add", "." }); g({ "commit", "-qm", "root" })
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(shown("Recent"), "status never rendered")
  local function summary(name)
    local path = rdir .. "/.git/COMMIT_EDITMSG"
    vim.fn.writefile({ "" }, path)
    petal.edit(path, "", true)
    local b
    vim.wait(3000, function()
      for _, x in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(x):match("git://diff to commit$") and table.concat(vim.api.nvim_buf_get_lines(x, 0, -1, false), "\n"):find(name, 1, true) then b = x end
      end
      return b ~= nil
    end, 10)
    vim.cmd("stopinsert | bwipeout!")
    return b ~= nil
  end
  assert(summary("root.txt"), "root amend: summary missing root.txt (vs empty tree)")
  vim.fn.writefile({ "b" }, rdir .. "/two.txt")
  g({ "add", "." }); g({ "commit", "-qm", "two" })
  assert(summary("two.txt"), "amend: summary missing two.txt (vs HEAD^)")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("d and e open their views once git answers (no blocking calls)", function()
  local rdir, g = repo()
  vim.fn.writefile({ "base" }, rdir .. "/m.txt")
  vim.fn.writefile({ "head" }, rdir .. "/v.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  g({ "switch", "-qc", "other" }); vim.fn.writefile({ "theirs" }, rdir .. "/m.txt"); g({ "commit", "-qam", "theirs" })
  g({ "switch", "-q", "main" }); vim.fn.writefile({ "ours" }, rdir .. "/m.txt"); g({ "commit", "-qam", "ours" })
  vim.system({ "git", "merge", "other" }, { cwd = rdir }):wait() -- conflicts on m.txt
  vim.fn.writefile({ "work" }, rdir .. "/v.txt")
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(shown("v%.txt") or shown("v.txt"), "status never rendered")
  vim.fn.cursor(vim.fn.search("modified.*v\\.txt", "nw"), 1)
  vim.api.nvim_feedkeys("d", "x", false)
  local head = vim.fn.bufnr("HEAD:v.txt")
  vim.wait(3000, function() head = vim.fn.bufnr("HEAD:v.txt"); return head ~= -1 end, 10)
  assert(head ~= -1, "d: no HEAD side")
  eq(vim.api.nvim_buf_get_lines(head, 0, -1, false), { "head" })
  vim.cmd("diffoff! | only")
  petal.open()
  assert(shown("unmerged.*m.txt"), "conflict not listed")
  vim.fn.cursor(vim.fn.search("unmerged.*m\\.txt", "nw"), 1)
  local tabs = #vim.api.nvim_list_tabpages()
  local oc, ol = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 200, 50 -- e's panes open by themselves only on a big screen
  vim.api.nvim_feedkeys("e", "x", false)
  assert(vim.wait(3000, function() return #vim.api.nvim_tabpage_list_wins(0) == 3 end, 10), "e: merge windows never opened")
  assert(#vim.api.nvim_list_tabpages() == tabs + 1, "e: no merge tab")
  local bars = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do bars[#bars + 1] = vim.wo[w].winbar end
  assert(table.concat(bars, "\n"):find("ours  main", 1, true), "e: ours label missing: " .. table.concat(bars, " | "))
  vim.cmd("diffoff! | tabclose")
  vim.o.columns, vim.o.lines = oc, ol
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("e on a small screen opens just the file; cp toggles the ours | theirs panes", function()
  local oc, ol = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 100, 30
  local rdir, g = repo()
  vim.fn.writefile({ "base" }, rdir .. "/m.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  g({ "switch", "-qc", "other" }); vim.fn.writefile({ "theirs" }, rdir .. "/m.txt"); g({ "commit", "-qam", "theirs" })
  g({ "switch", "-q", "main" }); vim.fn.writefile({ "ours" }, rdir .. "/m.txt"); g({ "commit", "-qam", "ours" })
  vim.system({ "git", "merge", "other" }, { cwd = rdir }):wait() -- conflicts on m.txt
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(shown("unmerged.*m.txt"), "conflict not listed")
  vim.fn.cursor(vim.fn.search("unmerged.*m\\.txt", "nw"), 1)
  vim.api.nvim_feedkeys("e", "x", false)
  local mwin
  assert(vim.wait(3000, function()
    local w = vim.api.nvim_tabpage_list_wins(0)
    if #w == 1 and vim.wo[w[1]].winbar:find("cp", 1, true) then mwin = w[1]; return true end
  end, 10), "e: merge setup never ran")
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "compact: expected only the file window")
  local mbuf, srow, erow = vim.api.nvim_win_get_buf(mwin)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)) do
    if l:match("^<<<<<<<") then srow = i elseif l:match("^>>>>>>>") then erow = i end
  end
  local ns, marks = vim.api.nvim_create_namespace("petal_merge"), {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(mbuf, ns, 0, -1, { details = true })) do
    if m[4].virt_text and m[4].virt_text[1] then marks[m[2] + 1] = m[4].virt_text[1][1] end
  end
  assert(marks[srow] and vim.startswith(marks[srow], "ours  main"), "ours label: " .. tostring(marks[srow]))
  assert(marks[erow] and vim.startswith(marks[erow], "theirs  other"), "theirs label: " .. tostring(marks[erow]))
  vim.api.nvim_feedkeys("cp", "x", false)
  assert(vim.wait(3000, function() return #vim.api.nvim_tabpage_list_wins(0) == 3 end, 10), "cp: panes never opened")
  eq(vim.api.nvim_get_current_win(), mwin, "cp: focus left the file window")
  vim.api.nvim_feedkeys("cp", "x", false)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "cp: panes did not close")
  vim.api.nvim_feedkeys("cp", "x", false)
  assert(vim.wait(3000, function() return #vim.api.nvim_tabpage_list_wins(0) == 3 end, 10), "cp: panes never reopened")
  local tabs = #vim.api.nvim_list_tabpages()
  vim.cmd.wincmd("k")
  vim.api.nvim_feedkeys("ZQ", "x", false)
  eq(#vim.api.nvim_list_tabpages(), tabs - 1, "ZQ from a pane did not close merge mode")
  vim.cmd.split(vim.fn.fnameescape(rdir .. "/m.txt"))
  eq(vim.wo.winbar, "", "merge winbar followed the file out of merge mode")
  vim.cmd.close()
  -- panes that arrive while another tab is current don't pull the user back
  petal.open()
  vim.fn.cursor(vim.fn.search("unmerged.*m\\.txt", "nw"), 1)
  vim.api.nvim_feedkeys("e", "x", false)
  assert(vim.wait(3000, function() return vim.fn.maparg("cp", "n") ~= "" end, 10), "e: merge setup never ran again")
  local mtab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_feedkeys("cp", "x", false)
  vim.cmd("tabprevious")
  local here = vim.api.nvim_get_current_tabpage()
  assert(vim.wait(3000, function() return #vim.api.nvim_tabpage_list_wins(mtab) == 3 end, 10), "cp: panes never opened in the background")
  eq(vim.api.nvim_get_current_tabpage(), here, "panes loading pulled focus back to the merge tab")
  vim.api.nvim_set_current_tabpage(mtab)
  vim.api.nvim_feedkeys("ZQ", "x", false)
  -- cp twice before git answers: the panes stay closed
  petal.open()
  vim.fn.cursor(vim.fn.search("unmerged.*m\\.txt", "nw"), 1)
  vim.api.nvim_feedkeys("e", "x", false)
  assert(vim.wait(3000, function() return vim.fn.maparg("cp", "n") ~= "" end, 10), "e: merge setup never ran a third time")
  vim.api.nvim_feedkeys("cpcp", "x", false)
  vim.wait(300, function() return false end, 20)
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "cp cp while loading left the panes open")
  vim.api.nvim_feedkeys("ZQ", "x", false)
  vim.o.columns, vim.o.lines = oc, ol
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("branch_plan: dd deletes, yy+p copies, edit renames, new line creates, edge cases refused", function()
  local orig = {
    { id = 1, name = "main", sha = "a", head = true },
    { id = 2, name = "feat", sha = "b" },
    { id = 3, name = "gone", sha = "c" },
  }
  local function ops(L)
    local p, why = t.branch_plan(orig, L, { origin = true })
    if not p then return why end
    local out = {}
    for _, o in ipairs(p) do out[#out + 1] = o.op .. " " .. (o.src and o.src.name or "HEAD") .. (o.to and (">" .. o.to) or "") end
    return out
  end
  eq(ops({ "/1 main", "/2 feat", "/3 gone" }), {})
  eq(ops({ "/1 trunk", "/2 feat2", "/2 feat", "", "new" }),
    { "delete gone", "rename main>trunk", "create feat>feat2", "create HEAD>new" })
  eq(ops({ "/2 feat", "/3 gone" }), "can't delete main: it is checked out")
  eq(ops({ "/1 main", "/2 gone", "/3 feat" }), "gone already exists (swap names in two saves)")
  eq(ops({ "/1 main", "/2 gone" }), { "delete gone", "rename feat>gone" }) -- freed by a delete
  eq(ops({ "/1 main", "/2 feat", "/2 feat" }), "feat is listed twice")
  eq(ops({ "/1 main", "/2feat" }), "line 2: its hidden id was edited, undo with u")
  eq(ops({ "/9 x" }), "line 1: unknown id /9")
  eq(ops({ "/1 main", "/2 origin/feat", "/3 gone" }), "origin/feat looks like a remote branch (remote branches: b R)")
end)

test("remote_unsafe: only a merged PR, no local branch, not the default", function()
  local o = { name = "origin/x" }
  local m = { state = "MERGED" }
  eq(t.remote_unsafe(o, m), nil)
  assert(t.remote_unsafe(o, nil) and t.remote_unsafe(o, { state = "OPEN" }) and t.remote_unsafe(o, { state = "MERGED", isDraft = true }))
  assert(t.remote_unsafe({ name = "origin/x", has_local = true }, m))
  assert(t.remote_unsafe({ name = "origin/main", default = true }, m))
end)

test("branches buffer: :w deletes, renames, copies, creates; one dialog flags unmerged", function()
  local rdir, g = repo()
  vim.fn.writefile({ "x" }, rdir .. "/x.txt")
  g({ "add", "." }); g({ "commit", "-qm", "x" })
  for _, b in ipairs({ "gone", "feat" }) do g({ "branch", b }) end
  -- an upstream that no longer exists: merged-ness falls back to HEAD, like git branch -d
  g({ "config", "branch.gone.remote", "." }); g({ "config", "branch.gone.merge", "refs/heads/deleted" })
  g({ "checkout", "-q", "-b", "unmerged" }); vim.fn.writefile({ "y" }, rdir .. "/x.txt"); g({ "commit", "-qam", "y" }); g({ "checkout", "-q", "main" })
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(vim.wait(3000, function() return t.S.data end, 10), "status never rendered")
  local real, asked = vim.fn.confirm, {}
  vim.fn.confirm = function(msg) asked[#asked + 1] = msg; return 1 end
  t.branches("local")
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function() return vim.api.nvim_buf_line_count(buf) == 4 end, 10), "branch list never loaded")
  local id = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do id[l:match("^/%d+ (.*)$")] = l:match("^(/%d+ )") end
  -- gone + unmerged dropped, feat renamed + copied, fresh new
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { id.main .. "main", id.feat .. "renamed", id.feat .. "copy", "fresh" })
  vim.cmd("write")
  assert(vim.wait(5000, function() return not vim.bo[buf].modified and vim.api.nvim_buf_line_count(buf) == 4 end, 20), "save never finished")
  vim.fn.confirm = real
  local loc = vim.split(vim.trim(g({ "for-each-ref", "--format=%(refname:short)", "refs/heads" })), "\n")
  table.sort(loc)
  eq(loc, { "copy", "fresh", "main", "renamed" })
  assert(asked[1]:find("rename  feat → renamed", 1, true), "summary: " .. asked[1])
  assert(asked[1]:find("delete  unmerged  (not merged", 1, true) and not asked[1]:find("gone  (not merged", 1, true), "merge state: " .. asked[1])
  eq(#asked, 1, "more than one dialog")
  vim.cmd("normal q")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("branches: deleting asks to delete the upstream, never the default or a shared one; remote list", function()
  local rdir, g = repo()
  local bare = vim.fn.tempname()
  vim.system({ "git", "init", "-q", "--bare", "-b", "main", bare }):wait()
  vim.fn.writefile({ "x" }, rdir .. "/x.txt")
  g({ "add", "." }); g({ "commit", "-qm", "x" })
  g({ "remote", "add", "origin", bare })
  for _, b in ipairs({ "main", "feat", "twin" }) do
    if b ~= "main" then g({ "branch", b }) end
    g({ "push", "-q", "-u", "origin", b })
  end
  g({ "remote", "set-head", "origin", "main" })
  g({ "branch", "--track", "rel", "origin/main" }); g({ "branch", "--track", "twin2", "origin/twin" })
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(vim.wait(3000, function() return t.S.data and t.S.data.remoteset.origin end, 10), "status never rendered")
  local real, asked = vim.fn.confirm, {}
  vim.fn.confirm = function(msg) asked[#asked + 1] = msg; return 1 end
  t.branches("local")
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function() return vim.api.nvim_buf_line_count(buf) == 5 end, 10), "branch list never loaded")
  local keep = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match(" main$") or l:match(" twin2$") then keep[#keep + 1] = l end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, keep) -- deletes feat, rel (tracks origin/main), twin (twin2 shares it)
  vim.cmd("write")
  assert(vim.wait(5000, function() return not vim.bo[buf].modified and vim.api.nvim_buf_line_count(buf) == 2 end, 20), "save never finished")
  vim.fn.confirm = real
  local function has(p) for _, m in ipairs(asked) do if m:find(p, 1, true) then return true end end end
  assert(has("on origin also delete: feat\n") or asked[1]:match("on origin also delete: feat$"), "upstream not offered: " .. vim.inspect(asked))
  eq(#asked, 1, "more than one dialog")
  local function rem()
    local r = vim.split(vim.trim(vim.system({ "git", "for-each-ref", "--format=%(refname:short)" }, { cwd = bare, text = true }):wait().stdout), "\n")
    table.sort(r)
    return r
  end
  vim.wait(5000, function() return #rem() == 2 end, 50) -- the push runs in the background
  eq(rem(), { "main", "twin" })
  vim.cmd("normal q")
  -- remote cleanup: only a merged PR with no local branch goes (twin: twin2 tracks it; main: default)
  g({ "branch", "done" }); g({ "push", "-q", "origin", "done" }); g({ "branch", "-D", "done" })
  local merged = { state = "MERGED", number = 1 }
  t.branches("remote")
  buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function() return vim.api.nvim_buf_line_count(buf) == 3 end, 10), "remote list never loaded")
  local L = vim.tbl_map(function(l) return (l:gsub("^/%d+ ", "")) end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  table.sort(L)
  eq(L, { "origin/done", "origin/main", "origin/twin" }) -- no origin/HEAD
  vim.wait(200) -- let any gh call in flight land, then stand in for it
  t.S.branch_prs = { root = t.S.root, at = vim.uv.now(), map = { done = merged, twin = merged, main = merged } }
  vim.cmd("normal X")
  eq(vim.api.nvim_buf_line_count(buf), 2)
  local twin, cleaned = nil, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(cleaned) do if l:match(" origin/twin$") then twin = i end end
  vim.api.nvim_buf_set_lines(buf, twin - 1, twin, false, {}) -- unsafe: refused, nothing pushed
  vim.cmd("write")
  eq(vim.bo[buf].modified, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, cleaned) -- API edits share one undo block: restore by hand
  vim.fn.confirm = function(msg) asked[#asked + 1] = msg; return 1 end
  vim.cmd("write")
  vim.fn.confirm = real
  vim.wait(5000, function() return #rem() == 1 end, 50)
  eq(rem(), { "main", "twin" })
  assert(asked[#asked]:find("delete  origin/done", 1, true), "dialog: " .. asked[#asked])
  vim.cmd("normal q")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf"); vim.fn.delete(bare, "rf")
end)

test("merge_mode: c-keys resolve on a marker, stay Vim's elsewhere; ZZ stages", function()
  local cdir = vim.fn.tempname()
  vim.fn.mkdir(cdir, "p")
  local function cgit(args) return vim.system(vim.list_extend({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args), { cwd = cdir, text = true }):wait() end
  local f = cdir .. "/a.txt"
  cgit({ "init", "-q", "-b", "main" })
  vim.fn.writefile({ "top", "x", "end" }, f); cgit({ "add", "." }); cgit({ "commit", "-qm", "base" })
  cgit({ "checkout", "-qb", "other" })
  vim.fn.writefile({ "top", "theirs, side", "end" }, f); cgit({ "commit", "-qam", "theirs" })
  cgit({ "checkout", "-q", "main" })
  vim.fn.writefile({ "top", "ours, side, more", "end" }, f); cgit({ "commit", "-qam", "ours" })
  assert(cgit({ "merge", "-q", "other" }).code ~= 0, "merge should conflict")
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(cdir)
  petal.open()
  assert(vim.wait(5000, function() return vim.fn.search("a.txt", "w") > 0 end, 10), "conflicted file not listed")
  local oc, ol = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = 200, 50 -- panes only open by themselves on a big screen
  vim.api.nvim_feedkeys("e", "x", false)
  assert(vim.wait(5000, function() return #vim.api.nvim_tabpage_list_wins(0) == 3 end, 10), "merge windows never opened")
  local mbuf = vim.api.nvim_get_current_buf()
  local function L() return vim.api.nvim_buf_get_lines(mbuf, 0, -1, false) end
  -- content line: ct is Vim's change-till, and keeps its count (2ct, = up to the second comma)
  vim.api.nvim_win_set_cursor(0, { vim.fn.search("^ours, side", "nw"), 0 })
  vim.api.nvim_feedkeys("2ct,OURS" .. vim.keycode("<esc>"), "x", false)
  assert(vim.tbl_contains(L(), "OURS, more"), "2ct, off a marker should edit: " .. vim.inspect(L()))
  -- marker line: co keeps ours; a count before it must not leak into the next command
  local mark = vim.fn.search("^<<<<<<<", "nw")
  vim.api.nvim_win_set_cursor(0, { mark, 0 })
  -- one typeahead, as typed: the x runs before the scheduled resolve, on the marker line
  vim.api.nvim_feedkeys("3cox", "x", false)
  eq(vim.fn.getline(mark), "<<<<<< HEAD", "x after 3co must delete one char (count leaked)")
  vim.wait(200)
  vim.api.nvim_buf_set_lines(mbuf, mark - 1, mark, false, { "<<<<<<< HEAD" }) -- undo the x by hand
  vim.api.nvim_win_set_cursor(0, { mark, 0 })
  vim.api.nvim_feedkeys("3co", "x", false)
  vim.wait(1000, function() return #L() == 3 end, 10)
  eq(L(), { "top", "OURS, more", "end" })
  vim.api.nvim_feedkeys("ZZ", "x", false)
  assert(vim.wait(5000, function() return cgit({ "diff", "--name-only", "--diff-filter=U" }).stdout == "" end, 20), "ZZ should stage the file")
  eq(vim.fn.readfile(f), { "top", "OURS, more", "end" })
  vim.o.columns, vim.o.lines = oc, ol
  vim.cmd("normal q")
  vim.cmd.cd(cwd)
  vim.fn.delete(cdir, "rf")
end)

test("d: ZZ from the HEAD pane writes the file and returns, ZQ drops the edit; then they are Vim's", function()
  local rdir, g = repo()
  local f = rdir .. "/v.txt"
  vim.fn.writefile({ "head" }, f); g({ "add", "." }); g({ "commit", "-qm", "base" })
  vim.fn.writefile({ "work" }, f); g({ "add", "." }) -- staged only: git diff is empty until ZZ writes
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  local function open_diff(pat)
    assert(shown(pat), "status never listed " .. pat)
    vim.fn.cursor(vim.fn.search(pat, "nw"), 1)
    vim.api.nvim_feedkeys("d", "x", false)
    assert(vim.wait(3000, function() return vim.fn.bufnr("HEAD:v.txt") ~= -1 end, 10), "d: no HEAD side")
  end
  local function zmap(buf, k) return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(k, "n") end) end
  -- ZZ from the HEAD pane
  open_diff("modified.*v\\.txt")
  local fbuf = vim.fn.bufnr(f)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "edited" })
  vim.api.nvim_set_current_win(vim.fn.bufwinid(vim.fn.bufnr("HEAD:v.txt")))
  vim.api.nvim_feedkeys("ZZ", "x", false)
  eq(vim.fn.readfile(f), { "edited" }, "ZZ did not write the file")
  eq(g({ "diff", "--name-only" }), "v.txt\n", "git diff does not list the file")
  eq(vim.fn.bufnr("HEAD:v.txt"), -1, "HEAD scratch left behind")
  eq(zmap(fbuf, "ZZ"), "", "ZZ map stayed on the file buffer")
  -- ZQ (from the working pane) leaves the file on disk unchanged
  open_diff("modified.*v\\.txt")
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "dropped" })
  vim.api.nvim_set_current_win(vim.fn.bufwinid(fbuf))
  vim.api.nvim_feedkeys("ZQ", "x", false)
  eq(vim.fn.readfile(f), { "edited" }, "ZQ changed the file on disk")
  eq(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), { "edited" }, "ZQ kept the edit in the buffer")
  eq(vim.fn.bufnr("HEAD:v.txt"), -1, "HEAD scratch left behind")
  eq(zmap(fbuf, "ZQ"), "", "ZQ map stayed on the file buffer")
  -- :DiffOff clears the maps too
  open_diff("modified.*v\\.txt")
  vim.cmd("DiffOff")
  eq(zmap(fbuf, "ZZ"), "", ":DiffOff left the ZZ map")
  -- deleted in the worktree: the working side is a nofile buffer, ZZ closes without writing or throwing
  vim.fn.delete(f)
  petal.open()
  open_diff("deleted.*v\\.txt")
  local wbuf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.b[b].git_work_diff then wbuf = b end end
  assert(wbuf, "d on a deleted file: no working side")
  vim.api.nvim_buf_set_lines(wbuf, 0, -1, false, { "x" })
  vim.v.errmsg = ""
  vim.api.nvim_set_current_win(vim.fn.bufwinid(wbuf))
  vim.api.nvim_feedkeys("ZZ", "x", false)
  eq(vim.v.errmsg, "", "ZZ on the nofile side raised: " .. vim.v.errmsg)
  eq(vim.fn.bufnr("HEAD:v.txt"), -1, "HEAD scratch left behind")
  eq(vim.fn.filereadable(f), 0, "ZZ wrote the deleted file")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("refresh: raw diff cache keeps unchanged file objects; lazy rows keep cursor and visual staging", function()
  local rdir, g = repo()
  local base = {}
  for i = 1, 12 do base[i] = "line " .. i end
  vim.fn.writefile(vim.deepcopy(base), rdir .. "/a.txt")
  vim.fn.writefile(vim.deepcopy(base), rdir .. "/b.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  local function change(path, extra)
    local l = vim.deepcopy(base)
    l[6] = path:sub(1, 1) .. "2"
    if extra then l[#l + 1] = extra end
    vim.fn.writefile(l, rdir .. "/" .. path)
  end
  change("a.txt"); change("b.txt")
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(vim.wait(3000, function() return t.S.data and #t.S.data.st.unstaged == 2 end, 10), "status never rendered")
  vim.fn.maparg("zR", "n", false, true).callback()
  assert(shown("^+a2$") and shown("^+b2$"), "diffs not expanded")
  local a, b = t.S.diffs["unstaged:a.txt"], t.S.diffs["unstaged:b.txt"]
  assert(a and b and a.seg and b.seg, "batched diffs or cached segments missing")
  local row = vim.fn.search("^+b2$", "nw")
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  change("a.txt", "a3") -- only a's raw chunk changes; b must reuse the exact parsed object
  petal.refresh()
  assert(shown("^+a3$"), "edited diff not redrawn")
  assert(t.S.diffs["unstaged:b.txt"] == b, "unchanged file lost its exact diff object")
  assert(t.S.diffs["unstaged:a.txt"] ~= a, "edited file kept its old diff object")
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  eq(vim.api.nvim_buf_get_lines(t.S.buf, cur - 1, cur, false)[1], "+b2", "cursor did not stay on the same lazy diff row")
  local marks = vim.api.nvim_buf_get_extmarks(t.S.buf, t.ns, { cur - 1, 0 }, { cur - 1, -1 }, { details = true })
  eq(marks[1] and marks[1][4].hl_group, "GitDiffAdd")
  vim.api.nvim_feedkeys("Vks", "x", false) -- select -b1/+b2 through lazy R rows, then stage just them
  assert(vim.wait(5000, function()
    local d = g({ "diff", "--cached", "--", "b.txt" })
    return d:find("\n-line 6\n", 1, true) and d:find("\n+b2\n", 1, true)
  end, 20), "visual hunk lines were not staged")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("show: one process renders normal, root and empty commits; folds reuse cached rows", function()
  local rdir, g = repo()
  vim.fn.writefile({ "one" }, rdir .. "/f.txt")
  g({ "add", "." }); g({ "commit", "-qm", "root commit" })
  local root = vim.trim(g({ "rev-parse", "HEAD" }))
  vim.fn.writefile({ "one", "two" }, rdir .. "/f.txt")
  g({ "commit", "-qam", "second commit" })
  g({ "commit", "-q", "--allow-empty", "-m", "empty commit" })
  local cwd, oldroot = vim.fn.getcwd(), t.S.root
  vim.cmd.cd(rdir)
  t.S.root = rdir
  local counts, real = { show = 0, log1 = 0 }, vim.system
  vim.system = function(cmd, ...)
    if cmd[1] == "git" and cmd[2] == "show" then counts.show = counts.show + 1 end
    if cmd[1] == "git" and cmd[2] == "log" and cmd[3] == "-1" then counts.log1 = counts.log1 + 1 end
    return real(cmd, ...)
  end
  local function lines_of(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
  local function open_show(rev, pat)
    t.show(rev)
    assert(vim.wait(3000, function()
      local buf = vim.api.nvim_get_current_buf()
      return vim.api.nvim_buf_get_name(buf):find("git://show ", 1, true) and lines_of(buf):find(pat, 1, true)
    end, 10), "show never rendered " .. pat)
    return vim.api.nvim_get_current_buf()
  end
  local buf = open_show("HEAD~1", "second commit")
  assert(lines_of(buf):find("+two", 1, true), "patch missing")
  vim.api.nvim_win_set_cursor(0, { vim.fn.search("^modified\\s\\+f\\.txt", "nw"), 0 })
  local function keycb(k) return vim.fn.maparg(k, "n", false, true).callback() end
  keycb("za")
  assert(not lines_of(buf):find("+two", 1, true), "za did not fold the file")
  keycb("zR")
  assert(lines_of(buf):find("+two", 1, true), "zR did not reopen the cached file rows")
  local row = vim.fn.search("^+two$", "nw") - 1
  local marks = vim.api.nvim_buf_get_extmarks(buf, t.ns, { row, 0 }, { row, -1 }, { details = true })
  eq(marks[1] and marks[1][4].hl_group, "GitDiffAdd")
  keycb("zM")
  assert(not lines_of(buf):find("+two", 1, true), "zM did not fold the files")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  buf = open_show(root, "root commit")
  assert(lines_of(buf):find("+one", 1, true), "root patch missing")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  buf = open_show("HEAD", "Files (0)")
  assert(lines_of(buf):find("empty commit", 1, true), "empty commit header missing")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  eq(counts, { show = 3, log1 = 0 })
  local notes, realnotify = {}, vim.notify
  vim.notify = function(msg) notes[#notes + 1] = msg end
  t.show("definitely-not-a-rev")
  assert(vim.wait(2000, function() return #notes > 0 end, 10), "invalid rev never notified")
  vim.notify = realnotify
  assert(notes[1]:find("show: definitely-not-a-rev not found", 1, true), notes[1])
  vim.system = real
  t.S.root = oldroot
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("refresh: stash list is cached by reflog/ref stamp and always tracks pushes and drops", function()
  local rdir, g = repo()
  vim.fn.writefile({ "base" }, rdir .. "/s.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(vim.wait(3000, function() return t.S.data and t.S.data.stashes end, 10), "status never rendered")
  eq(t.S.data.stashes, {})
  vim.fn.writefile({ "base", "stashed" }, rdir .. "/s.txt")
  g({ "stash", "push", "-qm", "saved work" })
  petal.refresh()
  assert(vim.wait(3000, function() return t.S.data and #t.S.data.stashes == 1 end, 10), "stash never appeared")
  assert(t.S.data.stashes[1].subject:find("saved work", 1, true), t.S.data.stashes[1].subject)
  local cached = t.S.data.stashes
  petal.refresh()
  assert(vim.wait(3000, function() return t.S.data and #t.S.data.stashes == 1 end, 10), "cached refresh never landed")
  assert(t.S.data.stashes == cached, "unchanged stash list was not reused")
  g({ "stash", "drop", "-q", "stash@{0}" })
  petal.refresh()
  assert(vim.wait(3000, function() return t.S.data and #t.S.data.stashes == 0 end, 10), "stash drop never appeared")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("absorb: multiple files blame in one batch and fold into their unpushed owners", function()
  local rdir, g = repo()
  local a, b = {}, {}
  for i = 1, 8 do a[i], b[i] = "a" .. i, "b" .. i end
  vim.fn.writefile(a, rdir .. "/a.txt"); vim.fn.writefile(b, rdir .. "/b.txt")
  g({ "add", "." }); g({ "commit", "-qm", "base" })
  a[3] = "a owned"; vim.fn.writefile(a, rdir .. "/a.txt"); g({ "commit", "-qam", "change a" })
  b[3] = "b owned"; vim.fn.writefile(b, rdir .. "/b.txt"); g({ "commit", "-qam", "change b" })
  a[3] = "a absorbed"; vim.fn.writefile(a, rdir .. "/a.txt")
  b[3] = "b absorbed"; vim.fn.writefile(b, rdir .. "/b.txt")
  g({ "add", "a.txt", "b.txt" })
  local counts, real_system = { blame = 0 }, vim.system
  vim.system = function(cmd, ...)
    local s = table.concat(cmd, " ")
    if s:find("blame", 1, true) then counts.blame = counts.blame + 1 end
    return real_system(cmd, ...)
  end
  local real_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 1 end
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(rdir)
  petal.open()
  assert(vim.wait(3000, function() return t.S.data and #t.S.data.st.staged == 2 end, 10), "status never rendered")
  vim.api.nvim_feedkeys("a", "x", false) -- on the Head line: does nothing
  vim.wait(200)
  eq(#t.S.data.st.staged, 2)
  vim.fn.search("a.txt")
  vim.api.nvim_feedkeys("a", "x", false)
  assert(vim.wait(10000, function()
    return g({ "--no-optional-locks", "status", "--porcelain" }) == "" and g({ "log", "-2", "--format=%s" }) == "change b\nchange a\n"
  end, 50), "absorb did not finish cleanly")
  vim.fn.confirm = real_confirm
  vim.system = real_system
  eq(g({ "show", "HEAD:b.txt" }), "b1\nb2\nb absorbed\nb4\nb5\nb6\nb7\nb8\n")
  eq(g({ "show", "HEAD~1:a.txt" }), "a1\na2\na absorbed\na4\na5\na6\na7\na8\n")
  eq(counts.blame, 1, "two file blames were not in one git_batch process")
  vim.cmd.cd(cwd)
  vim.fn.delete(rdir, "rf")
end)

test("select: multi-select marks update in place and never leak into the next picker", function()
  local picker = require("petal.select")
  local mns = vim.api.nvim_create_namespace("petal.select.mark")
  picker.select({ "one", "two", "three", "four" }, { multi = true, prompt = "Pick" }, function() end)
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].filetype == "qf", "picker did not open a quickfix buffer")
  local function rows()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, mns, 0, -1, { details = true })) do
      out[m[2] + 1] = { id = m[1], text = m[4].virt_text[1][1] }
    end
    return out
  end
  local before = rows()
  eq(#vim.api.nvim_buf_get_extmarks(buf, mns, 0, -1, {}), 4)
  eq(before[1].text, "[ ] ")
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  local after = rows()
  eq(after[1].text, "[x] ")
  eq(after[2].text, "[ ] ")
  for i = 1, 4 do eq(after[i].id, before[i].id, "mark " .. i .. " was redrawn") end
  vim.api.nvim_feedkeys("q", "x", false)

  picker.select({ "one", "two" }, { prompt = "Pick one" }, function() end)
  local buf2 = vim.api.nvim_get_current_buf()
  assert(buf2 == buf, "quickfix buffer was not reused")
  eq(#vim.api.nvim_buf_get_extmarks(buf2, mns, 0, -1, {}), 0, "single-select kept stale multi-select marks")
  vim.api.nvim_feedkeys("q", "x", false)
end)

vim.fn.delete(dir, "rf")
print(("%d/%d passed"):format(n - fails, n))
os.exit(fails > 0 and 1 or 0)
