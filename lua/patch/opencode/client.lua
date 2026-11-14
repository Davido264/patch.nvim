local M = {}
local process = require("patch.opencode.process")

local DEFAULT_SYSTEM_PROMPT = "You are an inline code editor. Given the selection and an instruction, reply with only the replacement code for the SELECTED region. No commentary, no explanations, no markdown fences.\n"
local system_prompt = DEFAULT_SYSTEM_PROMPT
local configured_model
local session_model
local primary_model

---@param callback function
---@param value any
---@param err string|nil
local function schedule_complete(callback, value, err)
  vim.schedule(function()
    callback(value, err)
  end)
end

---@class PatchClientOptions
---@field system_prompt? string
---@field model? string

---@param opts? PatchClientOptions
function M.setup(opts)
  opts = opts or {}
  system_prompt = opts.system_prompt or DEFAULT_SYSTEM_PROMPT
  configured_model = opts.model and vim.trim(opts.model) or nil
  configured_model = configured_model ~= "" and configured_model or nil
  session_model = nil
  primary_model = nil
end

---@class PatchModel
---@field id string
---@field name string
---@field provider string

---@class PatchRequest
---@field state "pending"|"cancelled"|"completed"
---@field process? PatchProcess
---@field session_id? string
---@field on_complete fun(res: string|nil, err: string|nil)

--- Delete the opencode session a request created, so patches do not clutter session history.
---
---@param session_id string|nil
local function delete_session(session_id)
  if session_id then
    process.exec({ "session", "delete", session_id }, nil, function() end)
  end
end

--- Abort an opencode request.
---
---@param request PatchRequest
---@return boolean cancelled
function M.cancel(request)
  if request.state ~= "pending" then
    return false
  end

  request.state = "cancelled"

  if request.process then
    request.process:kill()
    request.process = nil
  end

  delete_session(request.session_id)

  vim.schedule(function()
    request.on_complete(nil, "cancelled")
  end)

  return true
end

--- Parse `opencode models` output, one `provider/model` selector per line.
---
---@param stdout string
---@return PatchModel[] models
local function parse_models(stdout)
  local models = {}

  for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
    local provider, id = vim.trim(line):match("^([^/%s]+)/(%S+)$")
    if provider then
      table.insert(models, { provider = provider, id = id, name = id })
    end
  end

  return models
end

--- Retrieve the models available to opencode.
---
---@param on_complete fun(models: PatchModel[]|nil, err: string|nil)
function M.get_available_models(on_complete)
  process.exec({ "models" }, process.env(system_prompt), function(stdout, err)
    if err then
      schedule_complete(on_complete, nil, err)
      return
    end

    schedule_complete(on_complete, parse_models(stdout), nil)
  end)
end

--- Use a model for the remainder of the current Neovim session.
---
---@param model PatchModel
---@return string selector
function M.select_model(model)
  session_model = model.provider .. "/" .. model.id
  return session_model
end

--- Resolve the effective model selector used by Patch.
---
--- Completes with nil and no error when opencode has no configured default model,
--- in which case opencode chooses one itself.
---
---@param on_complete fun(model: string|nil, err: string|nil)
function M.resolve_model(on_complete)
  local override = session_model or configured_model
  if override then
    schedule_complete(on_complete, override, nil)
    return
  end

  if primary_model then
    schedule_complete(on_complete, primary_model, nil)
    return
  end

  process.exec({ "debug", "config" }, process.env(system_prompt), function(stdout, err)
    if err then
      schedule_complete(on_complete, nil, err)
      return
    end

    local decoded, config = pcall(vim.json.decode, stdout)
    if not decoded or type(config) ~= "table" then
      schedule_complete(on_complete, nil, "opencode returned an invalid configuration")
      return
    end

    if type(config.model) == "string" and config.model ~= "" then
      primary_model = config.model
    end

    schedule_complete(on_complete, primary_model, nil)
  end)
end

--- Describe an opencode error event payload.
---
---@param err any
---@return string message
local function format_event_error(err)
  if type(err) ~= "table" then
    return "opencode request failed"
  end

  if type(err.data) == "table" and type(err.data.message) == "string" and err.data.message ~= "" then
    return err.data.message
  end

  if type(err.message) == "string" and err.message ~= "" then
    return err.message
  end

  if type(err.name) == "string" and err.name ~= "" then
    return err.name
  end

  return "opencode request failed"
end

--- Send a prompt to opencode and deliver its final assistant text.
---
--- @param message string prompt containing the selection and surrounding context
--- @param on_complete fun(res: string|nil, err: string|nil)
--- @return PatchRequest request
function M.request(message, on_complete)
  local request = {
    state = "pending",
    process = nil,
    session_id = nil,
    on_complete = on_complete,
  }

  -- Text parts keyed by assistant message, so only the final message is used.
  local texts = {}
  local last_message_id
  local finished = false
  local event_error

  --- Complete this request exactly once on Neovim's main event loop.
  ---
  --- @param res string|nil
  --- @param err string|nil
  local function complete(res, err)
    if request.state ~= "pending" then
      return
    end

    request.state = "completed"
    request.process = nil
    delete_session(request.session_id)

    vim.schedule(function()
      request.on_complete(res, err)
    end)
  end

  --- Handle a decoded record from opencode's JSON event stream.
  ---
  --- @param record table
  local function handle_record(record)
    if type(record) ~= "table" then
      return
    end

    if type(record.sessionID) == "string" then
      request.session_id = request.session_id or record.sessionID
    end

    local part = type(record.part) == "table" and record.part or {}

    if record.type == "text" and type(part.text) == "string" then
      local message_id = part.messageID or ""
      if message_id ~= last_message_id then
        last_message_id = message_id
        texts[message_id] = texts[message_id] or {}
      end
      table.insert(texts[message_id], part.text)
    elseif record.type == "step_finish" then
      if part.reason == "tool-calls" then
        -- Text before a tool call is narration; judge only the final step.
        last_message_id = nil
      else
        finished = true
      end
    elseif record.type == "error" then
      event_error = format_event_error(record.error)
    end
  end

  --- Judge the collected events once opencode exits.
  ---
  --- @param result vim.SystemCompleted
  local function handle_exit(result)
    if request.state ~= "pending" then
      return
    end

    if event_error then
      complete(nil, event_error)
    elseif result.code ~= 0 then
      complete(nil, process.format_exit_error(result))
    elseif last_message_id then
      complete(table.concat(texts[last_message_id], "\n"), nil)
    elseif finished then
      -- Empty successful output is a valid deletion replacement.
      complete("", nil)
    else
      complete(nil, "opencode returned no response")
    end
  end

  local args = {}
  local model = session_model or configured_model

  if model then
    table.insert(args, "--model")
    table.insert(args, model)
  end

  local handle, start_error = process.run(args, message, process.env(system_prompt), {
    on_record = handle_record,
    on_error = function(err)
      complete(nil, err)
    end,
    on_exit = handle_exit,
  })

  if not handle then
    complete(nil, tostring(start_error))
    return request
  end

  request.process = handle
  return request
end

return M
