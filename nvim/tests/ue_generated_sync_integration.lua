vim.opt.runtimepath:prepend(vim.fn.getcwd())

local sync = require 'ue_generated_sync'
sync.setup()

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')

local function write_bytes(path, content)
  local file = assert(io.open(path, 'wb'))
  assert(file:write(content))
  file:close()
end

local function read_bytes(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read '*a'
  file:close()
  return content
end

local source_content = table.concat({
  '#pragma once',
  '#include "Actor.generated.h"',
  '',
  'UCLASS()',
  'class AActor {',
  'public:',
  '  GENERATED_BODY()',
  '};',
  '',
}, '\r\n')

local generated_content = table.concat({
  '#define FID_Test_Source_Module_Private_Actor_h_4_PROLOG',
  '#define FID_Test_Source_Module_Private_Actor_h_7_INCLASS value',
  '#define FID_Test_Source_Module_Private_Actor_h_7_GENERATED_BODY FID_Test_Source_Module_Private_Actor_h_7_INCLASS',
  '#define CURRENT_FILE_ID FID_Test_Source_Module_Private_Actor_h',
  '',
}, '\r\n')

local function fixture(name)
  local project = vim.fs.joinpath(root, name)
  local source_dir = vim.fs.joinpath(project, 'Source', 'Module', 'Private')
  local generated_dir = vim.fs.joinpath(project, 'Intermediate', 'Build', 'Win64', 'Editor', 'Inc', 'Module', 'UHT')
  vim.fn.mkdir(source_dir, 'p')
  vim.fn.mkdir(generated_dir, 'p')
  write_bytes(vim.fs.joinpath(project, name .. '.uproject'), '{}')
  local source = vim.fs.joinpath(source_dir, 'Actor.h')
  local generated = vim.fs.joinpath(generated_dir, 'Actor.generated.h')
  write_bytes(source, source_content)
  write_bytes(generated, generated_content)
  return source, generated
end

local function open_fixture(name)
  local source, generated = fixture(name)
  vim.cmd.edit(vim.fn.fnameescape(source))
  local bufnr = vim.api.nvim_get_current_buf()
  local state = assert(sync._states[bufnr], 'source did not attach')
  assert(#state.tracked == 2, 'expected two tracked macros')
  return bufnr, state, source, generated
end

local function insert_first_line(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '' })
  assert(
    vim.wait(1000, function()
      local state = sync._states[bufnr]
      return state and state.overlay_content ~= nil
    end),
    'overlay synchronization timed out'
  )
end

local discard_buf, discard_state, _, discard_generated = open_fixture 'Discard'
insert_first_line(discard_buf)
assert(read_bytes(discard_generated) == generated_content, 'unsaved synchronization touched disk')
assert(discard_state.overlay_content:find('_5_PROLOG', 1, true), 'UCLASS identifier did not move in overlay')
assert(discard_state.overlay_content:find('_8_GENERATED_BODY', 1, true), 'GENERATED_BODY identifier did not move in overlay')
assert(vim.bo[discard_state.generated_buf].buflisted == false, 'overlay buffer is listed')
assert(vim.bo[discard_state.generated_buf].modified == false, 'overlay buffer is modified')

vim.cmd.undo()
assert(vim.wait(1000, function() return discard_state.overlay_content == generated_content end), 'undo did not reverse the overlay')
vim.cmd.redo()
assert(vim.wait(1000, function() return discard_state.overlay_content ~= generated_content end), 'redo did not restore the overlay')
vim.cmd 'bdelete!'
assert(sync._states[discard_buf] == nil, 'discard left source state behind')
assert(read_bytes(discard_generated) == generated_content, 'discard wrote the generated header')

local save_buf, save_state, _, save_generated = open_fixture 'Save'
insert_first_line(save_buf)
vim.cmd.write()
local saved_generated = read_bytes(save_generated)
assert(saved_generated:find('_5_PROLOG', 1, true), 'save did not commit UCLASS identifier')
assert(saved_generated:find('_8_GENERATED_BODY', 1, true), 'save did not commit GENERATED_BODY identifier')
assert(not saved_generated:find '[^\r]\n', 'save did not preserve CRLF')
assert(saved_generated:sub(-2) == '\r\n', 'save did not preserve final newline')
assert(save_state.generated_buf == nil, 'save did not close the overlay')
vim.cmd 'bdelete!'

local conflict_buf, conflict_state, _, conflict_generated = open_fixture 'Conflict'
insert_first_line(conflict_buf)
write_bytes(conflict_generated, generated_content .. '// external\r\n')
vim.cmd.write()
local conflicted_generated = read_bytes(conflict_generated)
assert(conflicted_generated == generated_content .. '// external\r\n', 'conflict overwrote external generated content')
assert(conflict_state.generated_buf == nil, 'conflict did not close the overlay')
assert(conflict_state.suspended and conflict_state.suspended:find('externally', 1, true), 'conflict did not suspend synchronization')
vim.cmd 'bdelete!'

local delete_buf, delete_state = open_fixture 'DeleteMacro'
insert_first_line(delete_buf)
vim.api.nvim_buf_set_lines(delete_buf, 4, 5, false, { '' })
assert(vim.wait(1000, function() return delete_state.suspended ~= nil end), 'deleting a tracked macro did not suspend synchronization')
assert(delete_state.generated_buf == nil, 'invalid macro left a stale overlay open')
vim.cmd 'bdelete!'

local altered_buf, altered_state = open_fixture 'AlteredOverlay'
insert_first_line(altered_buf)
vim.api.nvim_buf_set_lines(altered_state.generated_buf, 0, 1, false, { '// user change' })
vim.api.nvim_buf_set_lines(altered_buf, 0, 0, false, { '' })
assert(vim.wait(1000, function() return altered_state.suspended ~= nil end), 'an independently modified overlay did not suspend synchronization')
assert(altered_state.generated_buf == nil, 'an independently modified overlay was not closed')
vim.cmd 'bdelete!'

vim.fn.delete(root, 'rf')
print 'ue_generated_sync integration tests passed'
