--[[
The Inline Interaction - This is where code is applied directly to a Neovim buffer
--]]

---@class CodeCompanion.Inline
---@field id number The ID of the inline prompt
---@field adapter CodeCompanion.HTTPAdapter The adapter to use for the inline prompt
---@field aug number The ID for the autocmd group
---@field buffer_context CodeCompanion.BufferContext
---@field bufnr number The buffer number to apply the inline edits to
---@field chat_context? table The content from the last opened chat buffer
---@field classification CodeCompanion.Inline.Classification Where to place the generated code in Neovim
---@field current_request? table The current request that's being processed
---@field diff_ui? CodeCompanion.DiffUI The diff UI instance
---@field lines table Lines in the buffer before the inline changes
---@field opts table
---@field original_content? string[] The original buffer content before LLM changes
---@field prompts table The prompts to send to the LLM
---@field streaming_before_request? boolean The adapter streaming state before inline changes it

---@class CodeCompanion.InlineArgs
---@field adapter? CodeCompanion.HTTPAdapter
---@field buffer_context? CodeCompanion.BufferContext
---@field chat_context? table Messages from a chat buffer
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
local editor_context = require("codecompanion.interactions.inline.editor_context")
local keymaps = require("codecompanion.utils.keymaps")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local api = vim.api
local fmt = string.format

local user_role = config.constants.USER_ROLE

local CONSTANTS = {
  AUTOCMD_GROUP = "codecompanion.inline",
  STATUS_ERROR = "error",
  STATUS_SUCCESS = "success",

  SYSTEM_PROMPT = [[You are a knowledgeable developer working in the Neovim text editor. You write %s code on behalf of a user, directly into their active Neovim buffer.

Your task:
- Carefully follow the user's prompt (enclosed in <prompt></prompt> tags).
- Use any provided code context to inform your response.
- Output only valid JSON as specified below.

Response schema:
%s

If you cannot answer, respond with a single-sentence reason in %s, enclosed in error tags:
{
  "error": "Reason for not being able to answer the prompt"
}

Rules:
- **CRITICAL**: ENSURE YOU PRESERVE THE EXACT INDENTATION (TABS/SPACES) as it appears in the provided code.
- Validate all code carefully.
- Adhere strictly to the JSON schema.
- Do not include markdown, code fences, or explanations.
- Include comments if appropriate for the language.
- Do not output anything except the JSON response]],

  RESPONSE_WITHOUT_PLACEMENT = [[Return your code in valid JSON matching this schema:

{
  "type": "object",
  "required": ["code", "language"],
  "properties": {
    "code": { "type": "string" },
    "language": { "type": "string" }
  },
  "additionalProperties": false
}

Example:
{
  "code": "print('Hello World')",
  "language": "python"
}
]],

  RESPONSE_WITH_PLACEMENT = [[Return your code and placement in valid JSON matching this schema:

{
  "type": "object",
  "required": ["placement"],
  "properties": {
    "code": { "type": "string" },
    "language": { "type": "string" },
    "placement": {
      "type": "string",
      "enum": ["replace", "add", "before", "new", "chat"],
      "description": "Where to place the code in Neovim."
    }
  },
  "additionalProperties": false
}

Placement options:
- "replace": Replace the user's current visual selection in the buffer with your code.
- "add": Insert your code after the user's current cursor position in the buffer.
- "before": Insert your code before the user's current cursor position in the buffer.
- "new": Create a new Neovim buffer and insert your code there.
- "chat": The prompt is conversational, informational, or otherwise not suitable for direct code insertion; respond as a message in the chat buffer instead.

Example:

{
  "code": "print('Hello World')",
  "language": "python",
  "placement": "replace"
}

If placement is "chat", omit the "code" and "language" fields:

{
  "placement": "chat"
}]],

  PLACEMENT_PROMPT = [[I would like you to assess a prompt which has been made from within the Neovim text editor. Based on this prompt, determine where the output from this prompt should be placed. I am calling this determination the "<method>".

The available methods are:

1. `replace` the current selection
2. `add` after the current cursor position
3. `before` before the current cursor position
4. `new` in a new buffer/file
5. `chat` in a chat buffer which the user can then interact with

Examples:

- "Can you refactor/fix/amend this code?" should be `replace`
- "Can you create a method/function that does XYZ" should be `add`
- "Can you add a docstring to this function?" should be `before`
- "Can you create a method/function for XYZ and put it in a new buffer?" should be `new`
- "Can you write unit tests for this code?" should be `new`
- "Why is Neovim so popular?" or "What does this code do?" should be `chat`
- "Write some comments for this code." should be `replace`

Respond with only one tag: `<replace>`, `<add>`, `<before>`, `<new>`, `<chat>`, or `<error>`.]],

  CODE_ONLY_PROMPT = [[The following response must contain ONLY raw text that can be directly written to a Neovim buffer:

1. No Markdown formatting or backticks
2. No explanations or prose
3. Use proper indentation and spacing for the target buffer
4. Include comments only when the user asked for code that needs them
5. Use actual line breaks
6. Preserve all whitespace
7. Only include the requested content
8. Do not echo the full file unless the prompt requires it

If you cannot provide clean buffer-ready text, reply with `<error>`]],
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

  -- NOTE: Ensure that focus is set to the correct buffer in case the user has navigated away
  api.nvim_set_current_buf(context.bufnr)
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

---@param adapter CodeCompanion.HTTPAdapter
---@param data table|string
---@param tools? table
---@return {status: string, output: table}|nil
local function parse_chat_output(adapter, data, tools)
  local result = adapters.call_handler(adapter, "parse_chat", data, tools or {})
  local parse_meta = adapters.get_handler(adapter, "parse_meta")

  if result and result.extra and type(parse_meta) == "function" then
    result = parse_meta(adapter, result)
  end

  return result
end

---@param bufnr number
---@return string[]
local function get_buffer_lines(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  return api.nvim_buf_get_lines(bufnr, 0, -1, true)
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
    lines = {},
    opts = args.opts or {},
    original_content = nil,
    prompts = vim.deepcopy(args.prompts),
    streaming_before_request = nil,
  }, { __index = Inline })

  self:set_adapter(args.adapter or config.interactions.inline.adapter)
  if not self.adapter then
    return log:error("[Inline] No adapter found")
  end
  if self.adapter.type ~= "http" then
    return log:warn("Only HTTP adapters are supported for inline interactions")
  end

  -- Check if the user has manually overridden the adapter
  if vim.g.codecompanion_adapter and self.adapter.name ~= vim.g.codecompanion_adapter then
    self:set_adapter(config.adapters[vim.g.codecompanion_adapter])
  end

  if self.opts and self.opts.placement then
    self.classification.placement = self.opts.placement
  end

  return self
end

---Set the adapter for the inline prompt
---@param adapter CodeCompanion.HTTPAdapter|string|function
---@return nil
function Inline:set_adapter(adapter)
  if not self.adapter or not adapters.resolved(adapter) then
    self.adapter = adapters.resolve(adapter)
  end
  if self.adapter then
    self.adapter.opts = self.adapter.opts or {}
  end
end

---Remember the adapter streaming state before inline temporarily changes it
---@return nil
function Inline:capture_streaming_state()
  if self.streaming_before_request == nil and self.adapter and self.adapter.opts then
    self.streaming_before_request = self.adapter.opts.stream
  end
end

---Restore the adapter streaming state after inline has finished
---@return nil
function Inline:restore_streaming_state()
  if self.streaming_before_request ~= nil and self.adapter and self.adapter.opts then
    self.adapter.opts.stream = self.streaming_before_request
    self.streaming_before_request = nil
  end
end

---Parse special syntax from user prompt (adapters and maintain editor context)
---@param prompt string
---@return string The cleaned prompt
function Inline:parse_special_syntax(prompt)
  local adapter_pattern = "adapter=([%w_]+)"
  local adapter_match = prompt:match(adapter_pattern)

  local config_adapters = vim.tbl_deep_extend("force", {}, config.adapters.acp, config.adapters.http)
  if adapter_match then
    if config_adapters[adapter_match] then
      self:set_adapter(adapter_match)
      prompt = prompt:gsub(adapter_pattern, "", 1) -- Remove only the first occurrence
    else
      utils.notify("Adapter not found: " .. adapter_match, vim.log.levels.ERROR)
    end
  else
    -- Handle legacy first-word adapter detection for backward compatibility
    local split = vim.split(prompt, " ")
    local first_word = split[1]
    if config_adapters[first_word] then
      self:set_adapter(first_word)
      table.remove(split, 1)
      prompt = table.concat(split, " ")
    end
  end

  return vim.trim(prompt)
end

---Set keymaps for the inline interaction
---@param bufnr? number
---@param opts? table
---@return nil
function Inline:set_keymaps(bufnr, opts)
  keymaps
    .new({
      bufnr = bufnr,
      callbacks = require("codecompanion.interactions.inline.keymaps"),
      data = self,
      keymaps = config.interactions.inline.keymaps,
    })
    :set(opts)
end

---Submit immediately when placement is known, otherwise classify first
---@param prompts table
---@return nil
function Inline:dispatch_prompts(prompts)
  self.prompts = prompts

  if self.classification.placement then
    return self:submit(prompts)
  end

  return self:classify(prompts)
end

---Build the payload used to classify where inline output should go
---@param prompts table
---@return table
function Inline:build_classification_payload(prompts)
  local user_prompts = vim
    .iter(prompts)
    :filter(function(prompt)
      return prompt.role == config.constants.USER_ROLE
    end)
    :map(function(prompt)
      return prompt.content
    end)
    :totable()

  return {
    messages = self.adapter:map_roles({
      { role = config.constants.SYSTEM_ROLE, content = CONSTANTS.PLACEMENT_PROMPT },
      { role = config.constants.USER_ROLE, content = table.concat(user_prompts, "\n") },
    }),
    tools = {},
  }
end

---Handle the completed placement classification
---@param placement string
---@param prompts table
---@return nil
function Inline:finish_classification(placement, prompts)
  local parsed = placement:match("<(.-)>")
  if not parsed or parsed == "error" then
    return log:error("[Inline] Could not determine where to place the output from the prompt")
  end

  self.classification.placement = parsed
  if parsed == "chat" then
    return self:to_chat()
  end

  return self:submit(prompts)
end

---Ask the LLM where the inline output should be placed
---@param prompts table
---@return nil
function Inline:classify(prompts)
  self:capture_streaming_state()
  self.adapter.opts.stream = true

  local placement = ""
  local payload = self:build_classification_payload(prompts)

  self.current_request = client
    .new({ adapter = self.adapter:map_schema_to_params(), user_args = { event = "InlineClassify" } })
    :request(payload, {
      callback = function(err, data)
        if err then
          return log:error("[Inline] Error during classification: %s", err.message or err)
        end

        local result = parse_chat_output(self.adapter, data)
        local text = result and result.output and result.output.content
        if type(text) == "string" then
          placement = placement .. text
        end
      end,
      done = function()
        return self:finish_classification(placement, prompts)
      end,
    }, {
      bufnr = self.buffer_context.bufnr,
      interaction = "inline",
      strategy = "inline",
    })
end

---Prompt the LLM
---@param user_prompt? string The prompt supplied by the user
---@return nil
function Inline:prompt(user_prompt)
  log:trace("[Inline] Starting")

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
    -- Parse adapters and editor context from the entire prompt
    user_prompt = self:parse_special_syntax(user_prompt)

    -- Check for any editor context
    local ec = editor_context.new({ inline = self, prompt = user_prompt })
    local found = ec:find():replace():output()
    if found then
      for _, item in ipairs(found) do
        add_prompt(item, user_role, { visible = false })
      end
      user_prompt = ec.prompt
    end

    -- Add the user's prompt
    add_prompt("<prompt>" .. user_prompt .. "</prompt>")
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
        return self:dispatch_prompts(vim.deepcopy(prompts))
      end)
    end)
  else
    return self:dispatch_prompts(vim.deepcopy(prompts))
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
        _meta = { tag = "visual" },
        opts = {
          visible = false,
        },
      })
    end
  end

  return prompts
end

---Stop the current request
---@return nil
function Inline:stop()
  if self.current_request then
    self.current_request.cancel()
    self.current_request = nil
    adapters.call_handler(self.adapter, "on_exit")
    self:refresh_diff({ status = "final" })
    self:reset()
  end
end

---Build prompts for streaming code generation
---@param prompts table
---@return table
function Inline:build_code_generation_prompts(prompts)
  local output = {
    {
      role = config.constants.SYSTEM_ROLE,
      content = CONSTANTS.CODE_ONLY_PROMPT,
      opts = { tag = "system_tag", visible = false },
    },
  }

  for i = #self.chat_context, 1, -1 do
    local message = self.chat_context[i]
    if message.role == config.constants.LLM_ROLE or message.role == config.constants.USER_ROLE then
      table.insert(output, {
        role = message.role,
        content = message.content,
        opts = { tag = "chat_context", visible = false },
      })
    end
  end

  vim.list_extend(output, prompts)
  return output
end

---Capture the buffer before streaming edits are applied
---@param placement string
---@return nil
function Inline:capture_original_content(placement)
  if placement == "new" then
    self.original_content = nil
    return
  end

  local ok, content = pcall(get_buffer_lines, self.buffer_context.bufnr)
  if ok then
    self.original_content = content
  else
    log:error("[Inline] Unable to capture original buffer content for diff: %s", content)
    self.original_content = nil
  end
end

---Start live diff rendering when the current buffer should show streamed changes
---@param placement string
---@return nil
function Inline:start_live_diff(placement)
  if not config.display.diff.enabled or placement == "new" or not self.original_content then
    return
  end

  self:start_diff({
    original_content = self.original_content,
    new_content = get_buffer_lines(self.classification.pos.bufnr),
    placement = placement,
    live = true,
  })
end

---Handle a streamed code-generation chunk
---@param data table|string
---@param opts { request_id: number, placement: string, bufnr: number }
---@return nil
function Inline:handle_stream_chunk(data, opts)
  local result = parse_chat_output(self.adapter, data)
  if result and result.output and result.output.reasoning and result.output.reasoning.content then
    utils.fire("ReasoningUpdated", { id = opts.request_id, reasoning = result.output.reasoning.content })
  end

  local text = result and result.output and result.output.content
  if type(text) ~= "string" or text == "" then
    return
  end

  vim.schedule(function()
    pcall(vim.cmd.undojoin)
    self:add_buf_message(text)
    if opts.placement == "new" and api.nvim_get_current_buf() == opts.bufnr then
      self:buf_scroll_to_end(opts.bufnr)
    end
  end)
end

---Finish a streaming inline request
---@param placement string
---@return nil
function Inline:finish_stream(placement)
  self.current_request = nil
  self:refresh_diff({ status = "final" })
  self:reset()
  utils.fire("InlineFinished", { placement = placement })
end

---Submit the prompts to the LLM to process
---@param prompt table The prompts to send to the LLM
---@return nil
function Inline:submit(prompt)
  local placement = self.classification.placement
  if not placement or placement == "" then
    return log:error("[Inline] No placement determined before submission")
  end

  self.prompts = prompt or self.prompts
  self:capture_streaming_state()
  self.adapter.opts.stream = true
  self:capture_original_content(placement)
  self:place(placement)
  self:start_live_diff(placement)

  local bufnr = self.classification.pos.bufnr
  self:set_keymaps(bufnr, { keymaps = { "stop" } })

  local request_id = math.random(10000000)
  local code_generation_prompts = self:build_code_generation_prompts(self.prompts)
  local stream_opts = { request_id = request_id, placement = placement, bufnr = bufnr }

  self.current_request = client
    .new({ adapter = self.adapter:map_schema_to_params(), user_args = { event = "InlineStarted" } })
    :request({ messages = self.adapter:map_roles(code_generation_prompts), tools = {} }, {
      ---@param err string
      ---@param data table
      callback = function(err, data)
        if err then
          local msg = type(err) == "table" and err.message or err
          return log:error("[Inline] Request failed with error %s", msg)
        end

        return self:handle_stream_chunk(data, stream_opts)
      end,
      done = function()
        return self:finish_stream(placement)
      end,
    }, {
      bufnr = bufnr,
      buffer_context = self.buffer_context or {},
      interaction = "inline",
      strategy = "inline",
      id = request_id,
    })
end

---Once the request has been completed, we can process the output
---@param output string The output from the LLM
---@return nil
function Inline:done(output)
  utils.fire("InlineFinished")

  local adapter_name = self.adapter.formatted_name

  if not output then
    log:error("[%s] No output received", adapter_name)
    return self:reset()
  end

  local json = self:parse_output(output)
  if not json then
    -- Logging is done in parse_output
    return self:reset()
  end
  if json and json.error then
    log:error("[%s] %s", adapter_name, json.error)
    return self:reset()
  end

  -- There should always be a placement whether that's from the LLM or the user's prompt
  local placement = json and json.placement or self.classification.placement
  if not placement then
    log:error("[%s] No placement returned", adapter_name)
    return self:reset()
  end
  placement = string.lower(placement)

  -- An LLM won't send a code response if it deems the placement should go to a chat buffer
  if json and not json.code and placement ~= "chat" then
    log:error("[%s] Returned no code", adapter_name)
    return self:reset()
  end

  if placement == "chat" then
    self:reset()
    return self:to_chat()
  end

  vim.schedule(function()
    if not config.display.diff.enabled or placement == "new" then
      self:place(placement)
      pcall(vim.cmd.undojoin)
      self:output(json.code)
      return self:reset()
    end

    local original_content = api.nvim_buf_get_lines(self.buffer_context.bufnr, 0, -1, true)
    local new_content = self:get_new_content(original_content, json.code, placement)

    self:start_diff({
      original_content = original_content,
      new_content = new_content,
      placement = placement,
      code = json.code,
    })
  end)
end

---Reset the inline prompt class
---@return nil
function Inline:reset()
  self:restore_streaming_state()
  self.current_request = nil
  api.nvim_clear_autocmds({ group = self.aug })
end

---Compute what the buffer content would look like after applying the LLM output
---@param original string[] The original buffer lines
---@param code string The code from the LLM
---@param placement string The placement type
---@return string[]
function Inline:get_new_content(original, code, placement)
  local new_lines = vim.split(code, "\n")
  local result = vim.deepcopy(original)
  local ctx = self.buffer_context

  if placement == "replace" then
    -- Replace the visual selection with the new code
    local before = vim.list_slice(result, 1, ctx.start_line - 1)
    local after = vim.list_slice(result, ctx.end_line + 1)

    -- Handle partial line replacement
    local start_prefix = ""
    local end_suffix = ""
    if ctx.start_col > 0 and result[ctx.start_line] then
      start_prefix = result[ctx.start_line]:sub(1, ctx.start_col - 1)
    end
    if result[ctx.end_line] then
      end_suffix = result[ctx.end_line]:sub(ctx.end_col + 1)
    end

    -- Combine prefix with first line and suffix with last line
    if #new_lines > 0 then
      new_lines[1] = start_prefix .. new_lines[1]
      new_lines[#new_lines] = new_lines[#new_lines] .. end_suffix
    else
      new_lines = { start_prefix .. end_suffix }
    end

    result = vim.list_extend(vim.list_extend(before, new_lines), after)
  elseif placement == "add" then
    -- Insert after the end line
    local before = vim.list_slice(result, 1, ctx.end_line)
    local after = vim.list_slice(result, ctx.end_line + 1)
    result = vim.list_extend(vim.list_extend(before, new_lines), after)
  elseif placement == "before" then
    -- Insert before the start line
    local before = vim.list_slice(result, 1, ctx.start_line - 1)
    local after = vim.list_slice(result, ctx.start_line)
    result = vim.list_extend(vim.list_extend(before, new_lines), after)
  end

  return result
end

---Extract a code block from markdown text
---@param content string
---@return string|nil
local function parse_with_treesitter(content)
  local parser = vim.treesitter.get_string_parser(content, "markdown")
  local syntax_tree = parser:parse()
  local root = syntax_tree[1]:root()

  local query = vim.treesitter.query.parse("markdown", [[(code_fence_content) @code]])

  local code = {}
  for id, node in query:iter_captures(root, content, 0, -1) do
    if query.captures[id] == "code" then
      local node_text = vim.treesitter.get_node_text(node, content)
      -- Deepseek protection!!
      node_text = node_text:gsub("```json", "")
      node_text = node_text:gsub("```", "")

      table.insert(code, node_text)
    end
  end

  return vim.tbl_count(code) > 0 and table.concat(code, "") or nil
end

---@param output string
---@return table|nil
function Inline:parse_output(output)
  -- Try parsing as plain JSON first
  output = output:gsub("^```json", ""):gsub("```$", "")
  local ok, json = pcall(vim.json.decode, output)
  if ok then
    return json
  end

  -- Fall back to Tree-sitter parsing
  local markdown_code = parse_with_treesitter(output)
  if markdown_code then
    ok, json = pcall(vim.json.decode, markdown_code)
    if ok then
      return json
    end
  end

  return log:error("[Inline] Failed to parse the response")
end

---Write the output from the LLM to the buffer
---@param output string
---@return nil
function Inline:output(output)
  local line = self.classification.pos.line - 1
  local col = self.classification.pos.col
  local bufnr = self.classification.pos.bufnr

  local lines = vim.split(output, "\n")

  -- If there's only one line, use buf_set_text
  if #lines == 1 then
    api.nvim_buf_set_text(bufnr, line, col, line, col, { output })
    self.classification.pos.line = line + 1
    self.classification.pos.col = col + #output
    return
  end

  -- For multiple lines:
  -- 1. Handle first line
  api.nvim_buf_set_text(bufnr, line, col, line, col, { lines[1] })

  -- 2. Add remaining lines
  api.nvim_buf_set_lines(bufnr, line + 1, line + 1, false, vim.list_slice(lines, 2))
end

---Write streamed text to the buffer and keep the insertion point updated
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
  self:refresh_diff({ status = "streaming" })
end

---Scroll every window displaying a buffer to the end
---@param bufnr number
---@return nil
function Inline:buf_scroll_to_end(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    pcall(api.nvim_win_set_cursor, win, { line_count, 0 })
  end
end

---Refresh an active live diff
---@param opts? table
---@return nil
function Inline:refresh_diff(opts)
  if not self.diff_ui or type(self.diff_ui.refresh) ~= "function" then
    return
  end

  local ok, err = pcall(self.diff_ui.refresh, self.diff_ui, opts or {})
  if not ok then
    log:error("[Inline] Failed to refresh diff: %s", err)
  end
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
      local ft = utils.safe_filetype(self.buffer_context.filetype)
      utils.set_option(bufnr, "filetype", ft)
    end

    -- TODO: This is duplicated from the chat interaction
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
    elseif config.display.inline.layout == "tab" then
      vim.cmd("tabnew")
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

---Send a prompt to the chat if the placement is chat
---@return CodeCompanion.Chat
function Inline:to_chat()
  local prompt = self.prompts

  for i = #prompt, 1, -1 do
    -- Remove all of the system prompts
    if prompt[i]._meta and prompt[i]._meta.tag == "system_tag" then
      table.remove(prompt, i)
    end
    -- Remove any visual selections as the chat buffer adds these from the context
    if self.buffer_context.is_visual and (prompt[i]._meta and prompt[i]._meta.tag == "visual") then
      table.remove(prompt, i)
    end
  end

  self:restore_streaming_state()

  local chat_opts = {
    adapter = self.adapter,
    auto_submit = true,
    buffer_context = self.buffer_context,
    messages = prompt,
  }

  -- Add rules to the chat buffer
  local rules_cb = require("codecompanion.interactions.shared.rules.helpers").add_callbacks(chat_opts)
  if rules_cb then
    chat_opts.callbacks = rules_cb
  end

  return require("codecompanion.interactions.chat").new(chat_opts)
end

---Build the banner text for the inline diff
---@return string
function Inline:build_diff_banner()
  local keys = config.interactions.shared.keymaps
  return fmt(
    "%s Always Accept | %s Accept | %s Reject",
    keys.always_accept.modes.n,
    keys.accept_change.modes.n,
    keys.reject_change.modes.n
  )
end

---Start the diff process
---@param args { original_content: string[], new_content: string[], placement: string, code?: string, live?: boolean }
---@return nil
function Inline:start_diff(args)
  log:debug("[Inline] Starting diff")

  local approvals = require("codecompanion.interactions.chat.tools.approvals")

  -- If the buffer has been added to the auto approval list, skip the diff
  if approvals:is_approved(self.bufnr, { tool_name = "inline" }) then
    if args.code then
      self:place(args.placement)
      pcall(vim.cmd.undojoin)
      self:output(args.code)
      return self:reset()
    end
    return
  end

  -- Store original content for potential restoration on reject
  self.original_content = args.original_content

  -- Show the inline diff - this will transform the buffer from original to new
  local helpers = require("codecompanion.helpers")
  self.diff_ui = helpers.show_diff({
    bufnr = self.buffer_context.bufnr,
    from_lines = args.original_content,
    to_lines = args.new_content,
    diff_id = self.id,
    ft = self.buffer_context.filetype,
    inline = true,
    banner = self:build_diff_banner(),
    live = args.live,
    keymaps = {
      on_accept = function()
        self:on_diff_accepted()
      end,
      on_reject = function()
        self:on_diff_rejected()
      end,
      on_always_accept = function()
        approvals:always(self.buffer_context.bufnr, { tool_name = "inline" })
      end,
    },
  })
end

---Handle diff accepted event
---@return nil
function Inline:on_diff_accepted()
  log:trace("[Inline] Diff accepted for id=%s", self.id)
  self.original_content = nil
  self.diff_ui = nil
  self:reset()
end

---Handle diff rejected event
---@return nil
function Inline:on_diff_rejected()
  log:trace("[Inline] Diff rejected for id=%s, restoring original content", self.id)

  if self.original_content and api.nvim_buf_is_valid(self.buffer_context.bufnr) then
    api.nvim_buf_set_lines(self.buffer_context.bufnr, 0, -1, false, self.original_content)
  end

  self.original_content = nil
  self.diff_ui = nil
  self:reset()
end

return Inline
