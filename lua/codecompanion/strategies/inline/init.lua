--[[
The Inline Assistant - This is where code is applied directly to a Neovim buffer
--]]

---@class CodeCompanion.Inline
---@field id integer The ID of the inline prompt
---@field adapter CodeCompanion.Adapter The adapter to use for the inline prompt
---@field aug number The ID for the autocmd group
---@field buffer_context table The context of the buffer the inline prompt was initiated from
---@field bufnr number The buffer number to apply the inline edits to
---@field chat_context? table The content from the last opened chat buffer
---@field classification CodeCompanion.Inline.Classification Where to place the generated code in Neovim
---@field current_request? table The current request that's being processed
---@field diff? table The diff provider
---@field lines table Lines in the buffer before the inline changes
---@field opts table
---@field prompts table The prompts to send to the LLM

---@class CodeCompanion.InlineArgs
---@field adapter? CodeCompanion.Adapter
---@field buffer_context? table The context of the buffer the inline prompt was initiated from
---@field chat_context? table Messages from a chat buffer
---@field diff? table The diff provider
---@field lines? table The lines in the buffer before the inline changes
---@field opts? table
---@field placement? string The placement of the code in Neovim
---@field pre_hook? fun():number Function to run before the inline prompt is started
---@field prompts? table The prompts to send to the LLM

---@class CodeCompanion.Inline.Classification
---@field placement string The placement of the code in Neovim
---@field pos {line: number, col: number, bufnr: number} The data for where the prompt should be placed

local adapters = require("codecompanion.adapters")
local client = require("codecompanion.http")
local config = require("codecompanion.config")
local keymaps = require("codecompanion.utils.keymaps")
local log = require("codecompanion.utils.log")
local util = require("codecompanion.utils")
local variables = require("codecompanion.strategies.inline.variables")

local api = vim.api
local fmt = string.format

local user_role = config.constants.USER_ROLE

local CONSTANTS = {
  AUTOCMD_GROUP = "codecompanion.inline",

  PLACEMENT_PROMPT =
  [[I would like you to assess a prompt which has been made from within the Neovim text editor. Based on this prompt, I require you to determine where the output from this prompt should be placed. I am calling this determination the "<method>". For example, the user may wish for the output to be placed in one of the following ways:

1. `replace` the current selection
2. `add` after the current cursor position
3. `before` before the current cursor position
4. `new` in a new buffer/file
5. `chat` in a buffer which the user can then interact with

Here are some example prompts and their correct method classification ("<method>") to help you:

- "Can you refactor/fix/amend this code?" would be `replace` as we're changing existing code
- "Can you create a method/function that does XYZ" would be `add` as it requires new code to be added to a buffer
- "Can you add a docstring to this function?" would be `before` as docstrings are typically before the start of a function
- "Can you create a method/function for XYZ and put it in a new buffer?" would be `new` as the user is explicitly asking for a new buffer
- "Can you write unit tests for this code?" would be `new` as tests are commonly written in a new file away from the logic of the code they're testing
- "Why is Neovim so popular?" or "What does this code do?" would be `chat` as the answer does not result in code being written and is a discursive topic leading to additional follow-up questions
- "Write some comments for this code." would be `replace` as we're changing existing code

The user may also provide a prompt which references a conversation you've had with them previously. Just focus on determining the correct method classification.

Please respond to this prompt in the format "<method>", placing the classification in a tag. For example "replace" would be `<replace>`, "add" would be `<add>`, "before" would be `<before>`, "new" would be `<new>` and "chat" would be `<chat>`. If you can't classify the message, reply with `<error>`. Do not provide any other content in your response or you'll break the plugin this is being called from.]],
  CODE_ONLY_PROMPT = [[The following response must contain ONLY raw code that can be directly written to a Neovim buffer:

1. No Markdown formatting or backticks
2. No explanations or prose
3. Use proper indentation for the target language
4. Include language-appropriate comments when needed
5. Use actual line breaks (not `\n`)
6. Preserve all whitespace
7. Only include relevant code (no full file echoing)
8. Be mindful that you may not need to return all of the code that the user has sent

If you cannot provide clean file-ready code, reply with `<error>`]],
}

---Format code into a code block alongside a message
---@param message string
---@param filetype string
---@param code table
---@return string
local function code_block(message, filetype, code)
  return fmt(
    [[%s
<code>
```%s
%s
```
</code>]],
    message,
    filetype,
    table.concat(code, "\n")
  )
end

---Overwrite the given selection in the buffer with an empty string
---@param context table The buffer context in the inline class
local function overwrite_selection(context)
  log:trace("[Inline] Overwriting selection: %s", context)
  if context.start_col > 0 then
    context.start_col = context.start_col - 1
  end

  local line_length = #vim.api.nvim_buf_get_lines(context.bufnr, context.end_line - 1, context.end_line, true)[1]
  if context.end_col > line_length then
    context.end_col = line_length
  end

  api.nvim_buf_set_text(
    context.bufnr,
    context.start_line - 1,
    context.start_col,
    context.end_line - 1,
    context.end_col,
    { "" }
  )
  api.nvim_win_set_cursor(context.winnr, { context.start_line, context.start_col })
end

---@class CodeCompanion.Inline
local Inline = {}

---@param args CodeCompanion.InlineArgs
function Inline.new(args)
  log:trace("[Inline] Initiating with args: %s", args)

  local id = math.random(10000000)

  local self = setmetatable({
    id = id,
    aug = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. ":" .. id, {
      clear = false,
    }),
    buffer_context = args.buffer_context,
    bufnr = args.buffer_context.bufnr,
    classification = {
      placement = args and args.placement,
      pos = {},
    },
    chat_context = args.chat_context or {},
    diff = args.diff or {},
    lines = {},
    opts = args.opts or {},
    prompts = vim.deepcopy(args.prompts),
  }, { __index = Inline })

  self:set_adapter(args.adapter or config.strategies.inline.adapter)
  if not self.adapter then
    return log:error("[Inline] No adapter found")
  end

  -- Check if the user has manually overridden the adapter
  if vim.g.codecompanion_adapter and self.adapter.name ~= vim.g.codecompanion_adapter then
    self:set_adapter(config.adapters[vim.g.codecompanion_adapter])
  end

  if self.opts and self.opts.placement then
    self.classification.placement = self.opts.placement
  end

  log:debug("[Inline] Instance created with ID %d", self.id)
  return self
end

---Set the adapter for the inline prompt
---@param adapter CodeCompanion.Adapter|string|function
---@return nil
function Inline:set_adapter(adapter)
  if not self.adapter or not adapters.resolved(adapter) then
    self.adapter = adapters.resolve(adapter)
  end
end

---Start the classification of the user's prompt
---@param opts? table
function Inline:start(opts)
  log:trace("[Inline] Starting with opts: %s", opts)

  if opts and opts[1] then
    self.opts = opts[1]
  end
  if opts and opts.args then
    return self:classify(opts.args)
  end

  if self.opts and self.opts.user_prompt then
    if type(self.opts.user_prompt) == "string" then
      return self:classify(self.opts.user_prompt)
    end

    local title
    if self.buffer_context.buftype == "terminal" then
      title = "Terminal"
    else
      title = string.gsub(self.buffer_context.filetype, "^%l", string.upper)
    end

    vim.ui.input({ prompt = title .. " " .. config.display.action_palette.prompt }, function(input)
      if not input then
        return
      end

      log:info("[Inline] User input received: %s", input)
      self.buffer_context.user_input = input
      return self:classify(input)
    end)
  else
    return self:classify()
  end
end

---Initially, we ask the LLM to classify the prompt, with the outcome being
---a judgement on the placement of the response.
---@param user_input? string
function Inline:classify(user_input)
  self.classification.prompts = self:form_prompt()

  if user_input and self.opts.append_user_prompt then
    table.insert(self.classification.prompts, {
      role = config.constants.USER_ROLE,
      content = "<question>" .. user_input .. "</question>",
      opts = {
        tag = "user_prompt",
        visible = true,
      },
    })
  end

  local merged_messages = {}
  for _, msg in ipairs(self.classification.prompts) do
    if msg.role == config.constants.USER_ROLE then
      table.insert(merged_messages, msg)
    end
  end
  local prompt = merged_messages
  log:debug("[Inline] Prompt to classify: %s", prompt)

  if not self.opts.placement then
    log:info("[Inline] Classification request started")
    util.fire("InlineStarted")

    -- Classification step uses streaming
    self.adapter.opts.stream = true
    self.classification.placement = ""

    ---Callback function to be called during the stream
    ---@param err string
    ---@param data table
    local cb = function(err, data)
      if err then
        return log:error("[Inline] Error during classification: %s", err)
      end

      if data then
        local content = self.adapter.handlers.chat_output(self.adapter, data)
        self.classification.placement = self.classification.placement .. content.output.content
      end
    end

    ---Callback function to be called when the stream is done
    local done = function()
      log:info('[Inline] Placement: "%s"', self.classification.placement)

      local ok, parts = pcall(function()
        return self.classification.placement:match("<(.-)>")
      end)
      if not ok or parts == "error" then
        return log:error("[Inline] Could not determine where to place the output from the prompt")
      end

      self.classification.placement = parts
      if self.classification.placement == "chat" then
        log:info("[Inline] Sending inline prompt to the chat buffer")
        return self:send_to_chat()
      end

      return self:submit()
    end

    -- Create proper payload object for client:request
    local classify_payload = {
      messages = self.adapter:map_roles({
        {
          role = config.constants.SYSTEM_ROLE,
          content = CONSTANTS.PLACEMENT_PROMPT,
        },
        {
          role = config.constants.USER_ROLE,
          content = 'The prompt to assess is: "' ..
              (prompt[1] and prompt[1].content or user_input or "Unknown prompt") .. '"',
        },
      }),
      tools = {},
    }

    self.current_request = client.new({ adapter = self.adapter:map_schema_to_params(), user_args = { event = "InlineClassify" } })
        :request(
          classify_payload,
          { callback = cb, done = done },
          {
            bufnr = self.buffer_context.bufnr,
            strategy = "inline",
          }
        )
  else
    self.classification.placement = self.opts.placement
    return self:submit()
  end
end

---Prompt the LLM
---@param user_prompt? string The prompt supplied by the user
---@return nil
function Inline:prompt(user_prompt)
  log:trace("[Inline] Starting")
  log:debug("[Inline] User prompt: %s", user_prompt)

  local prompts = {}

  local function add_prompt(content, role, opts)
    table.insert(prompts, {
      content = content,
      role = role or user_role,
      opts = opts or { visible = true },
    })
  end


  -- Followed by prompts from external sources
  local ext_prompts = self:make_ext_prompts()
  if ext_prompts then
    for i = 1, #ext_prompts do
      prompts[#prompts + 1] = ext_prompts[i]
    end
  end

  if user_prompt then
    -- 1. Check if the first word is an adapter
    local split = vim.split(user_prompt, " ")
    if config.adapters and config.adapters[split[1]] then
      local adapter = config.adapters[split[1]]
      self:set_adapter(adapter)
      table.remove(split, 1)
      user_prompt = table.concat(split, " ")
    end

    -- 2. Check for any variables
    local vars = variables.new({ inline = self, prompt = user_prompt })
    local found = vars:find():replace():output()
    if found then
      for _, var in ipairs(found) do
        add_prompt(var, user_role, { visible = false })
      end
      user_prompt = vars.prompt
    end

    -- 3. Add the user's prompt
    add_prompt("<prompt>" .. user_prompt .. "</prompt>")
    log:debug("[Inline] Modified user prompt: %s", user_prompt)
  end

  -- From the prompt library, user's can explicitly ask to be prompted for input
  if self.opts and self.opts.user_prompt then
    local title = string.gsub(self.buffer_context.filetype, "^%l", string.upper)
    vim.schedule(function()
      vim.ui.input({ prompt = title .. " " .. config.display.action_palette.prompt }, function(input)
        if not input then
          return
        end

        log:info("[Inline] User input received: %s", input)
        add_prompt("<prompt>" .. input .. "</prompt>", user_role)
        self.prompts = prompts
        return self:submit(vim.deepcopy(prompts))
      end)
    end)
  else
    self.prompts = prompts
    return self:submit(vim.deepcopy(prompts))
  end
end

---Prompts can enter the inline class from numerous external sources such as the
---cmd line and the action palette. We begin to form the payload to send to
---the LLM in this method, checking conditions and expanding functions.
---@return table|nil
function Inline:make_ext_prompts()
  local prompts = {}

  if self.prompts then
    for _, prompt in ipairs(self.prompts) do
      if prompt.opts and prompt.opts.contains_code and not config.can_send_code() then
        goto continue
      end
      if prompt.condition and not prompt.condition(self.buffer_context) then
        goto continue
      end
      if type(prompt.content) == "function" then
        prompt.content = prompt.content(self.buffer_context)
      end
      table.insert(prompts, {
        role = prompt.role,
        content = prompt.content,
        opts = prompt.opts or {},
      })
      ::continue::
    end
  end

  -- Add any visual selections to the prompt
  if config.can_send_code() then
    if self.buffer_context.is_visual and not self.opts.stop_context_insertion then
      log:trace("[Inline] Sending visual selection")
      table.insert(prompts, {
        role = user_role,
        content = code_block(
          "For context, this is the code that I've visually selected in the buffer, which is relevant to my prompt:",
          self.buffer_context.filetype,
          self.buffer_context.lines
        ),
        opts = {
          tag = "visual",
          visible = false,
        },
      })
    end
  end

  return prompts
end

---When a defined prompt is sent alongside the user's input, we need to do some
---additional processing such as evaluating conditions and determining if
---the prompt contains code which can be sent to the LLM.
---@return table
function Inline:form_prompt()
  local output = {}

  if self.prompts then
    for _, prompt in ipairs(self.prompts) do
      if prompt.opts and prompt.opts.contains_code and not config.can_send_code() then
        goto continue
      end
      if prompt.condition and not prompt.condition(self.buffer_context) then
        goto continue
      end

      if type(prompt.content) == "function" then
        prompt.content = prompt.content(self.buffer_context)
      end

      table.insert(output, {
        role = prompt.role,
        content = prompt.content,
        opts = prompt.opts or {},
      })

      ::continue::
    end
  end

  -- Add any visual selection to the prompt
  if config.can_send_code() then
    if self.buffer_context.is_visual and not self.opts.stop_context_insertion then
      log:trace("[Inline] Sending visual selection")
      table.insert(output, {
        role = config.constants.USER_ROLE,
        content = code_block(
          "For context, this is the code that I've selected in the buffer",
          self.buffer_context.filetype,
          self.buffer_context.lines
        ),
        opts = {
          tag = "visual",
          visible = true,
        },
      })
    end
  end

  return output
end

---Stop the current request
---@return nil
function Inline:stop()
  if self.current_request then
    self.current_request:shutdown()
    self.current_request = nil
    self.adapter.handlers.on_exit(self.adapter)
  end
end

---Submit the prompts to the LLM to process
---@return nil
function Inline:submit()
  self:place(self.classification.placement)
  log:debug("[Inline] Determined position for output: %s", self.classification.pos)

  local bufnr = self.classification.pos.bufnr

  -- Create fresh prompts for code generation (not reusing classification prompts)
  local code_generation_prompts = {}

  -- Add system prompt for code generation
  table.insert(code_generation_prompts, {
    role = config.constants.SYSTEM_ROLE,
    content = CONSTANTS.CODE_ONLY_PROMPT,
    opts = {
      tag = "system_tag",
      visible = false,
    },
  })

  -- Add the context from the chat buffer
  if not vim.tbl_isempty(self.chat_context) then
    if #self.chat_context > 0 then
      for i = #self.chat_context, 1, -1 do
        local message = self.chat_context[i]
        if message.role == config.constants.LLM_ROLE or message.role == config.constants.USER_ROLE then
          table.insert(code_generation_prompts, {
            role = message.role,
            content = message.content,
            opts = {
              tag = "chat_context",
              visible = false,
            },
          })
        end
      end
    end
  end

  -- Add the original prompts from external sources (but not classification prompts)
  local ext_prompts = self:form_prompt()
  if ext_prompts then
    for _, prompt in ipairs(ext_prompts) do
      table.insert(code_generation_prompts, prompt)
    end
  end

  log:info("[Inline] Request started")

  -- Add a keymap to cancel the request
  api.nvim_buf_set_keymap(bufnr, "n", "q", "", {
    desc = "Stop the request",
    callback = function()
      log:trace("[Inline] Cancelling the inline request")
      if self.current_request then
        self:stop()
      end
    end,
  })

  if vim.tbl_contains({ "replace", "add", "before" }, self.classification.placement) then
    pcall(function() self:start_diff() end)
    if config.strategies and config.strategies.inline and config.strategies.inline.keymaps then
      keymaps
          .new({
            bufnr = bufnr,
            callbacks = require("codecompanion.strategies.inline.keymaps"),
            data = self,
            keymaps = config.strategies.inline.keymaps,
          })
          :set()
    end
  end

  local id = math.random(10000000)

  local group = vim.api.nvim_create_augroup("ReadIDFromCodeCompanion", {})

  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "CodeCompanionRequestStarted",
    group = group,
    callback = function(request)
      id = request.data.id
    end,
  })


  ---Callback function to be called during the stream
  ---@param err string
  ---@param data table
  local cb = function(err, data)
    log:trace("[Inline] Callback called with err=%s, data=%s", err, data and "present" or "nil")

    if err then
      return log:error("[Inline] Error during stream: %s", err)
    end

    if data then
      log:trace("[Inline] Processing data: %s", data)
      local chat_data = self.adapter.handlers.chat_output(self.adapter, data)


      if chat_data and chat_data.output and chat_data.output.reasoning then
        util.fire("ReasoningUpdated", {
          id = id,
          reasoning = chat_data.output.reasoning.content,
        })
      end

      if chat_data and chat_data.output.content then
        vim.schedule(function()
          vim.cmd.undojoin()
          self:add_buf_message(chat_data.output.content)
          if self.classification.placement == "new" and api.nvim_get_current_buf() == bufnr then
            self:buf_scroll_to_end(bufnr)
          end
        end)
      end
    end
  end

  ---Callback function to be called when the stream is done
  local done = function()
    log:trace("[Inline] Done callback called")
    log:info("[Inline] Request finished")

    self.current_request = nil
    api.nvim_buf_del_keymap(self.classification.pos.bufnr, "n", "q")
    api.nvim_clear_autocmds({ group = self.aug })

    vim.schedule(function()
      util.fire("InlineFinished", { placement = self.classification.placement })
    end)
  end

  -- Validate prompts before passing to adapter
  if not code_generation_prompts or #code_generation_prompts == 0 then
    log:error("[Inline] No valid prompts generated for code generation")
    return
  end

  -- Create proper payload object for client:request
  local payload = {
    messages = self.adapter:map_roles(code_generation_prompts),
    tools = {},
  }

  self.current_request = client
      .new({ adapter = self.adapter:map_schema_to_params(), user_args = { event = "InlineSubmit" } })
      :request(payload, { callback = cb, done = done }, {
        bufnr = bufnr,
        strategy = "inline",
        adapter = {
          name = self.adapter.name,
          formatted_name = self.adapter.formatted_name,
          model = self.adapter.schema.model.default,
        },
        id = id,
      })
end

---Write the given text to the buffer
---@param content string
---@return nil
function Inline:add_buf_message(content)
  local line = self.classification.pos.line - 1
  local col = self.classification.pos.col
  local bufnr = self.classification.pos.bufnr

  local index = 1
  while index <= #content do
    local newline = content:find("\n", index) or (#content + 1)
    local substring = content:sub(index, newline - 1)

    if #substring > 0 then
      api.nvim_buf_set_text(bufnr, line, col, line, col, { substring })
      col = col + #substring
    end

    if newline <= #content then
      api.nvim_buf_set_lines(bufnr, line + 1, line + 1, false, { "" })
      line = line + 1
      col = 0
    end

    index = newline + 1
  end

  self.classification.pos.line = line + 1
  self.classification.pos.col = col
end

---Scroll buffer to end
---@param bufnr number
---@return nil
function Inline:buf_scroll_to_end(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  local windows = vim.fn.win_findbuf(bufnr)
  for _, win in ipairs(windows) do
    api.nvim_win_set_cursor(win, { line_count, 0 })
  end
end

---Reset the inline prompt class
---@return nil
function Inline:reset()
  self.current_request = nil
  api.nvim_clear_autocmds({ group = self.aug })
end

---With the placement determined, we can now place the output from the inline prompt
---@param placement string
---@return CodeCompanion.Inline
function Inline:place(placement)
  local pos = { line = self.buffer_context.start_line, col = 0, bufnr = 0 }

  if placement == "replace" then
    self.lines = api.nvim_buf_get_lines(self.buffer_context.bufnr, 0, -1, true)
    overwrite_selection(self.buffer_context)
    local cursor_pos = api.nvim_win_get_cursor(self.buffer_context.winnr)
    pos.line = cursor_pos[1]
    pos.col = cursor_pos[2]
    pos.bufnr = self.buffer_context.bufnr
  elseif placement == "add" then
    self.lines = api.nvim_buf_get_lines(self.buffer_context.bufnr, 0, -1, true)
    api.nvim_buf_set_lines(
      self.buffer_context.bufnr,
      self.buffer_context.end_line,
      self.buffer_context.end_line,
      false,
      { "" }
    )
    pos.line = self.buffer_context.end_line + 1
    pos.col = 0
    pos.bufnr = self.buffer_context.bufnr
  elseif placement == "before" then
    self.lines = api.nvim_buf_get_lines(self.buffer_context.bufnr, 0, -1, true)
    api.nvim_buf_set_lines(
      self.buffer_context.bufnr,
      self.buffer_context.start_line - 1,
      self.buffer_context.start_line - 1,
      false,
      { "" }
    )
    self.buffer_context.start_line = self.buffer_context.start_line + 1
    pos.line = self.buffer_context.start_line - 1
    pos.col = math.max(0, self.buffer_context.start_col - 1)
    pos.bufnr = self.buffer_context.bufnr
  elseif placement == "new" then
    local bufnr
    if self.opts and type(self.opts.pre_hook) == "function" then
      -- This is only for prompts coming from the prompt library
      bufnr = self.opts.pre_hook()
      assert(type(bufnr) == "number", "No buffer number returned from the pre_hook function")
    else
      bufnr = api.nvim_create_buf(true, false)
      local ft = util.safe_filetype(self.buffer_context.filetype)
      util.set_option(bufnr, "filetype", ft)
    end

    -- TODO: This is duplicated from the chat strategy
    if config.display.inline.layout == "vertical" then
      local cmd = "vsplit"
      local window_width = config.display.chat.window.width
      local width = window_width > 1 and window_width or math.floor(vim.o.columns * window_width)
      if width ~= 0 then
        cmd = width .. cmd
      end
      vim.cmd(cmd)
    elseif config.display.inline.layout == "horizontal" then
      local cmd = "split"
      local window_height = config.display.chat.window.height
      local height = window_height > 1 and window_height or math.floor(vim.o.lines * window_height)
      if height ~= 0 then
        cmd = height .. cmd
      end
      vim.cmd(cmd)
    end

    api.nvim_win_set_buf(api.nvim_get_current_win(), bufnr)
    pos.line = 1
    pos.col = 0
    pos.bufnr = bufnr
  end

  self.classification.pos = {
    line = pos.line,
    col = pos.col,
    bufnr = pos.bufnr,
  }

  return self
end

---A user's inline prompt may need to be converted into a chat
---@return CodeCompanion.Chat
function Inline:send_to_chat()
  local prompt = self.classification.prompts

  for i = #prompt, 1, -1 do
    -- Remove all of the system prompts
    if prompt[i].opts and prompt[i].opts.tag == "system_tag" then
      table.remove(prompt, i)
    end
    -- Remove any visual selections as the chat buffer adds these from the context
    if self.buffer_context.is_visual and (prompt[i].opts and prompt[i].opts.tag == "visual") then
      table.remove(prompt, i)
    end
  end

  api.nvim_clear_autocmds({ group = self.aug })

  return require("codecompanion.strategies.chat").new({
    buffer_context = self.buffer_context,
    adapter = self.adapter,
    messages = prompt,
    auto_submit = true,
  })
end

---Send a prompt to the chat if the placement is chat
---@return CodeCompanion.Chat
function Inline:to_chat()
  local prompt = self.prompts
  log:info("[Inline] Sending to chat")

  for i = #prompt, 1, -1 do
    -- Remove all of the system prompts
    if prompt[i].opts and prompt[i].opts.tag == "system_tag" then
      table.remove(prompt, i)
    end
    -- Remove any visual selections as the chat buffer adds these from the context
    if self.buffer_context.is_visual and (prompt[i].opts and prompt[i].opts.tag == "visual") then
      table.remove(prompt, i)
    end
  end

  -- Turn streaming back on
  self.adapter.opts.stream = _streaming

  return require("codecompanion.strategies.chat").new({
    adapter = self.adapter,
    auto_submit = true,
    buffer_context = self.buffer_context,
    messages = prompt,
  })
end

---Start the diff process
---@return nil
function Inline:start_diff()
  if config.display.diff.enabled == false then
    return
  end

  if self.classification.placement == "new" then
    return
  end

  keymaps
      .new({
        bufnr = self.buffer_context.bufnr,
        callbacks = require("codecompanion.strategies.inline.keymaps"),
        data = self,
        keymaps = config.strategies.inline.keymaps,
      })
      :set()

  local provider = config.display.diff.provider
  local ok, diff = pcall(require, "codecompanion.providers.diff." .. provider)
  if not ok then
    return log:error("[Inline] Diff provider not found: %s", provider)
  end

  ---@type CodeCompanion.Diff
  self.diff = diff.new({
    bufnr = self.buffer_context.bufnr,
    cursor_pos = self.buffer_context.cursor_pos,
    filetype = self.buffer_context.filetype,
    contents = self.lines,
    winnr = self.buffer_context.winnr,
  })
end

return Inline
