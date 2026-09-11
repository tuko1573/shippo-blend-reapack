--[[
  sb_ui_settings.lua
  Shippo Blend Plugins — 小窓の「設定」タブ。sb_ui_tabs.lua から再公開される。
  ここだけが sb_startup（起動時の自動送信の登録／解除）を触る。
--]]

local sb_startup = require("sb_startup")

local M = {}

local function tooltip(ImGui, ctx, text)
  if text and text ~= "" then ImGui.SetItemTooltip(ctx, text) end
end

local AI_LIST = { { "chatgpt", "ChatGPT" }, { "claude", "Claude" }, { "perplexity", "Perplexity" } }

function M.settings(ImGui, ctx, app, ui)
  local config = app.config

  ImGui.SeparatorText(ctx, "あなた")
  ImGui.Text(ctx, "メンバーID: " .. tostring(config:get_member_id() or "（未設定）"))
  tooltip(ImGui, ctx, "一度決めたら変えません（Dropbox上のファイル名になります）")

  app.edit_display_name = app.edit_display_name or (config:get_display_name() or "")
  ImGui.SetNextItemWidth(ctx, 240)
  local _, dn = ImGui.InputText(ctx, "表示名", app.edit_display_name)
  app.edit_display_name = dn
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "表示名を保存") then
    config:set_display_name(app.edit_display_name)
    app.settings_message = "表示名を保存しました（次回の更新でDropboxにも反映されます）。"
  end

  ImGui.SeparatorText(ctx, "Dropboxの場所")
  do
    local shown = app.dropbox_path or "（見つかっていません）"
    if app.dropbox_path and app.store and not app.store:path_exists(app.dropbox_path) then
      shown = shown .. "（見つかりません。Dropboxを移動した場合は下の「手で指定」へ）"
    end
    ImGui.Text(ctx, "今使っている場所: " .. shown)
  end
  if ImGui.Button(ctx, "再検出") then
    config:set_dropbox_override("")
    ui.resolve_root(app)
    app.pending_reload = true
    app.settings_message = app.dropbox_path and ("見つかりました: " .. app.dropbox_path)
      or "自動では見つかりませんでした。下の欄に貼り付けてください。"
  end
  app.edit_dropbox = app.edit_dropbox or (config:get_dropbox_override() or "")
  ImGui.SetNextItemWidth(ctx, 420)
  local _, dbp = ImGui.InputText(ctx, "手で指定", app.edit_dropbox)
  app.edit_dropbox = dbp
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "この場所を使う") then
    config:set_dropbox_override(app.edit_dropbox)
    ui.resolve_root(app)
    app.pending_reload = true
    app.settings_message = app.root and ("この場所を使います: " .. app.dropbox_path)
      or "その場所は読めませんでした。"
  end

  ImGui.SeparatorText(ctx, "リンクを探すときのAI")
  local cur = config:get_ai_choice()
  for _, item in ipairs(AI_LIST) do
    if ImGui.RadioButton(ctx, item[2], cur == item[1]) then config:set_ai_choice(item[1]) end
    ImGui.SameLine(ctx)
  end
  ImGui.NewLine(ctx)

  ImGui.SeparatorText(ctx, "データ")
  if ImGui.Button(ctx, "今すぐ更新") then
    app.pending_sendnow = true
    app.settings_message = "更新しています…"
  end
  tooltip(ImGui, ctx, "自分のプラグイン一覧を集め直してDropboxへ書きます")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "データを再読み込み") then
    app.pending_reload = true
  end
  ImGui.Text(ctx, "最後に送った日: " .. tostring(config:get_last_sent_date() or "（まだ）"))
  ImGui.Text(ctx, "一覧の指紋（前回）: " .. tostring(config:get_last_hash() or "（まだ）"))
  if app.state then
    ImGui.Text(ctx, ("読み込み済み: メンバー%d人 / プラグイン%d件")
      :format(#app.state.members, (function()
        local n = 0
        for _ in pairs(app.state.index) do n = n + 1 end
        return n
      end)()))
  end
  if app.settings_message then
    ImGui.TextWrapped(ctx, app.settings_message)
  end

  -- 開発用: 合成メンバーをDropboxに置く／消す。
  -- ExtState ShippoBlend/dev_fixtures にフォルダを入れた機械（開発機）でだけ出る。配布版には出ない。
  -- （または <REAPER設定フォルダ>/ShippoBlend.dev に、そのフォルダのパスを1行書いた機械）
  local DEV_FIX = reaper.GetExtState("ShippoBlend", "dev_fixtures")
  if DEV_FIX == "" then
    local f = io.open(reaper.GetResourcePath() .. "/ShippoBlend.dev", "rb")
    if f then DEV_FIX = (f:read("*l") or ""):gsub("%s+$", ""); f:close() end
  end
  if app.root and DEV_FIX ~= "" and reaper.file_exists(DEV_FIX .. "/kamil.json") then
    ImGui.SeparatorText(ctx, "開発用（このMacだけに出る）")
    if ImGui.Button(ctx, "試験メンバーを置く") then
      local n = 0
      for _, id in ipairs({ "kamil", "utaren", "shoki" }) do
        local text = app.store.deps.read_file(DEV_FIX .. "/" .. id .. ".json")
        if text then
          text = text:gsub('"member_id"%s*:%s*"' .. id .. '"', '"member_id":"test_' .. id .. '"', 1)
          text = text:gsub('"display_name"%s*:%s*"', '"display_name":"試験', 1)
          local dst = app.root .. app.store:sep() .. "members" .. app.store:sep() .. "test_" .. id .. ".json"
          if app.store.deps.write_file(dst, text) then n = n + 1 end
        end
      end
      app.settings_message = ("試験メンバーを%d人置きました"):format(n)
      app.pending_reload = true
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "試験メンバーを消す") then
      for _, id in ipairs({ "kamil", "utaren", "shoki" }) do
        app.store.deps.remove(app.root .. app.store:sep() .. "members" .. app.store:sep() .. "test_" .. id .. ".json")
      end
      app.settings_message = "試験メンバーを消しました"
      app.pending_reload = true
    end
  end

  ImGui.SeparatorText(ctx, "REAPER起動時の自動送信")
  M.startup_section(ImGui, ctx, app)
end

-- ============================================================
-- 起動時の自動送信（__startup.lua のマーカー付きの一塊）
-- ============================================================

--- 起動時に読み込まれるファイルを毎フレーム読みに行かないよう、結果を覚えておく。
local function startup_installed(app, force)
  if force or app.startup_installed == nil then
    local ok, res = pcall(sb_startup.is_installed, app.startup_deps)
    app.startup_installed = ok and res or false
  end
  return app.startup_installed
end

function M.startup_section(ImGui, ctx, app)
  if not app.startup_deps then
    ImGui.TextWrapped(ctx, "このスクリプトの置き場所が分からないため、登録できません。")
    return
  end

  local installed = startup_installed(app)
  ImGui.Text(ctx, "起動時の自動送信: " .. (installed and "登録済み" or "未登録"))
  tooltip(ImGui, ctx, sb_startup.startup_path(app.startup_deps))

  if ImGui.Button(ctx, "登録") then
    local ok, res = sb_startup.install(app.startup_deps)
    startup_installed(app, true)
    app.settings_message = ok
      and ("登録しました。次のREAPER起動から自動で送ります（設置場所: Scripts/" .. tostring(res) .. "）。")
      or ("登録できませんでした: " .. tostring(res))
    app.boot.log("設定タブ: 起動時の自動送信 登録 -> " .. tostring(ok) .. " " .. tostring(res))
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "解除") then
    local ok, err = sb_startup.uninstall(app.startup_deps)
    startup_installed(app, true)
    app.settings_message = ok and "解除しました（起動時には何もしません）。"
      or ("解除できませんでした: " .. tostring(err))
    app.boot.log("設定タブ: 起動時の自動送信 解除 -> " .. tostring(ok) .. " " .. tostring(err))
  end
  ImGui.TextWrapped(ctx,
    "REAPERの起動ファイルに、印で挟んだ一塊を足すだけです。印の外側は触りません。" ..
    "起動してから数秒待って送るので、画面には何も出ません。")
end

return M
