" Vim configuration file
" Maintainer:   Pierre-Antoine Lacaze
" This is a simplified version for server use

"{{{            Generic Settings - 1st part
"-----------------------------------------------
scriptencoding utf-8
set history=1000
set viminfo='1000,:1000,/1000
"}}}

"{{{            Pathes & Backups
 "-----------------------------------------------
let g:my_vimfiles_dir = "~/.config/nvim"
let s:my_cache_dir    = expand(g:my_vimfiles_dir) . "/cache"
let s:my_backupdir    = expand(s:my_cache_dir) . "/backup//"
let s:my_directory    = expand(s:my_cache_dir) . "/swap//"
let s:my_undodir      = expand(s:my_cache_dir) . "/undo//"

if !isdirectory(s:my_backupdir)
    call mkdir(s:my_backupdir, "p")
endif
if !isdirectory(s:my_directory)
    call mkdir(s:my_directory, "p")
endif
if !isdirectory(s:my_undodir)
    call mkdir(s:my_undodir, "p")
endif

let &backupdir = expand(s:my_backupdir)
let &directory = expand(s:my_directory)
let &undodir   = expand(s:my_undodir)

set backup " make a backup file
set writebackup
set swapfile
set undofile
set undolevels=1000
set undoreload=10000
"}}}

"{{{            Plugins management
" Bootstrap vim-plug, git and curl must be installed
let autoload_plug_path = stdpath('data') . '/site/autoload/plug.vim'
if !filereadable(autoload_plug_path)
    silent! execute '!curl -fsSLo ' . autoload_plug_path . '  --create-dirs
        \ "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"'
    autocmd VimEnter * silent! PlugInstall
endif
unlet autoload_plug_path

silent! if plug#begin(expand(stdpath('data') . '/plugged'))
    " Seamless navigation between tmux panes and vim splits
    Plug 'christoomey/vim-tmux-navigator'

    " File explorer
    Plug 'scrooloose/nerdtree' , { 'on': 'NERDTreeToggle' }

    " Handle big files
    Plug 'jreybert/vim-largefile'

    " Improved netrw
    Plug 'justinmk/vim-dirvish'

    " fzf integration
    Plug 'junegunn/fzf.vim'

    " Fix repeat in a number of plugins.
    Plug 'tpope/vim-repeat'

    " Comment stuff out
    Plug 'tomtom/tcomment_vim'

    " Switch between .h and .cpp
    Plug 'derekwyatt/vim-fswitch'

    " Lean & mean status/tabline for vim that's light as air
    Plug 'vim-airline/vim-airline'
    Plug 'vim-airline/vim-airline-themes'

    " Git wrapper
    Plug 'tpope/vim-fugitive'
    Plug 'junegunn/gv.vim'

    " A Vim plugin which shows a git diff in the gutter
    Plug 'airblade/vim-gitgutter'

    " A nice colorscheme
    Plug 'morhetz/gruvbox'

    " Additional syntax files
    Plug 'sheerun/vim-polyglot'

    call plug#end()
endif

let fzf_plug_path =  '/usr/share/doc/fzf/examples/plugin/fzf.vim'
if filereadable(fzf_plug_path)
    execute "source" . fzf_plug_path
endif
unlet fzf_plug_path

" }}}

"{{{            Generic Settings - 2nd part
"-----------------------------------------------
filetype on
filetype plugin on
filetype indent on
set nomodeline
"}}}

"{{{            Colors
"----------------------------------------------
set termencoding=utf-8
set termguicolors

if has('gui_running') || &t_Co > 2
    syntax on
    set background=dark

    let g:gruvbox_contrast_light='soft'
    let g:gruvbox_contrast_dark='hard'
    colorscheme gruvbox
endif

"}}}

"{{{            UI behaviour
"-----------------------------------------------
set number
set hidden
set showmatch
set showcmd
set showmode
set laststatus=2 " always show the status line

let g:terminal_scrollback_buffer_size=20000

set guicursor=n-v-c:block-Cursor/lCursor-blinkon0,i-ci:ver25-Cursor/lCursor,r-cr:hor20-Cursor/lCursor

set inccommand=nosplit
" set cmdheight=2

" Update sign column every 250 ms
set updatetime=250

set splitbelow splitright

set scrolloff=3 " at least one line after cursor
set sidescrolloff=2

set display+=lastline
set tabpagemax=50

" tab complete menu
set wildmenu
set wildmode=list:longest,full
set wildignore+=*.o,*~,*.bak,*.obj

" no noise, use this trick on visualbell because it is reset in guimode
set noerrorbells
set visualbell t_vb=
if has("autocmd")
    autocmd GUIEnter * set visualbell t_vb=
endif

" avoid Esc key pauses triggered by remapped meta keycodes
set timeout timeoutlen=1000 ttimeoutlen=10

set conceallevel=2
set guioptions-=T        " remove useless UI
set shortmess=atI        " remove useless messages
set lazyredraw           " speedup processing

" set fillchars+=fold:.
set foldmethod=marker
set foldlevel=99

"}}}

"{{{            Text editing
"-----------------------------------------------
" enable virtual edit in vblock mode, and one past the end
set virtualedit=block,onemore
set backspace=indent,eol,start  " make backspace delete anything

set encoding=utf8
set fileformats=unix,dos,mac

function! <SID>check_pager_mode()
    if exists("g:loaded_less") && g:loaded_less
        set laststatus=0
        set ruler
        set foldmethod=manual
        set foldlevel=99
        set nolist
    endif
endfunction
au VimEnter * :call <SID>check_pager_mode()

set formatoptions=crqn

let mapleader="\<SPACE>"

set nowrap
set whichwrap=<,>,[,],
set linebreak  " Wrap on words

"display tabs and trailing spaces
set listchars=tab:>-,trail:.,nbsp:.
set nolist

" indent options
set shiftwidth=4
set softtabstop=4
"set tabstop=4
set shiftround
set autoindent
set smartindent
set expandtab
set smarttab
set cinoptions=l1,g0,N-s,t0,j1,(0,ws,Ws,+0
"}}}

"{{{            Mouse
"-----------------------------------------------
set mouse=a             " enable the mouse even anywhere (in terms)
set mousehide           " hide the mouse whilst editing
set clipboard=unnamed   " yank / paste between windows using y and p keys
"}}}

"{{{            Searching
"-----------------------------------------------
set iskeyword+=_,$,@,%,#,-  " those should not be word dividers when searching
set incsearch
set hlsearch
set ignorecase
set smartcase
"}}}

"{{{            Programming
"-----------------------------------------------
set path+=src/
set completeopt=menu,preview
set showfulltag

"}}}

"{{{            Key Bindings
"-----------------------------------------------

" Make Vim recognize xterm escape sequences for Page and Arrow
" keys combined with modifiers such as Shift, Control, and Alt.
" See http://www.reddit.com/r/vim/comments/1a29vk/_/c8tze8p
if &term =~ '^screen'
    " Page keys http://sourceforge.net/p/tmux/tmux-code/ci/master/tree/FAQ
    execute "set t_kP=\e[5;*~"
    execute "set t_kN=\e[6;*~"
endif

inoremap <C-@> <C-Space>

" change annoying behaviours
vnoremap    <BS>            d
inoremap    #               X<BS>#
nmap        q:              :q
nnoremap    Y               y$

" Copy to clipboard
vnoremap  <leader>y  "+y
nnoremap  <leader>Y  "+yg_
nnoremap  <leader>y  "+y
nnoremap  <leader>yy  "+yy

" Paste from clipboard
nnoremap <leader>p "+p
nnoremap <leader>P "+P
vnoremap <leader>p "+p
vnoremap <leader>P "+P

" text formating
nnoremap <silent> Q gwip
nnoremap <silent> <leader>Q ggVGgq
nnoremap <silent> <leader>K :%norm vipJ<cr>

" , is easier than : on a bépo keyboard
nmap        ,               :

" easy indenting
vnoremap    <               <gv
vnoremap    >               >gv

" Enter will toggle folds
if ! exists("g:loaded_less")
    nnoremap    <Enter>         za
end

nmap        z1              :setlocal foldlevel=0<CR>
nmap        z2              :setlocal foldlevel=1<CR>
nmap        z3              :setlocal foldlevel=2<CR>
nmap        z4              :setlocal foldlevel=3<CR>
nmap        z5              :setlocal foldlevel=4<CR>
nmap        z6              :setlocal foldlevel=6<CR>
nmap        z0              :setlocal foldlevel=9999<CR>

" Use ALT-S for saving, also in Insert mode
nmap        <M-s>           :write<CR>
vmap        <M-s>           <C-C>:write<CR>
imap        <M-s>           <C-O>:write<CR>

" ALT-Q to close
nmap        <M-q>           :quit<CR>
vmap        <M-q>           <C-C>:quit<CR>
imap        <M-q>           <C-O>:quit<CR>

" comment out lines of code (toggles)
inoremap    <C-Space>       <C-_>
nmap        <silent> <M-x>  gcc
vmap        <silent> <M-x>  gc
imap        <silent> <M-x>  <C-O>:TComment<CR>
nmap        <silent> <M-c>  gccj
imap        <silent> <M-c>  <C-O>:TComment<CR><C-O>j

" tab control
nnoremap    <C-PageUp>      :tabp<CR>
nnoremap    <C-PageDown>    :tabn<CR>
inoremap    <C-PageUp>      <C-O>:tabp<CR>
inoremap    <C-PageDown>    <C-O>:tabn<CR>
nmap        <C-t>           :tabnew<CR>
imap        <C-t>           <C-O>:tabnew<CR>

" buffer control
nnoremap    <C-Up>          :bprevious<CR>
nnoremap    <C-Down>        :bnext<CR>
inoremap    <C-Up>          <C-O>:bprevious<CR>
inoremap    <C-Down>        <C-O>:bnext<CR>

" window control: moving between windows and resizing
nmap        <C-k>           <C-w>c
map         <C-S-Up>        <C-w>2+
imap        <C-S-Up>        <C-O><C-W>2+
map         <C-S-Down>      <C-w>2-
imap        <C-S-Down>      <C-O><C-W>2-
map         <C-S-Right>     <C-w>2>
imap        <C-S-Right>     <C-O><C-W>2>
map         <C-S-Left>      <C-w>2<
imap        <C-S-Left>      <C-O><C-W>2<

" terminal navigation
tnoremap    <F1>            <C-\><C-n>
tnoremap    <S-Up>          <C-\><C-n><C-w><Up>
tnoremap    <S-Down>        <C-\><C-n><C-w><Down>
tnoremap    <S-Right>       <C-\><C-n><C-w><Right>
tnoremap    <S-Left>        <C-\><C-n><C-w><Left>

" alternate .h -> .c
nmap <silent> <Leader>a<Right>   :FSRight<cr>
nmap <silent> <Leader>a<S-Right> :FSSplitRight<cr>
nmap <silent> <Leader>a<Left>    :FSLeft<cr>
nmap <silent> <Leader>a<S-Left>  :FSSplitLeft<cr>
nmap <silent> <Leader>a<Up>      :FSAbove<cr>
nmap <silent> <Leader>a<S-Up>    :FSSplitAbove<cr>
nmap <silent> <Leader>a<Down>    :FSBelow<cr>
nmap <silent> <Leader>a<S-Down>  :FSSplitBelow<cr>

" Jump between hunks
nmap <Leader>gn <Plug>(GitGutterNextHunk)  " git next
nmap <Leader>gp <Plug>(GitGutterPrevHunk)  " git previous

" Hunk-add and hunk-revert for chunk staging
nmap <Leader>ga <Plug>(GitGutterStageHunk)  " git add (chunk)
nmap <Leader>gu <Plug>(GitGutterUndoHunk)   " git undo (chunk)

let g:tmux_navigator_no_mappings = 1
nnoremap  <S-Left>   :TmuxNavigateLeft<CR>
nnoremap  <S-Down>   :TmuxNavigateDown<CR>
nnoremap  <S-Up>     :TmuxNavigateUp<CR>
nnoremap  <S-Right>  :TmuxNavigateRight<CR>
nnoremap  <A-p>      :TmuxNavigatePrevious<CR>
inoremap  <S-Left>   <C-O>:TmuxNavigateLeft<CR>
inoremap  <S-Down>   <C-O>:TmuxNavigateDown<CR>
inoremap  <S-Up>     <C-O>:TmuxNavigateUp<CR>
inoremap  <S-Right>  <C-O>:TmuxNavigateRight<CR>
inoremap  <A-p>      <C-O>:TmuxNavigatePrevious<CR>

nmap  <leader>e  :exe 'tabe ' . expand(g:my_vimfiles_dir) . '/init.vim'<CR>

" F keys

nnoremap    <silent> <F1>   :GitGutterFold<CR>
vnoremap    <silent> <F1>   <C-C>:GitGutterFold<CR>
inoremap    <silent> <F1>   <C-O>GitGutterFold<CR>

nnoremap    <silent> <S-F2>   zm
vnoremap    <silent> <S-F2>   <C-C>zm
inoremap    <silent> <S-F2>   <C-O>zm
nnoremap    <silent> <S-F3>   zr
vnoremap    <silent> <S-F3>   <C-C>zr
inoremap    <silent> <S-F3>   <C-O>zr

nnoremap    <silent> <F2>   :cprevious<CR>
inoremap    <silent> <F2>   <C-O>:cprevious<CR>
nnoremap    <silent> <F3>   :cnext<CR>
inoremap    <silent> <F3>   <C-O>:cnext<CR>

nnoremap    <silent> <F4>   :FSHere<CR>
inoremap    <silent> <F4>    <C-O>:FSHere<CR>
nnoremap    <silent> <F5>   :NERDTreeToggle<CR>
inoremap    <silent> <F5>   <C-O>:NERDTreeToggle<CR>

nnoremap    <silent> <F6>   :Files<CR>
inoremap    <silent> <F6>    <C-O>:Files<CR>
nnoremap    <silent> <F7>   :Rg<CR>
inoremap    <silent> <F7>    <C-O>:Rg<CR>

nnoremap    <silent> <F8>   :silent nohlsearch<CR>
inoremap    <silent> <F8>   <C-O>:silent nohlsearch<CR>

nnoremap    <F9>            :set list!<CR>
inoremap    <F9>            <C-O>:set list!<CR>

noremap     <silent> <F11>  :call <SID>StripTrailingSpaces()<CR>
inoremap    <silent> <F11>  <C-O>:call <SID>StripTrailingSpaces()<CR>
vnoremap    <silent> <F11>  <C-C>:call <SID>StripTrailingSpaces()<CR>

nnoremap    <F12> :GundoToggle<CR>

nnoremap <silent><C-p> :FZF -m<CR>
nnoremap <silent><C-g> :Rg <C-R><C-W><CR>
nnoremap <M-h> :History<CR>
nnoremap <M-b> :Buffers<CR>
"}}}

"{{{            Plugins settings
"-----------------------------------------------
" Settings for Explorer.vim
let g:explHideFiles='^\.'

" highlight! link SignColumn LineNr
" highlight clear SignColumn
let g:gitgutter_realtime = 0
let g:gitgutter_eager = 0

let g:gitgutter_sign_added = '+'
let g:gitgutter_sign_modified = '>'
let g:gitgutter_sign_removed = '-'
let g:gitgutter_sign_removed_first_line = '^'
let g:gitgutter_sign_modified_removed = '<'

" Settings for Netrw
let g:netrw_list_hide='^\.,\~$'
let g:netrw_banner = 0
let g:netrw_liststyle = 3
" let g:netrw_browse_split = 4
let g:netrw_altv = 1
let g:netrw_winsize = 25

" c specific options
let c_gnu            = 1
let c_no_if0         = 1
let c_syntax_for_h   = 1
let c_hi_identifiers = 'all'
let c_hi_libs        = ['*']

" airline
let g:airline_theme = 'gruvbox'
let g:airline#extensions#branch#enabled = 1
let g:airline#extensions#tabline#enabled = 0
let g:airline_solarized_bg='dark'

let NERDTreeWinPos     = 'right'
let NERDTreeQuitOnOpen = 1
let NERDTreeMouseMode  = 2
let NERDTreeIgnore     = ['\.o$', '\~$']

" custom comment string for tcomment plugin
autocmd FileType tmux set commentstring=#\ %s
autocmd FileType cabal set commentstring=--\ %s

let g:tmux_navigator_no_mappings = 1

"}}}

"{{{            Functions
"-----------------------------------------------
if has('eval')
    runtime! macros/matchit.vim

    " Fonction d'autosauvegarde en cas de buffer modifié
    function! <SID>AutoSave()
        if &modified
            :silent update!
        endif
    endfunction

    " Function removing trailing spaces
    function! <SID>StripTrailingSpaces()
        normal mZ
        silent! %s/\s\+$//e
        normal `Z
    endfunction
endif

"}}}

"{{{            AutoCommands
"-----------------------------------------------

" turn off any existing search
au VimEnter * nohlsearch

" cindent for c / c++ files
au BufEnter *.cpp,*.cc,*.h,*.c,*.hh,*cu
            \ setlocal cindent |
            \ runtime! syntax/clibs.vim |
            \ setlocal foldmethod=syntax |
            \ setlocal list |
            \ setlocal expandtab |
            \ setlocal foldlevel=99 |
            \ setlocal comments-=:// comments+=f://

au FileType text,mkd
            \ setlocal textwidth=80 |
            \ setlocal wrap

au BufEnter *.md,*.mkd
            \ setlocal wrap linebreak                                  |
            \ setlocal nnoremap <buffer> <silent> <F4>   :Toc<CR>      |
            \ setlocal inoremap <buffer> <silent> <F4>   <C-O>:Toc<CR> |
            \ setlocal spell spelllang=en

" jump to last edited line on opening
au BufReadPost *
            \ if line("'\"") > 0 && line("'\"") <= line("$") |
            \   exe "normal g`\"" |
            \ endif

"}}}

" set vbs=1
