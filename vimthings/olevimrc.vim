" .vimrc file
" Version: 220915
" author: @olemoudi
" compiled out of several online tutorial, tips, own prefs...

" UTF-8 before anything else: Windows Vim starts out in the legacy code page,
" and the airline symbols further down are UTF-8.
set encoding=utf-8
scriptencoding utf-8

" Per-user runtime dir: ~/vimfiles on Windows, ~/.vim everywhere else. The
" same file serves the terminal vim and Windows' gVim (olecharms copies it).
let s:vimdir = expand(has('win32') ? '$HOME/vimfiles' : '$HOME/.vim')

" Pathogen load
filetype off

call pathogen#infect()
call pathogen#helptags()

filetype plugin indent on
syntax on

"""""""""""""""""
""" Variables """
"""""""""""""""""

set cindent                 " avoid # comments going to sol
let mapleader = ","         " neat
set nocompatible
set visualbell              " please dont beep, thanks
set fileencodings=utf-8     " yes please
set fileformat=unix         " plzkthxbye
set backupcopy=yes

set history=1000            " keep a longer history
set hidden                  " manage multiple buffers effectively
set wildmenu                " show alternatives when autocompleting with tab
set wildmode=full           " <Tab> cycles between all matching choices.
set wildmode=list:longest   " like a shell
set title                   " set terminal title

set number                  " linenumbers
set numberwidth=3           " using only 1 column (and 1 space) while possible
set background=dark
set backspace=indent,eol,start " Intuitive backspacing in insert mode

" File-type highlighting and configuration.
" Run :filetype (without args) to see what you may have
" to turn on yourself, or just set them all to be sure.
syntax on
filetype on
filetype plugin on
filetype indent on
set undofile " Maintain history of undos between sessions
" Use let &opt so a $HOME containing spaces does not need escaping
let &undodir = s:vimdir . '/undodir'
" Trailing // names swap files after the full path: two README.md from
" different projects would otherwise share one swap file
let &directory = s:vimdir . '/swapfiles//'
 
" Highlight search terms...
set hlsearch
set incsearch               " ...dynamically as they are typed.

""" Moving Around/Editing
"set cursorline             " have a line indicate the cursor location
set ruler                   " show the cursor position all the time
set nostartofline           " Avoid moving cursor to BOL when jumping around
set noendofline             " Avoid moving cursor do EOL when jumping around
set virtualedit=block       " Let cursor move past the last char in <C-v> mode
set scrolloff=5             " Keep 5 context lines above and below the cursor
set backspace=2             " Allow backspacing over autoindent, EOL, and BOL
set showmatch               " Briefly jump to a paren once it's balanced
set wrap                    " wrap lines
set lbr                     " dont split words at EOL
"set nowrap                 " don't wrap text
"set linebreak              " don't wrap textin the middle of a word
set autoindent              " always set autoindenting on
set smartindent             " use smart indent if there is no indent file
set tabstop=4               " <tab> inserts 4 spaces 
set shiftwidth=4            " but an indent level is 2 spaces wide.
set softtabstop=4           " <BS> over an autoindent deletes both spaces.
set expandtab               " Use spaces, not tabs, for autoindent/tab key.
set shiftround              " rounds indent to a multiple of shiftwidth
set matchpairs+=<:>         " show matching <> (html mainly) as well
set foldmethod=indent       " allow us to fold on indents
set foldlevel=99            " don't fold by default

set clipboard=unnamed		"Now all operations work with the OS clipboard. No need for "+, "*

"""" Reading/Writing
set noautowrite             " Never write a file unless I request it.
set noautowriteall          " NEVER.
set noautoread              " Don't automatically re-read changed files.
set modeline                " Allow vim options to be embedded in files;
set modelines=5             " they must be within the first or last 5 lines.
set ffs=unix,dos,mac        " Try recognizing dos, unix, and mac line endings.

"""" Messages, Info, Status
set ls=2                    " allways show status line
"set noerrorbells           " don't bell or blink
set vb t_vb=                " Disable all bells.  I hate ringing/flashing.
set confirm                 " Y-N-C prompt if closing with unsaved changes.
set showcmd                 " Show incomplete normal mode commands as I type.
set report=0                " : commands always print changed line count.
set shortmess+=a            " Use [+]/[RO]/[w] for modified/readonly/written.
set laststatus=2            " Always show statusline, even if only 1 window.
set statusline=[%l,%v\ %P%M]\ %f\ %r%h%w\ (%{&ff}) 
"set statusline=[%l,%v\ %P%M]\ %f\ %r%h%w\ (%{&ff}) %{fugitive#statusline()}
set mouse=a                 " Enable basic mouse behaviour such as resizing buffers

""" Searching and Patterns
set ignorecase              " Default to using case insensitive searches,
set smartcase               " unless uppercase letters are used in the regex.
set smarttab                " Handle tabs more intelligently 
set hlsearch                " Highlight searches by default.
set incsearch               " Incrementally search while typing a /regex

"""" Display
" Patched Powerline font (https://github.com/powerline/fonts); every GUI spells
" font names its own way. Harmless in a terminal.
if has('win32')
    set guifont=DejaVu_Sans_Mono_for_Powerline:h12
elseif has('mac')
    set guifont=DejaVu\ Sans\ Mono\ for\ Powerline:h13
else
    set guifont=DejaVu\ Sans\ Mono\ for\ Powerline\ 12
endif
if has("gui_running")
    set lines=50 columns=130
endif
colorscheme desert

""""


""""""""""""""""""""""""
""" Leader shortcuts """
""""""""""""""""""""""""
""" Keep this section 
""" sorted alphabetically per keybind

"If the search term highlighting gets annoying, set a key to switch it off temporarily
" nmap <silent> <leader>n :silent :nohlsearch<CR>
" also <leader>space
nnoremap <leader><space> :nohlsearch<cr>

" close buffer and maintain status
nnoremap <leader>c :b#<bar>bd#<CR>

" Paste from clipboard
map <leader>p "+gP

" Quit window on <leader>q
nnoremap <leader>q :q<CR>

" ,v brings up my .vimrc
map <leader>v :sp $MYVIMRC<CR><C-W>_
" ,V reloads it -- making all changes active (have to save first)
map <silent> <leader>V :source $MYVIMRC<CR>:filetype detect<CR>:exe ":echo 'vimrc reloaded'"<CR>

""""


""""""""""""""""""""""
""" Confy commands """
""""""""""""""""""""""
" Seriously, guys. It's not like :W is bound to anything anyway.
command! W :w
" for when we forget to use sudo to open/edit a file
cmap w!! w !sudo tee % >/dev/null
" sudo write this
cmap W! w !sudo tee % >/dev/null
" don't outdent hashes
"inoremap # #
""" being sane
inoremap jj <Esc>
inoremap kk <Esc>
" control+s to save (mswin.vim maps it too, but terminal Vim skips mswin.vim)
nnoremap <silent> <c-s> :update<CR>
inoremap <silent> <c-s> <c-o>:update<CR>
if has('win32') || has('gui_running')
    source $VIMRUNTIME/mswin.vim
    behave mswin
endif

""" System clipboard in terminal Vim
" 'clipboard=unnamed' above needs a Vim built with a working clipboard; the
" terminal Vim of WSL, Debian/Ubuntu and macOS (/usr/bin/vim) usually is not,
" and there "+ is not even a valid register. There, olecharms' bin/olecharms-clip
" stands in (clip.exe on WSL, pbcopy, wl-copy/xclip, OSC 52 over SSH):
"   y (any yank) also lands on the system clipboard, as with 'unnamed'
"   "+ / "* before y, d, c, x... copy the text too
"   "+p "+P "+gp "+gP paste the system clipboard (also ,p);  <C-r>+ in insert
"   and command-line mode
" Deletes stay inside Vim, so x or dd never wipe what you copied elsewhere.
" Ctrl-C copies a visual selection, as in Windows.
if !has('gui_running') && !has('win32')
    xmap <c-c> "+y
endif
let s:clip = fnamemodify(resolve(expand('<sfile>:p')), ':h:h') . '/bin/olecharms-clip'
" A native clipboard that works makes all this unnecessary. Vims before
" 8.1.1837 cannot tell whether theirs works: trust +clipboard there.
let s:clip_native = has('patch-8.1.1837') ? has('clipboard_working') : has('clipboard')
if !has('gui_running') && !has('win32') && !s:clip_native && exists('##TextYankPost') && filereadable(s:clip)
    let s:clip_text = ''
    let s:clip_warned = 0
    let s:clip_timer = -1
    let s:clip_backend = ''

    function! s:ClipBackend() abort
        if s:clip_backend ==# ''
            let s:clip_backend = substitute(system('sh ' . shellescape(s:clip) . ' backend'), '\n', '', 'g')
        endif
        return s:clip_backend
    endfunction

    function! s:ClipWarn(msg) abort
        echohl WarningMsg | echomsg 'clipboard: ' . substitute(a:msg, '\n\+$', '', '') | echohl None
    endfunction

    " Over SSH the copy is an escape sequence for the local terminal: Vim
    " sends it itself, a background job has no terminal to write to
    function! s:ClipOsc52(text) abort
        if exists('*base64_encode') && exists('*str2blob')
            let b64 = base64_encode(str2blob(split(a:text, "\n", 1)))
        else
            let b64 = substitute(system('base64', a:text), '\n', '', 'g')
        endif
        let seq = "\e]52;c;" . b64 . "\x07"
        if !empty($TMUX)
            let seq = "\ePtmux;\e" . seq . "\e\\"
        endif
        if exists('*echoraw')
            call echoraw(seq)
        else
            call writefile([seq], '/dev/tty', 'b')
        endif
    endfunction

    function! s:ClipSend(sync) abort
        let s:clip_timer = -1
        let text = s:clip_text
        if s:ClipBackend() ==# 'none'
            " No clipboard here (a console, sudo -i...): say so once, not per yank
            if !s:clip_warned
                let s:clip_warned = 1
                call s:ClipWarn('no system clipboard here; yanks stay inside Vim')
            endif
        elseif s:ClipBackend() ==# 'ssh'
            call s:ClipOsc52(text)
        elseif has('job') && !a:sync
            " In the background, so a yank never waits for clip.exe & co.
            let job = job_start(['sh', s:clip, 'copy'], {'in_io': 'pipe', 'out_io': 'null',
                        \ 'err_cb': {ch, msg -> s:ClipWarn(msg)}, 'stoponexit': ''})
            call ch_sendraw(job, text)
            call ch_close_in(job)
        else
            let out = system('sh ' . shellescape(s:clip) . ' copy', text)
            if v:shell_error | call s:ClipWarn(out) | endif
        endif
    endfunction

    " Copied: any yank to the default register, and anything done with "+ / "*
    " (which arrive as an explicit "", reported as regname '"'). Wait a moment
    " before copying: a macro doing many yanks copies once.
    function! s:ClipYanked() abort
        if !(v:event.regname ==# '"' || (v:event.regname ==# '' && v:event.operator ==# 'y'))
            return
        endif
        let s:clip_text = join(v:event.regcontents, "\n") . (v:event.regtype ==# 'V' ? "\n" : '')
        if has('timers')
            call timer_stop(s:clip_timer)
            let s:clip_timer = timer_start(150, {_ -> s:ClipSend(0)})
        else
            call s:ClipSend(0)
        endif
    endfunction

    function! s:ClipFlush() abort
        if s:clip_timer != -1
            call timer_stop(s:clip_timer)
            call s:ClipSend(1)
        endif
    endfunction

    " "+ and "* become an explicit "" (Vim without a clipboard rejects them),
    " which TextYankPost reports as regname '"'
    function! s:ClipArm() abort
        return '""'
    endfunction

    function! s:ClipGet() abort
        let text = system('sh ' . shellescape(s:clip) . ' paste')
        if v:shell_error
            call s:ClipWarn(text)
            return ''
        endif
        return substitute(text, "\r", '', 'g')
    endfunction

    function! s:ClipPaste(cmd, count, visual) abort
        let text = s:ClipGet()
        if text ==# ''
            if !v:shell_error | echo 'clipboard: empty' | endif
            return
        endif
        call setreg('"', text)
        " No explicit "" here: the text a visual paste replaces must not be
        " copied back over the clipboard
        execute 'normal! ' . (a:visual ? 'gv' : a:count) . a:cmd
    endfunction

    augroup olecharms_clipboard
        autocmd!
        autocmd TextYankPost * call s:ClipYanked()
        autocmd VimLeavePre * call s:ClipFlush()
    augroup END
    for s:r in ['+', '*']
        execute 'nnoremap <expr> "' . s:r . ' <SID>ClipArm()'
        execute 'xnoremap <expr> "' . s:r . ' <SID>ClipArm()'
        for s:p in ['p', 'P', 'gp', 'gP']
            execute 'nnoremap <silent> "' . s:r . s:p . ' :<C-u>call <SID>ClipPaste(' . string(s:p) . ', v:count1, 0)<CR>'
            execute 'xnoremap <silent> "' . s:r . s:p . ' :<C-u>call <SID>ClipPaste(' . string(s:p) . ', 1, 1)<CR>'
        endfor
        execute 'inoremap <silent> <C-r>' . s:r . ' <C-r><C-r>=<SID>ClipGet()<CR>'
        execute 'cnoremap <C-r>' . s:r . ' <C-r>=substitute(<SID>ClipGet(), "\n", " ", "g")<CR>'
    endfor
    unlet s:r s:p
endif


""""


"""""""""""""""""""""""""
""" Movement commands """
"""""""""""""""""""""""""
" ctrl-jklh  changes focus to corresponding buffer
map <c-j> <c-w>j
map <c-k> <c-w>k
map <c-l> <c-w>l
map <c-h> <c-w>h
" and lets make these all work in insert mode too ( <C-O> makes next cmd
"  happen as if in command mode )
imap <C-W> <C-O><C-W>

" Previous buffer (Ctrl-N is next). A comment after a mapping becomes part
" of it, and <c-B> is the same key as <c-b>, so the old next/previous pair
" ended up as previous plus stray keystrokes.
map <c-b> :bp<CR>
" Cycle through buffers
nnoremap <c-n> :bnext<CR>

" Scroll the viewport faster
nnoremap <C-e> 3<C-e>
nnoremap <C-y> 3<C-y>

" Move by 'display lines' rather than 'logical lines'
nnoremap <silent> j gj
nnoremap <silent> k gk
" Make logical line move accessible
nnoremap <silent> gj j
nnoremap <silent> gk k

" pag forward/backward easier
nnoremap J <c-f>
nnoremap K <c-b>

" ffs move to the right
" nnoremap i a

" Cycle thorugh buffers like web-browser tabs
if has("gui_running")
    nnoremap <c-Tab> :bnext<CR>
    nnoremap <c-S-Tab> :bprevious<CR>
endif

""""

"""""""""""""""
""" Plugins """
"""""""""""""""

" example of aliases
" for loop
"map! =for for ($i = 0; $i ; $i++<Right> {<Up><Up><ESC>/ ;<CR>i


""" NERDTree
nmap <leader>N :NERDTree<CR>
nmap <leader>D :NERDTreeToggle<CR>
nmap <leader>F :NERDTreeFind<CR>


""" CtrlP
nmap <leader>b :CtrlPBuffer<CR>
nmap <leader>t :CtrlP<CR>
nmap <leader>T :CtrlPClearCache<CR>:CtrlP<CR>
" Search with ripgrep, or ag, when installed: :grep (results in the quickfix
" list) and CtrlP's file list — fast, and they skip what .gitignore hides
if executable('rg')
    set grepprg=rg\ --vimgrep\ --smart-case
    set grepformat=%f:%l:%c:%m
    let g:ctrlp_user_command = 'rg %s --files --hidden --glob "!.git"'
    let g:ctrlp_use_caching = 0
elseif executable('ag')
    set grepprg=ag\ --vimgrep\ --smart-case
    set grepformat=%f:%l:%c:%m
    let g:ctrlp_user_command = 'ag %s -l --nocolor --hidden --ignore .git -g ""'
    let g:ctrlp_use_caching = 0
endif

""" python-mode
" let g:pymode_options_max_line_length = 119
" do not autoopen quickfix window when errors are found
" let g:pymode_lint_cwindow = 0
" let g:pymode_python = 'python'
" leave lint to syntastic
" let g:pymode_lint = 0
" let g:pymode_lint_write = 0

""" syntastic
let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 0
let g:syntastic_check_on_open = 0
let g:syntastic_check_on_wq = 0
nmap <leader>S :SyntasticToggleMode<CR>
nmap <leader>s :SyntasticCheck<CR>

""" jedi 
" I dont want the docstring window of jedi
" autocmd FileType python setlocal completeopt-=preview


""" vim-airline
let g:airline_powerline_fonts = 1
if !exists('g:airline_symbols')
    let g:airline_symbols = {}
endif
" enable tabs
let g:airline#extensions#tabline#enabled = 1

" unicode symbols
let g:airline_left_sep = '»'
let g:airline_left_sep = '▶'
let g:airline_right_sep = '«'
let g:airline_right_sep = '◀'
let g:airline_symbols.linenr = '␊'
let g:airline_symbols.linenr = '␤'
let g:airline_symbols.linenr = '¶'
let g:airline_symbols.branch = '⎇'
let g:airline_symbols.paste = 'ρ'
let g:airline_symbols.paste = 'Þ'
let g:airline_symbols.paste = '∥'
let g:airline_symbols.whitespace = 'Ξ'

""" ctrlp help
"Press <F5> to purge the cache for the current directory to get new files, remove deleted files and apply new ignore options.
"Press <c-f> and <c-b> to cycle between modes.
"Press <c-d> to switch to filename only search instead of full path.
"Press <c-r> to switch to regexp mode.
"Use <c-j>, <c-k> or the arrow keys to navigate the result list.
"Use <c-t> or <c-v>, <c-x> to open the selected entry in a new tab or in a new split.
"Use <c-n>, <c-p> to select the next/previous string in the prompt's history.
"Use <c-y> to create a new file and its parent directories.
"Use <c-z> to mark/unmark multiple files and <c-o> to open them

""" closetag
let g:closetag_filenames = '*.html,*.xhtml,*.phtml, *.xml'

""" easymotion
" make it work similarly to smartcase
let g:EasyMotion_smartcase = 1


