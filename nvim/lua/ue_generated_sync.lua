local M = {}

local namespace = vim.api.nvim_create_namespace 'ue_generated_sync'
local states = {}
local is_windows = package.config:sub(1, 1) == '\\'
local temp_counter = 0

local function slash(path) return vim.fs.normalize(path):gsub('\\', '/') end

local function path_key(path)
  path = slash(path)
  return is_windows and path:lower() or path
end

local function escape_pattern(text) return (text:gsub('([^%w])', '%%%1')) end

local function read_file(path)
  local file, err = io.open(path, 'rb')
  if not file then return nil, err end
  local content = file:read '*a'
  file:close()
  return content
end

local function write_file(path, content, expected_content)
  local uv = vim.uv or vim.loop
  local stat, stat_err = uv.fs_stat(path)
  if not stat then return nil, stat_err end

  local temporary_path, fd, open_err
  for _ = 1, 10 do
    temp_counter = temp_counter + 1
    temporary_path = ('%s.ue-generated-sync.%d.%d.tmp'):format(path, uv.os_getpid(), temp_counter)
    fd, open_err = uv.fs_open(temporary_path, 'wx', stat.mode)
    if fd then break end
  end
  if not fd then return nil, open_err end

  local offset = 0
  local write_err
  while offset < #content do
    local written
    written, write_err = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not written or written == 0 then break end
    offset = offset + written
  end
  local synced, sync_err = uv.fs_fsync(fd)
  local closed, close_err = uv.fs_close(fd)

  if offset ~= #content or not synced or not closed then
    uv.fs_unlink(temporary_path)
    return nil, write_err or sync_err or close_err or ('short write: %d of %d bytes'):format(offset, #content)
  end

  if expected_content then
    local current_content, read_err = read_file(path)
    if not current_content or current_content ~= expected_content then
      uv.fs_unlink(temporary_path)
      return nil, read_err or 'generated header changed externally before replacement'
    end
  end

  local renamed, rename_err = uv.fs_rename(temporary_path, path)
  if not renamed then
    uv.fs_unlink(temporary_path)
    return nil, rename_err
  end
  return true
end

local function directory_has_marker(path, extension)
  local ok, iterator = pcall(vim.fs.dir, path)
  if not ok or not iterator then return false end
  for name, kind in iterator do
    if kind == 'file' and name:lower():match('%.' .. extension .. '$') then return true end
  end
  return false
end

local function relative_path(root, path)
  root = slash(root):gsub('/$', '')
  path = slash(path)
  local compare_root = is_windows and root:lower() or root
  local compare_path = is_windows and path:lower() or path
  if compare_path:sub(1, #compare_root + 1) ~= compare_root .. '/' then return nil end
  return path:sub(#root + 2)
end

function M.find_context(source_path)
  source_path = vim.fs.normalize(source_path)
  local plugin_root, project_root, owner_root

  for parent in vim.fs.parents(source_path) do
    local has_plugin = directory_has_marker(parent, 'uplugin')
    local has_project = directory_has_marker(parent, 'uproject')
    if not owner_root and (has_plugin or has_project) then owner_root = parent end
    if has_plugin and not plugin_root then plugin_root = parent end
    if has_project and not project_root then project_root = parent end
  end

  if not owner_root then return nil, 'no .uproject or .uplugin ancestor' end

  local relative = relative_path(owner_root, source_path)
  local module = relative and relative:match '^Source/([^/]+)/'
  if not module then return nil, 'header is not under Source/<Module> below its Unreal root' end

  local roots, seen = {}, {}
  for _, root in ipairs { project_root, plugin_root } do
    if root then
      local build_root = vim.fs.joinpath(root, 'Intermediate', 'Build')
      local key = path_key(build_root)
      if not seen[key] then
        seen[key] = true
        roots[#roots + 1] = build_root
      end
    end
  end

  return {
    owner_root = owner_root,
    plugin_root = plugin_root,
    project_root = project_root,
    search_roots = roots,
    module = module,
  }
end

local function lex_line(line, lexical_state, keep_strings)
  lexical_state = lexical_state or { block_comment = false }
  local output = {}
  local index = 1
  local quote = lexical_state.quote

  while index <= #line do
    local char = line:sub(index, index)
    local pair = line:sub(index, index + 1)

    if lexical_state.block_comment then
      if pair == '*/' then
        output[#output + 1] = '  '
        lexical_state.block_comment = false
        index = index + 2
      else
        output[#output + 1] = ' '
        index = index + 1
      end
    elseif quote then
      output[#output + 1] = keep_strings and char or ' '
      if char == '\\' and index < #line then
        output[#output + 1] = keep_strings and line:sub(index + 1, index + 1) or ' '
        index = index + 2
      else
        if char == quote then quote = nil end
        index = index + 1
      end
    elseif pair == '//' then
      output[#output + 1] = string.rep(' ', #line - index + 1)
      break
    elseif pair == '/*' then
      output[#output + 1] = '  '
      lexical_state.block_comment = true
      index = index + 2
    elseif char == '"' or char == "'" then
      quote = char
      output[#output + 1] = keep_strings and char or ' '
      index = index + 1
    else
      output[#output + 1] = char
      index = index + 1
    end
  end

  lexical_state.quote = quote
  return table.concat(output), lexical_state
end

function M.find_generated_include(source_lines)
  local includes = {}
  local lexical_state = { block_comment = false }

  for _, line in ipairs(source_lines) do
    local code
    code, lexical_state = lex_line(line, lexical_state, true)
    local include = code:match '^%s*#%s*include%s*[<"]([^>"]+%.generated%.h)[>"]'
    if include then includes[#includes + 1] = include end
  end

  if #includes ~= 1 then return nil, ('expected exactly one generated include, found %d'):format(#includes) end
  return includes[1]:match '[^/\\]+$'
end

function M.find_generated_header(context, include_name)
  local candidates, seen = {}, {}
  local expected_tail = ('/Inc/%s/UHT/%s'):format(context.module, include_name)
  if is_windows then expected_tail = expected_tail:lower() end

  for _, root in ipairs(context.search_roots) do
    if (vim.uv or vim.loop).fs_stat(root) then
      local found = vim.fs.find(include_name, { path = root, type = 'file', limit = math.huge })
      for _, path in ipairs(found) do
        local normalized = slash(path)
        local compared = is_windows and normalized:lower() or normalized
        if compared:sub(-#expected_tail) == expected_tail then
          local key = path_key(path)
          if not seen[key] then
            seen[key] = true
            candidates[#candidates + 1] = vim.fs.normalize(path)
          end
        end
      end
    end
  end

  table.sort(candidates)
  if #candidates == 0 then return nil, 'generated header not found; run UHT/build once' end
  if #candidates > 1 then return nil, 'multiple generated headers found:\n' .. table.concat(candidates, '\n') end
  return candidates[1]
end

function M.parse_generated(content)
  local file_ids = {}
  for file_id in content:gmatch '#%s*define%s+CURRENT_FILE_ID%s+([A-Za-z_][A-Za-z0-9_]*)' do
    file_ids[file_id] = true
  end

  local file_id
  for candidate in pairs(file_ids) do
    if file_id then return nil, 'multiple CURRENT_FILE_ID definitions found' end
    file_id = candidate
  end
  if not file_id then return nil, 'CURRENT_FILE_ID was not found' end

  local numbers = {}
  local pattern = '%f[%w_]' .. escape_pattern(file_id) .. '_(%d+)_'
  for number in content:gmatch(pattern) do
    numbers[tonumber(number)] = true
  end

  local lines = {}
  for number in pairs(numbers) do
    lines[#lines + 1] = number
  end
  table.sort(lines)
  if #lines == 0 then return nil, 'no generated line identifiers were found' end

  return { file_id = file_id, lines = lines }
end

function M.find_macro_on_line(line, lexical_state)
  local code
  code, lexical_state = lex_line(line, lexical_state or { block_comment = false }, false)
  local matches = {}
  local search_from = 1

  while true do
    local start_pos, end_pos, name_pos, name = code:find('%f[%w_]()([A-Z_][A-Z0-9_]*)%s*%(', search_from)
    if not start_pos then break end
    matches[#matches + 1] = {
      name = name,
      start_col = name_pos - 1,
      end_col = name_pos - 1 + #name,
    }
    search_from = end_pos + 1
  end

  if #matches ~= 1 then return nil, lexical_state, ('expected exactly one macro invocation, found %d'):format(#matches) end
  return matches[1], lexical_state
end

local function same_number_set(numbers, tracked)
  if #numbers ~= #tracked then return false end
  local expected = {}
  for _, item in ipairs(tracked) do
    expected[item.generated_line] = true
  end
  for _, number in ipairs(numbers) do
    if not expected[number] then return false end
  end
  return true
end

function M.transform_generated(content, file_id, mapping)
  local parsed, parse_err = M.parse_generated(content)
  if not parsed then return nil, parse_err end
  if parsed.file_id ~= file_id then return nil, 'CURRENT_FILE_ID changed unexpectedly' end

  local mapping_count = 0
  local targets = {}
  for old_line, new_line in pairs(mapping) do
    mapping_count = mapping_count + 1
    if type(old_line) ~= 'number' or type(new_line) ~= 'number' or old_line < 1 or new_line < 1 or old_line % 1 ~= 0 or new_line % 1 ~= 0 then
      return nil, 'line mappings must contain positive integers'
    end
    if targets[new_line] then return nil, ('multiple generated identifiers map to line %d'):format(new_line) end
    targets[new_line] = true
  end
  if mapping_count ~= #parsed.lines then return nil, 'mapping does not cover every generated line identifier' end
  for _, old_line in ipairs(parsed.lines) do
    if not mapping[old_line] then return nil, ('mapping is missing generated line %d'):format(old_line) end
  end

  local counts = {}
  local pattern = '(%f[%w_]' .. escape_pattern(file_id) .. '_(%d+)_' .. ')'
  local transformed = content:gsub(pattern, function(token, number)
    local old_line = tonumber(number)
    local new_line = mapping[old_line]
    if not new_line then return token end
    counts[old_line] = (counts[old_line] or 0) + 1
    return ('%s_%d_'):format(file_id, new_line)
  end)

  for old_line in pairs(mapping) do
    if not counts[old_line] then return nil, ('no identifier was replaced for generated line %d'):format(old_line) end
  end
  return transformed
end

local function content_format(content)
  local without_crlf = content:gsub('\r\n', '')
  if without_crlf:find '[\r\n]' then return nil, 'generated header has mixed or unsupported line endings' end

  local newline = content:find('\r\n', 1, true) and '\r\n' or '\n'
  local final_newline = #content >= #newline and content:sub(-#newline) == newline
  return { newline = newline, final_newline = final_newline }
end

local function content_lines(content, format)
  local body = format.final_newline and content:sub(1, #content - #format.newline) or content
  if body == '' then return { '' } end
  return vim.split(body, format.newline, { plain = true })
end

local function buffer_content(bufnr, format)
  local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), format.newline)
  return format.final_newline and content .. format.newline or content
end

local function notify_failure(state, message)
  state.suspended = message
  vim.notify_once(('UE generated sync: %s\n%s'):format(message, state.source_path), vim.log.levels.WARN, { title = 'UE generated sync' })
end

local function initialize_marks(state, parsed, source_lines)
  local lexical_state = { block_comment = false }
  local macros_by_line = {}
  local wanted = {}
  for _, line_number in ipairs(parsed.lines) do
    wanted[line_number] = true
  end

  for line_number, line in ipairs(source_lines) do
    local macro, next_state, err = M.find_macro_on_line(line, lexical_state)
    lexical_state = next_state
    if wanted[line_number] then
      if not macro then return nil, ('generated line %d is not safely aligned: %s; run UHT/build once'):format(line_number, err) end
      macros_by_line[line_number] = macro
    end
  end

  for _, line_number in ipairs(parsed.lines) do
    local macro = macros_by_line[line_number]
    if not macro then return nil, ('generated line %d is outside the source buffer; run UHT/build once'):format(line_number) end
    local id = vim.api.nvim_buf_set_extmark(state.source_buf, namespace, line_number - 1, macro.start_col, {
      end_row = line_number - 1,
      end_col = macro.end_col,
      right_gravity = true,
      end_right_gravity = false,
    })
    state.tracked[#state.tracked + 1] = {
      extmark_id = id,
      macro_name = macro.name,
      original_line = line_number,
      generated_line = line_number,
    }
  end

  return true
end

local function validate_mark(state, item)
  local mark = vim.api.nvim_buf_get_extmark_by_id(state.source_buf, namespace, item.extmark_id, { details = true })
  if #mark == 0 then return nil, ('extmark for %s disappeared'):format(item.macro_name) end

  local row, col, details = mark[1], mark[2], mark[3]
  if details.end_row ~= row or not details.end_col then return nil, ('extmark for %s no longer covers one line'):format(item.macro_name) end
  local line = vim.api.nvim_buf_get_lines(state.source_buf, row, row + 1, false)[1]
  if not line then return nil, ('line for %s disappeared'):format(item.macro_name) end

  local marked_name = line:sub(col + 1, details.end_col)
  local following = line:sub(details.end_col + 1)
  if marked_name ~= item.macro_name or not following:match '^%s*%(' then
    return nil, ('tracked macro %s was deleted or changed; run UHT/build once'):format(item.macro_name)
  end

  return row + 1
end

local function build_line_mapping(state)
  local mapping, targets = {}, {}
  local identity = true

  for _, item in ipairs(state.tracked) do
    local current_line, err = validate_mark(state, item)
    if not current_line then return nil, nil, err end
    if mapping[item.generated_line] then return nil, nil, ('duplicate generated line %d'):format(item.generated_line) end
    if targets[current_line] then return nil, nil, ('tracked macros now share source line %d'):format(current_line) end
    mapping[item.generated_line] = current_line
    targets[current_line] = true
    if item.generated_line ~= current_line then identity = false end
  end

  return mapping, identity
end

local function force_source_rebuild(client, state)
  local changetracking = require 'vim.lsp._changetracking'
  changetracking.flush(client, state.generated_buf)
  changetracking.flush(client, state.source_buf)
  client:notify('textDocument/didChange', {
    textDocument = {
      uri = vim.uri_from_bufnr(state.source_buf),
      version = vim.lsp.util.buf_versions[state.source_buf],
    },
    contentChanges = {},
    forceRebuild = true,
    wantDiagnostics = true,
  })
end

local function attach_clangd(state, force_rebuild)
  if not state.generated_buf or not vim.api.nvim_buf_is_valid(state.generated_buf) then return end
  for _, client in ipairs(vim.lsp.get_clients { bufnr = state.source_buf }) do
    if client.name == 'clangd' and not vim.lsp.buf_is_attached(state.generated_buf, client.id) then
      vim.lsp.buf_attach_client(state.generated_buf, client.id)
      if force_rebuild then force_source_rebuild(client, state) end
    end
  end
end

local function notify_generated_changed(state)
  for _, client in ipairs(vim.lsp.get_clients { bufnr = state.source_buf }) do
    if client.name == 'clangd' then force_source_rebuild(client, state) end
  end
end

local function overlay_is_intact(state)
  if #vim.fn.win_findbuf(state.generated_buf) > 0 then return nil, 'generated overlay became visible; it was not changed or written' end
  if vim.bo[state.generated_buf].modified then return nil, 'generated overlay was modified independently; it was not changed or written' end
  if buffer_content(state.generated_buf, state.content_format) ~= state.overlay_content then
    return nil, 'generated overlay content changed unexpectedly; it was not changed or written'
  end
  return true
end

local function close_overlay(state)
  local generated_buf = state.generated_buf
  state.generated_buf = nil
  state.overlay_base_content = nil
  state.overlay_content = nil
  state.content_format = nil
  if generated_buf and vim.api.nvim_buf_is_valid(generated_buf) then vim.api.nvim_buf_delete(generated_buf, { force = true }) end
end

local function open_overlay(state)
  local existing = vim.fn.bufnr(state.generated_path, false)
  if existing >= 0 and vim.api.nvim_buf_is_valid(existing) then return nil, 'generated header already has a Neovim buffer; refusing to commandeer it' end

  local base_content, read_err = read_file(state.generated_path)
  if not base_content then return nil, 'could not read generated header: ' .. tostring(read_err) end
  local format, format_err = content_format(base_content)
  if not format then return nil, format_err end

  local generated_buf = vim.fn.bufadd(state.generated_path)
  vim.bo[generated_buf].buflisted = false
  vim.bo[generated_buf].swapfile = false
  vim.bo[generated_buf].undofile = false
  vim.fn.bufload(generated_buf)

  local disk_after_load, second_read_err = read_file(state.generated_path)
  if not disk_after_load then
    vim.api.nvim_buf_delete(generated_buf, { force = true })
    return nil, 'could not reread generated header: ' .. tostring(second_read_err)
  end
  if disk_after_load ~= base_content then
    vim.api.nvim_buf_delete(generated_buf, { force = true })
    return nil, 'generated header changed while its overlay was opening'
  end
  if vim.bo[generated_buf].modified then
    vim.api.nvim_buf_delete(generated_buf, { force = true })
    return nil, 'generated header buffer was modified while loading'
  end

  vim.bo[generated_buf].buflisted = false
  vim.bo[generated_buf].swapfile = false
  vim.bo[generated_buf].undofile = false
  vim.bo[generated_buf].filetype = vim.bo[state.source_buf].filetype ~= '' and vim.bo[state.source_buf].filetype or 'cpp'
  vim.bo[generated_buf].fileformat = format.newline == '\r\n' and 'dos' or 'unix'
  vim.bo[generated_buf].endofline = format.final_newline
  vim.bo[generated_buf].fixeol = false

  state.generated_buf = generated_buf
  state.overlay_base_content = base_content
  state.overlay_content = base_content
  state.content_format = format
  attach_clangd(state, false)
  return true
end

local function sync_overlay(state)
  state.pending = false
  if state.suspended or not vim.api.nvim_buf_is_valid(state.source_buf) then return nil, state.suspended end

  local mapping, identity, mapping_err = build_line_mapping(state)
  if not mapping then
    close_overlay(state)
    notify_failure(state, mapping_err)
    return nil, mapping_err
  end
  if state.generated_buf then
    local intact, integrity_err = overlay_is_intact(state)
    if not intact then
      close_overlay(state)
      notify_failure(state, integrity_err)
      return nil, integrity_err
    end
  end
  if identity then return true end

  if not state.generated_buf then
    local opened, open_err = open_overlay(state)
    if not opened then
      notify_failure(state, open_err)
      return nil, open_err
    end
  end

  local parsed, parse_err = M.parse_generated(state.overlay_content)
  if not parsed or parsed.file_id ~= state.file_id or not same_number_set(parsed.lines, state.tracked) then
    local reason = parse_err or 'generated identifier set no longer matches tracked macros'
    close_overlay(state)
    notify_failure(state, reason)
    return nil, reason
  end

  local transformed, transform_err = M.transform_generated(state.overlay_content, state.file_id, mapping)
  if not transformed then
    close_overlay(state)
    notify_failure(state, transform_err)
    return nil, transform_err
  end

  vim.api.nvim_buf_set_lines(state.generated_buf, 0, -1, false, content_lines(transformed, state.content_format))
  vim.bo[state.generated_buf].modified = false
  state.overlay_content = transformed
  notify_generated_changed(state)
  for _, item in ipairs(state.tracked) do
    item.generated_line = mapping[item.generated_line]
  end
  return true
end

local function schedule_sync(state)
  if state.pending or state.suspended then return end
  state.pending = true
  vim.schedule(function()
    local current = states[state.source_buf]
    if current == state and current.pending then sync_overlay(current) end
  end)
end

local function commit_overlay(state)
  if state.pending then sync_overlay(state) end
  if state.suspended or not state.generated_buf then return end

  local intact, integrity_err = overlay_is_intact(state)
  if not intact then
    close_overlay(state)
    notify_failure(state, integrity_err)
    return
  end

  local disk_content, read_err = read_file(state.generated_path)
  if not disk_content then
    close_overlay(state)
    notify_failure(state, 'could not verify generated header before writing: ' .. tostring(read_err))
    return
  end
  if disk_content ~= state.overlay_base_content then
    close_overlay(state)
    notify_failure(state, 'generated header changed externally; the overlay was discarded')
    return
  end

  if state.overlay_content ~= disk_content then
    local written, write_err = write_file(state.generated_path, state.overlay_content, state.overlay_base_content)
    if not written then
      close_overlay(state)
      notify_failure(state, 'could not write generated header: ' .. tostring(write_err))
      return
    end
  end
  close_overlay(state)
end

local function discard_state(bufnr)
  local state = states[bufnr]
  if not state then return end
  states[bufnr] = nil
  close_overlay(state)
end

local function inspect_source(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= '' then return nil, 'buffer is not a normal file buffer' end
  local source_path = vim.api.nvim_buf_get_name(bufnr)
  if source_path == '' or not source_path:lower():match '%.h$' then return nil, 'buffer is not a .h file' end
  local stat = (vim.uv or vim.loop).fs_stat(source_path)
  if not stat or stat.type ~= 'file' then return nil, 'header does not exist on disk' end

  local context, context_err = M.find_context(source_path)
  if not context then return nil, context_err end
  local source_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local include_name, include_err = M.find_generated_include(source_lines)
  if not include_name then return nil, include_err, context end
  local generated_path, generated_err = M.find_generated_header(context, include_name)
  if not generated_path then return nil, generated_err, context end
  local generated_content, read_err = read_file(generated_path)
  if not generated_content then return nil, 'could not read generated header: ' .. tostring(read_err), context end
  local parsed, parse_err = M.parse_generated(generated_content)
  if not parsed then return nil, parse_err, context end

  return {
    source_path = vim.fs.normalize(source_path),
    source_lines = source_lines,
    context = context,
    include_name = include_name,
    generated_path = generated_path,
    parsed = parsed,
  }
end

local function attach_source_buffer(bufnr, manual)
  if states[bufnr] then return states[bufnr] end
  local inspected, err, context = inspect_source(bufnr)
  if not inspected then
    if manual or context then vim.notify_once('UE generated sync: ' .. err, vim.log.levels.WARN, { title = 'UE generated sync' }) end
    return nil, err
  end

  local state = {
    source_buf = bufnr,
    source_path = inspected.source_path,
    generated_path = inspected.generated_path,
    context = inspected.context,
    file_id = inspected.parsed.file_id,
    tracked = {},
    pending = false,
  }

  local initialized, init_err = initialize_marks(state, inspected.parsed, inspected.source_lines)
  if not initialized then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    if manual or context then vim.notify_once('UE generated sync: ' .. init_err, vim.log.levels.WARN, { title = 'UE generated sync' }) end
    return nil, init_err
  end

  states[bufnr] = state
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      local current = states[bufnr]
      if not current then return true end
      schedule_sync(current)
    end,
  })
  return state
end

local function state_info(bufnr)
  local state = states[bufnr]
  if not state then
    local inspected, err, context = inspect_source(bufnr)
    if not inspected then
      local details = { 'eligible: no', 'reason: ' .. err }
      if context then
        details[#details + 1] = 'module: ' .. context.module
        details[#details + 1] = 'search roots: ' .. table.concat(context.search_roots, ', ')
      end
      return table.concat(details, '\n')
    end
    return table.concat({
      'eligible: yes (not attached)',
      'module: ' .. inspected.context.module,
      'search roots: ' .. table.concat(inspected.context.search_roots, ', '),
      'generated path: ' .. inspected.generated_path,
      'generated lines: ' .. table.concat(inspected.parsed.lines, ', '),
    }, '\n')
  end

  local tracked = {}
  for _, item in ipairs(state.tracked) do
    local current_line = validate_mark(state, item)
    tracked[#tracked + 1] = ('%s: original %d, generated %d, current %s'):format(
      item.macro_name,
      item.original_line,
      item.generated_line,
      current_line or 'invalid'
    )
  end
  local clients = {}
  if state.generated_buf and vim.api.nvim_buf_is_valid(state.generated_buf) then
    for _, client in ipairs(vim.lsp.get_clients { bufnr = state.generated_buf }) do
      if client.name == 'clangd' then clients[#clients + 1] = tostring(client.id) end
    end
  end

  return table.concat({
    'eligible: yes',
    'module: ' .. state.context.module,
    'project root: ' .. (state.context.project_root or 'none'),
    'plugin root: ' .. (state.context.plugin_root or 'none'),
    'search roots: ' .. table.concat(state.context.search_roots, ', '),
    'generated path: ' .. state.generated_path,
    'tracked: ' .. table.concat(tracked, '; '),
    'overlay: ' .. (state.generated_buf and 'open' or 'closed'),
    'clangd clients on overlay: ' .. (#clients > 0 and table.concat(clients, ', ') or 'none'),
    'status: ' .. (state.suspended or 'active'),
  }, '\n')
end

function M.setup()
  local group = vim.api.nvim_create_augroup('ue-generated-sync', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group,
    callback = function(event) attach_source_buffer(event.buf, false) end,
  })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(event)
      local state = states[event.buf]
      if state then attach_clangd(state, true) end
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(event)
      local state = states[event.buf]
      if state then commit_overlay(state) end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    callback = function(event) discard_state(event.buf) end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      local buffers = vim.tbl_keys(states)
      for _, bufnr in ipairs(buffers) do
        discard_state(bufnr)
      end
    end,
  })

  vim.api.nvim_create_user_command('UEGeneratedSync', function()
    local bufnr = vim.api.nvim_get_current_buf()
    local state, err = attach_source_buffer(bufnr, true)
    if not state then
      vim.notify('UE generated sync: ' .. err, vim.log.levels.ERROR)
      return
    end
    if state.suspended then
      vim.notify('UE generated sync is suspended: ' .. state.suspended, vim.log.levels.ERROR)
      return
    end
    local ok, sync_err = sync_overlay(state)
    vim.notify(ok and 'UE generated sync: synchronized' or ('UE generated sync: ' .. tostring(sync_err)), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end, {})

  vim.api.nvim_create_user_command(
    'UEGeneratedSyncInfo',
    function() vim.notify(state_info(vim.api.nvim_get_current_buf()), vim.log.levels.INFO, { title = 'UE generated sync' }) end,
    {}
  )

  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then attach_source_buffer(bufnr, false) end
    end
  end)
end

M._states = states
M._content_format = content_format
M._content_lines = content_lines
M._inspect_source = inspect_source
M._sync_overlay = sync_overlay

return M
