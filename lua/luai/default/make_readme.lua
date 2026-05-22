return setmetatable({
	history = [==[ [
  {
    "description": "The function should also make sure to:\nMake a readme file in the buffer that is active. Look for content in the current codebase. Don't override but complete.",
    "implementation": "return function(opts)\n  -- gather codebase context, then ask Claude to complete the README without overwriting\n  local buf = vim.api.nvim_get_current_buf()\n  local existing = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), \"\\n\"))\n\n  local root = vim.fs.root(buf, { \"package.json\", \"Cargo.toml\", \"pyproject.toml\", \"go.mod\", \"composer.json\", \".git\" })\n    or vim.uv.cwd()\n\n  local ctx = {}\n  for _, fname in ipairs { \"package.json\", \"Cargo.toml\", \"pyproject.toml\", \"go.mod\", \"composer.json\", \"setup.py\" } do\n    local fpath = vim.fs.joinpath(root, fname)\n    if vim.uv.fs_stat(fpath) then\n      local lines = vim.fn.readfile(fpath)\n      ctx[#ctx + 1] = \"--- \" .. fname .. \" ---\\n\" .. table.concat(vim.list_slice(lines, 1, math.min(#lines, 60)), \"\\n\")\n    end\n  end\n\n  local dirs = {}\n  for name, ftype in vim.fs.dir(root) do\n    if ftype == \"directory\" and not name:match(\"^%.\") and name ~= \"node_modules\" and name ~= \"vendor\" then\n      dirs[#dirs + 1] = name .. \"/\"\n    end\n  end\n  if #dirs > 0 then\n    ctx[#ctx + 1] = \"top-level dirs: \" .. table.concat(dirs, \"  \")\n  end\n\n  local codebase_ctx = #ctx > 0 and table.concat(ctx, \"\\n\\n\") or \"(no metadata found)\"\n\n  local instruction = existing ~= \"\"\n    and (\"Existing README content — preserve every existing section exactly, only append or fill in missing parts:\\n\" .. existing)\n    or \"No README yet. Write a complete README from scratch.\"\n\n  local prompt = \"Write a README.md for this project. Output raw markdown only, no surrounding code fences.\\n\\n\"\n    .. instruction .. \"\\n\\nProject codebase context:\\n\" .. codebase_ctx\n\n  vim.notify(\"[make_readme] Generating README…\", vim.log.levels.INFO)\n\n  local ok, luai = pcall(require, \"luai\")\n  if not ok then\n    vim.notify(\"[make_readme] luai not available: \" .. luai, vim.log.levels.ERROR)\n    return\n  end\n\n  local rok, response = pcall(luai._dispatch_to_provider, prompt, opts or {})\n  if not rok then\n    vim.notify(\"[make_readme] \" .. tostring(response), vim.log.levels.ERROR)\n    return\n  end\n\n  local content = vim.trim(response)\n  content = content:gsub(\"^```markdown%s*\\n\", \"\"):gsub(\"^```%s*\\n\", \"\"):gsub(\"\\n```%s*$\", \"\")\n\n  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, \"\\n\"))\n  vim.bo[buf].filetype = \"markdown\"\n  vim.notify(\"[make_readme] Done.\", vim.log.levels.INFO)\nend",
    "option_example": [],
    "option_list": ""
  }
] ]==],
	implementation = function()
		return function(opts)
			-- gather codebase context, then ask Claude to complete the README without overwriting
			local buf = vim.api.nvim_get_current_buf()
			local existing = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))

			local root = vim.fs.root(
				buf,
				{ "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "composer.json", ".git" }
			) or vim.uv.cwd()

			local ctx = {}
			for _, fname in ipairs({
				"package.json",
				"Cargo.toml",
				"pyproject.toml",
				"go.mod",
				"composer.json",
				"setup.py",
			}) do
				local fpath = vim.fs.joinpath(root, fname)
				if vim.uv.fs_stat(fpath) then
					local lines = vim.fn.readfile(fpath)
					ctx[#ctx + 1] = "--- "
						.. fname
						.. " ---\n"
						.. table.concat(vim.list_slice(lines, 1, math.min(#lines, 60)), "\n")
				end
			end

			local dirs = {}
			for name, ftype in vim.fs.dir(root) do
				if ftype == "directory" and not name:match("^%.") and name ~= "node_modules" and name ~= "vendor" then
					dirs[#dirs + 1] = name .. "/"
				end
			end
			if #dirs > 0 then
				ctx[#ctx + 1] = "top-level dirs: " .. table.concat(dirs, "  ")
			end

			local codebase_ctx = #ctx > 0 and table.concat(ctx, "\n\n") or "(no metadata found)"

			local instruction = existing ~= ""
					and ("Existing README content — preserve every existing section exactly, only append or fill in missing parts:\n" .. existing)
				or "No README yet. Write a complete README from scratch."

			local prompt = "Write a README.md for this project. Output raw markdown only, no surrounding code fences.\n\n"
				.. instruction
				.. "\n\nProject codebase context:\n"
				.. codebase_ctx

			vim.notify("[make_readme] Generating README…", vim.log.levels.INFO)

			local ok, luai = pcall(require, "luai")
			if not ok then
				vim.notify("[make_readme] luai not available: " .. luai, vim.log.levels.ERROR)
				return
			end

			local rok, response = pcall(luai._dispatch_to_provider, prompt, opts or {})
			if not rok then
				vim.notify("[make_readme] " .. tostring(response), vim.log.levels.ERROR)
				return
			end

			local content = vim.trim(response)
			content = content:gsub("^```markdown%s*\n", ""):gsub("^```%s*\n", ""):gsub("\n```%s*$", "")

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
			vim.bo[buf].filetype = "markdown"
			vim.notify("[make_readme] Done.", vim.log.levels.INFO)
		end
	end,
}, {
	__call = function(self, ...)
		return self.implementation()(...)
	end,
})
