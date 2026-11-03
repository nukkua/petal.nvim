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

vim.fn.delete(dir, "rf")
print(("%d/%d passed"):format(n - fails, n))
os.exit(fails > 0 and 1 or 0)
