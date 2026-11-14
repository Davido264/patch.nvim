local M = {}

local uv = vim.uv or vim.loop

--- Username the opencode service expects for HTTP basic authentication.
local USERNAME = "opencode"

---@class PatchEndpoint
---@field host string
---@field port integer
---@field password string|nil

---@class PatchServiceRequest
---@field cancel fun(self: PatchServiceRequest)

---@class PatchHttpResponse
---@field status integer
---@field body string

--- Path of the file where the opencode background service publishes its address.
---
---@return string path
function M.state_file()
  local state = vim.env.XDG_STATE_HOME
  if not state or state == "" then
    state = (vim.env.HOME or "") .. "/.local/state"
  end

  return state .. "/opencode/service.json"
end

--- Read the address and credentials of the running opencode service.
---
---@return PatchEndpoint|nil endpoint
---@return string|nil error_message
function M.read_endpoint()
  local file = io.open(M.state_file(), "r")
  if not file then
    return nil, "opencode service is not running"
  end

  local contents = file:read("*a")
  file:close()

  local decoded, info = pcall(vim.json.decode, contents)
  if not decoded or type(info) ~= "table" or type(info.url) ~= "string" then
    return nil, "opencode service state is invalid: " .. M.state_file()
  end

  local host, port = info.url:match("^http://%[?([^%]/]-)%]?:(%d+)/?$")
  if not host then
    return nil, "unsupported opencode service url: " .. info.url
  end

  if host == "localhost" then
    host = "127.0.0.1"
  end

  return {
    host = host,
    port = tonumber(port),
    password = type(info.password) == "string" and info.password or nil,
  }, nil
end

--- Decode a chunked transfer-encoded body.
---
---@param data string
---@return string|nil body nil while the body is incomplete
local function decode_chunked(data)
  local parts = {}
  local position = 1

  while true do
    local line_end = data:find("\r\n", position, true)
    if not line_end then
      return nil
    end

    local size = tonumber(data:sub(position, line_end - 1):match("^%x+"), 16)
    if not size then
      return nil
    end

    if size == 0 then
      return table.concat(parts)
    end

    local chunk_start = line_end + 2
    local chunk_end = chunk_start + size - 1
    if #data < chunk_end + 2 then
      return nil
    end

    table.insert(parts, data:sub(chunk_start, chunk_end))
    position = chunk_end + 3
  end
end

--- Parse a raw HTTP/1.1 response.
---
---@param data string bytes received so far
---@param eof boolean whether the connection has closed
---@return PatchHttpResponse|nil response nil while the response is incomplete
---@return string|nil error_message
function M.parse_response(data, eof)
  local header_end = data:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil, eof and "opencode service sent an incomplete response" or nil
  end

  local head = data:sub(1, header_end - 1)
  local status = tonumber(head:match("^HTTP/%d[%.%d]* (%d%d%d)"))
  if not status then
    return nil, "opencode service sent an invalid response"
  end

  local headers = {}
  for name, value in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
    headers[name:lower()] = value
  end

  local rest = data:sub(header_end + 4)
  local body

  if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
    body = decode_chunked(rest)
  elseif headers["content-length"] then
    local length = tonumber(headers["content-length"])
    if length and #rest >= length then
      body = rest:sub(1, length)
    end
  elseif eof then
    body = rest
  end

  if not body then
    return nil, eof and "opencode service sent an incomplete response" or nil
  end

  return { status = status, body = body }, nil
end

--- Send one HTTP request to the service.
---
---@param endpoint PatchEndpoint
---@param method string
---@param path string
---@param body string|nil
---@param on_complete fun(response: PatchHttpResponse|nil, err: string|nil, connect_failed: boolean|nil)
---@return fun() close aborts the request without calling on_complete
local function send(endpoint, method, path, body, on_complete)
  local tcp = uv.new_tcp()
  local buffer = ""
  local done = false

  local function close()
    done = true
    if not tcp:is_closing() then
      tcp:close()
    end
  end

  local function finish(response, err, connect_failed)
    if done then
      return
    end

    close()
    vim.schedule(function()
      on_complete(response, err, connect_failed)
    end)
  end

  local lines = {
    string.format("%s %s HTTP/1.1", method, path),
    string.format("Host: %s:%d", endpoint.host, endpoint.port),
    "Accept: application/json",
    "Connection: close",
  }

  if endpoint.password then
    table.insert(lines, "Authorization: Basic " .. vim.base64.encode(USERNAME .. ":" .. endpoint.password))
  end

  if body then
    table.insert(lines, "Content-Type: application/json")
    table.insert(lines, "Content-Length: " .. #body)
  end

  local request = table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")

  local ok, connect_error = pcall(tcp.connect, tcp, endpoint.host, endpoint.port, function(err)
    if err then
      finish(nil, "cannot connect to opencode service: " .. err, true)
      return
    end

    tcp:write(request, function(write_error)
      if write_error then
        finish(nil, "cannot send request to opencode service: " .. write_error)
      end
    end)

    tcp:read_start(function(read_error, data)
      if read_error then
        finish(nil, "cannot read opencode service response: " .. read_error)
        return
      end

      if data then
        buffer = buffer .. data
      end

      local response, parse_error = M.parse_response(buffer, data == nil)
      if response or parse_error then
        finish(response, parse_error)
      end
    end)
  end)

  if not ok then
    finish(nil, "cannot connect to opencode service: " .. tostring(connect_error), true)
  end

  return close
end

---@type fun(err: string|nil)[]|nil
local starting

--- Start the opencode background service, sharing one start among concurrent requests.
---
---@param on_started fun(err: string|nil)
---@return fun() forget stops waiting for the start
local function start_service(on_started)
  local waiting = true
  local function callback(err)
    if waiting then
      on_started(err)
    end
  end

  if starting then
    table.insert(starting, callback)
  else
    starting = { callback }

    local function notify_all(err)
      local callbacks = starting or {}
      starting = nil
      for _, waiter in ipairs(callbacks) do
        waiter(err)
      end
    end

    local ok, start_error = pcall(vim.system, { "opencode", "service", "start" }, { text = true }, function(result)
      if result.code ~= 0 then
        -- Keep the error messages and drop the stack trace that follows them.
        local stderr = vim.trim(((result.stderr or ""):match("^(.-)\n%s+at ") or result.stderr or ""))
        notify_all("cannot start opencode service" .. (stderr ~= "" and ": " .. stderr or ""))
      else
        notify_all(nil)
      end
    end)

    if not ok then
      notify_all("Failed to start opencode: " .. tostring(start_error))
    end
  end

  return function()
    waiting = false
  end
end

--- Describe an error response from the service.
---
---@param response PatchHttpResponse
---@return string message
local function format_http_error(response)
  local decoded, body = pcall(vim.json.decode, response.body)
  if decoded and type(body) == "table" then
    if type(body.message) == "string" and body.message ~= "" then
      return body.message
    end
    if type(body._tag) == "string" and body._tag ~= "" then
      return body._tag
    end
  end

  if response.status == 401 then
    return "opencode service rejected the credentials in " .. M.state_file()
  end

  return "opencode service returned HTTP " .. response.status
end

--- Make a JSON request to the opencode background service, starting it when needed.
---
--- The callback runs on Neovim's main event loop and is not called after cancellation.
---
---@param method string
---@param path string
---@param payload table|nil JSON request body
---@param on_complete fun(data: any, err: string|nil)
---@return PatchServiceRequest request
function M.request(method, path, payload, on_complete)
  local body = payload and vim.json.encode(payload) or nil
  local cancelled = false
  local abort = function() end

  local function deliver(data, err)
    vim.schedule(function()
      if not cancelled then
        on_complete(data, err)
      end
    end)
  end

  local function handle_response(response, err)
    if err then
      deliver(nil, err)
      return
    end

    if response.status < 200 or response.status >= 300 then
      deliver(nil, format_http_error(response))
      return
    end

    if vim.trim(response.body) == "" then
      deliver(nil, nil)
      return
    end

    local decoded, data = pcall(vim.json.decode, response.body, { luanil = { object = true, array = true } })
    if not decoded then
      deliver(nil, "opencode service returned invalid JSON")
      return
    end

    deliver(data, nil)
  end

  local function attempt(may_start)
    if cancelled then
      return
    end

    local endpoint, endpoint_error = M.read_endpoint()

    local function start_then_retry(err)
      if not may_start then
        deliver(nil, err)
        return
      end

      abort = start_service(function(start_error)
        if start_error then
          deliver(nil, start_error)
        else
          attempt(false)
        end
      end)
    end

    if not endpoint then
      start_then_retry(endpoint_error)
      return
    end

    abort = send(endpoint, method, path, body, function(response, err, connect_failed)
      if cancelled then
        return
      end

      if connect_failed then
        start_then_retry(err)
      else
        handle_response(response, err)
      end
    end)
  end

  attempt(true)

  return {
    cancel = function()
      cancelled = true
      abort()
    end,
  }
end

return M
