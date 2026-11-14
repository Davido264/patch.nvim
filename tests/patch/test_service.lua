local eq = MiniTest.expect.equality
local uv = vim.uv or vim.loop

local service
local state_home
local original_state_home
local original_system
local servers

local function write_state(url, password)
  vim.fn.mkdir(state_home .. "/opencode", "p")
  local file = assert(io.open(state_home .. "/opencode/service.json", "w"))
  file:write(vim.json.encode({ url = url, password = password, pid = 1 }))
  file:close()
end

--- Start a one-request-per-connection HTTP server that replies with `respond(request)`.
local function serve(respond)
  local server = uv.new_tcp()
  server:bind("127.0.0.1", 0)
  local fake = { requests = {}, port = server:getsockname().port }

  server:listen(16, function()
    local socket = uv.new_tcp()
    server:accept(socket)
    local buffer = ""

    socket:read_start(function(_, data)
      if not data then
        socket:close()
        return
      end

      buffer = buffer .. data
      local header_end = buffer:find("\r\n\r\n", 1, true)
      if not header_end then
        return
      end

      local head = buffer:sub(1, header_end - 1)
      local length = tonumber(head:match("[Cc]ontent%-[Ll]ength: (%d+)")) or 0
      local body = buffer:sub(header_end + 4)
      if #body < length then
        return
      end

      local request = {
        line = head:match("^[^\r\n]+"),
        authorization = head:match("Authorization: ([^\r\n]+)"),
        body = body,
      }
      table.insert(fake.requests, request)

      local reply = respond(request)
      if reply then
        socket:write(reply, function()
          socket:close()
        end)
      end
    end)
  end)

  table.insert(servers, server)
  fake.url = "http://127.0.0.1:" .. fake.port
  return fake
end

local function json_reply(status, value, extra_headers)
  local body = vim.json.encode(value)
  return table.concat({
    "HTTP/1.1 " .. status .. " X",
    "content-type: application/json",
    "content-length: " .. #body,
    extra_headers or "Connection: keep-alive",
    "",
    body,
  }, "\r\n")
end

local function wait_result(result)
  assert(vim.wait(2000, function()
    return result.called
  end, 5), "timed out waiting for service response")
end

local function call(method, path, payload)
  local result = {}
  local handle = service.request(method, path, payload, function(data, err)
    result.called = true
    result.data = data
    result.err = err
  end)
  return result, handle
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      servers = {}
      original_state_home = vim.env.XDG_STATE_HOME
      original_system = vim.system
      state_home = vim.fn.tempname()
      vim.env.XDG_STATE_HOME = state_home
      package.loaded["patch.opencode.service"] = nil
      service = require("patch.opencode.service")
    end,
    post_case = function()
      for _, server in ipairs(servers) do
        if not server:is_closing() then
          server:close()
        end
      end
      vim.system = original_system
      vim.env.XDG_STATE_HOME = original_state_home
      vim.fn.delete(state_home, "rf")
      package.loaded["patch.opencode.service"] = nil
    end,
  },
})

T["reads the service endpoint from opencode's state file"] = function()
  write_state("http://localhost:4096", "secret")
  eq(service.read_endpoint(), { host = "127.0.0.1", port = 4096, password = "secret" })

  write_state("http://[::1]:4096/", nil)
  eq(service.read_endpoint(), { host = "::1", port = 4096 })

  write_state("https://example.com", "x")
  local endpoint, err = service.read_endpoint()
  eq(endpoint, nil)
  eq(err, "unsupported opencode service url: https://example.com")
end

T["parses content-length, chunked, and incomplete responses"] = function()
  eq(service.parse_response("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi", false), { status = 200, body = "hi" })
  eq(service.parse_response("HTTP/1.1 200 OK\r\ncontent-length: 4\r\n\r\nhi", false), nil)
  eq(
    service.parse_response("HTTP/1.1 201 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n", false),
    { status = 201, body = "hello" }
  )
  eq(service.parse_response("HTTP/1.1 200 OK\r\n\r\nuntil close", true), { status = 200, body = "until close" })

  local response, err = service.parse_response("HTTP/1.1 200 OK\r\ncontent-length: 9\r\n\r\nhi", true)
  eq(response, nil)
  eq(err, "opencode service sent an incomplete response")
end

T["sends authenticated JSON requests and decodes responses"] = function()
  local fake = serve(function()
    return json_reply(200, { data = { text = "ok" } })
  end)
  write_state(fake.url, "secret")

  local result = call("POST", "/api/experimental/generate/text", { prompt = "hello" })
  wait_result(result)

  eq(result.err, nil)
  eq(result.data, { data = { text = "ok" } })
  eq(fake.requests[1].line, "POST /api/experimental/generate/text HTTP/1.1")
  eq(fake.requests[1].authorization, "Basic " .. vim.base64.encode("opencode:secret"))
  eq(vim.json.decode(fake.requests[1].body), { prompt = "hello" })
end

T["accepts empty no-content responses"] = function()
  local fake = serve(function()
    return "HTTP/1.1 204 No Content\r\n\r\n"
  end)
  write_state(fake.url, "secret")

  local result = call("POST", "/api/experimental/session/ses_1/wait")
  wait_result(result)
  eq(result.err, nil)
  eq(result.data, nil)
end

T["reports error messages from the service"] = function()
  local fake = serve(function()
    return json_reply(502, { _tag = "ProviderRequestError", message = "Free usage limit reached." })
  end)
  write_state(fake.url, "secret")

  local result = call("GET", "/api/model")
  wait_result(result)
  eq(result.data, nil)
  eq(result.err, "Free usage limit reached.")
end

T["starts the service when it is not running and retries once"] = function()
  local fake = serve(function()
    return json_reply(200, { data = {} })
  end)
  local started = 0

  vim.system = function(command, _, on_exit)
    eq(command, { "opencode", "service", "start" })
    started = started + 1
    write_state(fake.url, "fresh")
    vim.schedule(function()
      on_exit({ code = 0, stdout = fake.url, stderr = "" })
    end)
    return {}
  end

  local result = call("GET", "/api/model")
  wait_result(result)

  eq(result.err, nil)
  eq(result.data, { data = {} })
  eq(started, 1)
  eq(fake.requests[1].authorization, "Basic " .. vim.base64.encode("opencode:fresh"))
end

T["reports when the service cannot be started"] = function()
  vim.system = function(_, _, on_exit)
    vim.schedule(function()
      on_exit({ code = 1, stdout = "", stderr = "Error: boom\nError: port in use\n    at <anonymous> (chunk.js:1:1)\n" })
    end)
    return {}
  end

  local result = call("GET", "/api/model")
  wait_result(result)
  eq(result.err, "cannot start opencode service: Error: boom\nError: port in use")
end

T["does not deliver a cancelled request"] = function()
  local fake = serve(function()
    return nil -- never reply
  end)
  write_state(fake.url, "secret")

  local result, handle = call("POST", "/api/experimental/generate/text", { prompt = "slow" })
  assert(vim.wait(2000, function()
    return #fake.requests == 1
  end, 5))

  handle:cancel()
  vim.wait(50)
  eq(result.called, nil)
end

return T
