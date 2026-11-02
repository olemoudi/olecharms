# olecharms

My terminal environment — vim, zsh (oh-my-zsh), fonts and shell utilities —
set up the same way on Linux, macOS and WSL. From WSL it also configures
Windows' own gVim and installs the fonts for Windows.

## Install

On a new machine, as your normal user (not root):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/olemoudi/olecharms/master/bootstrap.sh)"
```

It installs git if it is missing, clones this repository into `~/olecharms`
(set `OLECHARMS_DIR` to use another folder) and runs `olecharms install`,
which asks before using sudo for system packages. Without root or Homebrew
it installs what it can in your home instead (rg, fd, bat, delta, jq, fzf,
zoxide, tldr and mise, with mise, npm or the project's install script, which
it downloads first and then runs, never piped), points `npm install -g` at
`~/.local`, and tells you what is left. Running it again is safe: an
existing checkout is updated, never replaced.

Or by hand:

```sh
git clone https://github.com/olemoudi/olecharms.git ~/olecharms
~/olecharms/olecharms.sh install
```

Then open a new terminal (or run `exec zsh`).

## Everyday use

```sh
olecharms update        # pull the latest changes and re-apply everything
olecharms sync          # quicker: pull and refresh, no packages or plugins
olecharms doctor --fix  # find what is broken and repair it (asks first)
olecharms config        # downloads cleanup, paranoid mode, shared settings, zsh extras
olecharms help          # every command
```

Handy commands it adds (`olecharms help` lists them all):

```sh
j proj                  # jump to a folder you have visited (zoxide; ji picks one)
trash old.zip build/    # delete recoverably (Recycle Bin, Trash or a 30-day quarantine)
ssk bind work ~/work    # git inside ~/work always uses the "work" SSH key and email
ssk run personal -- git push   # one command as another identity, nothing global changes
wt feature-x            # a git worktree per task or agent; wt rm feature-x
pwd | copy              # the clipboard, the same on Linux, macOS, WSL and over SSH
```

On macOS, `olecharms macvim` installs MacVim in `~/Applications` (no admin
needed) with the same config and plugins as vim, and links `mvim`.

Coding agents (Claude Code, Codex, Gemini CLI) are told about these, and about
which identity goes with which folder: `olecharms agents show`.

How it works inside: [ARCHITECTURE.md](ARCHITECTURE.md). Tests: `tests/run.sh`
(sandboxed: they never touch your files; `--full` adds a real update on WSL).
