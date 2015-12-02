let s:redmine_server = get(g:, 'metarw_redmine_server')
let s:redmine_apikey = get(g:, 'metarw_redmine_apikey')

function! metarw#redmine#complete(arglead, cmdline, cursorpos)
  let _ = s:parse_incomplete_fakepath(a:arglead)

  let candidates = []
  if !_.project_given_p
    for project in s:get_projects(_)
      call add(candidates,
      \        printf('%s:/%s',
      \               _.scheme,
      \               project.identifier))
    endfor
    let head_part = printf('%s:/', _.scheme)
    let tail_part = _.project
  else
    for issue in s:get_issues(_)
      call add(candidates,
      \        printf('%s:/%s/%s',
      \               _.scheme,
      \               _.project,
      \               issue.id)
      \ )
    endfor
    let head_part = printf('%s:/%s/', _.scheme, _.project)
    let tail_part = _.issue
  endif

  return [candidates, head_part, tail_part]
endfunction

function! metarw#redmine#read(fakepath)
  let _ = s:parse_incomplete_fakepath(a:fakepath)

  if _.issue_given_p
    let result = s:read_content(_)
  else
    let result = s:read_list(_)
  endif

  return result
endfunction

function! metarw#redmine#write(fakepath, line1, line2, append_p)
  let _ = s:parse_incomplete_fakepath(a:fakepath)

  let content = join(getline(a:line1, a:line2), "\n")
  if !_.project_given_p && !_.issue_given_p
    echoerr 'Unexpected a:incomplete_fakepath:' string(a:incomplete_fakepath)
    throw 'metarw:redmine#e1'
  elseif !_.issue_given_p
    let result = s:write_new(_, content)
    if result[0] != 'error'
    endif
  else
    let result = s:write_update(_, content)
  endif

  return result
endfunction

function! s:parse_incomplete_fakepath(incomplete_fakepath)
  let _ = {}

  let fragments = split(a:incomplete_fakepath, '^\l\+\zs:', !0)
  if len(fragments) <= 1
    echoerr 'Unexpected a:incomplete_fakepath:' string(a:incomplete_fakepath)
    throw 'metarw:redmine#e1'
  endif
  let fragments = [fragments[0]] + split(fragments[1], '[\/]')

  let _.given_fakepath = a:incomplete_fakepath
  let _.scheme = fragments[0]

  " {project}
  let i = 1
  if i < len(fragments)
    let _.project_given_p = !0
    let _.project = fragments[i]
    let i += 1
  else
    let _.project_given_p = !!0
    let _.project = ''
  endif

  " {issue}
  if i < len(fragments)
    let _.issue_given_p = !0
    let _.issue = fragments[i]
    let i += 1
  else
    let _.issue_given_p = !!0
    let _.issue = ''
  endif

  return _
endfunction

function! s:format(issue)
  let content = []
  for [k, v] in items(a:issue)
    if k != 'description'
      if type(v) == 4 && has_key(v, 'id')
        call add(content, printf("%s: %s", k, v.id))
      else
        call add(content, printf("%s: %s", k, iconv(webapi#json#encode(v), 'utf-8', &encoding)))
      endif
    endif
    unlet v
  endfor
  call add(content, '--')
  let description = has_key(a:issue, 'description') ? substitute(a:issue.description, "\r", "", "g") : ''
  let content += split(description, "\n")
  return content
endfunction

function! s:read_content(_)
  try
    let issue = s:get_issue(a:_)
  catch
    return ['error', v:exception]
  endtry
  call setline(1, s:format(issue))

  return ['done', '']
endfunction

function! s:read_list(_)
  let result = []
  if a:_.project_given_p
    try
      let issues = s:get_issues(a:_)
    catch
      return ['error', v:exception]
    endtry
    for issue in issues
      call add(result, {
      \    'label': issue.subject,
      \    'fakepath': printf('%s:/%s/%s',
      \                       a:_.scheme,
      \                       a:_.project,
      \                       issue.id)
      \ })
    endfor
  else
    try
      let projects = s:get_projects(a:_)
    catch
      return ['error', v:exception]
    endtry
    for project in projects
      call add(result, {
      \    'label': project.identifier . '/',
      \    'fakepath': printf('%s:/%s/',
      \                       a:_.scheme,
      \                       project.identifier)
      \ })
    endfor
  endif

  return ['browse', result]
endfunction

function! s:url(...)
  let server = substitute(s:redmine_server, '/\+$', '', '')
  return join([server] + a:000 + ['?key=', s:redmine_apikey], '')
endfunction

function! s:write_new(_, content)
  let data = {}
  let lines = split(a:content, '\n--\n', 2)
  if len(lines) < 2
    let metadata = ''
    let body = a:content
  else
    let metadata = lines[0]
    let body = lines[1]
  endif
  for line in split(metadata, "\n")
    let pos = stridx(line, ':')
    if pos > 0
      let data[line[0:pos-1]] = webapi#json#decode(line[pos+1:])
    endif
  endfor
  if !has_key(data, 'subject')
    let data['subject'] = split(body, "\n", 1)[0]
  endif
  let data['description'] = body
  let data['project_id'] = a:_.project
  let result = webapi#http#post(s:url('/issues.json'),
  \ webapi#json#encode({"issue": data}), {
  \   "Content-Type": "application/json"
  \ })
  if split(result.header[0])[1] != '201'
    return ['error', result.header[0]]
  endif
  let data = webapi#json#decode(result.content).issue
  exe 'noau file' printf('redmine:/%s/%s', data.project.id, data.id)
  silent! %d _
  call setline(1, s:format(data))

  setlocal nomodified

  return ['done', '']
endfunction

function! s:write_update(_, content)
  let data = {}
  let lines = split(a:content, '\n--\n', 2)
  if len(lines) < 2
    let metadata = ''
    let body = a:content
  else
    let metadata = lines[0]
    let body = lines[1]
  endif
  for line in split(metadata, "\n")
    let pos = stridx(line, ':')
    if pos > 0
      let data[line[0:pos-1]] = webapi#json#decode(line[pos+1:])
    endif
  endfor
  if !has_key(data, 'subject')
    let data['subject'] = split(body, "\n", 1)[0]
  endif
  let data['description'] = body
  let data['project_id'] = a:_.project
  let result = webapi#http#post(s:url('/issues/', a:_.issue, '.json'),
  \ webapi#json#encode({"issue": data}), {
  \   "Content-Type": "application/json"
  \ }, 'PUT')
  if result.status !~ '^2'
    return ['error', result.message]
  endif

  return ['done', '']
endfunction

function! s:get_projects(_)
  let result = webapi#http#get(s:url('/projects.json'), '', {
  \   "Content-Type": "application/json"
  \ })
  if result.status !~ '^2'
    throw result.message
  endif

  let json = webapi#json#decode(result.content)
  if type(json) != 3 && has_key(json, 'errors')
    throw json.error
  endif

  return json.projects
endfunction

function! s:get_issues(_)
  let result = webapi#http#get(s:url('/issues.json'), '', {
  \   "Content-Type": "application/json"
  \ })
  if result.status !~ '^2'
    return ['error', result.message]
  endif

  let json = webapi#json#decode(result.content)
  if type(json) != 3 && has_key(json, 'errors')
    throw json.error
  endif

  return json.issues
endfunction

function! s:get_issue(_)
  let result = webapi#http#get(s:url('/issues/', a:_.issue, '.json'), '', {
  \   "Content-Type": "application/json"
  \ })
  if result.status !~ '^2'
    return ['error', result.message]
  endif

  let json = webapi#json#decode(result.content)
  if type(json) != 3 && has_key(json, 'errors')
    throw json.error
  endif

  return json.issue
endfunction
