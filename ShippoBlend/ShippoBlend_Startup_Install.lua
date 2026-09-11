--[[
  ShippoBlend_Startup_Install.lua
  Shippo Blend Plugins — REAPER起動時の自動送信を登録する（アクションリストから実行）。

  何をするか: `<REAPERリソース>/Scripts/__startup.lua` に、印で挟んだ一塊を足すだけ。
  印の外側は触りません。外したいときは、小窓（ShippoBlend_Plugins）の設定タブの
  「解除」を押してください。

  参照: 計画書/計画書.md 3-4節、5章Phase5。
--]]

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path

local sb_startup = require("sb_startup")
local sb_bootstrap = require("sb_bootstrap")

local deps = {
  resource_path = reaper.GetResourcePath(),
  script_dir = SCRIPT_DIR,
  read_file = sb_bootstrap.read_file,
  write_file = sb_bootstrap.write_file,
  file_exists = reaper.file_exists,
}

local ok, subpath_or_err = sb_startup.install(deps)

if ok then
  sb_bootstrap.log("起動時の自動送信を登録した（設置場所: Scripts/" .. tostring(subpath_or_err) .. "）")
  reaper.MB(
    "REAPER起動時の自動送信を登録しました。\n\n" ..
    "次にREAPERを起動したときから、自分のプラグイン一覧が自動でDropboxへ送られます" ..
    "（1日1回、前回と同じ内容なら送りません。画面には何も出ません）。\n\n" ..
    "書き足した場所: " .. sb_startup.startup_path(deps) .. "\n" ..
    "外すときは、小窓の設定タブの「解除」を押してください。",
    "Shippo Blend: 起動時の自動送信", 0)
else
  sb_bootstrap.log("起動時の自動送信の登録に失敗: " .. tostring(subpath_or_err))
  reaper.MB(
    "登録できませんでした。\n\n" .. tostring(subpath_or_err) .. "\n\n" ..
    "ログ: " .. sb_bootstrap.log_path(),
    "Shippo Blend: 起動時の自動送信", 0)
end
