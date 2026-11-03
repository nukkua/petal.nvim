-- petal/select.lua — a picker as a quickfix list
-- <CR> picks the cursor row, q/<Esc> or leaving the window cancels
-- opts.multi: <Tab> marks rows and <CR> returns the marked items as a list (just the cursor row if none)

local M = {}

function M.select(items, opts, on_choice)
  opts = opts or {}
  local fmt = opts.format_item or tostring
  if #items == 0 then return on_choice(nil, nil) end

  -- format_item may return { {text, hl}, ... } chunks: joined for the qf text, colored with extmarks
  local qf, hls = {}, {}
  for i, it in ipairs(items) do
    local v = fmt(it)
    if type(v) == "table" then
      local text = ""
      for _, c in ipairs(v) do
        if c[2] then hls[#hls + 1] = { i - 1, #text, #text + #c[1], c[2] } end
        text = text .. c[1]
      end
      v = text
    end
    qf[i] = { text = v }
  end
  -- new list (not "r") so :colder gets the previous errors back
  vim.fn.setqflist({}, " ", {
    title = opts.prompt and vim.trim(opts.prompt):gsub(":$", "") or "Select",
    items = qf,
    quickfixtextfunc = function(info)
      local lines = {}
      for i, it in ipairs(vim.fn.getqflist({ id = info.id, items = 1 }).items) do
        lines[i] = it.text
      end
      return lines
    end,
  })
  local id = vim.fn.getqflist({ id = 0 }).id
  vim.cmd("copen " .. (opts.height or 12))
  local buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_create_namespace("petal.select")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end

  local marked, mns = {}, vim.api.nvim_create_namespace("petal.select.mark")
  local function draw_marks()
    vim.api.nvim_buf_clear_namespace(buf, mns, 0, -1)
    for i = 1, #items do
      vim.api.nvim_buf_set_extmark(buf, mns, i - 1, 0, { virt_text_pos = "inline",
        virt_text = { marked[i] and { "[x] ", "Special" } or { "[ ] ", "Comment" } } })
    end
  end
  if opts.multi then draw_marks() end

  local finished = false
  local function finish(idx)
    if finished then return end
    finished = true
    vim.cmd("cclose")
    if not opts.multi then return on_choice(idx and items[idx] or nil, idx) end
    if not idx then return on_choice(nil) end
    local out = {}
    for i, it in ipairs(items) do if marked[i] then out[#out + 1] = it end end
    on_choice(#out > 0 and out or { items[idx] })
  end

  -- the qf buffer outlives this picker: keys only act while this list is current, otherwise as usual
  local function map(key, fn)
    vim.keymap.set("n", key, function()
      if finished or vim.fn.getqflist({ id = 0 }).id ~= id then
        return vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
      end
      fn()
    end, { buffer = buf, nowait = true })
  end
  map("<CR>", function() finish(vim.fn.line(".")) end)
  if opts.multi then
    map("<Tab>", function()
      local l = vim.fn.line(".")
      marked[l] = not marked[l] or nil
      draw_marks()
      if l < #items then vim.cmd("normal! j") end
    end)
  end
  for _, l in ipairs({ "q", "<Esc>" }) do map(l, function() finish(nil) end) end
  -- focus lost (mouse click, :wincmd) counts as cancel so the caller is never left hanging
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function() finish(nil) end })
end

return M
