local function build_items()
  return {}
end

local function pick(_opts)
  error "luai telescope extension: pick not implemented yet"
end

return require("telescope").register_extension {
  exports = {
    run = pick,
    luai = pick,
  },
}
