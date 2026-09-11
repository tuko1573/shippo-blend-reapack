--[[
  sb_config.lua
  Shippo Blend Plugins — ExtState（REAPERの設定保存）の薄いラッパー。
  section は固定で "ShippoBlend"。REAPER呼び出しは含まない
  （get/set関数を注入する。テストは素のテーブルを使う。実機では
  reaper.GetExtState/SetExtState(section, key, val, true) を渡す — 第4引数trueで
  永続化＝reaper.iniに残る）。

  参照: 計画書/計画書.md 3-1節（sb_config.lua）。
--]]

local M = {}
M.SECTION = "ShippoBlend"

local KEYS = {
  "member_id", "display_name", "dropbox_override", "ai_choice",
  "last_sent_date", "last_hash", "startup_installed",
}

local AI_CHOICES = { chatgpt = true, claude = true, perplexity = true }

--- deps = { get(section, key) -> string, set(section, key, value) }
-- get/set が無ければインメモリのテーブルで代用する（テスト用途）。
function M.new(deps)
  deps = deps or {}
  local self = setmetatable({}, { __index = M })
  if deps.get and deps.set then
    self.deps = deps
  else
    -- インメモリのフォールバック（実機ではExtStateを渡すこと）。
    local store = {}
    self.deps = {
      get = function(_section, key) return store[key] end,
      set = function(_section, key, value) store[key] = value end,
    }
  end
  return self
end

function M:get(key)
  local v = self.deps.get(M.SECTION, key)
  if v == nil or v == "" then return nil end
  return v
end

function M:set(key, value)
  self.deps.set(M.SECTION, key, value or "")
end

-- ============================================================
-- member_id の検証
-- ============================================================

--- 半角英数・アンダースコアのみ、1〜16文字。
function M.valid_member_id(id)
  return type(id) == "string" and id:match("^[a-z0-9_]+$") ~= nil and #id >= 1 and #id <= 16
end

-- ============================================================
-- 各項目の get/set（型のある読み書き）
-- ============================================================

function M:get_member_id() return self:get("member_id") end

--- 検証NGなら書き込まず false, err を返す。
function M:set_member_id(id)
  if not M.valid_member_id(id) then
    return false, "member_idは半角英数字とアンダースコアのみ、1〜16文字"
  end
  self:set("member_id", id)
  return true
end

function M:get_display_name() return self:get("display_name") end
function M:set_display_name(name) self:set("display_name", name) end

function M:get_dropbox_override() return self:get("dropbox_override") end
function M:set_dropbox_override(path)
  -- 貼り付けの引用符・空白・末尾区切りを落としてから保存する（入口が複数あるのでここで必ず通す）
  self:set("dropbox_override", require("sb_store").normalize_pasted_path(path))
end

function M:get_ai_choice() return self:get("ai_choice") or "chatgpt" end

function M:set_ai_choice(choice)
  if not AI_CHOICES[choice] then
    return false, "ai_choiceは chatgpt|claude|perplexity のいずれか"
  end
  self:set("ai_choice", choice)
  return true
end

function M:get_last_sent_date() return self:get("last_sent_date") end
function M:set_last_sent_date(date) self:set("last_sent_date", date) end

function M:get_last_hash() return self:get("last_hash") end
function M:set_last_hash(hash) self:set("last_hash", hash) end

function M:get_startup_installed()
  return self:get("startup_installed") == "1"
end

function M:set_startup_installed(installed)
  self:set("startup_installed", installed and "1" or "0")
end

--- 一度に全部読む（無ければnil）。UIの設定タブ初期表示用。
function M:read_all()
  local out = {}
  for _, key in ipairs(KEYS) do
    out[key] = self:get(key)
  end
  return out
end

return M
