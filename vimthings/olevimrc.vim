" .vimrc file
" Version: 220915
" author: @olemoudi
" compiled out of several online tutorial, tips, own prefs...

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
set undodir=$HOME/.vim/undodir
set directory=$HOME/.vim/swapfiles
 
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
if has("gui_running")
    set lines=50 columns=130
    " windows format
    set guifont=DejaVu_Sans_Mono_for_Powerline:h12
    "Try patched powerline font
    "https://github.com/powerline/fonts
    colorscheme desert
else
    colorscheme desert
endif

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
" control+s to save
imap <c-s> <c-o><c-s>        
if has('win32') || has('gui_running')
    source $VIMRUNTIME/mswin.vim
    behave mswin
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

map <c-b> :bn<CR> " next buffer
map <c-B> :bp<CR> " previous buffer
" Cycle through buffers
nnoremap <c-n>  :bnext<CR> 

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
set guifont=DejaVu_Sans_Mono_for_Powerline:h12
if !exists('g:airline_symbols')
    let g:airline_symbols = {}
endif
" enable tabs
let g:airline#extensions#tabline#enabled = 1

set encoding=utf-8
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


