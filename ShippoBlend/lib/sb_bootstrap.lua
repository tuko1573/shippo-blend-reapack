--[[
  sb_bootstrap.lua
  Shippo Blend Plugins — 2つの入口スクリプト（ShippoBlend_SendNow.lua と
  ShippoBlend_Plugins.lua）が共通で必要とする「起動のお膳立て」。
  ここだけが reaper の一般APIを触る（ImGuiは触らない）。

  中身:
    - ログ（<REAPERリソース>/ShippoBlend.log、末尾200行だけ残す）
    - sb_store 用の deps（ファイル読み書き・列挙・時刻）を実機reaperから組み立てる
    - sb_config（ExtState）の生成
    - 初回設定（メンバーID・表示名）の確認
    - Dropboxの場所の確認（見つからなければ貼り付けを聞く。聞かない選択もできる）

  参照: 計画書/計画書.md 3-1/3-2節。
--]]

local sb_store = require("sb_store")
local sb_config = require("sb_config")

local M = {}

M.LOG_MAX_LINES = 200

-- ============================================================
-- ログ
-- ============================================================

function M.resource_path()
  return reaper.GetResourcePath()
end

function M.log_path()
  return M.resource_path() .. "/ShippoBlend.log"
end

--- ログに1行足す。末尾 LOG_MAX_LINES 行だけ残す（無限に太らせない）。
function M.log(msg)
  local path = M.log_path()
  local line = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(msg)
  local lines = {}
  local f = io.open(path, "rb")
  if f then
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
  end
  lines[#lines + 1] = line
  local start = math.max(1, #lines - M.LOG_MAX_LINES + 1)
  local out = io.open(path, "wb")
  if out then
    for i = start, #lines do out:write(lines[i], "\n") end
    out:close()
  end
end

--- ログの最後の1行（設定タブの「今すぐ更新」の結果表示用）。
function M.log_last_line()
  local f = io.open(M.log_path(), "rb")
  if not f then return nil end
  local last = nil
  for l in f:lines() do if l ~= "" then last = l end end
  f:close()
  return last
end

-- ============================================================
-- sb_store 用の deps
-- ============================================================

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

function M.build_deps(log_fn)
  log_fn = log_fn or M.log
  return {
    os_name = reaper.GetOS(),
    getenv = os.getenv,
    file_exists = reaper.file_exists,
    enumerate_files = function(dir)
      local names = {}
      reaper.EnumerateFiles(dir, -1) -- キャッシュを無効化してから読む
      local i = 0
      while true do
        local name = reaper.EnumerateFiles(dir, i)
        if not name then break end
        names[#names + 1] = name
        i = i + 1
      end
      return names
    end,
    read_file = M.read_file,
    write_file = M.write_file,
    rename = os.rename,
    remove = os.remove,
    mkdir_p = function(path) reaper.RecursiveCreateDirectory(path, 0) end,
    now_iso = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    log = log_fn,
  }
end

function M.now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- ============================================================
-- 設定（ExtState）
-- ============================================================

function M.new_config()
  return sb_config.new({
    get = function(section, key) return reaper.GetExtState(section, key) end,
    set = function(section, key, value) reaper.SetExtState(section, key, value, true) end,
  })
end

function M.new_store(log_fn)
  return sb_store.new(M.build_deps(log_fn))
end

-- ============================================================
-- 初回設定: member_id / display_name
-- ============================================================

--- 未設定なら reaper.GetUserInputs で1回だけ聞く。
-- @return true（設定済み or 今設定した） / false（キャンセル・不正）
function M.ensure_member_identity(config, log_fn)
  log_fn = log_fn or M.log
  if config:get_member_id() and config:get_display_name() then return true end

  local ok, csv = reaper.GetUserInputs(
    "Shippo Blend 初回設定", 2, "メンバーID（半角英数）,表示名", "")
  if not ok then
    log_fn("初回設定がキャンセルされた")
    return false
  end
  local id, display_name = csv:match("^([^,]*),(.*)$")
  id = (id or ""):gsub("^%s+", ""):gsub("%s+$", "")
  display_name = (display_name or ""):gsub("^%s+", ""):gsub("%s+$", "")

  local set_ok, err = config:set_member_id(id)
  if not set_ok then
    log_fn("member_idが不正: " .. tostring(err))
    return false
  end
  if display_name == "" then display_name = id end
  config:set_display_name(display_name)
  return true
end

-- ============================================================
-- Dropboxの場所
-- ============================================================

--- @param opts { prompt = bool }  prompt=false なら見つからなくても聞かずに nil を返す
--   （小窓は設定タブを開いて案内する。SendNowは聞く）。
-- @return path|nil, source|nil
function M.ensure_dropbox_path(store, config, log_fn, opts)
  opts = opts or {}
  log_fn = log_fn or M.log
  local override = config:get_dropbox_override()
  local path, source = store:locate_dropbox(override)
  if path then return path, source end

  if opts.prompt == false then
    log_fn("Dropboxが見つからない（設定タブで指定が必要）")
    return nil, nil
  end

  local ok, pasted = reaper.GetUserInputs(
    "Shippo Blend: Dropboxの場所", 1, "Dropboxフォルダのパスを貼り付け", "")
  if not ok or pasted == "" then
    log_fn("Dropboxパスが見つからず、入力もキャンセルされた")
    return nil, nil
  end
  config:set_dropbox_override(pasted)
  return store:locate_dropbox(pasted)
end

return M
