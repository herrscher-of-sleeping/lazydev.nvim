local Config = require("lazydev.config")
local Lsp = require("lazydev.lsp")
local Pkg = require("lazydev.pkg")
local Workspace = require("lazydev.workspace")

local M = {}

---@type table<number,number>
M.attached = {}

---@type table<string, vim.loader.ModuleInfo|false>
M.modules = {}

function M.setup()
  M.add(Config.runtime)
  for _, lib in pairs(Config.library) do
    M.add(lib)
  end

  -- debounce updates
  local update = vim.schedule_wrap(M.update)
  local timer = assert(vim.uv.new_timer())
  M.update = function()
    timer:start(100, 0, update)
  end

  local group = vim.api.nvim_create_augroup("lazydev", { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and client.name == "lua_ls" then
        M.on_attach(client, ev.buf)
      end
    end,
  })

  -- Attach to all existing clients
  for _, client in ipairs(M.get_clients()) do
    for buf in pairs(client.attached_buffers) do
      M.on_attach(client, buf)
    end
  end

  -- Check for library changes
  M.update()
end

--- Will add the path to the library list
--- if it is not already included.
--- Automatically appends "/lua" if it exists.
---@param path string
function M.add(path)
  path = vim.fs.normalize(path)
  -- try to resolve to a plugin path
  if path:sub(1, 1) ~= "/" and not vim.uv.fs_stat(path) then
    local name, extra = path:match("([^/]+)(/?.*)")
    if name then
      local pp = Pkg.get_plugin_path(name)
      path = pp and (pp .. extra) or path
    end
  end
  -- append /lua if it exists
  if not path:find("/lua/?$") and vim.uv.fs_stat(path .. "/lua") then
    path = path .. "/lua"
  end
  Workspace:global():add(path)
end

--- Gets all LuaLS clients that are enabled
function M.get_clients()
  return vim.lsp.get_clients({ name = "lua_ls" })
end

---@param client vim.lsp.Client
function M.on_attach(client, buf)
  local root = Workspace.get_root(client, buf)
  if not Config.is_enabled(root) then
    return
  end
  if M.attached[buf] then
    return
  end
  M.attached[buf] = buf
  -- Attach to buffer events
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, _, last)
      M.on_lines(b, first, last)
    end,
    on_detach = function()
      M.attached[buf] = nil
    end,
    on_reload = function()
      M.on_lines(buf, 0, vim.api.nvim_buf_line_count(buf))
    end,
  })
  -- Trigger initial scan
  M.on_lines(buf, 0, vim.api.nvim_buf_line_count(buf))
  M.update()
end

--- Triggered when lines are changed
---@param buf number
---@param first number
---@param last number
function M.on_lines(buf, first, last)
  local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
  for _, line in ipairs(lines) do
    local module = Pkg.get_module(line)
    if module then
      M.on_require(buf, module)
    end
  end
end

--- Check if a module is available and add it to the library
---@param buf number
---@param modname string
function M.on_require(buf, modname)
  local mod = M.modules[modname]

  if mod == nil then
    mod = vim.loader.find(modname)[1]
    if not mod then
      local paths = Pkg.get_unloaded(modname)
      mod = vim.loader.find(modname, { rtp = false, paths = paths })[1]
    end
    M.modules[modname] = mod or false
  end

  if mod then
    local lua = mod.modpath:find("/lua/", 1, true)
    local path = lua and mod.modpath:sub(1, lua + 3) or mod.modpath
    if path and Workspace.find(buf):add(path) then
      M.update()
    end
  end
end

--- Update LuaLS settings with the current library
function M.update()
  if package.loaded["neodev"] then
    vim.notify_once(
      "Please disable `neodev.nvim` in your config.\nThis is no longer needed when you use `lazydev.nvim`",
      vim.log.levels.WARN
    )
  end
  for _, client in ipairs(M.get_clients()) do
    local update = false
    for _, ws in ipairs(client.workspace_folders) do
      local w = Workspace.get(client.id, ws.name)
      if Config.is_enabled(w.root) and w:update() then
        update = true
      end
    end
    if update then
      Lsp.attach(client)
      Lsp.update(client)
    end
  end
end

return M
