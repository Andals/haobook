set nu
set nowrap
set background=dark
set encoding=utf-8
set fileencoding=utf-8

noremap <F3> <Esc>:TlistToggle <CR>
noremap <F8> <Esc>:! $PWD/init.sh <CR>
"noremap <F9> <Esc>:! $PWD/tool/srcindex_cscope.sh <CR> <Esc>: execute "cs add ".$PWD."/tmp/cscope.out" <CR>
"noremap <F9> <Esc>:! $PWD/tool/srcindex_ctags.sh <CR>
