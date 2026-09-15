--[[
  ShippoBlend_SendNow.lua
  Shippo Blend Plugins — 自分のプラグイン一覧を集めてDropboxへ書く。画面は出さない
  （初回だけ reaper.GetUserInputs でメンバーIDとDropboxパスを聞く）。
  起動時（__startup.lua、Phase 5）と「今すぐ更新」ボタン（Phase 3）の両方から呼ぶ想定。

  実行前に `SHIPPOBLEND_FORCE = true` をグローバルに立てると、今日すでに送っていても
  スロットル（1日1回）を無視して送る（「今すぐ更新」ボタン用）。

  参照: 計画書/計画書.md 3-2/3-4節、5章Phase2。
  このファイルはFableの指示で「書くだけ・実行しない」（REAPERは起動しない）。
  実機での動作確認はPhase 2の受け入れ（つこさんのREAPERセッション）で行う。
--]]

-- ============================================================
-- lib/ の場所を自分のパスから解決する
-- ============================================================

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local LIB_DIR = this_dir() .. "/lib"
package.path = LIB_DIR .. "/?.lua;" .. package.path

local sb_bootstrap = require("sb_bootstrap")
local sb_store = require("sb_store")
local sb_collector = require("sb_collector")
local sb_normalize = require("sb_normalize")
local sb_json = require("sb_json")

local RESOURCE_PATH = sb_bootstrap.resource_path()
local LOG_PATH = sb_bootstrap.log_path()

--- ログ（互換のためグローバル名も残す。実体は sb_bootstrap.log）。
function SB_SENDNOW_LOG(msg) sb_bootstrap.log(msg) end

local config = sb_bootstrap.new_config()

-- ============================================================
-- EnumInstalledFX の収集
-- ============================================================

local function collect_entries()
  local out = {}
  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    out[#out + 1] = { index = i, name = name, ident = ident }
    i = i + 1
  end
  return out
end

--- reaper-vstplugins_*.ini はOSごとにファイル名が違う。存在する方を読む。
local function read_vst_ini_text(deps)
  local candidates = {
    RESOURCE_PATH .. "/reaper-vstplugins_arm64.ini", -- macOS-arm64
    RESOURCE_PATH .. "/reaper-vstplugins64.ini",      -- Win64 / OSX64
  }
  for _, path in ipairs(candidates) do
    if deps.file_exists(path) then
      return deps.read_file(path)
    end
  end
  return nil
end

-- ============================================================
-- 既存メンバーファイルの unusable フラグを引き継ぐ
-- ============================================================

local function load_existing_unusable(store, root, member_id)
  local unusable_by_key = {}
  local text = store.deps.read_file(root .. store:sep() .. "members" .. store:sep() .. member_id .. ".json")
  if not text then return unusable_by_key end
  local ok, doc = pcall(sb_json.decode, text)
  if not ok or type(doc) ~= "table" then return unusable_by_key end
  for _, p in ipairs(doc.plugins or {}) do
    if p.unusable then unusable_by_key[p.key] = true end
  end
  return unusable_by_key
end

-- ============================================================
-- メイン
-- ============================================================

local function main()
  local deps = sb_bootstrap.build_deps(SB_SENDNOW_LOG)
  local store = sb_store.new(deps)

  -- 起動時（SHIPPOBLEND_QUIET）は、画面に何も出さない約束なので一切聞かない。
  -- 未設定なら黙って諦め、ログにだけ残す（判断5: 起動時の通知は出さない）。
  local quiet = (SHIPPOBLEND_QUIET == true)

  if not config:get_member_id() or not config:get_display_name() then
    if quiet then
      SB_SENDNOW_LOG("起動時の自動送信: 初回設定がまだなので中止（小窓を1回開いてください）")
      return
    end
    if not sb_bootstrap.ensure_member_identity(config, SB_SENDNOW_LOG) then return end
  end
  local member_id = config:get_member_id()
  local display_name = config:get_display_name()

  local dropbox_path, dropbox_source = sb_bootstrap.ensure_dropbox_path(
    store, config, SB_SENDNOW_LOG, { prompt = not quiet })
  -- Windowsでどの info.json が効いたかを必ず記録する（受け入れ表で読む）。
  SB_SENDNOW_LOG(("Dropboxの場所: %s（見つけ方=%s）")
    :format(tostring(dropbox_path), tostring(dropbox_source)))
  if not dropbox_path then
    SB_SENDNOW_LOG("Dropboxが見つからないため中止")
    return
  end

  local root = store:root(dropbox_path)
  store:ensure_dirs(root)

  -- スロットル: 今日すでに送っていれば、SHIPPOBLEND_FORCE が無い限り何もしない。
  local today = deps.now_iso():sub(1, 10)
  local force = (SHIPPOBLEND_FORCE == true)
  if not force and config:get_last_sent_date() == today then
    -- 起動時に一覧が揃っているかを後で比べられるよう、件数だけ数えて記録する
    local n = 0
    while reaper.EnumInstalledFX(n) do n = n + 1 end
    SB_SENDNOW_LOG(("今日はすでに送信済みなのでスキップ (member=%s, 一覧%d件)"):format(member_id, n))
    return
  end

  local entries = collect_entries()
  local ini_vst_text = read_vst_ini_text(deps)
  local inv = sb_collector.build_inventory(entries, { ini_vst = ini_vst_text })

  local unusable_by_key = load_existing_unusable(store, root, member_id)

  local plugins = {}
  for key, p in pairs(inv.plugins) do
    local class_id = nil
    for _, f in ipairs(p.formats) do
      if f.fmt == "VST3" and f.class_id and f.class_id ~= "" then class_id = f.class_id; break end
    end
    if not class_id then
      for _, f in ipairs(p.formats) do
        if f.class_id and f.class_id ~= "" then class_id = f.class_id; break end
      end
    end
    local formats = {}
    for _, f in ipairs(p.formats) do
      formats[#formats + 1] = { fmt = f.fmt, raw_name = f.raw_name, ident = f.ident }
    end
    plugins[#plugins + 1] = {
      key = key, name = p.name, vendor = p.vendor, instrument = p.instrument,
      unusable = unusable_by_key[key] == true,
      class_id = class_id, formats = formats,
    }
  end

  local doc = {
    schema = sb_store.SCHEMA,
    normalizer_version = sb_normalize.VERSION,
    member_id = member_id,
    display_name = display_name,
    os = deps.os_name,
    reaper = reaper.GetAppVersion(),
    updated_at = deps.now_iso(),
    inventory_hash = nil,
    plugins = plugins,
  }
  doc.inventory_hash = sb_store.hash_member_doc(doc)

  local same_as_before = (doc.inventory_hash == config:get_last_hash())
  local member_path = root .. store:sep() .. "members" .. store:sep() .. member_id .. ".json"

  if same_as_before and not force and deps.file_exists(member_path) then
    -- 前回と同じ一覧で、ファイルも既にある → 日付だけ更新して書かない
    config:set_last_sent_date(today)
    SB_SENDNOW_LOG("前回と同じ一覧なので書き込みなし (member=" .. member_id .. ")")
    SB_RESULT = { skipped = true, plugins = #plugins }
    return
  end

  local ok, err = store:write_member(root, doc)
  if not ok then
    SB_SENDNOW_LOG("write_member失敗: " .. tostring(err))
    SB_RESULT = { error = tostring(err) }
    return
  end
  SB_RESULT = { plugins = #plugins, path = member_path, changed = not same_as_before }

  config:set_last_sent_date(today)
  config:set_last_hash(doc.inventory_hash)

  SB_SENDNOW_LOG(string.format(
    "送信完了 member=%s plugins=%d hash=%s (前回から%s)",
    member_id, #plugins, doc.inventory_hash, same_as_before and "変化なし" or "変化あり"))
end

SB_RESULT = nil
local ok, err = pcall(main)
if not ok then
  SB_SENDNOW_LOG("エラー: " .. tostring(err))
  SB_RESULT = { error = tostring(err) }
end

-- 手で実行したときだけ結果を1つのダイアログで見せる（起動時は SHIPPOBLEND_QUIET = true で黙る）
if SHIPPOBLEND_QUIET ~= true then
  local r = SB_RESULT or {}
  local msg
  if r.error then
    msg = "失敗しました。\n\n" .. r.error .. "\n\nログ: " .. LOG_PATH
  elseif r.skipped then
    msg = ("前回と同じ一覧（%d件）なので書き込みませんでした。"):format(r.plugins or 0)
  elseif r.path then
    msg = ("書き込みました（%d件）。\n\n%s"):format(r.plugins or 0, r.path)
  else
    msg = "中止しました（初回設定またはDropboxの場所が未確定）。\n\nログ: " .. LOG_PATH
  end
  reaper.MB(msg, "Shippo Blend: 今すぐ更新", 0)
end

-- ============================================================
-- 日本語パッチの自動更新（起動時だけ。1日1回・画面は止めない）
-- ============================================================
-- ここは main() の外・いちばん最後。初回設定が済んでいなくても走らせたいので、
-- 上の処理がどう終わったかに関係なく実行する。失敗しても本体には影響させない。
if SHIPPOBLEND_QUIET == true then
  pcall(function()
    local sb_langpack = require("sb_langpack")
    -- reaper.defer で後から動くので、いまの「黙って動く」状態を値として渡す
    sb_langpack.run(
      sb_langpack.reaper_deps(sb_bootstrap.read_file, sb_bootstrap.write_file, SB_SENDNOW_LOG),
      { force = false, verbose = false })
  end)
end
