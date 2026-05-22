return setmetatable({
  history = [==[ [
  {
    "description": "The function should also make sure to:\nGenerate a barebone readme file with mostly used titles",
    "implementation": "return function(opts)\n  -- Common README sections for most open source / internal projects\n  local sections = {\n    \"# Project Name\",\n    \"\",\n    \"> Short description of what this project does.\",\n    \"\",\n    \"## Table of Contents\",\n    \"\",\n    \"- [Requirements](#requirements)\",\n    \"- [Installation](#installation)\",\n    \"- [Usage](#usage)\",\n    \"- [Configuration](#configuration)\",\n    \"- [Contributing](#contributing)\",\n    \"- [License](#license)\",\n    \"\",\n    \"## Requirements\",\n    \"\",\n    \"\",\n    \"## Installation\",\n    \"\",\n    \"\",\n    \"## Usage\",\n    \"\",\n    \"\",\n    \"## Configuration\",\n    \"\",\n    \"\",\n    \"## Contributing\",\n    \"\",\n    \"\",\n    \"## License\",\n    \"\",\n    \"MIT\",\n  }\n\n  local cwd = vim.uv.cwd()\n  local path = cwd .. \"/README.md\"\n\n  if vim.uv.fs_stat(path) then\n    vim.notify(\"README.md already exists\", vim.log.levels.WARN)\n    return\n  end\n\n  vim.cmd(\"edit \" .. vim.fn.fnameescape(path))\n  local buf = vim.api.nvim_get_current_buf()\n  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sections)\n  vim.cmd(\"write\")\n  vim.notify(\"README.md created\", vim.log.levels.INFO)\nend",
    "option_example": [],
    "option_list": ""
  }
] ]==],
  implementation = function()
return function(opts)
  -- Common README sections for most open source / internal projects
  local sections = {
    "# Project Name",
    "",
    "> Short description of what this project does.",
    "",
    "## Table of Contents",
    "",
    "- [Requirements](#requirements)",
    "- [Installation](#installation)",
    "- [Usage](#usage)",
    "- [Configuration](#configuration)",
    "- [Contributing](#contributing)",
    "- [License](#license)",
    "",
    "## Requirements",
    "",
    "",
    "## Installation",
    "",
    "",
    "## Usage",
    "",
    "",
    "## Configuration",
    "",
    "",
    "## Contributing",
    "",
    "",
    "## License",
    "",
    "MIT",
  }

  local cwd = vim.uv.cwd()
  local path = cwd .. "/README.md"

  if vim.uv.fs_stat(path) then
    vim.notify("README.md already exists", vim.log.levels.WARN)
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sections)
  vim.cmd("write")
  vim.notify("README.md created", vim.log.levels.INFO)
end
  end,
}, { __call = function(self, ...) return self.implementation()(...) end })

