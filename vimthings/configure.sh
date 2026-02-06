#!/bin/bash
set -e
command -v git >/dev/null 2>&1 || { echo "I require git but it's not installed.  Aborting." >&2; exit 1; }
mkdir -p ~/.vim
cp -r * ~/.vim/
cat olevimrc.vim >> ~/.vimrc
mkdir -p ~/.fonts
cp fonts/powerline/DejaVuSansMono/* ~/.fonts/
fc-cache -vf ~/.fonts/
cd ~/.vim
mkdir -p undodir
mkdir -p swapfiles

