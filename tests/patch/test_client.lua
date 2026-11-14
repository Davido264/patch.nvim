local helpers = require("tests.helpers")
local eq = MiniTest.expect.equality

local function is_nil(value)
  eq(value, nil)
end

local function is_true(value)
  eq(value, true)
end

local function is_false(value)
  eq(value, false)
end

local client
local calls

local function reset()
  calls = {}

  package.loaded["patch.opencode.service"] = {
    request = function(method, path, payload, on_complete)
      local call = { method = method, path = path, payload = payload, on_complete = on_complete, cancelled = 0 }
      call.handle = {
        cancel = function()
          call.cancelled = call.cancelled + 1
        end,
      }
      table.insert(calls, call)
      return call.handle
    end,
  }
  package.loaded["patch.opencode.client"] = nil
  client = require("patch.opencode.client")
  client.setup()
end

local function cleanup()
  package.loaded["patch.opencode.client"] = nil
  package.loaded["patch.opencode.service"] = nil
end

local T = MiniTest.new_set({ hooks = { pre_case = reset, post_case = cleanup } })

local function test(name, action)
  T[name] = action
end

local function wait_for_result(result)
  helpers.wait_for(function()
    return result.called
  end)
end

local function record(result, values)
  result.called = true
  for key, value in pairs(values) do
    result[key] = value
  end
end

local function last_call()
  return calls[#calls]
end

--- Answer the pending service call after checking which endpoint it targets.
local function reply(method, path, data, err)
  local call = last_call()
  eq(call.method .. " " .. call.path, method .. " " .. path)
  call.on_complete(data, err)
  return call
end

local function idle(assistant)
  return { data = { { type = "idle", outcome = "succeeded" }, assistant, { type = "user", text = "prompt" } } }
end

local function assistant(...)
  local content = {}
  for _, text in ipairs({ ... }) do
    table.insert(content, { type = "text", text = text })
  end
  return { type = "assistant", finish = "stop", content = content }
end

--- Drive a request through session creation, instructions, and prompt submission.
local function start_session(message, on_complete)
  local request = client.request(message, on_complete)
  reply("POST", "/api/session", { data = { id = "ses_1" } })
  reply("PUT", "/api/experimental/session/ses_1/instructions/entries/patch.nvim", nil)
  reply("POST", "/api/session/ses_1/prompt", { data = {} })
  reply("POST", "/api/experimental/session/ses_1/wait", nil)
  return request
end

local function find_call(method, path)
  for _, call in ipairs(calls) do
    if call.method == method and call.path == path then
      return call
    end
  end
end

test("runs the prompt in a restricted session and returns the final text", function()
  local result = {}
  local request = start_session("replace this", function(value, err)
    record(result, { value = value, err = err })
  end)

  local create = calls[1].payload
  eq(create.title, "patch.nvim")
  eq(create.agent, "build")
  is_nil(create.model)
  eq(create.permissions, client.PERMISSIONS)
  assert(calls[2].payload.value:find("inline code editor", 1, true))
  eq(calls[3].payload, { text = "replace this" })

  reply("GET", "/api/session/ses_1/message?limit=20", idle(assistant("first", "second")))
  wait_for_result(result)

  eq(result.value, "first\nsecond")
  is_nil(result.err)
  eq(request.state, "completed")
  is_true(find_call("DELETE", "/api/session/ses_1") ~= nil)
end)

test("passes configured system prompt and model reference", function()
  client.setup({ system_prompt = "custom prompt", model = " openai/gpt-5#high " })
  client.request("prompt", function() end)

  eq(calls[1].payload.model, { providerID = "openai", id = "gpt-5", variant = "high" })
  reply("POST", "/api/session", { data = { id = "ses_1" } })
  eq(calls[2].payload, { value = "custom prompt" })
end)

test("never denies every read, which opencode's free models reject", function()
  for _, rule in ipairs(client.PERMISSIONS) do
    is_false(rule.action == "*" or (rule.action == "read" and rule.resource == "*"))
  end
end)

test("rejects invalid model selectors without contacting opencode", function()
  client.setup({ model = "not-a-selector" })
  local result = {}
  client.request("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)
  wait_for_result(result)

  eq(#calls, 0)
  eq(result.err, "invalid model selector 'not-a-selector', expected provider/model")
end)

test("waits again while the session is still busy", function()
  local result = {}
  start_session("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)

  reply("GET", "/api/session/ses_1/message?limit=20", { data = { { type = "user", text = "prompt" } } })
  reply("POST", "/api/experimental/session/ses_1/wait", nil)
  reply("GET", "/api/session/ses_1/message?limit=20", idle(assistant("done")))
  wait_for_result(result)

  eq(result.value, "done")
end)

test("keeps empty text as a deletion", function()
  local result = {}
  start_session("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)
  reply("GET", "/api/session/ses_1/message?limit=20", idle(assistant()))
  wait_for_result(result)

  eq(result.value, "")
  is_nil(result.err)
end)

test("cancels a pending request once and discards its session", function()
  local result = {}
  local request = start_session("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)
  local pending = last_call()

  is_true(client.cancel(request))
  is_false(client.cancel(request))
  wait_for_result(result)

  eq(request.state, "cancelled")
  eq(pending.cancelled, 1)
  is_nil(result.value)
  eq(result.err, "cancelled")

  reply("POST", "/api/session/ses_1/interrupt", nil)
  is_true(find_call("DELETE", "/api/session/ses_1") ~= nil)

  -- A late response after cancellation is ignored.
  pending.on_complete(idle(assistant("late")), nil)
  vim.wait(20)
  eq(result.err, "cancelled")
end)

test("reports service, generation, and missing-response errors", function()
  local failed = {}
  client.request("prompt", function(value, err)
    record(failed, { value = value, err = err })
  end)
  reply("POST", "/api/session", nil, "cannot connect")
  wait_for_result(failed)
  is_nil(failed.value)
  eq(failed.err, "cannot connect")

  local provider = {}
  start_session("prompt", function(value, err)
    record(provider, { value = value, err = err })
  end)
  reply("GET", "/api/session/ses_1/message?limit=20", {
    data = {
      { type = "idle", outcome = "failed", error = { type = "provider.free-limit", message = "Free usage limit reached." } },
      { type = "assistant", finish = "error", content = {}, error = { message = "Free usage limit reached." } },
      { type = "user", text = "prompt" },
    },
  })
  wait_for_result(provider)
  eq(provider.err, "Free usage limit reached.")

  local empty = {}
  start_session("prompt", function(_, err)
    record(empty, { err = err })
  end)
  reply("GET", "/api/session/ses_1/message?limit=20", { data = { { type = "idle" }, { type = "user", text = "prompt" } } })
  wait_for_result(empty)
  eq(empty.err, "opencode returned no response")
end)

test("lists enabled models from the service", function()
  local result = {}
  client.get_available_models(function(models, err)
    record(result, { models = models, err = err })
  end)

  eq(calls[1].method, "GET")
  eq(calls[1].path, "/api/model")
  calls[1].on_complete({
    data = {
      { providerID = "openai", id = "gpt-5", name = "GPT-5" },
      { providerID = "opencode", id = "big-pickle" },
      { providerID = "old", id = "off", enabled = false },
      { name = "malformed" },
    },
  }, nil)
  wait_for_result(result)

  eq(result.models, {
    { provider = "openai", id = "gpt-5", name = "GPT-5" },
    { provider = "opencode", id = "big-pickle", name = "big-pickle" },
  })
  is_nil(result.err)

  result = {}
  client.get_available_models(function(models, err)
    record(result, { models = models, err = err })
  end)
  calls[2].on_complete(nil, "failed")
  wait_for_result(result)
  is_nil(result.models)
  eq(result.err, "failed")
end)

test("resolves configured, session, and service default models", function()
  local result = {}
  client.setup({ model = "configured/model" })
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  wait_for_result(result)
  eq(result.value, "configured/model")

  eq(client.select_model({ provider = "provider", id = "session" }), "provider/session")
  result = {}
  client.resolve_model(function(value)
    record(result, { value = value })
  end)
  wait_for_result(result)
  eq(result.value, "provider/session")
  eq(#calls, 0)

  client.setup()
  result = {}
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  eq(calls[1].path, "/api/model/default")
  calls[1].on_complete({ data = { providerID = "primary", id = "model" } }, nil)
  wait_for_result(result)
  eq(result.value, "primary/model")
  is_nil(result.err)
end)

test("resolves no model when opencode has no default", function()
  local result = {}
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  calls[1].on_complete({ data = nil }, nil)
  wait_for_result(result)
  is_nil(result.value)
  is_nil(result.err)

  result = {}
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  calls[2].on_complete(nil, "unreachable")
  wait_for_result(result)
  eq(result.err, "unreachable")
end)

return T
