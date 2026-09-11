--[[
  sb_ui_tabs.lua
  Shippo Blend Plugins — 小窓の検索タブと整備タブ。設定タブは sb_ui_settings.lua、
  中に出る2つの小窓（リンク登録・同じものとして扱う）は sb_ui_popups.lua にあり、
  ここから再公開している。sb_ui.lua から呼ばれる。
  表示する中身の計算は sb_viewmodel が持ち、ここは並べるだけ。
--]]

local VM = require("sb_viewmodel")
local Popups = require("sb_ui_popups")
local Settings = require("sb_ui_settings")

local M = {}

-- 1ファイルを短く保つための分割。呼び出し側（sb_ui.lua）は sb_ui_tabs だけ見ればよい。
M.settings = Settings.settings
M.link_popup = Popups.link_popup
M.alias_popup = Popups.alias_popup

local MARK = { has = "○", unusable = "△", none = "×" }

local function tooltip(ImGui, ctx, text)
  if text and text ~= "" then ImGui.SetItemTooltip(ctx, text) end
end

local function link_button(ImGui, ctx, ui, app, row, label_prefix)
  local link = row.link
  if link and link.url and link.url ~= "" then
    if ImGui.Button(ctx, "開く") then ui.shell_open(link.url) end
    tooltip(ImGui, ctx, link.url .. "\n（登録: " .. tostring(link.by or "?") .. "）")
    ImGui.SameLine(ctx)
    if link.free then
      ImGui.TextColored(ctx, 0x66DD88FF, "無料")
      ImGui.SameLine(ctx)
    end
    if ImGui.SmallButton(ctx, "直す") then
      app.link_request = { key = row.key, name = row.name, vendor = row.vendor, ask_ai = false,
        url = link.url, free = link.free }
    end
  else
    if ImGui.Button(ctx, label_prefix or "探す") then
      app.link_request = { key = row.key, name = row.name, vendor = row.vendor, ask_ai = true }
    end
    tooltip(ImGui, ctx, "選んだAIに質問を入れて開き、URLを貼り付ける小窓を出します")
  end
end

-- ============================================================
-- 検索タブ
-- ============================================================

function M.search(ImGui, ctx, app, ui)
  local state = app.state
  if not state then
    ImGui.TextWrapped(ctx, app.load_error and ("読み込みに失敗しました: " .. app.load_error)
      or "Dropboxの場所がまだ決まっていません。設定タブで指定してください。")
    return
  end

  if app.focus_search then
    ImGui.SetKeyboardFocusHere(ctx)
    app.focus_search = false
  end
  ImGui.SetNextItemWidth(ctx, 320)
  local _, q = ImGui.InputText(ctx, "検索", app.query)
  app.query = q

  -- 誰と組むか
  local rv, v
  rv, v = ImGui.Checkbox(ctx, "全員", app.selected[VM.ALL] == true)
  if rv then app.selected[VM.ALL] = v or nil end
  tooltip(ImGui, ctx, "30日以内に更新のあるメンバー全員が持っている物だけにする")
  for _, m in ipairs(state.members) do
    ImGui.SameLine(ctx)
    local label = m.display_name .. (m.stale and "（古い）" or "")
    if m.is_me then
      ImGui.BeginDisabled(ctx)
      ImGui.Checkbox(ctx, label .. "（自分・常に含む）##" .. m.id, true)
      ImGui.EndDisabled(ctx)
    else
      rv, v = ImGui.Checkbox(ctx, label .. "##" .. m.id, app.selected[m.id] == true)
      if rv then app.selected[m.id] = v or nil end
      tooltip(ImGui, ctx, "最終更新: " .. tostring(m.updated_at) .. " / " .. m.plugin_count .. "件")
    end
  end

  local rows = ui.rows(app)
  ImGui.Text(ctx, ("%d件"):format(#rows))
  if #rows > ui.MAX_ROWS then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, ("（表示は先頭%d件まで。検索語を足して絞ってください）"):format(ui.MAX_ROWS))
  end

  local ncols = 5 + #state.members
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg |
    ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable
  local avail_h = select(2, ImGui.GetContentRegionAvail(ctx)) - 26
  if ImGui.BeginTable(ctx, "sb_rows", ncols, flags, 0, avail_h > 80 and avail_h or 0) then
    ImGui.TableSetupColumn(ctx, "名前", ImGui.TableColumnFlags_WidthFixed, 240)
    ImGui.TableSetupColumn(ctx, "メーカー", ImGui.TableColumnFlags_WidthFixed, 130)
    for _, m in ipairs(state.members) do
      ImGui.TableSetupColumn(ctx, m.display_name, ImGui.TableColumnFlags_WidthFixed, 52)
    end
    ImGui.TableSetupColumn(ctx, "形式", ImGui.TableColumnFlags_WidthFixed, 120)
    ImGui.TableSetupColumn(ctx, "リンク", ImGui.TableColumnFlags_WidthFixed, 140)
    ImGui.TableSetupColumn(ctx, "使えない", ImGui.TableColumnFlags_WidthFixed, 60)
    ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    ImGui.TableHeadersRow(ctx)

    local shown = math.min(#rows, ui.MAX_ROWS)
    for i = 1, shown do
      local row = rows[i]
      ImGui.PushID(ctx, row.key)
      ImGui.TableNextRow(ctx)

      ImGui.TableSetColumnIndex(ctx, 0)
      -- 行の左上（画面座標）を控えておく。Selectable は SpanAllColumns にしてあるので
      -- 幅が「行全体」として扱われ、SameLine では次の物が最後の列の右端へ飛んでしまう。
      -- 「≒」ボタンは名前の右へ、座標で直接置く。
      local name_x, name_y = ImGui.GetCursorScreenPos(ctx)
      ImGui.SetNextItemAllowOverlap(ctx)
      ImGui.Selectable(ctx, row.name, false,
        ImGui.SelectableFlags_SpanAllColumns | ImGui.SelectableFlags_AllowDoubleClick)
      if ImGui.IsItemHovered(ctx) then
        if ImGui.IsMouseDoubleClicked(ctx, 0) then
          local ok, msg = ui.insert_row(app, row)
          app.status = msg
          if ok then app.status = msg end
        end
      end
      if row.near then
        local name_w = ImGui.CalcTextSize(ctx, row.name)
        ImGui.SetCursorScreenPos(ctx, name_x + name_w + 8, name_y)
        if ImGui.SmallButton(ctx, "≒") then
          app.alias_request = { key = row.key, name = row.name, vendor = row.vendor }
        end
        tooltip(ImGui, ctx,
          "似た名前の別の行があります。同じプラグインなら、ここから「同じものとして扱う」ことができます")
      end

      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, row.vendor or "")

      local col = 2
      for _, m in ipairs(state.members) do
        ImGui.TableSetColumnIndex(ctx, col)
        local mark = row.by_member[m.id] or "none"
        ImGui.Text(ctx, MARK[mark])
        if mark == "unusable" then tooltip(ImGui, ctx, "持っているが「使えない」印が付いています") end
        col = col + 1
      end

      ImGui.TableSetColumnIndex(ctx, col)
      local fmt_text = table.concat(row.formats_mine, "/")
      if row.mismatch then
        ImGui.TextColored(ctx, 0xFFCC55FF, fmt_text .. " !")
        tooltip(ImGui, ctx, "他の人はVST3、あなたは" .. (fmt_text ~= "" and fmt_text or "なし"))
      else
        ImGui.Text(ctx, fmt_text)
      end

      ImGui.TableSetColumnIndex(ctx, col + 1)
      link_button(ImGui, ctx, ui, app, row)

      ImGui.TableSetColumnIndex(ctx, col + 2)
      local can_flag = (state.me_has_file and row.mine ~= nil)
      if not can_flag then ImGui.BeginDisabled(ctx) end
      local rv2, v2 = ImGui.Checkbox(ctx, "##unusable", row.unusable_mine == true)
      if rv2 and can_flag then
        local ok, err = VM.toggle_unusable(state, row.key, app.store, app.root, app.boot.now_iso())
        if ok then
          app.pending_reload = true
          app.status = ("「使えない」印を%s: %s"):format(v2 and "付けました" or "外しました", row.name)
        else
          app.status = "印を変えられませんでした: " .. tostring(err)
        end
      end
      if not can_flag then ImGui.EndDisabled(ctx) end

      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end

  ImGui.Text(ctx, app.status or "")
end

-- ============================================================
-- 整備タブ
-- ============================================================

local function maintenance_rows(app)
  local state = app.state
  if not state then return nil end
  if app.maint_generation ~= state.generation then
    app.maint = VM.maintenance(state)
    app.maint_generation = state.generation
  end
  return app.maint
end

function M.maintenance(ImGui, ctx, app, ui)
  local state = app.state
  if not state then
    ImGui.TextWrapped(ctx, "Dropboxの場所がまだ決まっていません。設定タブで指定してください。")
    return
  end
  local maint = maintenance_rows(app)

  if ImGui.CollapsingHeader(ctx, ("他の人はVST3、あなたはVST2/AUだけ（%d件）"):format(#maint.mismatch)) then
    for _, row in ipairs(maint.mismatch) do
      ImGui.PushID(ctx, "mm" .. row.key)
      ImGui.Text(ctx, ("%s（%s） — あなた: %s"):format(row.name, row.vendor or "",
        table.concat(row.formats_mine, "/")))
      local holders = table.concat(row.vst3_members or {}, "・")
      tooltip(ImGui, ctx, holders ~= "" and ("VST3を持っている人: " .. holders)
        or "VST3を持っている人がいます")
      ImGui.SameLine(ctx)
      link_button(ImGui, ctx, ui, app, row)
      ImGui.PopID(ctx)
    end
  end

  if ImGui.CollapsingHeader(ctx, ("「使えない」印 → アンインストール候補（%d件）"):format(#maint.unusable_mine)) then
    for _, row in ipairs(maint.unusable_mine) do
      ImGui.PushID(ctx, "un" .. row.key)
      ImGui.Text(ctx, ("%s（%s）"):format(row.name, row.vendor or ""))
      for j, idn in ipairs(row.idents or {}) do
        ImGui.PushID(ctx, j)
        if idn.kind == "path" then
          if ImGui.SmallButton(ctx, "場所を開く") then ui.locate_file(idn.value) end
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, idn.value)
        else
          ImGui.Text(ctx, "  " .. idn.raw ..
            (idn.raw:find(":") and "（AUは ~/Library/Audio/Plug-Ins/Components フォルダ）" or ""))
        end
        ImGui.PopID(ctx)
      end
      ImGui.PopID(ctx)
    end
  end

  if ImGui.CollapsingHeader(ctx, ("自分以外の誰かが持つ無料プラグイン（%d件）"):format(#maint.free_missing)) then
    for _, row in ipairs(maint.free_missing) do
      ImGui.PushID(ctx, "fr" .. row.key)
      ImGui.Text(ctx, ("%s（%s）"):format(row.name, row.vendor or ""))
      ImGui.SameLine(ctx)
      link_button(ImGui, ctx, ui, app, row)
      ImGui.PopID(ctx)
    end
  end
end

return M
