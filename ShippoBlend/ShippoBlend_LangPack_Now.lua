--[[
  ShippoBlend_LangPack_Now.lua
  Shippo Blend Plugins — 日本語パッチの更新を「今すぐ」確認する（Actionsから手で実行）。

  ふだんはREAPERの起動時に1日1回だけ自動で確認する（ShippoBlend_SendNow.lua の末尾）。
  こちらは1日1回の制限を無視し、結果を必ずダイアログで知らせる。

  中身は lib/sb_langpack.lua。
--]]

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

package.path = this_dir() .. "/lib/?.lua;" .. package.path

local sb_bootstrap = require("sb_bootstrap")
local sb_langpack = require("sb_langpack")

local deps = sb_langpack.reaper_deps(
  sb_bootstrap.read_file, sb_bootstrap.write_file, sb_bootstrap.log)

local ok, err = pcall(sb_langpack.run, deps, { force = true, verbose = true })
if not ok then
  sb_bootstrap.log("LangPack: エラー: " .. tostring(err))
  reaper.ShowMessageBox(
    "日本語パッチの確認でエラーが起きました。\n\n" .. tostring(err)
    .. "\n\nログ: " .. sb_bootstrap.log_path(),
    sb_langpack.TITLE, 0)
end
