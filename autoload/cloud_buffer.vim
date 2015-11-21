" =============================================================================
" File:          autoload/cloud_buffer.vim
" Author:        Javier Blanco <http://jbgutierrez.info>
" =============================================================================

let g:loaded_cloud_buffer   = 1
let g:vim_cloud_buffer_data = 0

function! s:error(str)
  echohl ErrorMsg
  echomsg a:str
  echohl None
  let v:errmsg = a:str
endfunction

function! s:debug(str)
  if exists("g:cloud_buffer_debug") && g:cloud_buffer_debug
    echohl Debug
    echomsg a:str
    echohl None
  endif
endfunction

function! s:sub(str,pat,rep)
  return substitute(a:str,'\v\C'.a:pat,a:rep,'')
endfunction

function! s:distance_of_time_in_words(since_time)
  let now = localtime()
  let distance_in_seconds = now - a:since_time
  let distance_in_minutes = distance_in_seconds / 60

  if distance_in_minutes < 1
    return distance_in_seconds."s"
  elseif distance_in_minutes < 91
    return distance_in_minutes."m"
  elseif distance_in_minutes < 1440 " up to 24 hours
    let hours = float2nr(round(distance_in_minutes / 60))
    return hours . "h"
  elseif distance_in_minutes < 43200 " up to 30 days
    let days = float2nr(round(distance_in_minutes / 1440))
    return days."d"
  elseif distance_in_minutes < 525600 " up to 365 days
    let months = float2nr(floor(distance_in_minutes / 43200))
    return months."m"
  else
    let years = float2nr(floor(distance_in_minutes / 518400))
    return years."y"
  endif
endfunction

let s:bufprefix = 'buffers' . (has('unix') ? ':' : '_')
function! s:buffer_open(buffer_name, split) abort
  let buffer_name = s:bufprefix.a:buffer_name
  let winnum = bufwinnr(bufnr(buffer_name))
  if winnum != -1
    if winnum != bufwinnr('%')
      exe winnum 'wincmd w'
    endif
  else
    if (a:split)
      exe 'split' buffer_name
    endif
  endif
endfunction

exe "rubyfile " . expand('<sfile>:p:h') . "/../ruby/cloud_buffer.rb"
function! s:rest_api(cmd, ...)
  if (a:0 > 0)
    unlet! g:vim_cloud_buffer_data
    let g:vim_cloud_buffer_data = a:1
  endif
  exe "ruby VimCloudBuffer::gw.".a:cmd
  return g:vim_cloud_buffer_data
endfunction

function! s:serialize_buffer()
  let now = localtime()
  if exists('b:buffer')
    let buffer = b:buffer
  else
    let buffer = { 'created_at': now, 'updated_at': now }
  endif

  if now - buffer.updated_at > 3600 | let buffer.updates += 1 | endif

  let pos = getpos('.')
  let options = {
    \ 'filetype': &filetype,
    \ 'lnum': pos[1],
    \ 'col': pos[2]
    \ }

  call extend(buffer, {
    \ 'content': join(getline(0, line('$')), "\n"),
    \ 'options': options,
    \ 'updated_at': now
    \ })
  return buffer
endfunction

function! s:buffer_add() abort
  redraw | echomsg 'Saving buffer... '

  let unnamed_buffer = bufname('%') == ''
  let buffer = s:serialize_buffer()
  if !unnamed_buffer | let buffer.buffer_name = bufname('%') | endif
  let buffer = s:rest_api('add', buffer)

  let content = buffer.content
  call setline(1, split(content, "\n"))

  let b:buffer = buffer
  let b:buffer_id = buffer._id['$oid']

  if unnamed_buffer
    let buffer_name = s:bufprefix.'edit:'.b:buffer_id
    exe "file" buffer_name
  else
    write
  endif

  au! BufWriteCmd <buffer> call s:buffer_update(expand("<amatch>"))

  redraw | echo ''
endfunction

function! s:buffer_update(fname) abort
  redraw | echomsg 'Updating buffer... '
  let buffer = s:serialize_buffer()
  let synced = a:fname !~# '^'.s:bufprefix.'edit'
  if synced | let buffer.buffer_name = fnamemodify(a:fname, ':t') | endif
  if exists('buffer.buffer_name')
    file s:bufprefix.'edit:'.a:id.''.buffer.buffer_name
  endif
  let buffer = s:rest_api('update("'.b:buffer_id.'")', buffer)
  if synced
    setlocal buftype=
    if a:fname != bufname('%')
      exe 'file' a:fname
    endif
    exe 'w' (v:cmdbang ? '!' : '') a:fname
  else
    setlocal nomodified
  endif
  redraw | echo ''
endfunction

function! s:buffer_get(id) abort
  let buffer_name = 'edit:'.a:id

  call s:buffer_open(buffer_name, 0)
  if (exists('b:buffer')) | return | endif

  redraw | echomsg 'Getting buffer... '
  let buffer = s:rest_api('get("'.a:id.'")')
  call s:buffer_open(buffer_name, 1)
  if exists('buffer.buffer_name')
    exe "file" buffer_name.':'.buffer.buffer_name
  endif
  call setline(1, split(buffer.content, "\n"))
  let options = buffer.options
  let &filetype = options.filetype
  call cursor(options.lnum, options.col)
  let b:buffer = buffer
  let b:buffer_id = buffer._id['$oid']
  au! BufWriteCmd <buffer> call s:buffer_update(expand("<amatch>"))
  setlocal buftype=acwrite bufhidden=delete noswapfile
  setlocal nomodified

  redraw | echo ''
endfunction

function! s:format_buffer(buffer) abort
  let content = substitute(a:buffer.content, '[\r\n\t]', ' ', 'g')
  let content = substitute(content, '  ', ' ', 'g')
  let lines   = len(split(a:buffer.content, "\n"))
  let id      = a:buffer._id['$oid']
  if exists('a:buffer.deleted_at') | exe 'syn match CloudBufferDeleted ".*'.id.'.*"' | endif
  let filetype = a:buffer.options.filetype
  let updated_at = s:distance_of_time_in_words(a:buffer.updated_at)
  let buffer_name = exists('a:buffer.buffer_name') ? a:buffer.buffer_name : id
  return printf(' %4S  |  %4S  |  %-9s  |  %-24s  |  %s (%14s)', updated_at, lines, filetype, buffer_name, content, id)
endfunction

function! s:buffers_list_action(action) abort
  let line = getline('.')
  let regex = '\v<[0-9a-z]{24}>'
  if line =~ regex
    let id = matchlist(line, regex)[0]
    if a:action == 'get'
      call s:buffer_get(id)
    elseif a:action == 'restore'
      call s:buffer_restore(id)
    end
  endif
  if line =~# '^more\.\.\.$'
    let b:options.sk += 1000
    redraw | echomsg 'Loading more buffers...'
    let buffers = s:rest_api('list', b:options)
    call s:buffers_list_append(buffers)
    redraw | echo ''
  endif
endfunction

function s:buffers_list_append(buffers)
  setlocal modifiable
  let position = b:options.sk
  let horizontal_line = '-------|--------|--------------|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
  if !position
    0,%delete
    let header = ' date  |  locs  |  filetype    |  buffer name               |  contents'
    call append(0, [horizontal_line, header, horizontal_line])
  endif
  let lines = map(a:buffers, 's:format_buffer(v:val)')
  call setline(position + 4, lines)
  call append('$', horizontal_line)
  if len(a:buffers) == 1000 | call append('$', 'more...') | endif
  setlocal nomodifiable
endfunction

function! s:buffers_list(include_deleted,regex) abort
  redraw | echomsg 'Listing buffers...'

  let options = {
        \   's': {
        \     'updated_at': -1
        \   },
        \   'q': {
        \     'deleted_at': { '$exists': 0 },
        \     'content': { '$regex': a:regex }
        \   },
        \   'sk': 0
        \ }
  if a:include_deleted | unlet options.q.deleted_at | endif
  if a:regex == '' | unlet options.q.content | endif
  let buffers = s:rest_api('list', options)
  call s:buffer_open('list', 1)

  hi def link CloudBufferDeleted Comment
  syn clear CloudBufferDeleted
  let b:options = options

  call s:buffers_list_append(buffers)
  setlocal buftype=nofile bufhidden=delete noswapfile

  nnoremap <silent> <buffer> <cr> :call <sid>buffers_list_action('get')<cr>
  nnoremap <silent> <buffer> r :call <sid>buffers_list_action('restore')<cr>

  redraw | echo ''
endfunction

function! s:buffer_delete(permanent) abort
  let choice = confirm("Are you sure you want to delete?", "&Yes\n&No", 0)
  if choice != 1 | return | endif
  redraw | echomsg 'Deleting buffer... '
  if a:permanent
    call s:rest_api('remove("'.b:buffer_id.'")')
  else
    call s:rest_api('update("'.b:buffer_id.'")', { '$set': { 'deleted_at': localtime() } })
  end
  redraw | echo ''
endfunction

function! s:buffer_restore(id) abort
  redraw | echomsg 'Restoring deleted buffer... '
  call s:rest_api('update("'.a:id.'")', { '$unset': { 'deleted_at': 1 } })
  redraw | echo ''
endfunction

function! s:shellwords(str) abort
  let words = split(a:str, '\%(\([^ \t\''"]\+\)\|''\([^\'']*\)''\|"\(\%([^\"\\]\|\\.\)*\)"\)\zs\s*\ze')
  let words = map(words, 'substitute(v:val, ''\\\([\\ ]\)'', ''\1'', "g")')
  let words = map(words, 'matchstr(v:val, ''^\%\("\zs\(.*\)\ze"\|''''\zs\(.*\)\ze''''\|.*\)$'')')
  return words
endfunction

let s:UNKNOWN_RE = '\v^--*(.*)$'
function! cloud_buffer#CloudBuffer(bang, ...) abort
  try
    let args = (a:0 > 0) ? s:shellwords(a:1) : [ '--list' ]

    let idx=0
    for arg in args
      if arg =~# '\v^(-l|--list)$'
        let regex = ''
      elseif arg =~# '\v^(-d|--delete)$'
        call s:buffer_delete(a:bang)
      elseif arg =~# '\v^(-s|--save)$'
        if exists('b:buffer')
          throw 'Please type ":w" to save your buffer contents'
        else
          call s:buffer_add()
        end
      elseif arg =~# '\v^(-re|--regex)$'
        let regex = ''
        if exists('args['.(idx+1).']')
          let regex = args[idx+1]
        endif
      elseif arg =~# s:UNKNOWN_RE
        throw "Unknown option ".matchlist(arg, s:UNKNOWN_RE)[1]
      end
      let idx = idx + 1
    endfor

    if exists('regex')
      call s:buffers_list(a:bang, regex)
    endif
  catch /RestClient/
    call s:error(v:errmsg)
  catch
    call s:error(v:exception)
  endtry
endfunction

function! cloud_buffer#CloudBufferArgs(A,L,P)
  return [ "-l", "--list", "-d", "--delete", "-s", "--save", "-re", "--regex" ]
endfunction

" vim:fen:fdm=marker:fmr=function,endfunction:fdl=0:fdc=1:ts=2:sw=2:sts=2
