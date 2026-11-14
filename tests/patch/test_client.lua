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
local process
local handle
local handlers
local run_args
local run_message
local run_env
local exec_calls

local function reset()
  exec_calls = {}
  handle = { closed = false, killed = 0 }
  function handle:kill()
    self.killed = self.killed + 1
    self.closed = true
  end

  process = {
    AGENT = "patch",
    env = function(system_prompt)
      return { PROMPT = system_prompt }
    end,
    run = function(args, message, env, supplied_handlers)
      run_args = args
      run_message = message
      run_env = env
      handlers = supplied_handlers
      return handle
    end,
    exec = function(args, env, on_complete)
      table.insert(exec_calls, { args = args, env = env, on_complete = on_complete })
    end,
    format_exit_error = function(result)
      return "exit " .. result.code
    end,
  }

  package.loaded["patch.opencode.process"] = process
  package.loaded["patch.opencode.client"] = nil
  client = require("patch.opencode.client")
  client.setup()
end

local function cleanup()
  package.loaded["patch.opencode.client"] = nil
  package.loaded["patch.opencode.process"] = nil
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

local function text(message_id, value)
  return {
    type = "text",
    sessionID = "ses_1",
    part = { type = "text", messageID = message_id, text = value },
  }
end

local function step_finish(reason)
  return { type = "step_finish", sessionID = "ses_1", part = { type = "step-finish", reason = reason } }
end

local function find_exec(args)
  for _, call in ipairs(exec_calls) do
    if vim.deep_equal(call.args, args) then
      return call
    end
  end
end

test("sends the prompt on stdin and completes when opencode exits", function()
  local result = {}
  local request = client.request("replace this", function(value, err)
    record(result, { value = value, err = err })
  end)

  eq(request.state, "pending")
  eq(run_message, "replace this")
  eq(run_args, {})
  assert(run_env.PROMPT:find("inline code editor", 1, true))

  handlers.on_record(text("msg_1", "replacement"))
  handlers.on_record(step_finish("stop"))
  vim.wait(20)
  is_nil(result.called)

  handlers.on_exit({ code = 0 })
  wait_for_result(result)

  eq(result.value, "replacement")
  is_nil(result.err)
  eq(request.state, "completed")
end)

test("deletes the opencode session after completing", function()
  client.request("prompt", function() end)
  handlers.on_record(text("msg_1", "x"))
  handlers.on_exit({ code = 0 })

  is_true(find_exec({ "session", "delete", "ses_1" }) ~= nil)
end)

test("uses the final message and joins its text parts", function()
  local result = {}
  client.request("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)

  handlers.on_record(text("msg_1", "narration before a tool call"))
  handlers.on_record(step_finish("tool-calls"))
  handlers.on_record(text("msg_2", "first"))
  handlers.on_record(text("msg_2", "second"))
  handlers.on_record(step_finish("stop"))
  handlers.on_exit({ code = 0 })
  wait_for_result(result)

  eq(result.value, "first\nsecond")
  is_nil(result.err)
end)

test("passes configured system prompt and model arguments", function()
  client.setup({ system_prompt = "custom prompt", model = " openai/model " })
  client.request("prompt", function() end)

  eq(run_args, { "--model", "openai/model" })
  eq(run_env, { PROMPT = "custom prompt" })
end)

test("treats a finished step without text as a deletion", function()
  local result = {}
  client.request("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)

  handlers.on_record(step_finish("stop"))
  handlers.on_exit({ code = 0 })
  wait_for_result(result)

  eq(result.value, "")
  is_nil(result.err)
end)

test("cancels a pending request once by killing opencode", function()
  local result = {}
  local request = client.request("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)
  handlers.on_record({ type = "step_start", sessionID = "ses_1", part = {} })

  is_true(client.cancel(request))
  is_false(client.cancel(request))
  wait_for_result(result)

  eq(request.state, "cancelled")
  eq(handle.killed, 1)
  is_nil(result.value)
  eq(result.err, "cancelled")
  is_true(find_exec({ "session", "delete", "ses_1" }) ~= nil)

  -- A late exit after cancellation is ignored.
  handlers.on_exit({ code = 143 })
  vim.wait(20)
  eq(result.err, "cancelled")
end)

test("reports error events from opencode", function()
  local result = {}
  client.request("prompt", function(value, err)
    record(result, { value = value, err = err })
  end)

  handlers.on_record({
    type = "error",
    sessionID = "ses_1",
    error = { name = "APIError", data = { message = "rate limited" } },
  })
  handlers.on_exit({ code = 1 })
  wait_for_result(result)

  is_nil(result.value)
  eq(result.err, "rate limited")
end)

test("reports missing responses", function()
  local result = {}
  client.request("prompt", function(_, err)
    record(result, { err = err })
  end)
  handlers.on_exit({ code = 0 })
  wait_for_result(result)
  eq(result.err, "opencode returned no response")
end)

test("reports process start, stream, and exit failures", function()
  process.run = function()
    return nil, "cannot start"
  end
  local start_result = {}
  client.request("prompt", function(_, err)
    record(start_result, { err = err })
  end)
  wait_for_result(start_result)
  eq(start_result.err, "cannot start")

  process.run = function(_, _, _, supplied_handlers)
    handlers = supplied_handlers
    return handle
  end
  local exit_result = {}
  client.request("prompt", function(_, err)
    record(exit_result, { err = err })
  end)
  handlers.on_exit({ code = 7 })
  wait_for_result(exit_result)
  eq(exit_result.err, "exit 7")

  local stream_result = {}
  client.request("prompt", function(_, err)
    record(stream_result, { err = err })
  end)
  handlers.on_error("bad json")
  handlers.on_exit({ code = 143 })
  wait_for_result(stream_result)
  eq(stream_result.err, "bad json")
end)

test("parses available models from opencode models output", function()
  local result = {}
  client.get_available_models(function(models, err)
    record(result, { models = models, err = err })
  end)

  local call = find_exec({ "models" })
  call.on_complete("openai/gpt-5\nopencode/big-pickle\n\nnot a model line\n", nil)
  wait_for_result(result)

  eq(result.models, {
    { provider = "openai", id = "gpt-5", name = "gpt-5" },
    { provider = "opencode", id = "big-pickle", name = "big-pickle" },
  })
  is_nil(result.err)

  result = {}
  client.get_available_models(function(models, err)
    record(result, { models = models, err = err })
  end)
  exec_calls[#exec_calls].on_complete(nil, "failed")
  wait_for_result(result)
  is_nil(result.models)
  eq(result.err, "failed")
end)

test("resolves configured, session, and cached default models", function()
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

  client.setup()
  result = {}
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  eq(#exec_calls, 1)
  eq(exec_calls[1].args, { "debug", "config" })
  exec_calls[1].on_complete(vim.json.encode({ model = "primary/model" }), nil)
  wait_for_result(result)
  eq(result.value, "primary/model")

  result = {}
  client.resolve_model(function(value)
    record(result, { value = value })
  end)
  wait_for_result(result)
  eq(result.value, "primary/model")
  eq(#exec_calls, 1)
end)

test("resolves no model when opencode has no default", function()
  local result = {}
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  exec_calls[1].on_complete('{"model":null}', nil)
  wait_for_result(result)
  is_nil(result.value)
  is_nil(result.err)

  result = {}
  client.resolve_model(function(value, err)
    record(result, { value = value, err = err })
  end)
  exec_calls[2].on_complete("not json", nil)
  wait_for_result(result)
  eq(result.err, "opencode returned an invalid configuration")
end)

return T
