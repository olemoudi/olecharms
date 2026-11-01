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
which asks for sudo to install system packages. Running it again is safe: an
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

How it works inside: [ARCHITECTURE.md](ARCHITECTURE.md). Tests: `tests/run.sh`
(sandboxed: they never touch your files; `--full` adds a real update on WSL).
