vim.opt.runtimepath:prepend(vim.fn.getcwd())

local sync = require 'ue_generated_sync'

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then error(('%s\nexpected: %s\nactual: %s'):format(message, vim.inspect(expected), vim.inspect(actual))) end
end

local generated = table.concat({
  '#define FID_Test_h_14_A one',
  '#define FID_Test_h_15_B FID_Test_h_15_C',
  '#define OTHER_FID_14_A unchanged',
  '#define CURRENT_FILE_ID FID_Test_h',
  '',
}, '\r\n')

local parsed = assert(sync.parse_generated(generated))
equal(parsed.file_id, 'FID_Test_h', 'parses CURRENT_FILE_ID')
equal(parsed.lines, { 14, 15 }, 'collects sorted unique generated lines')

local transformed = assert(sync.transform_generated(generated, parsed.file_id, { [14] = 15, [15] = 16 }))
assert(transformed:find('FID_Test_h_15_A', 1, true), 'moves 14 to 15')
assert(transformed:find('FID_Test_h_16_B FID_Test_h_16_C', 1, true), 'moves every 15 token to 16 without cascading')
assert(transformed:find('OTHER_FID_14_A', 1, true), 'leaves unrelated file IDs unchanged')
assert(not transformed:find '[^\r]\n', 'preserves CRLF')
assert(transformed:sub(-2) == '\r\n', 'preserves final newline')

equal(assert(sync.transform_generated(generated, parsed.file_id, { [14] = 14, [15] = 15 })), generated, 'identity mapping is a no-op')
assert(not sync.transform_generated(generated, parsed.file_id, { [14] = 15 }), 'rejects incomplete mappings')
assert(not sync.transform_generated(generated, parsed.file_id, { [14] = 16, [15] = 16 }), 'rejects duplicate targets')

local macro = assert(sync.find_macro_on_line '\tGENERATED_BODY ( ) // UCLASS()')
equal({ macro.name, macro.start_col, macro.end_col }, { 'GENERATED_BODY', 1, 15 }, 'finds a generic uppercase macro and its byte range')
assert(not sync.find_macro_on_line 'const char* text = "UCLASS()"; // GENERATED_BODY()', 'ignores strings and line comments')

local lexical_state = { block_comment = false }
local _, next_state = sync.find_macro_on_line('/* UCLASS()', lexical_state)
local after_comment = assert(sync.find_macro_on_line('still comment */ GENERATED_BODY()', next_state))
equal(after_comment.name, 'GENERATED_BODY', 'ignores block comments across lines')
assert(not sync.find_macro_on_line 'UCLASS() GENERATED_BODY()', 'rejects ambiguous lines')

local string_state = { block_comment = false }
local _, continued_state = sync.find_macro_on_line('const char* text = "UCLASS()\\', string_state)
local after_string = assert(sync.find_macro_on_line('GENERATED_BODY()"; UCLASS()', continued_state))
equal(after_string.name, 'UCLASS', 'ignores continued strings across lines')

equal(
  assert(sync.find_generated_include { '/* #include "Old.generated.h" */', '#include "Folder/Real.generated.h"' }),
  'Real.generated.h',
  'finds one active generated include'
)
assert(not sync.find_generated_include { '#include "One.generated.h"', '#include "Two.generated.h"' }, 'rejects multiple generated includes')

local format = assert(sync._content_format 'a\r\nb\r\n')
equal(format, { newline = '\r\n', final_newline = true }, 'detects CRLF and final newline')
equal(sync._content_lines('a\r\nb\r\n', format), { 'a', 'b' }, 'converts byte content to Neovim lines')
assert(not sync._content_format 'a\r\nb\n', 'rejects mixed line endings')

print 'ue_generated_sync pure tests passed'
