local BaseSlashCommand = require("codecompanion.slash_commands").BaseSlashCommand
local api = vim.api
local fn = vim.fn

---@class TabCommand: CodeCompanion.BaseSlashCommand
local TabCommand = BaseSlashCommand:extend()

function TabCommand:init(opts)
  opts = opts or {}
  BaseSlashCommand.init(self, opts)
end

--- Complete file paths for the command.
--- @param params cmp.SourceCompletionApiParams
--- @param callback fun(response: CodeCompanion.SlashCommandCompletionResponse|nil)
---@diagnostic disable-next-line: unused-local
function TabCommand:complete(params, callback)
  local bufs = api.nvim_list_bufs()
  ---@type CodeCompanion.SlashCommandCompletionItem[]
  local items = {}

  for _, buf in ipairs(bufs) do
    if api.nvim_buf_is_loaded(buf) then
      local name = api.nvim_buf_get_name(buf)
      ---@diagnostic disable-next-line: undefined-field
      if name == "" or name:match("*[CodeCompanion]*") then
        goto continue
      end

      table.insert(items, {
        label = name,
        kind = require("cmp").lsp.CompletionItemKind.File,
        slash_command_name = self.name,
        slash_command_args = {
          bufnr = buf,
        },
      })

      ::continue::
    end
  end

  return items
end

---Resolve completion item (optional). This is called right before the completion is about to be displayed.
---Useful for setting the text shown in the documentation window (`completion_item.documentation`).
---@param completion_item CodeCompanion.SlashCommandCompletionItem
---@param callback fun(completion_item: CodeCompanion.SlashCommandCompletionItem|nil)
function TabCommand:resolve(completion_item, callback)
  local bufnr = completion_item.slash_command_args.bufnr
  local full_path = api.nvim_buf_get_name(bufnr)
  local cwd_relative_path = fn.fnamemodify(full_path, ":.")
  local lines = api.nvim_buf_get_lines(bufnr, 0, 1, false)

  local item = {
    label = full_path,
    kind = require("cmp").lsp.CompletionItemKind.File,
    documentation = string.format("```%s\n%s\n```", cwd_relative_path, table.concat(lines, "\n")),
  }

  return callback(item)
end

return TabCommand
