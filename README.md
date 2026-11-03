# petal.nvim

Magit-style git status for Neovim, built on the git CLI. Every git call is async, and there's
GitHub PR support through `gh`.

## Requirements

- Neovim 0.12+
- `git`
- optional: [`gh`](https://cli.github.com) for pull requests
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for progress spinners (without it you get plain notifications)

## Install

```lua
-- vim.pack
vim.pack.add({ "https://github.com/nukkua/petal.nvim" })

-- lazy.nvim
{ "nukkua/petal.nvim", opts = {} }
```

## Setup

`setup()` is optional. These are the defaults:

```lua
require("petal").setup({
  reviewers = {},                                      -- picked from when creating a PR; empty = never asks
  base_branches = { "origin/develop", "origin/main" }, -- tried in order for "merged into", then origin/HEAD
  recent = 10,                                         -- commits in the Recent section
  height = 12,                                         -- height of the bottom pickers/popups
  commit_suggest = nil,                                -- agent that suggests commit messages, see below
})

vim.keymap.set("n", "<leader>gg", "<cmd>Petal<cr>", { desc = "Git status" })
```

## Usage

- `:Petal` opens the status buffer. Press `?` inside it to list every key.
- `:Petal <args>` runs a single git command, e.g. `:Petal log -5`.
- `O` opens the PR popup: list (`<CR>` copies the PR URL), create, open, close.
- Creating a PR with `reviewers` set opens a quickfix picker. `<Tab>` marks one or more reviewers
  and `<CR>` confirms. `<CR>` with nothing marked takes the row under the cursor, and the
  `(no reviewer)` row creates the PR without one.

## Commit message suggestions

Set `commit_suggest` to a command that reads the staged diff on stdin and prints a commit
message. It starts as soon as the commit buffer opens. While the message is empty, the
suggestion shows as ghost text; press `<c-c><c-s>` to accept it. If you press it before the
agent answers, the message goes in when it arrives. Typing your own message hides the ghost,
and closing the buffer stops the agent. Here it is with [Claude Code](https://claude.com/claude-code):

```lua
require("petal").setup({
  commit_suggest = { "claude", "-p", "--model", "haiku",
    "Write ONE git commit message for the staged diff on stdin, Conventional Commits style: "
    .. "type(scope): subject. Types: feat fix refactor docs style test perf build ci chore revert; "
    .. "scope optional, lowercase. Subject: imperative, lowercase, max 50 chars, no period. "
    .. "No body unless the why is truly non-obvious, then one blank line and at most 2 short lines. "
    .. "Output only the message: no quotes, no code fences, no Co-Authored-By or other trailers." },
})
```

Any CLI that works this way can be used, e.g. `llm` or `ollama run`.

## Highlights

Every group is defined with `default = true`, so your colorscheme can override any of them.
Git groups are named `Git*` (e.g. `GitSectionHeader`, `GitDiffAdd`) and PR groups are
`PrOpen`, `PrMerged`, `PrClosed`, `PrDraft`, `PrWarn` and `PrBranch`.

## Inspiration

- [Neogit](https://github.com/NeogitOrg/neogit) is the main inspiration. Petal borrows its status
  layout, its popups with switches, and the idea of bringing magit to Neovim.
- [Magit](https://magit.vc) is the original Emacs workflow that all of this comes from.
- [vim-fugitive](https://github.com/tpope/vim-fugitive) showed that Neovim can wrap the git CLI
  directly.

## License

[MIT](LICENSE)
