local Job = require("plenary.job")

local log = require("codecompanion.utils.log")

local M = {}

local stderr = {}
local stdout = {}
local status = ""

local api = vim.api

---@param bufnr number
local function announce_start(bufnr)
  api.nvim_exec_autocmds("User", { pattern = "CodeCompanionAgent", data = { bufnr = bufnr, status = "started" } })
end

---@param bufnr number
local function announce_end(bufnr)
  api.nvim_exec_autocmds(
    "User",
    { pattern = "CodeCompanionAgent", data = { bufnr = bufnr, status = status, error = stderr, output = stdout } }
  )
end

---Run the jobs
---@param cmds table
---@param chat CodeCompanion.Chat
---@param index number
---@return nil
local function run(cmds, chat, index)
  if index > #cmds then
    return
  end

  local cmd = cmds[index]

  log:debug("Running cmd: %s", cmd)

  chat.current_tool = Job:new({
    command = cmd[1],
    args = { unpack(cmd, 2) }, -- args start from index 2
    on_exit = function(_, exit_code)
      run(cmds, chat, index + 1)

      vim.schedule(function()
        if _G.codecompanion_cancel_tool then
          return announce_end(chat.bufnr)
        end

        if index == #cmds then
          if exit_code ~= 0 then
            status = "error"
            log:error("Command failed: %s", stderr)
          end
          return announce_end(chat.bufnr)
        end
      end)
    end,
    on_stdout = function(_, data)
      vim.schedule(function()
        log:trace("stdout: %s", data)
        if index == #cmds then
          table.insert(stdout, data)
        end
      end)
    end,
    on_stderr = function(_, data)
      table.insert(stderr, data)
    end,
  }):start()
end

---Initiate the job runner
---@param cmds table
---@param chat CodeCompanion.Chat
---@return nil
function M.init(cmds, chat)
  -- Reset defaults
  status = "success"
  stderr = {}
  stdout = {}
  _G.codecompanion_cancel_tool = false

  announce_start(chat.bufnr)
  return run(cmds, chat, 1)
end

return M
