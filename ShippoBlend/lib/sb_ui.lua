--[[
  sb_ui.lua
  Shippo Blend Plugins — REAPER内の検索小窓（ReaImGui）。窓の骨組み・状態の読み直し・
  REAPER側の操作（FX挿入、URLを開く、ファイルの場所を開く、今すぐ更新）をここに置き、
  3つのタブの中身は sb_ui_tabs.lua / sb_ui_settings.lua / sb_ui_popups.lua に分ける。

  表示する中身の計算は一切しない（すべて sb_viewmodel が持つ）。
  ImGui と reaper を触るのは、このファイルと sb_ui_* の3つと入口スクリプトだけ。

  ReaImGui: 1.92.1 / API版 '0.10'（同梱の ReaImGui_Demo.lua が使っている版に合わせた）。
--]]

local VM = require("sb_viewmodel")

local M = {}

M.RELOAD_INTERVAL_SEC = 60
M.MAX_ROWS = 400

-- ============================================================
-- REAPER側の操作（SWSが無い環境でも落ちないようにガードする）
-- ============================================================

--- URLや、ファイル・フォルダを既定のアプリで開く。
function M.shell_open(target)
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(target)
    return true, "CF_ShellExecute"
  end
  local os_name = reaper.GetOS() or ""
  local cmd
  if os_name:match("^Win") then
    cmd = 'cmd /c start "" "' .. target .. '"'
  else
    cmd = 'open "' .. target .. '"'
  end
  reaper.ExecProcess(cmd, -1)
  return true, "ExecProcess"
end

--- ファイルの置き場所をFinder/エクスプローラで開く。
function M.locate_file(path)
  if reaper.CF_LocateInExplorer then
    reaper.CF_LocateInExplorer(path)
    return true, "CF_LocateInExplorer"
  end
  local dir = path:match("^(.*)[/\\][^/\\]+$") or path
  return M.shell_open(dir)
end

--- 選択中のトラックへ挿す。候補を順に試し、最初に通ったものを採用してログに残す。
-- @return ok, message
function M.insert_row(app, row)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    return false, "トラックを選んでください"
  end
  local candidates = VM.insert_candidates(row)
  if #candidates == 0 then
    return false, "挿入できませんでした（自分は持っていません）"
  end

  reaper.Undo_BeginBlock()
  local used, fx_index = nil, -1
  for _, name in ipairs(candidates) do
    local idx = reaper.TrackFX_AddByName(track, name, false, -1)
    if idx and idx >= 0 then used, fx_index = name, idx; break end
  end
  reaper.Undo_EndBlock("Shippo Blend: " .. tostring(row.name) .. " を挿入", -1)

  local track_no = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0)
  if used then
    app.boot.log(("挿入成功 key=%s 通った名前=%q fx=%d"):format(row.key, used, fx_index))
    return true, ("挿入: %s → トラック %d"):format(row.name, track_no)
  end
  app.boot.log(("挿入失敗 key=%s 試した候補=%d件: %s"):format(row.key, #candidates,
    table.concat(candidates, " | ")))
  return false, "挿入できませんでした"
end

-- ============================================================
-- 状態の読み直し
-- ============================================================

function M.reload(app, force)
  if not app.root then
    app.state = nil
    return
  end
  local ok, state = pcall(VM.load, app.store, app.root, app.config,
    app.boot.now_iso(), (not force) and app.state or nil)
  if ok then
    app.state = state
    app.rows_sig = nil -- 表の作り直しを促す
    app.last_reload = reaper.time_precise()
    app.load_error = nil
  else
    app.load_error = tostring(state)
    app.boot.log("小窓: 読み込み失敗 " .. tostring(state))
  end
end

--- 表の行は毎フレーム作り直さない（検索語・選択・読み直しが変わったときだけ）。
function M.rows(app)
  local state = app.state
  if not state then return {} end
  local ids = {}
  for id, on in pairs(app.selected) do
    if on then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local sort = app.sort
  local sort_sig = sort and (tostring(sort.column) .. (sort.descending and ":desc" or ":asc")) or ""
  local sig = table.concat(ids, ",") .. "\1" .. app.query .. "\1" .. tostring(state.generation)
    .. "\1" .. sort_sig
  if app.rows_sig ~= sig then
    app.rows_cache = VM.rows(state, app.query, ids, { sort = sort })
    app.rows_sig = sig
  end
  return app.rows_cache
end

function M.selected_ids(app)
  local ids = {}
  for id, on in pairs(app.selected) do
    if on then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

-- ============================================================
-- 「今すぐ更新」（SendNowを呼ぶ）
-- ============================================================

--- 描画の途中（Begin〜End の中）では実行しない。次のフレームの頭で呼ぶ。
function M.run_sendnow(app)
  SHIPPOBLEND_FORCE = true
  SHIPPOBLEND_QUIET = true
  local ok, err = pcall(dofile, app.sendnow_path)
  SHIPPOBLEND_FORCE = nil
  SHIPPOBLEND_QUIET = nil
  if not ok then
    app.boot.log("小窓からの今すぐ更新でエラー: " .. tostring(err))
    app.settings_message = "更新に失敗しました: " .. tostring(err)
  else
    app.settings_message = app.boot.log_last_line() or "更新しました。"
  end
  -- Dropboxの場所が今回の実行で決まったかもしれないので取り直す
  M.resolve_root(app)
  M.reload(app, true)
end

--- Dropboxの場所を解決して app.root を決める（見つからなければ nil のまま）。
function M.resolve_root(app)
  local path = app.boot.ensure_dropbox_path(app.store, app.config, app.boot.log, { prompt = false })
  app.dropbox_path = path
  app.root = path and app.store:root(path) or nil
  return path
end

-- ============================================================
-- 窓
-- ============================================================

--- @param opts { boot, config, store, sendnow_path, script_dir }
function M.open(opts)
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  local ImGui = require "imgui" "0.10"
  local Tabs = require("sb_ui_tabs")

  local app = {
    boot = opts.boot,
    config = opts.config,
    store = opts.store,
    sendnow_path = opts.sendnow_path,
    ImGui = ImGui,

    -- 起動時の自動送信（sb_startup）が使う。REAPER依存はここで閉じる。
    startup_deps = opts.script_dir and {
      resource_path = opts.boot.resource_path(),
      script_dir = opts.script_dir,
      read_file = opts.boot.read_file,
      write_file = opts.boot.write_file,
      file_exists = reaper.file_exists,
    } or nil,
    startup_installed = nil,

    query = "",
    selected = {},        -- [member_id or VM.ALL] = true
    sort = nil,            -- {column="name"|"vendor", descending=bool}｜nil＝既定順（保存しない）
    rows_cache = {},
    rows_sig = nil,
    status = "",
    settings_message = nil,
    focus_search = true,
    last_reload = 0,
    tab_force_settings = false,

    -- リンク編集の小窓（「探す」を押した行の情報を次のフレームへ渡す）
    link_request = nil,   -- {key, name, vendor}
    link_edit = nil,      -- {key, name, url, free}

    -- 「同じものとして扱う」の小窓（「≒」を押した行の情報を次のフレームへ渡す）
    alias_request = nil,  -- {key, name, vendor}
    alias_edit = nil,     -- {key, name, vendor, info}

    pending_sendnow = false,
    pending_reload = false,
  }

  M.resolve_root(app)
  if not app.root then
    app.tab_force_settings = true
    app.settings_message =
      "Dropboxの場所が見つかりませんでした。下の「Dropboxの場所」に貼り付けてください。"
  end
  M.reload(app, true)

  local ctx = ImGui.CreateContext("Shippo Blend Plugins")
  app.ctx = ctx

  -- 日本語（と ○△× ）を出すためのフォント。失敗しても窓は開く。
  local ok_font, font = pcall(ImGui.CreateFont, "sans-serif")
  if ok_font and font then
    local ok_attach = pcall(ImGui.Attach, ctx, font)
    app.font = ok_attach and font or nil
  end

  local function frame()
    -- 描画の外でやること（ImGuiのBegin〜Endの中でdofileやダイアログを出さない）
    if app.pending_sendnow then
      app.pending_sendnow = false
      M.run_sendnow(app)
    end
    if app.pending_reload then
      app.pending_reload = false
      M.reload(app, true)
    end
    local now = reaper.time_precise()
    if app.root and (now - app.last_reload) > M.RELOAD_INTERVAL_SEC then
      M.reload(app, false) -- 中身が同じなら作り直さない（sb_viewmodelが判定）
    end

    if app.font then ImGui.PushFont(ctx, app.font, 14) end

    ImGui.SetNextWindowSize(ctx, 900, 560, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, "Shippo Blend Plugins", true)
    if visible then
      if ImGui.BeginTabBar(ctx, "sb_tabs") then
        local search_flags = 0
        local settings_flags = 0
        if app.tab_force_settings then
          settings_flags = ImGui.TabItemFlags_SetSelected
          app.tab_force_settings = false
        end

        if ImGui.BeginTabItem(ctx, "検索", nil, search_flags) then
          Tabs.search(ImGui, ctx, app, M)
          ImGui.EndTabItem(ctx)
        end
        if ImGui.BeginTabItem(ctx, "整備") then
          Tabs.maintenance(ImGui, ctx, app, M)
          ImGui.EndTabItem(ctx)
        end
        if ImGui.BeginTabItem(ctx, "設定", nil, settings_flags) then
          Tabs.settings(ImGui, ctx, app, M)
          ImGui.EndTabItem(ctx)
        end
        ImGui.EndTabBar(ctx)
      end
      Tabs.link_popup(ImGui, ctx, app, M)
      Tabs.alias_popup(ImGui, ctx, app, M)
      ImGui.End(ctx)
    end

    if app.font then ImGui.PopFont(ctx) end

    if open then
      reaper.defer(frame)
    end
  end

  reaper.defer(frame)
  return app
end

return M
