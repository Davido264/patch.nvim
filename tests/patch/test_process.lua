local eq = MiniTest.expect.equality
local process
local original_system

local function reset()
  package.loaded["patch.opencode.process"] = nil
  process = require("patch.opencode.process")
  original_system = vim.system
end

local function cleanup()
  vim.system = original_system
end

local T = MiniTest.new_set({ hooks = { pre_case = reset, post_case = cleanup } })

local function test(name, action)
  T[name] = action
end

local function fake_system()
  local invocation = {}
  local fake = { kills = {} }

  function fake:kill(signal)
    table.insert(self.kills, signal)
  end

  vim.system = function(command, options, on_exit)
    invocation.command = command
    invocation.options = options
    invocation.on_exit = on_exit
    invocation.process = fake
    return fake
  end

  return invocation
end

local function noop_handlers(overrides)
  return vim.tbl_extend("force", {
    on_record = function() end,
    on_error = function() end,
    on_exit = function() end,
  }, overrides or {})
end

test("runs opencode with the patch agent and sends the message on stdin", function()
  local invocation = fake_system()
  local env = { KEY = "value" }
  assert(process.run({ "--model", "provider/model" }, "hello", env, noop_handlers()))

  eq(invocation.command, {
    "opencode", "run",
    "--pure",
    "--format", "json",
    "--agent", "patch",
    "--title", "patch.nvim",
    "--model", "provider/model",
  })
  eq(invocation.options.stdin, "hello")
  eq(invocation.options.env, env)
  eq(type(invocation.options.stdout), "function")
end)

test("builds an isolated environment around the system prompt", function()
  local env = process.env("system prompt")
  local config = vim.json.decode(env.OPENCODE_CONFIG_CONTENT)

  eq(config.agent.patch, {
    mode = "primary",
    prompt = "system prompt",
    tools = { ["*"] = false },
    permission = { ["*"] = "deny" },
  })
  eq(env.OPENCODE_DISABLE_PROJECT_CONFIG, "1")
  eq(env.OPENCODE_DISABLE_CLAUDE_CODE_PROMPT, "1")
  eq(env.OPENCODE_DISABLE_AUTOUPDATE, "1")
end)

test("decodes records split across stdout chunks", function()
  local invocation = fake_system()
  local records = {}
  assert(process.run({}, "", {}, noop_handlers({
    on_record = function(record)
      table.insert(records, record)
    end,
  })))

  invocation.options.stdout(nil, '{"type":"fir')
  invocation.options.stdout(nil, 'st"}\n{"type":"second"}\n')

  eq(records, { { type = "first" }, { type = "second" } })
end)

test("decodes a final record without a newline", function()
  local invocation = fake_system()
  local records = {}
  assert(process.run({}, "", {}, noop_handlers({
    on_record = function(record)
      table.insert(records, record)
    end,
  })))

  invocation.options.stdout(nil, '{"type":"final"}')
  invocation.options.stdout(nil, nil)

  eq(records, { { type = "final" } })
end)

test("reports malformed JSON once and kills the process", function()
  local invocation = fake_system()
  local errors = {}
  local handle = assert(process.run({}, "", {}, noop_handlers({
    on_error = function(err)
      table.insert(errors, err)
    end,
  })))

  invocation.options.stdout(nil, "not-json\n")
  invocation.options.stdout(nil, "still-not-json\n")

  eq(#errors, 1)
  assert(errors[1]:find("Failed to decode opencode output:", 1, true))
  eq(handle.closed, true)
  eq(invocation.process.kills, { "sigterm" })
end)

test("reports stdout errors", function()
  local invocation = fake_system()
  local received
  assert(process.run({}, "", {}, noop_handlers({
    on_error = function(err)
      received = err
    end,
  })))

  invocation.options.stdout("broken pipe", nil)

  eq(received, "Failed to read opencode output: broken pipe")
end)

test("kills idempotently", function()
  local invocation = fake_system()
  local handle = assert(process.run({}, "", {}, noop_handlers()))

  handle:kill()
  handle:kill()

  eq(invocation.process.kills, { "sigterm" })
end)

test("kills running processes when Neovim exits", function()
  local invocation = fake_system()
  local handle = assert(process.run({}, "", {}, noop_handlers()))

  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "patch-opencode" })

  eq(handle.closed, true)
  eq(invocation.process.kills, { "sigterm" })
end)

test("marks the handle closed when the process exits", function()
  local invocation = fake_system()
  local exited
  local handle = assert(process.run({}, "", {}, noop_handlers({
    on_exit = function(result)
      exited = result
    end,
  })))

  invocation.on_exit({ code = 0 })

  eq(exited, { code = 0 })
  eq(handle.closed, true)
end)

test("reports process start failures", function()
  vim.system = function()
    error("not executable")
  end

  local handle, err = process.run({}, "", {}, noop_handlers())

  eq(handle, nil)
  assert(err:find("Failed to start opencode:", 1, true))
  assert(err:find("not executable", 1, true))
end)

test("formats process errors with trimmed stderr", function()
  eq(process.format_exit_error({ code = 3, stderr = "  failure\n" }), "opencode exited with code 3: failure")
  eq(process.format_exit_error({ code = 2, stderr = "" }), "opencode exited with code 2")
end)

test("exec returns stdout on success", function()
  local invocation = fake_system()
  local result
  process.exec({ "models" }, { KEY = "value" }, function(stdout, err)
    result = { stdout, err }
  end)

  eq(invocation.command, { "opencode", "models" })
  eq(invocation.options.env, { KEY = "value" })
  invocation.on_exit({ code = 0, stdout = "a/b\n" })
  eq(result, { "a/b\n", nil })
end)

test("exec reports non-zero exits and start failures", function()
  local invocation = fake_system()
  local result
  process.exec({ "models" }, nil, function(stdout, err)
    result = { stdout, err }
  end)
  invocation.on_exit({ code = 1, stderr = "boom" })
  eq(result, { nil, "opencode exited with code 1: boom" })

  vim.system = function()
    error("missing")
  end
  process.exec({ "models" }, nil, function(stdout, err)
    result = { stdout, err }
  end)
  eq(result[1], nil)
  assert(result[2]:find("Failed to start opencode:", 1, true))
end)

return T
