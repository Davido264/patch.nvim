local M = {}
local service = require("patch.opencode.service")

local DEFAULT_SYSTEM_PROMPT = "You are an inline code editor. Given the selection and an instruction, reply with only the replacement code for the SELECTED region. No commentary, no explanations, no markdown fences."
local system_prompt = DEFAULT_SYSTEM_PROMPT
local configured_model
local session_model

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
end

---@class PatchModel
---@field id string
---@field name string
---@field provider string

---@class PatchModelRef
---@field providerID string
---@field id string
---@field variant? string

---@class PatchRequest
---@field state "pending"|"cancelled"|"completed"
---@field service_request? PatchServiceRequest
---@field session_id? string
---@field on_complete fun(res: string|nil, err: string|nil)

--- Agent the patch session runs as. Its tools are restricted by PERMISSIONS below.
M.AGENT = "build"

--- Key of the session instruction entry that carries the system prompt.
M.INSTRUCTIONS_KEY = "patch.nvim"

--- How many times to wait for the session to become idle before giving up.
local MAX_WAITS = 10

--- Deny every tool that changes files, runs commands, or asks the user. Web fetch and
--- search stay allowed so the model can look things up.
---
--- `read` stays allowed apart from env files: opencode's free models reject requests
--- whose tool set denies `read`, and an env-file read would otherwise prompt for
--- permission and stall the request.
local PERMISSIONS = {}
for _, action in ipairs({
  "edit", "bash", "task", "question", "skill", "browser",
  "external_directory", "todowrite",
}) do
  table.insert(PERMISSIONS, { action = action, resource = "*", effect = "deny" })
end
table.insert(PERMISSIONS, { action = "read", resource = "*.env", effect = "deny" })
table.insert(PERMISSIONS, { action = "read", resource = "*.env.*", effect = "deny" })
M.PERMISSIONS = PERMISSIONS

--- Delete a session created for a request, so patches do not clutter session history.
---
---@param session_id string|nil
---@param interrupt boolean stop a generation that is still running first
local function discard_session(session_id, interrupt)
  if not session_id then
    return
  end

  local path = "/api/session/" .. session_id
  local function delete()
    service.request("DELETE", path, nil, function() end)
  end

  if interrupt then
    service.request("POST", path .. "/interrupt", nil, delete)
  else
    delete()
  end
end

--- Parse a `provider/model` or `provider/model#variant` selector.
---
---@param selector string
---@return PatchModelRef|nil ref
function M.parse_selector(selector)
  local provider, rest = selector:match("^([^/%s]+)/(%S+)$")
  if not provider then
    return nil
  end

  local id, variant = rest:match("^(.-)#(.+)$")
  return { providerID = provider, id = id or rest, variant = variant }
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

  if request.service_request then
    request.service_request:cancel()
    request.service_request = nil
  end

  discard_session(request.session_id, true)

  vim.schedule(function()
    request.on_complete(nil, "cancelled")
  end)

  return true
end

--- Retrieve the models available to opencode.
---
---@param on_complete fun(models: PatchModel[]|nil, err: string|nil)
function M.get_available_models(on_complete)
  service.request("GET", "/api/model", nil, function(response, err)
    if err then
      on_complete(nil, err)
      return
    end

    if type(response) ~= "table" or type(response.data) ~= "table" then
      on_complete(nil, "opencode returned an invalid model list")
      return
    end

    local models = {}
    for _, model in ipairs(response.data) do
      if type(model) == "table" and type(model.providerID) == "string" and type(model.id) == "string"
          and model.enabled ~= false then
        table.insert(models, {
          provider = model.providerID,
          id = model.id,
          name = type(model.name) == "string" and model.name or model.id,
        })
      end
    end

    on_complete(models, nil)
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
--- Completes with nil and no error when opencode has no default model.
---
---@param on_complete fun(model: string|nil, err: string|nil)
function M.resolve_model(on_complete)
  local override = session_model or configured_model
  if override then
    schedule_complete(on_complete, override, nil)
    return
  end

  service.request("GET", "/api/model/default", nil, function(response, err)
    if err then
      on_complete(nil, err)
      return
    end

    local model = type(response) == "table" and response.data or nil
    if type(model) == "table" and type(model.providerID) == "string" and type(model.id) == "string" then
      on_complete(model.providerID .. "/" .. model.id, nil)
    else
      on_complete(nil, nil)
    end
  end)
end

--- Describe an opencode error payload.
---
---@param err any
---@return string message
local function format_error(err)
  if type(err) == "table" and type(err.message) == "string" and err.message ~= "" then
    return err.message
  end

  if type(err) == "table" and type(err.type) == "string" then
    return "opencode request failed: " .. err.type
  end

  return "opencode request failed"
end

--- Judge a session's messages (newest first) once it is idle.
---
---@param messages table[]
---@return string|nil text
---@return string|nil err
---@return boolean|nil busy the session has not finished yet
function M.read_result(messages)
  local newest = messages[1]
  if type(newest) ~= "table" or newest.type ~= "idle" then
    return nil, nil, true
  end

  if newest.outcome == "failed" and newest.error then
    return nil, format_error(newest.error)
  end

  for _, message in ipairs(messages) do
    if type(message) == "table" and message.type == "assistant" then
      if message.error then
        return nil, format_error(message.error)
      end

      local texts = {}
      for _, part in ipairs(message.content or {}) do
        if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
          table.insert(texts, part.text)
        end
      end

      -- Empty successful output is a valid deletion replacement.
      return table.concat(texts, "\n"), nil
    end

    if type(message) == "table" and message.type == "user" then
      break
    end
  end

  return nil, "opencode returned no response"
end

--- Send a prompt to an opencode session and deliver the final assistant text.
---
--- @param message string prompt containing the selection and surrounding context
--- @param on_complete fun(res: string|nil, err: string|nil)
--- @return PatchRequest request
function M.request(message, on_complete)
  local request = {
    state = "pending",
    service_request = nil,
    session_id = nil,
    on_complete = on_complete,
  }

  local function complete(res, err)
    if request.state ~= "pending" then
      return
    end

    request.state = "completed"
    request.service_request = nil
    discard_session(request.session_id, false)
    on_complete(res, err)
  end

  --- Run one service call as a step of this request.
  ---
  ---@param on_success fun(data: any)
  local function step(method, path, payload, on_success)
    request.service_request = service.request(method, path, payload, function(data, err)
      if request.state ~= "pending" then
        return
      end

      if err then
        complete(nil, err)
      else
        on_success(data)
      end
    end)
  end

  local session = {
    title = "patch.nvim",
    agent = M.AGENT,
    permissions = PERMISSIONS,
  }

  local selector = session_model or configured_model
  if selector then
    local ref = M.parse_selector(selector)
    if not ref then
      vim.schedule(function()
        complete(nil, "invalid model selector '" .. selector .. "', expected provider/model")
      end)
      return request
    end
    session.model = ref
  end

  local base
  local experimental

  local function collect(waits)
    step("POST", experimental .. "/wait", nil, function()
      step("GET", base .. "/message?limit=20", nil, function(response)
        local messages = type(response) == "table" and response.data or nil
        if type(messages) ~= "table" then
          complete(nil, "opencode returned an invalid message list")
          return
        end

        local text, err, busy = M.read_result(messages)
        if busy and waits < MAX_WAITS then
          collect(waits + 1)
        elseif busy then
          complete(nil, "opencode did not finish the request")
        else
          complete(text, err)
        end
      end)
    end)
  end

  step("POST", "/api/session", session, function(response)
    local info = type(response) == "table" and response.data or nil
    if type(info) ~= "table" or type(info.id) ~= "string" then
      complete(nil, "opencode did not create a session")
      return
    end

    request.session_id = info.id
    base = "/api/session/" .. info.id
    experimental = "/api/experimental/session/" .. info.id

    step("PUT", experimental .. "/instructions/entries/" .. M.INSTRUCTIONS_KEY,
      { value = system_prompt }, function()
        step("POST", base .. "/prompt", { text = message }, function()
          collect(1)
        end)
      end)
  end)

  return request
end

return M
