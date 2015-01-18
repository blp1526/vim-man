" variable initialization {{{1

let s:man_tag_depth = 0

let s:man_sect_arg = ''
let s:man_find_arg = '-w'
try
  if !has('win32') && $OSTYPE !~ 'cygwin\|linux' && system('uname -s') =~ 'SunOS' && system('uname -r') =~ '^5'
    let s:man_sect_arg = '-s'
    let s:man_find_arg = '-l'
  endif
catch /E145:/
  " Ignore the error in restricted mode
endtry

" }}}
" man#get_page {{{1

function! man#get_page(split_type, ...)
  if a:0 == 0
    call s:handle_nroff_file_or_error(a:split_type)
    return
  elseif a:0 == 1
    let sect = ''
    let page = a:1
  elseif a:0 >= 2
    let sect = a:1
    let page = a:2
  endif

  if sect !=# '' && !s:manpage_exists(sect, page)
    let sect = ''
  endif
  if !s:manpage_exists(sect, page)
    call s:error("No manual entry for '".page."'.")
    return
  endif

  call s:update_man_tag_variables()
  call s:get_new_or_existing_man_window(a:split_type)
  call s:set_manpage_buffer_name(page, sect)
  call s:load_manpage_text(page, sect)
endfunction

" }}}
" :Man command in nroff files {{{1

" handles :Man command invocation with zero arguments
function! s:handle_nroff_file_or_error(split_type)
  " :Man command can be invoked in 'nroff' files to convert it to a manpage
  if &filetype ==# 'nroff'
    if filereadable(expand('%'))
      return s:get_nroff_page(a:split_type, expand('%:p'))
    else
      return s:error("Can't open file ".expand('%'))
    endif
  else
    " simulating vim's error when not enough args provided
    return s:error('E471: Argument required')
  endif
endfunction

" open a nroff file as a manpage
function! s:get_nroff_page(split_type, nroff_file)
  call s:update_man_tag_variables()
  call s:get_new_or_existing_man_window(a:split_type)
  silent exec 'edit '.fnamemodify(a:nroff_file, ':t').'\ manpage\ (from\ nroff)'
  call s:load_manpage_text(a:nroff_file, '')
endfunction

" }}}
" man#get_page_from_cword {{{1

function! man#get_page_from_cword(split_type, cnt)
  if a:cnt == 0
    let old_isk = &iskeyword
    if &filetype ==# 'man'
      " when in a manpage try determining section from a word like this 'printf(3)'
      setlocal iskeyword+=(,),:
    endif
    let str = expand('<cword>')
    let &l:iskeyword = old_isk
    let page = matchstr(str, '\(\k\|:\)\+')
    let sect = matchstr(str, '(\zs[^)]*\ze)')
    if sect !~# '^[0-9nlpo][a-z]*$' || sect ==# page
      let sect = ''
    endif
  else
    let sect = a:cnt
    let old_isk = &iskeyword
    setlocal iskeyword+=:
    let page = expand('<cword>')
    let &l:iskeyword = old_isk
  endif
  call man#get_page(a:split_type, sect, page)
endfunction

" }}}
" man#pop_page {{{1

function! man#pop_page()
  if s:man_tag_depth <= 0
    return
  endif
  let s:man_tag_depth -= 1
  let buffer = s:man_tag_buf_{s:man_tag_depth}
  let line   = s:man_tag_lin_{s:man_tag_depth}
  let column = s:man_tag_col_{s:man_tag_depth}
  " jumps to exact buffer, line and column
  exec buffer.'b'
  exec line
  exec 'norm! '.column.'|'
  unlet s:man_tag_buf_{s:man_tag_depth}
  unlet s:man_tag_lin_{s:man_tag_depth}
  unlet s:man_tag_col_{s:man_tag_depth}
endfunction

" }}}
" man#section_movement {{{1

function! man#section_movement(direction, mode, count)
  norm! m'
  if a:mode ==# 'v'
    norm! gv
  endif
  let i = 0
  while i < a:count
    let i += 1
    " saving current position
    let line = line('.')
    let col  = col('.')
    let pos = search('^\a\+', 'W'.a:direction)
    " if there are no more matches, return to last position
    if pos == 0
      call cursor(line, col)
      return
    endif
  endwhile
endfunction

" }}}
" man#command_completion {{{1

function! man#command_completion(A, L, P)
  let manpath = s:get_manpath()
  if manpath =~# '^\s*$'
    return []
  endif
  let section = s:get_manpage_section(a:L, a:P)
  let path_glob = s:get_path_glob(manpath, section)
  let matching_files = s:expand_path_glob(path_glob, a:A)
  return s:strip_file_names(matching_files)
endfunction

" extracts the manpage section number (if there is one) from the command
function! s:get_manpage_section(line, cursor_position)
  " extracting section argument from the line
  let leading_line = strpart(a:line, 0, a:cursor_position)
  let section_arg = matchstr(leading_line, '^\s*\S\+\s\+\zs\S\+\ze\s\+')
  if !empty(section_arg)
    return s:extract_permitted_section_value(section_arg)
  endif
  " no section arg or extracted section cannot be used for man dir name globbing
  return ''
endfunction

" fetches a colon separated list of paths where manpages are stored
function! s:get_manpath()
  " We don't expect manpath to change, so after first invocation it's
  " saved/cached in a script variable to speed things up on later invocations.
  if !exists('s:manpath')
    " perform a series of commands until manpath is found
    let s:manpath = $MANPATH
    if s:manpath ==# ''
      let s:manpath = system('manpath 2>/dev/null')
      if s:manpath ==# ''
        let s:manpath = system('man '.s:man_find_arg.' 2>/dev/null')
      endif
    endif
    " strip trailing newline for output from the shell
    let s:manpath = substitute(s:manpath, '\n$', '', '')
  endif
  return s:manpath
endfunction

" strips file names so they correspond manpage names
function! s:strip_file_names(matching_files)
  if empty(a:matching_files)
    return []
  else
    let matches = []
    let len = 0
    for manpage_path in a:matching_files
      " since already looping also count list length
      let len += 1
      call add(matches, s:strip_dirname_and_extension(manpage_path))
    endfor
    " remove duplicates from small lists (it takes noticeably longer
    " and is less relevant for large lists)
    return len > 500 ? matches : filter(matches, 'index(matches, v:val, v:key+1)==-1')
  endif
endfunction

" }}}
" man#grep {{{1

function! man#grep(...)
  " argument handling and sanitization
  if a:0 ==# 1
    " just the pattern is provided
    " defaulting section to 1
    let section = '1'
    let pattern = a:1
  elseif a:0 ==# 2
    " section + pattern provided
    let section = s:extract_permitted_section_value(a:1)
    let pattern = a:2
    if section ==# ''
      " don't run an expensive grep on *all* sections if a user made a typo
      return s:error('Unknown man section '.a:1)
    endif
  else
    return
  endif

  let manpath = s:get_manpath()
  if manpath =~# '^\s*$'
    return
  endif
  let path_glob = s:get_path_glob(manpath, section)
  let matching_files = s:expand_path_glob(path_glob, '*')
  " create new quickfix list
  call setqflist([], ' ')
  call s:grep_man_files(pattern, matching_files)
endfunction

function! s:grep_man_files(pattern, files)
  let $MANWIDTH = s:manwidth()
  for file in a:files
    let output_manfile  = '/usr/bin/man '.file.' | col -b |'
    let trim_whitespace = "sed '1 {\n /^[:space:]*$/d \n}' |"
    let grep            = 'grep -n -E '.a:pattern
    let matches = systemlist(output_manfile . trim_whitespace . grep)
    if v:shell_error ==# 0
      " found matches
      call s:add_matches_to_quickfixlist(a:pattern, file, matches)
    endif
  endfor
endfunction

" adds grep matches for a single manpage
function! s:add_matches_to_quickfixlist(pattern, file_path, matches)
  let man_name = s:strip_dirname_and_extension(a:file_path)
  let section = matchstr(fnamemodify(a:file_path, ':h:t'), '^\(man\|cat\)\zs.*')
  let buf_num = s:create_empty_buffer_for_manpage(man_name, section)
  for result in a:matches
    let line_num = matchstr(result, '^\d\+')
    " trimmed line content
    let line_text = matchstr(result, '^[^:]\+:\s*\zs.\{-}\ze\s*$')
    call setqflist([{'bufnr': buf_num, 'lnum': line_num, 'text': line_text}], 'a')
  endfor
endfunction

function! s:create_empty_buffer_for_manpage(name, section)
  let buffer_num = bufnr(a:name.'('.a:section.')', 1)
  call setbufvar(buffer_num, 'man_name', a:name)
  call setbufvar(buffer_num, 'man_section', a:section)
  exec 'au BufEnter <buffer='.buffer_num.'> call man#quickfix_get_page()'
  return buffer_num
endfunction

" }}}
" man#quickfix_get_page {{{1

function! man#quickfix_get_page()
  exec 'au! BufEnter <buffer='.bufnr('%').'>'
  let manpage_name = get(b:, 'man_name')
  let manpage_section = get(b:, 'man_section')
  call s:update_man_tag_variables()
  " TODO: switch to existing 'man' window or create a split
  call s:set_manpage_buffer_name(manpage_name, manpage_section)
  call s:load_manpage_text(manpage_name, manpage_section)
endfunction

" }}}
" helper functions {{{1

function! s:error(str)
  echohl ErrorMsg
  echomsg a:str
  echohl None
endfunction

function! s:get_cmd_arg(sect, page)
  if a:sect == ''
    return a:page
  else
    return s:man_sect_arg.' '.a:sect.' '.a:page
  endif
endfunction

function! s:manpage_exists(sect, page)
  let where = system('/usr/bin/man '.s:man_find_arg.' '.s:get_cmd_arg(a:sect, a:page))
  if where !~# '^\s*/'
    " result does not look like a file path
    return 0
  else
    " found a manpage
    return 1
  endif
endfunction

function! s:remove_blank_lines_from_top_and_bottom()
  while getline(1) =~ '^\s*$'
    silent keepj norm! ggdd
  endwhile
  while getline('$') =~ '^\s*$'
    silent keepj norm! Gdd
  endwhile
  silent keepj norm! gg
endfunction

function! s:set_manpage_buffer_name(page, section)
  silent exec 'edit '.s:manpage_buffer_name(a:page, a:section)
endfunction

function! s:manpage_buffer_name(page, section)
  if !empty(a:section)
    return a:page.'('.a:section.')\ manpage'
  else
    return a:page.'\ manpage'
  endif
endfunction

function! s:load_manpage_text(page, section)
  setlocal modifiable
  silent keepj norm! 1GdG
  let $MANWIDTH = s:manwidth()
  silent exec 'r!/usr/bin/man '.s:get_cmd_arg(a:section, a:page).' | col -b'
  call s:remove_blank_lines_from_top_and_bottom()
  setlocal filetype=man
  setlocal nomodifiable
endfunction

" Default manpage width is 80 characters. Change this with 'g:man_width',
" example: 'let g:man_width = 120'.
" If g:man_width is set to 0, the width of the current vim window is used.
function! s:manwidth()
  if exists('g:man_width')
    return g:man_width ==# 0 ? winwidth(0) : g:man_width
  else
    return 80
  end
endfunction

function! s:get_new_or_existing_man_window(split_type)
  if &filetype != 'man'
    let thiswin = winnr()
    exec "norm! \<C-W>b"
    if winnr() > 1
      exec 'norm! '.thiswin."\<C-W>w"
      while 1
        if &filetype == 'man'
          break
        endif
        exec "norm! \<C-W>w"
        if thiswin == winnr()
          break
        endif
      endwhile
    endif
    if &filetype != 'man'
      if a:split_type == 'vertical'
        vnew
      else
        new
      endif
    endif
  endif
endfunction

function! s:update_man_tag_variables()
  let s:man_tag_buf_{s:man_tag_depth} = bufnr('%')
  let s:man_tag_lin_{s:man_tag_depth} = line('.')
  let s:man_tag_col_{s:man_tag_depth} = col('.')
  let s:man_tag_depth += 1
endfunction

function! s:extract_permitted_section_value(section_arg)
  if a:section_arg =~# '^*$'
    " matches all dirs with a glob 'man*'
    return a:section_arg
  elseif a:section_arg =~# '^\d[xp]\?$'
    " matches dirs: man1, man1x, man1p
    return a:section_arg
  elseif a:section_arg =~# '^[nlpo]$'
    " matches dirs: mann, manl, manp, mano
    return a:section_arg
  elseif a:section_arg =~# '^\d\a\+$'
    " take only first digit, sections 3pm, 3ssl, 3tiff, 3tcl are searched in man3
    return matchstr(a:section_arg, '^\d')
  else
    return ''
  endif
endfunction

" creates a string containing shell globs suitable to finding matching manpages
function! s:get_path_glob(manpath, section)
  let section_part = empty(a:section) ? '*' : a:section
  let man_globs = substitute(a:manpath.':', ':', '/*man'.section_part.'/,', 'g')
  let cat_globs = substitute(a:manpath.':', ':', '/*cat'.section_part.'/,', 'g')
  " remove one unecessary comma from the end
  let cat_globs = substitute(cat_globs, ',$', '', '')
  return man_globs.cat_globs
endfunction

" path glob expansion to get filenames
function! s:expand_path_glob(path_glob, manpage_prefix)
  if empty(a:manpage_prefix)
    let manpage_part = '*'
  elseif a:manpage_prefix =~# '*$'
    " asterisk is already present
    let manpage_part = a:manpage_prefix
  else
    let manpage_part = a:manpage_prefix.'*'
  endif
  return globpath(a:path_glob, manpage_part, 1, 1)
endfunction

" first strips the directory name from the match, then the extension
function! s:strip_dirname_and_extension(manpage_path)
  return StripExtension(fnamemodify(a:manpage_path, ':t'))
endfunction

" Public function so it can be used for testing.
" Check 'manpage_extension_stripping_test.vim' for example input and output
" this regex produces.
function! StripExtension(filename)
  return substitute(a:filename, '\.\(\d\a*\|n\|ntcl\)\(\.\a*\|\.bz2\)\?$', '', '')
endfunction

" }}}

" vim:set ft=vim et sw=2:
