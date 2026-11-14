local M = {}

---@type table<PatchProcess, true>
local running = {}

--- Name of the agent patch.nvim injects into opencode's configuration.
M.AGENT = "patch"

---@class PatchProcess
---@field process? vim.SystemObj
---@field closed boolean
---@field kill fun(self: PatchProcess)

---@class PatchProcessHandlers
---@field on_record fun(record: table)
---@field on_error fun(err: string)
---@field on_exit fun(result: vim.SystemCompleted)

--- Create a callback that decodes newline-delimited JSON records.
---
---@param on_record fun(record: table)
---@param on_error fun(err: string)
---@return fun(error_message: string|nil, data: string|nil)
local function read_jsonl(on_record, on_error)
  local buffer = ""
  local stopped = false

  local function emit(line)
    line = line:gsub("\r$", "")
    if line == "" then
      return true
    end

    local decoded, record = pcall(vim.json.decode, line)
    if not decoded then
      stopped = true
      on_error("Failed to decode opencode output: " .. record)
      return false
    end

    on_record(record)
    return true
  end

  return function(error_message, data)
    if stopped then
      return
    end

    if error_message then
      stopped = true
      on_error("Failed to read opencode output: " .. error_message)
      return
    end

    buffer = buffer .. (data or "")

    while true do
      local newline = buffer:find("\n", 1, true)
      if not newline then
        break
      end

      local line = buffer:sub(1, newline - 1)
      buffer = buffer:sub(newline + 1)

      if not emit(line) then
        return
      end
    end

    if data == nil and buffer ~= "" then
      local line = buffer
      buffer = ""
      emit(line)
    end
  end
end

--- Format a non-zero opencode process result, including captured stderr when available.
---
---@param result vim.SystemCompleted
---@return string message
function M.format_exit_error(result)
  local message = "opencode exited with code " .. result.code
  local stderr = vim.trim(result.stderr or "")

  if stderr ~= "" then
    return message .. ": " .. stderr
  end

  return message
end

--- Build the environment that isolates opencode from project context.
---
--- The injected agent replaces opencode's coding-agent prompt and has every tool
--- disabled, and project/Claude Code instruction files are not loaded, so the model
--- sees only the system prompt and the captured selection.
---
---@param system_prompt string
---@return table<string, string> env
function M.env(system_prompt)
  return {
    OPENCODE_CONFIG_CONTENT = vim.json.encode({
      agent = {
        [M.AGENT] = {
          mode = "primary",
          prompt = system_prompt,
          tools = { ["*"] = false },
          permission = { ["*"] = "deny" },
        },
      },
    }),
    OPENCODE_DISABLE_PROJECT_CONFIG = "1",
    OPENCODE_DISABLE_CLAUDE_CODE_PROMPT = "1",
    OPENCODE_DISABLE_AUTOUPDATE = "1",
  }
end

--- Start `opencode run`, feeding the message on stdin and streaming its JSON events.
---
---@param args string[] additional `opencode run` arguments
---@param message string prompt sent on stdin
---@param env table<string, string>
---@param handlers PatchProcessHandlers
---@return PatchProcess|nil process
---@return string|nil error_message
function M.run(args, message, env, handlers)
  local handle = {
    process = nil,
    closed = false,
  }

  function handle:kill()
    if self.closed then
      return
    end

    self.closed = true
    running[self] = nil
    local process = self.process
    self.process = nil

    if process then
      pcall(process.kill, process, "sigterm")
    end
  end

  local function handle_error(err)
    handle:kill()
    handlers.on_error(err)
  end

  local command = {
    "opencode", "run",
    "--pure",
    "--format", "json",
    "--agent", M.AGENT,
    "--title", "patch.nvim",
  }
  vim.list_extend(command, args)

  local started, process_or_error = pcall(
    vim.system,
    command,
    {
      -- opencode reads a non-TTY stdin to EOF and uses it as the message.
      stdin = message,
      stdout = read_jsonl(handlers.on_record, handle_error),
      env = env,
    },
    function(result)
      handle.process = nil
      handle.closed = true
      running[handle] = nil
      handlers.on_exit(result)
    end
  )

  if not started then
    handle.closed = true
    return nil, "Failed to start opencode: " .. tostring(process_or_error)
  end

  handle.process = process_or_error
  running[handle] = true
  return handle, nil
end

--- Kill every running `opencode run` process.
---
--- opencode keeps retrying failed provider calls instead of exiting, so a pending
--- request would otherwise outlive Neovim.
function M.kill_all()
  for handle in pairs(running) do
    handle:kill()
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("patch-opencode", { clear = true }),
  callback = M.kill_all,
})

--- Run a one-shot opencode command and return its stdout.
---
---@param args string[] opencode arguments
---@param env table<string, string>|nil
---@param on_complete fun(stdout: string|nil, err: string|nil)
function M.exec(args, env, on_complete)
  local command = { "opencode" }
  vim.list_extend(command, args)

  local started, process_error = pcall(
    vim.system,
    command,
    { stdin = false, text = true, env = env },
    function(result)
      if result.code ~= 0 then
        on_complete(nil, M.format_exit_error(result))
        return
      end

      on_complete(result.stdout or "", nil)
    end
  )

  if not started then
    on_complete(nil, "Failed to start opencode: " .. tostring(process_error))
  end
end

return M
