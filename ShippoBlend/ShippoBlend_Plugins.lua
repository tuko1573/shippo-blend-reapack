--[[
@description Shippo Blend Plugins
@author tuko
@version 0.2.2
@changelog
  0.2.2: Windows報告の修正。並び替え部品の配布漏れ、Dropboxを移動していると存在しない場所を使う問題、貼り付けたパスの引用符。
  0.2.1: 「非表示」の書き込み失敗を修正。「使えない」をボタン化して説明を追加。名前・メーカーの見出しクリックで並び替え。
  0.2.0: 「非表示」を追加。検索タブの「隠す」で、その行を全員の一覧から消せる
  （「使えない」△とは別。整備タブの「非表示」から戻せる）。
  0.1.0: 「同じものとして扱う」訂正、整備タブの補足表示、
  REAPER起動時の自動送信の登録／解除、ReaPackでの配布。
@about
  # Shippo Blend Plugins

  Shippo Blend のメンバーが持っているプラグインを集めて、
  REAPERの中で「誰と組むなら何が使えるか」を引ける小窓です。
  データの置き場はDropboxの共有フォルダ「Shippo Blend」。

  必要なもの: REAPER 7以降 / ReaImGui / SWS。
  入れたあとの手順は docs/onboarding_ja.md を見てください。
@provides
  [main] ShippoBlend_SendNow.lua
  [main] ShippoBlend_Startup_Install.lua
  [nomain] lib/sb_bootstrap.lua
  [nomain] lib/sb_collector.lua
  [nomain] lib/sb_config.lua
  [nomain] lib/sb_ini.lua
  [nomain] lib/sb_json.lua
  [nomain] lib/sb_matcher.lua
  [nomain] lib/sb_matcher_links.lua
  [nomain] lib/sb_normalize.lua
  [nomain] lib/sb_startup.lua
  [nomain] lib/sb_store.lua
  [nomain] lib/sb_ui.lua
  [nomain] lib/sb_ui_popups.lua
  [nomain] lib/sb_ui_settings.lua
  [nomain] lib/sb_ui_tabs.lua
  [nomain] lib/sb_viewmodel.lua
  [nomain] lib/sb_viewmodel_actions.lua
  [nomain] lib/sb_viewmodel_sort.lua
--]]

--[[
  ShippoBlend_Plugins.lua
  Shippo Blend Plugins — REAPER内の検索小窓（検索／整備／設定）を開く入口。

  必要なもの: REAPER 7以降、ReaImGui（1.92以降）、SWS（URLとフォルダを開くのに使う。
  無くても ExecProcess で代用する）。

  参照: 計画書/計画書.md 2章・5章Phase3。
--]]

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB(
    "ReaImGui が見つかりません。\n\nReaPack の「Browse packages」から ReaImGui を入れてから、" ..
    "もう一度このスクリプトを実行してください。",
    "Shippo Blend Plugins", 0)
  return
end

local boot = require("sb_bootstrap")
local sb_ui = require("sb_ui")

local config = boot.new_config()

-- メンバーIDと表示名が未設定なら、ここで1回だけ聞く（小窓を開いた後にダイアログが
-- 割り込まないように、描画を始める前に済ませる）。
if not boot.ensure_member_identity(config, boot.log) then
  reaper.MB("メンバーIDが決まっていないので開けません。もう一度実行してください。\n\n" ..
    "メンバーIDは半角英数字とアンダースコアのみ（例: taro）、表示名は日本語で構いません。",
    "Shippo Blend Plugins", 0)
  return
end

local store = boot.new_store(boot.log)

-- Dropboxが見つからなくても窓は開く（設定タブで指定してもらう）。
local ok, err = pcall(sb_ui.open, {
  boot = boot,
  config = config,
  store = store,
  sendnow_path = SCRIPT_DIR .. "/ShippoBlend_SendNow.lua",
  script_dir = SCRIPT_DIR,
})

if not ok then
  boot.log("小窓の起動に失敗: " .. tostring(err))
  reaper.MB("小窓を開けませんでした。\n\n" .. tostring(err) .. "\n\nログ: " .. boot.log_path(),
    "Shippo Blend Plugins", 0)
end
