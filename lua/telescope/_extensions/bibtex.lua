local has_telescope, telescope = pcall(require, 'telescope')
--local utils = require('telescope._extensions.bibtex.utils')
local bibtex_actions = require('telescope-bibtex.actions')
local utils = require('telescope-bibtex.utils')

if not has_telescope then
  error(
    'This plugin requires telescope.nvim (https://github.com/nvim-telescope/telescope.nvim)'
  )
end

local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local actions = require('telescope.actions')
local previewers = require('telescope.previewers')
local conf = require('telescope.config').values
local scan = require('plenary.scandir')
local path = require('plenary.path')
local putils = require('telescope.previewers.utils')
local loop = vim.loop

local depth = 1
local wrap = false
local formats = {}
formats['tex'] = '\\cite{%s}'
formats['md'] = '@%s'
formats['markdown'] = '@%s'
formats['typst'] = '@%s'
formats['rmd'] = '@%s'
formats['quarto'] = '@%s'
formats['pandoc'] = '@%s'
formats['plain'] = '%s'
local fallback_format = 'plain'
local use_auto_format = false
local user_format = ''
local user_files = {}
local files_initialized = false
local files = {}
local context_files = {}
local search_keys = { 'author', 'year', 'title' }
local citation_format = '{{author}} ({{year}}), {{title}}.'
local citation_trim_firstname = true
local citation_max_auth = 2
local user_context = false
local user_context_fallback = true
local keymaps = {
  i = {
    ["<C-e>"] = bibtex_actions.entry_append,
    ["<C-c>"] = bibtex_actions.citation_append(citation_format),
  }
}

local function table_contains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end

local function getContextBibFiles()
  local found_files = {}
  context_files = {}
  if utils.isPandocFile() then
    found_files = utils.parsePandoc()
  elseif utils.isLatexFile() then
    found_files = utils.parseLatex()
  end
  for _, file in pairs(found_files) do
    if not utils.file_present(context_files, file) then
      table.insert(context_files, { name = file, mtime = 0, entries = {} })
    end
  end
end

local function getBibFiles(dir)
  scan.scan_dir(dir, {
    depth = depth,
    search_pattern = '.*%.bib',
    on_insert = function(file)
      local p = path:new(file):absolute()
      if not utils.file_present(files, p) then
        table.insert(files, { name = p , mtime = 0, entries = {} })
      end
    end,
  })
end

local function initFiles()
  for _, file in pairs(user_files) do
    local p = path:new(file)
    if p:is_dir() then
      getBibFiles(file)
    elseif p:is_file() then
      if not utils.file_present(files, file) then
        table.insert(files, { name = file, mtime = 0, entries = {} })
      end
    end
  end
  getBibFiles('.')
end

local function read_file(file)
  local labels = {}
  local contents = {}
  local search_relevants = {}
  local p = path:new(file)
  if not p:exists() then
    return {}
  end
  local data = p:read()
  data = data:gsub('\r', '')
  local entry = ''
  while true do
    entry = data:match('@%w*%s*%b{}')
    if entry == nil then
      break
    end
    local label = entry:match('{%s*[^{},~#%\\]+,\n')
    if label then
      label = vim.trim(label:gsub('\n', ''):sub(2, -2))
      local content = vim.split(entry, '\n')
      table.insert(labels, label)
      contents[label] = content
      search_relevants[label] = {}
      if table_contains(search_keys, [[label]]) then
        search_relevants[label]['label'] = label
      end
      for _, key in pairs(search_keys) do
        local key_pattern = utils.construct_case_insensitive_pattern(key)
        local match_base = '%f[%w]' .. key_pattern
        local s = nil
        local bracket_match = entry:match(match_base .. '%s*=%s*%b{}')
        local quote_match = entry:match(match_base .. '%s*=%s*%b""')
        local number_match = entry:match(match_base .. '%s*=%s*%d+')
        if bracket_match ~= nil then
          s = bracket_match:match('%b{}')
        elseif quote_match ~= nil then
          s = quote_match:match('%b""')
        elseif number_match ~= nil then
          s =  number_match:match('%d+')
        end
        if s ~= nil then
          s = s:gsub('["{}\n]', ''):gsub('%s%s+', ' ')
          search_relevants[label][string.lower(key)] = vim.trim(s)
        end
      end
    end
    data = data:sub(#entry + 2)
  end
  return labels, contents, search_relevants
end

local function formatDisplay(entry)
  local display_string = ''
  local search_string = ''
  for _, val in pairs(search_keys) do
    if tonumber(entry[val]) ~= nil then
      display_string = display_string .. ' ' .. '(' .. entry[val] .. ')'
      search_string = search_string .. ' ' .. entry[val]
    elseif entry[val] ~= nil then
      display_string = display_string .. ', ' .. entry[val]
      search_string = search_string .. ' ' .. entry[val]
    end
  end
  return vim.trim(display_string:sub(2)), search_string:sub(2)
end

local function setup_picker(context, context_fallback)
  if context then
    getContextBibFiles()
  end
  if not files_initialized then
    initFiles()
    files_initialized = true
  end
  local results = {}
  local current_files = files
  if context and (not context_fallback or next(context_files)) then
    current_files = context_files
  end
  for _, file in pairs(current_files) do
    local mtime = loop.fs_stat(file.name).mtime.sec
    if mtime ~= file.mtime then
      file.entries = {}
      local result, content, search_relevants = read_file(file.name)
      for _, entry in pairs(result) do
        table.insert(results, {
          name = entry,
          content = content[entry],
          search_keys = search_relevants[entry],
        })
        table.insert(file.entries, {
          name = entry,
          content = content[entry],
          search_keys = search_relevants[entry],
        })
      end
      file.mtime = mtime
    else
      for _, entry in pairs(file.entries) do
        table.insert(results, entry)
      end
    end
  end
  return results
end

local function parse_format_string(opts)
  local format_string = nil
  if opts.format_string ~= nil then
    format_string = opts.format_string
  elseif opts.format ~= nil then
    format_string = formats[opts.format]
  elseif use_auto_format then
    format_string = formats[vim.bo.filetype]
    if format_string == nil and vim.bo.filetype:match('markdown%.%a+') then
      format_string = formats['markdown']
    end
  end
  format_string = format_string or formats[user_format]
  return format_string
end

local function parse_context(opts)
  local context = nil
  if opts.context ~= nil then
    context = opts.context
  else
    context = user_context
  end
  return context
end

local function parse_context_fallback(opts)
  local context_fallback = nil
  if opts.context_fallback ~= nil then
    context_fallback = opts.context_fallback
  else
    context_fallback = user_context_fallback
  end
  return context_fallback
end

local function bibtex_picker(opts)
  opts = opts or {}
  local format_string = parse_format_string(opts)
  local context = parse_context(opts)
  local context_fallback = parse_context_fallback(opts)
  local results = setup_picker(context, context_fallback)
  pickers
    .new(opts, {
      prompt_title = 'Bibtex References',
      finder = finders.new_table({
        results = results,
        entry_maker = function(line)
          local display_string, search_string = formatDisplay(line.search_keys)
          if display_string == '' then
            display_string = line.name
          end
          if search_string == '' then
            search_string = line.name
          end
          return {
            value = search_string,
            ordinal = search_string,
            display = display_string,
            id = line,
          }
        end,
      }),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry, status)
          vim.api.nvim_buf_set_lines(
            self.state.bufnr,
            0,
            -1,
            true,
            results[entry.index].content
          )
          putils.highlighter(self.state.bufnr, 'bib')
          vim.api.nvim_win_set_option(
            status.preview_win,
            'wrap',
            utils.parse_wrap(opts, wrap)
          )
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(_, map)
        actions.select_default:replace(bibtex_actions.key_append(format_string))
        for mode, mappings in pairs(keymaps) do
          for key, action in pairs(mappings) do
            map(mode, key, action)
          end
        end
        return true
      end,
    })
    :find()
end


return telescope.register_extension({
  setup = function(ext_config)
    depth = ext_config.depth or depth
    local custom_formats = ext_config.custom_formats or {}
    for _, format in pairs(custom_formats) do
      formats[format.id] = format.cite_marker
    end
    if ext_config.format ~= nil and formats[ext_config.format] ~= nil then
      user_format = ext_config.format
    else
      user_format = fallback_format
      use_auto_format = true
    end
    user_context = ext_config.context or user_context
    user_context_fallback = ext_config.context_fallback or user_context_fallback
    if ext_config.global_files ~= nil then
      for _, file in pairs(ext_config.global_files) do
        table.insert(user_files, vim.fn.expand(file))
      end
    end
    search_keys = ext_config.search_keys or search_keys
    citation_format = ext_config.citation_format
      or '{{author}} ({{year}}), {{title}}.'
    citation_trim_firstname = ext_config.citation_trim_firstname
      or citation_trim_firstname
    citation_max_auth = ext_config.citation_max_auth or citation_max_auth
    wrap = ext_config.wrap or wrap
    keymaps = vim.tbl_extend("force", keymaps, ext_config.mappings or {})
  end,
  exports = {
    bibtex = bibtex_picker,
  },
})
