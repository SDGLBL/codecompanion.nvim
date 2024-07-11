local api = vim.api
local M = {}

local locked_buffers = {}

-- Store the original buffer options
local function store_buffer_options(bufnr)
  return {
    modifiable = vim.bo[bufnr].modifiable,
    readonly = vim.bo[bufnr].readonly,
    modified = vim.bo[bufnr].modified,
  }
end

-- Restore the original buffer options
local function restore_buffer_options(bufnr, options)
  vim.bo[bufnr].modifiable = options.modifiable
  vim.bo[bufnr].readonly = options.readonly
  vim.bo[bufnr].modified = options.modified
end

-- Lock the buffer
local function lock_buffer(bufnr)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

-- Unlock the buffer for editing
local function unlock_buffer(bufnr)
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
end

function M.with_locked_buffer(bufnr, func)
  if locked_buffers[bufnr] then
    return false, "Buffer is already locked"
  end

  local original_options = store_buffer_options(bufnr)
  locked_buffers[bufnr] = true
  lock_buffer(bufnr)

  -- Create a temporary unlock function for the passed function to use
  local temp_unlock = function()
    unlock_buffer(bufnr)
  end

  local success, result = pcall(function()
    return func(temp_unlock)
  end)

  locked_buffers[bufnr] = nil
  restore_buffer_options(bufnr, original_options)

  if not success then
    return false, "Error occurred while modifying buffer: " .. tostring(result)
  end

  return true, result
end

-- Add an autocommand to prevent modifications when the buffer is locked
api.nvim_create_autocmd("BufModifiedSet", {
  group = api.nvim_create_augroup("CodeCompanionBufferLocker", { clear = true }),
  callback = function(ev)
    if locked_buffers[ev.buf] then
      vim.schedule(function()
        vim.bo[ev.buf].modified = false
      end)
    end
  end,
})

return M
