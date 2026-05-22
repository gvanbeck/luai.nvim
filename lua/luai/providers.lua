---@alias luai.Provider fun(prompt: string, opts: table): string

local M = {}

local function json_result(provider_name)
  return function(stdout, _stderr, _code)
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok then
      error(string.format("[luai] %s: invalid JSON response:\n%s", provider_name, stdout))
    end
    if type(decoded) ~= "table" or type(decoded.result) ~= "string" then
      error(string.format("[luai] %s: JSON did not contain a string `result` field:\n%s", provider_name, stdout))
    end
    return decoded.result
  end
end

local function make_stream_json_parser(user_on_chunk)
  local pending = ""
  local final_result

  local function process_line(line)
    if line == "" then return end
    local ok, event = pcall(vim.json.decode, line)
    if not ok or type(event) ~= "table" then
      vim.notify(string.format("[luai] stream-json: skipping malformed line: %s", line), vim.log.levels.WARN)
      return
    end

    if event.type == "assistant" and type(event.message) == "table" and type(event.message.content) == "table" then
      for _, content in ipairs(event.message.content) do
        if type(content) == "table" and content.type == "text" and type(content.text) == "string" then
          user_on_chunk(content.text)
        end
      end
    elseif event.type == "result" and type(event.result) == "string" then
      final_result = event.result
    end
  end

  local function consume(raw_chunk)
    pending = pending .. raw_chunk
    while true do
      local nl = pending:find "\n"
      if not nl then break end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      process_line(line)
    end
  end

  local function finalize()
    -- Flush any unterminated trailing line without re-processing what consume
    -- already handled during streaming.
    if pending ~= "" then
      process_line(pending)
      pending = ""
    end
    if final_result == nil then
      error "[luai] claude_code: no result event in stream-json output"
    end
    return final_result
  end

  return {
    consume = consume,
    finalize = finalize,
  }
end

---@param spec { name: string, cmd: string[]|fun(prompt: string, opts: table): string[], parse_response?: fun(stdout: string, stderr: string, exit_code: integer): string, env?: table }
---@return luai.Provider
function M.cli(spec)
  assert(spec and type(spec.name) == "string", "luai.providers.cli: `name` is required")
  assert(spec and spec.cmd, "luai.providers.cli: `cmd` is required")

  return function(prompt, opts)
    local argv = type(spec.cmd) == "function" and spec.cmd(prompt, opts) or spec.cmd
    assert(type(argv) == "table" and argv[1], "luai.providers.cli: cmd must produce a non-empty argv list")

    if vim.fn.executable(argv[1]) ~= 1 then
      error(string.format("[luai] %s: command not on PATH: %s", spec.name, argv[1]))
    end

    local on_chunk = opts.__on_chunk
    local stdout, stderr, code

    if on_chunk then
      local stdout_chunks = {}
      local stderr_chunks = {}
      local done = false

      local sys = vim.system(argv, {
        text = true,
        env = spec.env,
        stdout = function(_, chunk)
          if chunk then
            table.insert(stdout_chunks, chunk)
            vim.schedule(function() on_chunk(chunk) end)
          end
        end,
        stderr = function(_, chunk)
          if chunk then table.insert(stderr_chunks, chunk) end
        end,
      }, function(result)
        code = result.code
        done = true
      end)

      local ok = vim.wait(300000, function() return done end, 50)
      if not ok then
        pcall(function() sys:kill(15) end)
        error(string.format("[luai] %s: generation timed out after 5m", spec.name))
      end

      stdout = table.concat(stdout_chunks)
      stderr = table.concat(stderr_chunks)
    else
      local result = vim.system(argv, { text = true, env = spec.env }):wait()
      stdout = result.stdout or ""
      stderr = result.stderr or ""
      code = result.code
    end

    if code ~= 0 then
      local trimmed_err = vim.trim(stderr)
      local trimmed_out = vim.trim(stdout)
      local details = trimmed_err ~= "" and trimmed_err or trimmed_out
      if details == "" then
        details = "exit code " .. tostring(code)
      end
      error(string.format("[luai] %s failed: %s", spec.name, details))
    end

    if spec.parse_response then
      return spec.parse_response(stdout, stderr, code)
    end

    return stdout
  end
end

---@param spec { model: string }
---@return luai.Provider
function M.cursor_agent(spec)
  assert(spec and type(spec.model) == "string", "luai.providers.cursor_agent: `model` is required")

  local provider = M.cli {
    name = "cursor_agent",
    cmd = function(prompt, opts)
      local model = opts.__model or spec.model
      local workspace = vim.uv.cwd() or vim.fn.getcwd()
      return {
        "agent",
        "-p",
        "--mode", "ask",
        "--output-format", "json",
        "--model", model,
        "--trust",
        "--workspace", workspace,
        prompt,
      }
    end,
    parse_response = json_result "cursor_agent",
  }

  -- cursor_agent does not support streaming in v1; drop __on_chunk so cli
  -- falls into the sync :wait() branch instead of streaming raw JSON to the
  -- caller's window.
  return function(prompt, opts)
    if opts.__on_chunk ~= nil then
      local clean_opts = {}
      for k, v in pairs(opts) do
        if k ~= "__on_chunk" then clean_opts[k] = v end
      end
      opts = clean_opts
    end
    return provider(prompt, opts)
  end
end

---@param spec { model: string }
---@return luai.Provider
function M.claude_code(spec)
  assert(spec and type(spec.model) == "string", "luai.providers.claude_code: `model` is required")

  return function(prompt, opts)
    local user_on_chunk = opts.__on_chunk
    local stream = user_on_chunk and make_stream_json_parser(user_on_chunk) or nil

    local provider = M.cli {
      name = "claude_code",
      cmd = function(_prompt, _opts)
        local model = _opts.__model or spec.model
        if stream then
          return {
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            _prompt,
          }
        end
        return {
          "claude",
          "-p",
          "--output-format", "json",
          "--model", model,
          _prompt,
        }
      end,
      parse_response = function(stdout, stderr, code)
        if stream then
          return stream.finalize()
        end
        return json_result "claude_code"(stdout, stderr, code)
      end,
    }

    local call_opts = opts
    if stream then
      call_opts = vim.tbl_extend("force", opts, { __on_chunk = stream.consume })
    end

    return provider(prompt, call_opts)
  end
end

return M
