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

  return M.cli {
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
end

---@param spec { model: string }
---@return luai.Provider
function M.claude_code(spec)
  assert(spec and type(spec.model) == "string", "luai.providers.claude_code: `model` is required")

  return M.cli {
    name = "claude_code",
    cmd = function(prompt, opts)
      local model = opts.__model or spec.model
      return {
        "claude",
        "-p",
        "--output-format", "json",
        "--model", model,
        prompt,
      }
    end,
    parse_response = json_result "claude_code",
  }
end

return M
