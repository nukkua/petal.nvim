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
  t.S.root = root
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
    local by = t.split_diff(out)
    for _, p in ipairs({ "a", "b", "c" }) do
      local ls = by["diff --git a/" .. p .. " b/" .. p]
      local old = t.parse_diff(table.concat(ls, "\n"))
      local copy = vim.list_extend({}, ls)
      while copy[#copy] == "" do copy[#copy] = nil end
      eq(t.parse_diff(copy), old, p .. " " .. table.concat(extra, " "))
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

vim.fn.delete(dir, "rf")
print(("%d/%d passed"):format(n - fails, n))
os.exit(fails > 0 and 1 or 0)
