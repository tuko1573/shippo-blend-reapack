--[[
  sb_store.lua
  Shippo Blend Plugins — Dropbox共有フォルダの場所探し・読み書き。
  REAPER呼び出しは含まない。io/os/reaper に相当する操作はすべて deps として注入する
  （テストではモックを渡す。REAPER内では ShippoBlend_SendNow.lua が本物のreaper APIから
  deps を組み立てる）。

  参照: 計画書/計画書.md 3-2節（共有フォルダの中身）。

  deps = {
    getenv(name) -> string|nil,
    file_exists(path) -> bool,
    enumerate_files(dir) -> {name, ...}  -- ディレクトリ内のファイル名一覧
    read_file(path) -> string|nil,
    write_file(path, text) -> bool,
    rename(old, new) -> bool,
    remove(path) -> bool,               -- 無くても失敗として扱わない
    mkdir_p(path) -> bool,
    os_name = "macOS-arm64" | "Win64" | ...,
    now_iso() -> "YYYY-MM-DDTHH:MM:SSZ",
    log(msg),
  }
--]]

local sb_json = require("sb_json")

local M = {}
M.SCHEMA = 1

-- ファイル名として受け付けるもの（Dropboxの「競合コピー」や .sbtmp を自動で除外する）。
local NAME_PATTERN = "^[a-z0-9_]+%.json$"
M.NAME_PATTERN = NAME_PATTERN

-- ============================================================
-- 生成
-- ============================================================

function M.new(deps)
  deps = deps or {}
  local self = setmetatable({}, { __index = M })
  self.deps = deps
  return self
end

--- OSごとのパス区切り。Win64 / Windows で始まるもの以外は "/"。
function M.sep_for(os_name)
  if os_name and os_name:match("^Win") then return "\\" end
  return "/"
end

function M:sep()
  return M.sep_for(self.deps.os_name)
end

local function log(self, msg)
  if self.deps.log then self.deps.log(msg) end
end

local function json_decode_file(self, path)
  local deps = self.deps
  local text = deps.read_file(path)
  if not text then return nil, "read_file failed" end
  local ok, doc = pcall(sb_json.decode, text)
  if not ok then return nil, "json decode failed: " .. tostring(doc) end
  if type(doc) ~= "table" then return nil, "json is not an object" end
  return doc
end

-- ============================================================
-- Dropbox の場所探し
-- ============================================================

--- override（ExtStateなどから渡された明示指定）→ mac info.json → Windows info.json の順。
-- @return path|nil, source|nil  ("override" | "mac_info_json" | "win_localappdata" | "win_appdata")
function M:locate_dropbox(override)
  local deps = self.deps

  if override and override ~= "" then
    return override, "override"
  end

  -- mac: ~/.dropbox/info.json
  local home = deps.getenv and deps.getenv("HOME")
  if home and home ~= "" then
    local info_path = home .. "/.dropbox/info.json"
    if deps.file_exists and deps.file_exists(info_path) then
      local doc, err = json_decode_file(self, info_path)
      if doc then
        local path = (doc.personal and doc.personal.path) or (doc.business and doc.business.path)
        if path and path ~= "" then
          return path, "mac_info_json"
        end
      else
        log(self, "sb_store: info.json 読み取り失敗 (" .. info_path .. "): " .. tostring(err))
      end
    end
  end

  -- Windows: %LOCALAPPDATA%\Dropbox\info.json → %APPDATA%\Dropbox\info.json
  local win_candidates = {
    { base = deps.getenv and deps.getenv("LOCALAPPDATA"), source = "win_localappdata" },
    { base = deps.getenv and deps.getenv("APPDATA"), source = "win_appdata" },
  }
  for _, c in ipairs(win_candidates) do
    if c.base and c.base ~= "" then
      local info_path = c.base .. "\\Dropbox\\info.json"
      if deps.file_exists and deps.file_exists(info_path) then
        local doc, err = json_decode_file(self, info_path)
        if doc then
          local path = (doc.personal and doc.personal.path) or (doc.business and doc.business.path)
          if path and path ~= "" then
            return path, c.source
          end
        else
          log(self, "sb_store: info.json 読み取り失敗 (" .. info_path .. "): " .. tostring(err))
        end
      end
    end
  end

  return nil, nil
end

-- ============================================================
-- ルートとディレクトリ
-- ============================================================

function M:root(dropbox_path)
  local sep = self:sep()
  return dropbox_path .. sep .. "Shippo Blend" .. sep .. "plugins" .. sep .. "v1"
end

function M:ensure_dirs(root)
  local sep = self:sep()
  local deps = self.deps
  if not deps.mkdir_p then return end
  deps.mkdir_p(root)
  deps.mkdir_p(root .. sep .. "members")
  deps.mkdir_p(root .. sep .. "links")
  deps.mkdir_p(root .. sep .. "aliases")
  deps.mkdir_p(root .. sep .. "hides")
end

-- ============================================================
-- 一時ファイル→rename の原子的書き込み
-- ============================================================

function M:_atomic_write(dir_path, filename, text)
  local deps = self.deps
  local sep = self:sep()
  local final_path = dir_path .. sep .. filename
  local tmp_path = final_path .. ".sbtmp"

  -- 置き場のフォルダが無ければ作る（古い版で作った v1 には hides/ が無い、など）
  if deps.mkdir_p then deps.mkdir_p(dir_path) end
  if not deps.write_file(tmp_path, text) then
    return false, "write_file 失敗: " .. tmp_path
  end
  if deps.file_exists and deps.file_exists(final_path) and deps.remove then
    deps.remove(final_path)
  end
  if not deps.rename(tmp_path, final_path) then
    return false, "rename 失敗: " .. tmp_path .. " -> " .. final_path
  end
  return true
end

-- ============================================================
-- メンバーJSON: 安定した並び（ハッシュ再現性のため）
-- ============================================================

--- plugins を key 順、各 plugin の formats を fmt 順に並べ替えた「浅いコピー」を返す。
-- 元の doc は変更しない。
function M.sort_member_doc(doc)
  local out = {}
  for k, v in pairs(doc) do out[k] = v end

  local plugins = {}
  for i, p in ipairs(doc.plugins or {}) do plugins[i] = p end
  table.sort(plugins, function(a, b) return (a.key or "") < (b.key or "") end)

  local plugins2 = {}
  for i, p in ipairs(plugins) do
    local formats = {}
    for j, f in ipairs(p.formats or {}) do formats[j] = f end
    table.sort(formats, function(a, b) return (a.fmt or "") < (b.fmt or "") end)

    local p2 = {}
    for k, v in pairs(p) do p2[k] = v end
    p2.formats = formats
    plugins2[i] = p2
  end
  out.plugins = plugins2
  return out
end

-- ============================================================
-- ハッシュ（一覧の変化検出用）: FNV-1a 32-bit（純Lua、整数ビット演算）
-- ============================================================

--- idents（生の識別子の並び）から、ソート済み・改行区切りにした文字列のFNV-1aを取る。
-- @return 8桁hex文字列
function M.hash_idents(idents)
  local sorted = {}
  for i, v in ipairs(idents or {}) do sorted[i] = v or "" end
  table.sort(sorted)
  local joined = table.concat(sorted, "\n")

  local h = 2166136261 -- FNV offset basis (32-bit)
  for i = 1, #joined do
    h = h ~ joined:byte(i)
    h = (h * 16777619) & 0xFFFFFFFF
  end
  return string.format("%08x", h)
end

--- member doc の plugins[].formats[].ident を集めてハッシュを取る便利関数。
function M.hash_member_doc(doc)
  local idents = {}
  for _, p in ipairs(doc.plugins or {}) do
    for _, f in ipairs(p.formats or {}) do
      idents[#idents + 1] = f.ident or ""
    end
  end
  return M.hash_idents(idents)
end

-- ============================================================
-- members / links / aliases / hides の書き込み
-- ============================================================

--- doc は 計画書 3-2 のスキーマ（member_id を含む）。
function M:write_member(root, doc)
  if not doc or not doc.member_id or doc.member_id == "" then
    return false, "member_id が無い"
  end
  local sorted = M.sort_member_doc(doc)
  local ok, text = pcall(sb_json.encode, sorted)
  if not ok then return false, "json encode失敗: " .. tostring(text) end
  local sep = self:sep()
  return self:_atomic_write(root .. sep .. "members", doc.member_id .. ".json", text)
end

function M:write_links(root, member_id, tbl)
  if not member_id or member_id == "" then return false, "member_id が無い" end
  local ok, text = pcall(sb_json.encode, tbl)
  if not ok then return false, "json encode失敗: " .. tostring(text) end
  local sep = self:sep()
  return self:_atomic_write(root .. sep .. "links", member_id .. ".json", text)
end

function M:write_aliases(root, member_id, tbl)
  if not member_id or member_id == "" then return false, "member_id が無い" end
  local ok, text = pcall(sb_json.encode, tbl)
  if not ok then return false, "json encode失敗: " .. tostring(text) end
  local sep = self:sep()
  return self:_atomic_write(root .. sep .. "aliases", member_id .. ".json", text)
end

--- 非表示（検索タブの一覧から全員分まとめて消す）。中身は
-- { schema=1, member_id, updated_at, entries = { [key] = {hidden, updated_at, by} } }。
function M:write_hides(root, member_id, tbl)
  if not member_id or member_id == "" then return false, "member_id が無い" end
  local ok, text = pcall(sb_json.encode, tbl)
  if not ok then return false, "json encode失敗: " .. tostring(text) end
  local sep = self:sep()
  return self:_atomic_write(root .. sep .. "hides", member_id .. ".json", text)
end

-- ============================================================
-- members / links / aliases / hides の読み込み
-- ============================================================

function M:_list_files(dir_path)
  local deps = self.deps
  if not deps.enumerate_files then return {} end
  return deps.enumerate_files(dir_path) or {}
end

--- subdir（"members"|"links"|"aliases"|"hides"）配下の *.json を読む。
-- ファイル名は ^[a-z0-9_]+%.json$ のみ採用（Dropboxの競合コピー・.sbtmpは自動で無視）。
-- 壊れたJSONは pcall で捕まえて log() し、スキップする（1件の破損で全体を止めない）。
function M:_read_collection(root, subdir)
  local sep = self:sep()
  local dir_path = root .. sep .. subdir
  local names = self:_list_files(dir_path)
  local out = {}
  for _, name in ipairs(names) do
    if type(name) == "string" and name:match(NAME_PATTERN) then
      local doc, err = json_decode_file(self, dir_path .. sep .. name)
      if doc then
        out[#out + 1] = doc
      else
        log(self, "sb_store: " .. subdir .. "/" .. name .. " を読み飛ばした: " .. tostring(err))
      end
    end
  end
  return out
end

function M:read_members(root) return self:_read_collection(root, "members") end
function M:read_links(root) return self:_read_collection(root, "links") end
function M:read_aliases(root) return self:_read_collection(root, "aliases") end
function M:read_hides(root) return self:_read_collection(root, "hides") end

return M
