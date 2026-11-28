# petal.nvim

Magit-style Git status for Neovim, built on the Git CLI. Status refreshes and Git actions run
asynchronously; initial repository discovery is synchronous. GitHub PR support uses `gh`.


## Requirements

- Neovim 0.12+
- `git` (2.38+ for conflict previews; 2.40+ for moving hunks between commits)
- A POSIX shell (`sh`)
- optional: [`gh`](https://cli.github.com) for pull requests (`gh auth login`)
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for progress spinners (without it you get plain notifications)

Git runs without interactive credential prompts. Set up an SSH agent or a credential helper
before fetching or pushing.

## Install

```lua
-- vim.pack
vim.pack.add({ "https://github.com/nukkua/petal.nvim" })

-- lazy.nvim
{ "nukkua/petal.nvim", opts = {} }
```

## Setup

`setup()` is optional. It records options without loading the core until first use.
Options are merged shallowly: a table you pass replaces that entire option. These are the defaults:

```lua
require("petal").setup({
  reviewers = {},                                      -- picked from when creating a PR; empty = never asks
  base_branches = { "origin/develop", "origin/main" },  -- first existing ref; otherwise origin/HEAD, then origin/develop
  recent = 10,                                         -- commits in the Recent section
  height = 12,                                         -- height of the bottom pickers/popups
  commit_suggest = nil,                                -- agent that suggests commit messages, see below
  mappings = {},                                       -- status keys, see below
  watch = true,                                        -- refresh when the repo changes outside nvim
  diff_ribbons = true,                                 -- use the optional diff-ribbons.nvim gutter with d
  simple = false,                                      -- core status and keys only, see below
})

vim.keymap.set("n", "<leader>gg", "<cmd>Petal<cr>", { desc = "Git status" })
```

## Simple mode

`simple = true` keeps petal plain: the status buffer and the core keys (`c b f p P l Z`,
`s S <C-s> u U x`, `d e`, `<C-r> <CR>`, folds, `?`, `q`). It turns off the automatic PR line and
branch-list PR badges, the conflict radar, the background fetch on open, the file watcher and
the summary under the commit buffer. Pull and push can still fetch. You can bind any other
action yourself, e.g. `mappings = { r = "rebase", O = "pr" }`.

## Usage

- `:Petal` opens the status buffer for the current directory's repository, or offers to initialize
  one. Press `?` to list your active keys. Full docs: `:h petal`.
- `:Petal <args>` runs `git <args>` through the shell (e.g. `:Petal log -5`); `Q` prompts for the
  arguments. After opening Petal, commands run from the selected repository root.
- `d` compares the working file against HEAD. `:DiffOff` returns to status without saving or
  dropping edits; in the diff, `ZZ` saves and `ZQ` discards unsaved edits. `e` opens conflict
  resolution on a conflicted file.
- Install [diff-ribbons.nvim](https://github.com/nukkua/diff-ribbons.nvim) to connect changes
  across the two panes opened by `d`, using your colorscheme. Set `diff_ribbons = false` to
  keep the native view even when the plugin is installed.
- `D` opens the diff popup: what your branch adds vs its base (`base...HEAD`), vs any ref, or any range.
- `b l` and `b R` list local and remote branches. Use `<CR>` to switch or edit the list and write
  it with `:w`; remote edits are limited to deleting eligible branches with merged PRs.
- `a` absorbs eligible staged hunks into their unpushed commits after a preview; `o` in a commit
  view moves a hunk or file's hunks to another unpushed commit without changing HEAD's final tree.
- `O` opens the PR popup: list (`<CR>` copies the PR URL), checkout, diff, checks (`<CR>` on a failed
  GitHub Actions job shows its failed-step log), create, open, close.
- Creating a PR with `reviewers` set opens a quickfix picker. `<Tab>` marks one or more reviewers
  and `<CR>` confirms. `<CR>` with nothing marked takes the row under the cursor, and the
  `(no reviewer)` row creates the PR without one.

## Mappings

`mappings` maps a key to an action name (listed in `:h petal-actions`) or to `false` to remove it.
A key you set replaces its default; the rest stay. Configure mappings before the first status
buffer opens. To move an action, disable its old key as well as binding the new one.

```lua
require("petal").setup({
  mappings = {
    x = false,                 -- no discard on x
    ["<leader>x"] = "discard", -- discard moves here
    ["<Tab>"] = "toggle_fold",
  },
})
```

`:checkhealth petal` checks the Neovim version, Git, `gh` and its login, fidget,
`commit_suggest` and `mappings`.

## Commit message suggestions

Outside simple mode, the commit buffer opens above a summary of the changes in the index Git
will commit (including any temporary index Git uses). Amend compares against HEAD's parent,
or the empty tree for the root commit. The summary shows each file's +/− counts; press `za` to
see its diff. In the message buffer, `<C-c><C-c>` saves and closes it; `<C-c><C-k>` aborts.

Set `commit_suggest` to a command that reads the diff being committed on stdin and prints a commit
message. Petal sends the diff to that command when the commit buffer opens, if the diff isn't
empty. Choose the command with that access in mind. While the message is empty, the
suggestion shows as ghost text; press `<c-c><c-s>` to accept it, or `<c-c><c-y>` to accept it
and commit right away. If you press either before the command answers, it takes effect when the
message arrives if you're still in the commit buffer. Typing your own message hides the ghost:
`<c-c><c-s>` can replace it, but `<c-c><c-y>` won't. Closing the buffer stops a running suggestion.
Here it is with [Claude Code](https://claude.com/claude-code):

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

## Tests

```sh
nvim -l tests/run.lua
```

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

Designed and developed with AI-assisted implementation. I defined the requirements, workflows, and desired behavior.

## License

[MIT](LICENSE)
