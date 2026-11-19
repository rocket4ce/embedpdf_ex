defmodule EmbedPdf.Live.UI do
  @moduledoc false
  use Phoenix.Component

  import EmbedPdf.Live.Icons
  alias EmbedPdf.I18n
  alias EmbedPdf.Live.{Layout, Viewer}
  alias Phoenix.LiveView.JS

  @swatches ~w(#ffcd45 #e44234 #ff8a00 #57c84d #3b82f6 #8b5cf6 #ec4899 #000000 #ffffff)

  # ---------------------------------------------------------------- root

  def viewer(assigns) do
    assigns =
      assigns
      |> assign(:scale, if(assigns.status == :ready, do: Viewer.scale(assigns), else: 1.0))
      |> assign(:f, assigns.features)

    ~H"""
    <div
      id={@viewer_id}
      class={["epdf", @fullscreen? && "epdf-fullscreen", "epdf-tool-#{@tool}", "epdf-mode-#{@mode}"]}
      data-epdf-viewer={@viewer_id}
      data-theme={@theme}
    >
      <link rel="stylesheet" href={"#{@base}/assets/viewer.css?v=#{EmbedPdf.Live.CSS.version()}"} />
      <link :if={@status == :ready} rel="stylesheet" href={"#{@base}/probe/#{@viewer_id}/#{@probe_nonce}.css"} />
      <link
        :if={@status == :ready and @scroll != :paged}
        rel="stylesheet"
        href={"#{@base}/seen/#{@viewer_id}/#{length(@sizes)}/#{@seen.nonce}.css"}
      />
      <iframe name={"#{@viewer_id}-sink"} class="epdf-sink" title="" tabindex="-1" aria-hidden="true"></iframe>

      <.topbar {assigns} />
      <.doc_tabs :if={@f["documents.tabs"] and length(@tabs) > 1} {assigns} />
      <.modebar :if={@status == :ready and @mode != :view} {assigns} />
      <.hint {assigns} />

      <div class="epdf-body">
        <.left_panel :if={@left && @status == :ready} {assigns} />
        <main class="epdf-main">
          <.viewport :if={@status == :ready} {assigns} />
          <.empty :if={@status in [:empty, :error, :password]} {assigns} />
          <.pager :if={@status == :ready} {assigns} />
        </main>
        <.right_panel :if={@right && @status == :ready} {assigns} />
      </div>

      <.dialogs {assigns} />

      <a
        :if={@scroll_to}
        id={"#{@viewer_id}-goto-#{@scroll_nonce}"}
        href={"#" <> @scroll_to}
        class="epdf-hidden"
        tabindex="-1"
        aria-hidden="true"
        phx-mounted={JS.dispatch("click")}
      ></a>
    </div>
    """
  end

  defp t(assigns, key, bindings \\ %{}),
    do: I18n.t(assigns.locale, key, bindings, assigns.overrides)

  # ---------------------------------------------------------------- top bar

  defp topbar(assigns) do
    ~H"""
    <header class="epdf-topbar">
      <div class="epdf-group">
        <div class="epdf-menu-wrap">
          <button class={["epdf-btn", @menu == "document" && "is-active"]} phx-click="menu" phx-value-menu="document" title={t(assigns, "menu.document")} aria-label={t(assigns, "menu.document")}>
            <.icon name="menu" />
          </button>
          <div :if={@menu == "document"} class="epdf-menu" phx-click-away="close_menu">
            <label :if={@f["documents.open"]} class="epdf-menu-item" for={@uploads.pdf.ref}>
              <.icon name="upload" /> {t(assigns, "menu.open")}
            </label>
            <a :if={@doc_id && @f["documents.download"]} class="epdf-menu-item" href={"#{@base}/d/#{@doc_id}/download"} download={@name}>
              <.icon name="download" /> {t(assigns, "menu.download")}
            </a>
            <a :if={@doc_id && @f["documents.download"]} class="epdf-menu-item" href={"#{@base}/d/#{@doc_id}/download?flatten=1"} download={@name}>
              <.icon name="download" /> {t(assigns, "menu.download_flat")}
            </a>
            <button :if={@doc_id && @f["documents.print"]} class="epdf-menu-item" phx-click="dialog" phx-value-dialog="print">
              <.icon name="print" /> {t(assigns, "menu.print")}
            </button>
            <button :if={@doc_id} class="epdf-menu-item" phx-click="dialog" phx-value-dialog="properties">
              <.icon name="info" /> {t(assigns, "menu.properties")}
            </button>
            <hr />
            <button class="epdf-menu-item" phx-click="fullscreen">
              <.icon name={if @fullscreen?, do: "fullscreen-exit", else: "fullscreen"} />
              {if @fullscreen?, do: t(assigns, "menu.exit_fullscreen"), else: t(assigns, "menu.fullscreen")}
            </button>
            <button class="epdf-menu-item" phx-click="dialog" phx-value-dialog="shortcuts">
              <.icon name="keyboard" /> {t(assigns, "menu.shortcuts")}
            </button>
            <button :if={@doc_id && @f["documents.open"]} class="epdf-menu-item" phx-click="close_document">
              <.icon name="close" /> {t(assigns, "menu.close")}
            </button>
          </div>
        </div>
        <button
          :if={@status == :ready}
          class={["epdf-btn", @left && "is-active"]}
          phx-click="panel"
          phx-value-side="left"
          phx-value-panel={@left || "thumbnails"}
          title={t(assigns, "panel.sidebar")}
          aria-label={t(assigns, "panel.sidebar")}
        >
          <.icon name="sidebar" />
        </button>
        <span class="epdf-title" title={@name}>{@name}<span :if={@dirty?} class="epdf-dirty" title={t(assigns, "unsaved")}>•</span></span>
      </div>

      <nav :if={@status == :ready} class="epdf-tabs" role="tablist">
        <button
          :for={mode <- modes(@f)}
          role="tab"
          class={["epdf-tab", @mode == mode && "is-active"]}
          aria-selected={to_string(@mode == mode)}
          phx-click="mode"
          phx-value-mode={mode}
        >
          {t(assigns, "mode.#{mode}")}
        </button>
      </nav>

      <div :if={@status == :ready} class="epdf-group epdf-right">
        <div class="epdf-zoom">
          <button class="epdf-btn" phx-click="zoom" phx-value-to="out" title={t(assigns, "zoom.out")} aria-label={t(assigns, "zoom.out")}>
            <.icon name="minus" />
          </button>
          <div class="epdf-menu-wrap">
            <button class="epdf-zoom-label" phx-click="menu" phx-value-menu="zoom" title={t(assigns, "zoom.menu")}>
              {Layout.label(@zoom, @scale)}
            </button>
            <div :if={@menu == "zoom"} class="epdf-menu epdf-menu-center" phx-click-away="close_menu">
              <button :for={p <- [50, 75, 100, 125, 150, 200, 300, 400]} class="epdf-menu-item" phx-click="zoom" phx-value-to={p}>
                {p}%
              </button>
              <hr />
              <button class={["epdf-menu-item", @zoom.mode == :fit_width && "is-checked"]} phx-click="zoom" phx-value-to="fit_width">{t(assigns, "zoom.fit_width")}</button>
              <button class={["epdf-menu-item", @zoom.mode == :fit_page && "is-checked"]} phx-click="zoom" phx-value-to="fit_page">{t(assigns, "zoom.fit_page")}</button>
              <button class={["epdf-menu-item", @zoom.mode == :automatic && "is-checked"]} phx-click="zoom" phx-value-to="automatic">{t(assigns, "zoom.automatic")}</button>
            </div>
          </div>
          <button class="epdf-btn" phx-click="zoom" phx-value-to="in" title={t(assigns, "zoom.in")} aria-label={t(assigns, "zoom.in")}>
            <.icon name="plus" />
          </button>
        </div>

        <div class="epdf-menu-wrap">
          <button class={["epdf-btn", @menu == "view" && "is-active"]} phx-click="menu" phx-value-menu="view" title={t(assigns, "view.spread")} aria-label={t(assigns, "view.spread")}>
            <.icon name="layout" />
          </button>
          <div :if={@menu == "view"} class="epdf-menu epdf-menu-right" phx-click-away="close_menu">
            <div class="epdf-menu-label">{t(assigns, "view.scroll")}</div>
            <button :for={m <- [:vertical, :horizontal, :paged]} class={["epdf-menu-item", @scroll == m && "is-checked"]} phx-click="scroll_mode" phx-value-mode={m}>
              {t(assigns, "view.#{m}")}
            </button>
            <div class="epdf-menu-label">{t(assigns, "view.spread")}</div>
            <button :for={{m, k} <- [none: "single", odd: "odd", even: "even"]} class={["epdf-menu-item", @spread == m && "is-checked"]} phx-click="spread" phx-value-mode={m}>
              {t(assigns, "view.#{k}")}
            </button>
            <hr />
            <button class="epdf-menu-item" phx-click="rotate" phx-value-dir="cw"><.icon name="rotate-cw" /> {t(assigns, "view.rotate_cw")}</button>
            <button class="epdf-menu-item" phx-click="rotate" phx-value-dir="ccw"><.icon name="rotate-ccw" /> {t(assigns, "view.rotate_ccw")}</button>
            <div class="epdf-menu-label">{t(assigns, "view.theme")}</div>
            <button :for={th <- ~w(light dark system)} class={["epdf-menu-item", @theme == th && "is-checked"]} phx-click="theme" phx-value-theme={th}>
              {if th == "system", do: "Auto", else: t(assigns, "view.#{th}")}
            </button>
          </div>
        </div>

        <button class={["epdf-btn", @tool == :pan && "is-active"]} phx-click="tool" phx-value-tool="pan" title={t(assigns, "tool.pan")} aria-label={t(assigns, "tool.pan")}>
          <.icon name="hand" />
        </button>
        <button :if={@f["snapshots"]} class={["epdf-btn", @tool == :snapshot && "is-active"]} phx-click="tool" phx-value-tool="snapshot" title={t(assigns, "tool.snapshot")} aria-label={t(assigns, "tool.snapshot")}>
          <.icon name="camera" />
        </button>
        <button :if={@f["search"]} class={["epdf-btn", @right == :search && "is-active"]} phx-click="panel" phx-value-side="right" phx-value-panel="search" title={t(assigns, "panel.search")} aria-label={t(assigns, "panel.search")}>
          <.icon name="search" />
        </button>
        <button :if={@f["comments"]} class={["epdf-btn", @right == :comments && "is-active"]} phx-click="panel" phx-value-side="right" phx-value-panel="comments" title={t(assigns, "panel.comments")} aria-label={t(assigns, "panel.comments")}>
          <.icon name="comment" />
        </button>
      </div>
    </header>
    <form id={"#{@viewer_id}-upload"} class="epdf-hidden" phx-change="validate_upload">
      <.live_file_input upload={@uploads.pdf} />
      <.live_file_input upload={@uploads.insert} />
      <.live_file_input upload={@uploads.attachment} />
    </form>
    """
  end

  defp doc_tabs(assigns) do
    ~H"""
    <div class="epdf-doctabs" role="tablist">
      <div :for={tab <- @tabs} class={["epdf-doctab", tab.id == @doc_id && "is-active"]} role="tab" aria-selected={to_string(tab.id == @doc_id)}>
        <button class="epdf-doctab-name" phx-click="switch_tab" phx-value-id={tab.id} title={tab.name}><.icon name="file" class="epdf-icon-sm" /> {tab.name}</button>
        <button class="epdf-doctab-close" phx-click="close_tab" phx-value-id={tab.id} title={t(assigns, "close")} aria-label={t(assigns, "close")}><.icon name="close" class="epdf-icon-sm" /></button>
      </div>
      <label :if={@f["documents.open"]} class="epdf-btn epdf-btn-sm" for={@uploads.pdf.ref} title={t(assigns, "menu.open")}><.icon name="plus" class="epdf-icon-sm" /></label>
    </div>
    """
  end

  defp modes(f) do
    [
      {:view, true},
      {:annotate, f["annotations"]},
      {:shapes, f["shapes"]},
      {:insert, f["stamps"] || f["annotations.links"] || f["attachments.adding"]},
      {:form, f["forms"]},
      {:redact, f["redaction"]},
      {:pages, f["pages"]}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # ---------------------------------------------------------------- mode bar

  defp modebar(assigns) do
    assigns = assign(assigns, :tools, mode_tools(assigns.mode, assigns.f))

    ~H"""
    <div class="epdf-modebar" role="toolbar">
      <div class="epdf-group">
        <button
          :for={{tool, icon} <- @tools}
          class={["epdf-btn", @tool == tool && "is-active"]}
          phx-click="tool"
          phx-value-tool={tool}
          title={t(assigns, "tool.#{tool}")}
          aria-label={t(assigns, "tool.#{tool}")}
          aria-pressed={to_string(@tool == tool)}
        >
          <.icon name={icon} />
        </button>

        <div :if={@mode == :insert and @f["stamps"]} class="epdf-menu-wrap">
          <button class={["epdf-btn epdf-btn-text", @tool == :stamp && "is-active"]} phx-click="menu" phx-value-menu="stamps">
            <.icon name="stamp" /> {stamp_label(@stamp)} <.icon name="chevron-down" class="epdf-icon-sm" />
          </button>
          <div :if={@menu == "stamps"} class="epdf-menu epdf-stamp-menu" phx-click-away="close_menu">
            <button :for={s <- stamps()} class="epdf-menu-item" phx-click="stamp" phx-value-stamp={s.id}>
              <span class="epdf-stamp-chip" style={"color:#{Viewer.color_hex(s.color)};border-color:#{Viewer.color_hex(s.color)}"}>{s.label}</span>
            </button>
          </div>
        </div>

        <label :if={@mode == :insert and @f["attachments.adding"]} class="epdf-btn" for={@uploads.attachment.ref} title={t(assigns, "tool.attachment")}>
          <.icon name="paperclip" />
        </label>

        <.style_controls :if={@mode in [:annotate, :shapes] and @tool not in [:pointer, :pan]} {assigns} />

        <button :if={@mode == :form and @f["forms.filling"]} class="epdf-btn epdf-btn-text" phx-click="form_reset">{t(assigns, "form.reset")}</button>

        <button :if={@mode == :redact} class="epdf-btn epdf-btn-text epdf-danger" phx-click="redact_apply">
          <.icon name="check" /> {t(assigns, "redact.apply")}
        </button>

        <.pages_controls :if={@mode == :pages} {assigns} />
      </div>
      <div class="epdf-group epdf-right">
        <button class="epdf-btn" phx-click="undo" disabled={@history.undo == []} title={t(assigns, "history.undo")} aria-label={t(assigns, "history.undo")}>
          <.icon name="undo" />
        </button>
        <button class="epdf-btn" phx-click="redo" disabled={@history.redo == []} title={t(assigns, "history.redo")} aria-label={t(assigns, "history.redo")}>
          <.icon name="redo" />
        </button>
      </div>
    </div>
    """
  end

  defp mode_tools(:annotate, f) do
    [
      {f["annotations.highlight"], {:highlight, "highlight"}},
      {f["annotations.markup"], {:underline, "underline"}},
      {f["annotations.markup"], {:strikeout, "strikeout"}},
      {f["annotations.markup"], {:squiggly, "squiggly"}},
      {f["annotations.drawing"], {:ink, "pen"}},
      {f["annotations.text"], {:free_text, "text"}},
      {f["annotations.notes"], {:note, "note"}}
    ]
    |> pick()
  end

  defp mode_tools(:shapes, _f) do
    [
      square: "square",
      circle: "circle",
      line: "line",
      arrow: "arrow",
      polygon: "polygon",
      polyline: "polyline"
    ]
  end

  defp mode_tools(:insert, f) do
    [
      {f["annotations.links"], {:link, "link"}},
      {f["measurement"], {:measure, "ruler"}}
    ]
    |> pick()
  end

  defp mode_tools(:redact, _f), do: [redact_text: "redact", redact_area: "square"]
  defp mode_tools(:view, _f), do: []
  defp mode_tools(_, _), do: []

  defp pick(list), do: for({true, tool} <- list, do: tool)

  defp stamp_label(id) do
    case Enum.find(stamps(), &(&1.id == id)) do
      nil -> id
      s -> s.label
    end
  end

  defp stamps do
    if Code.ensure_loaded?(EmbedPdf.Stamps) and function_exported?(EmbedPdf.Stamps, :list, 0),
      do: EmbedPdf.Stamps.list(),
      else: [%{id: "Approved", label: "APPROVED", color: {0.1, 0.6, 0.2}}]
  end

  defp style_controls(assigns) do
    assigns = assign(assigns, :st, Map.get(assigns.style, assigns.tool, %{}))

    ~H"""
    <form id={"#{@viewer_id}-style"} class="epdf-style" phx-change="style">
      <span class="epdf-sep"></span>
      <div class="epdf-swatches" role="radiogroup" aria-label={t(assigns, "style.color")}>
        <label :for={c <- swatches()} class={["epdf-swatch", @st[:color] == c && "is-active"]} style={"--c:#{c}"} title={c}>
          <input type="radio" name="color" value={c} checked={@st[:color] == c} />
        </label>
      </div>
      <label :if={Map.has_key?(@st, :fill)} class="epdf-field-inline">
        {t(assigns, "style.fill")}
        <select name="fill">
          <option value="" selected={@st[:fill] in [nil, ""]}>{t(assigns, "style.none")}</option>
          <option :for={c <- swatches()} value={c} selected={@st[:fill] == c}>{c}</option>
        </select>
      </label>
      <label :if={Map.has_key?(@st, :stroke)} class="epdf-field-inline">
        {t(assigns, "style.stroke")}
        <input type="range" name="stroke" min="1" max="12" step="1" value={@st[:stroke]} />
      </label>
      <label :if={Map.has_key?(@st, :font_size)} class="epdf-field-inline">
        {t(assigns, "style.font_size")}
        <select name="font_size">
          <option :for={s <- [8, 10, 12, 14, 16, 18, 24, 32, 48]} value={s} selected={round(@st[:font_size] || 14) == s}>{s}</option>
        </select>
      </label>
      <label :if={Map.has_key?(@st, :font)} class="epdf-field-inline">
        {t(assigns, "style.font")}
        <select name="font">
          <option :for={{v, l} <- [helvetica: "Helvetica", times: "Times", courier: "Courier"]} value={v} selected={@st[:font] == to_string(v)}>{l}</option>
        </select>
      </label>
      <label :if={Map.has_key?(@st, :opacity)} class="epdf-field-inline">
        {t(assigns, "style.opacity")}
        <input type="range" name="opacity" min="10" max="100" step="5" value={round((@st[:opacity] || 1.0) * 100)} />
      </label>
    </form>
    """
  end

  defp swatches, do: @swatches

  defp pages_controls(assigns) do
    ~H"""
    <span class="epdf-sep"></span>
    <button class="epdf-btn" phx-click="pages" phx-value-op="rotate_ccw" title={t(assigns, "pages.rotate_ccw")}><.icon name="rotate-ccw" /></button>
    <button class="epdf-btn" phx-click="pages" phx-value-op="rotate_cw" title={t(assigns, "pages.rotate_cw")}><.icon name="rotate-cw" /></button>
    <button class="epdf-btn" phx-click="pages" phx-value-op="up" title={t(assigns, "pages.move_up")}><.icon name="chevron-up" /></button>
    <button class="epdf-btn" phx-click="pages" phx-value-op="down" title={t(assigns, "pages.move_down")}><.icon name="chevron-down" /></button>
    <button class="epdf-btn" phx-click="pages" phx-value-op="duplicate" title={t(assigns, "pages.duplicate")}><.icon name="copy" /></button>
    <button class="epdf-btn" phx-click="pages" phx-value-op="blank" title={t(assigns, "pages.insert_blank")}><.icon name="file" /></button>
    <label class="epdf-btn" for={@uploads.insert.ref} title={t(assigns, "pages.insert_file")}><.icon name="upload" /></label>
    <button class="epdf-btn" phx-click="pages_extract" title={t(assigns, "pages.extract")}><.icon name="download" /></button>
    <button class="epdf-btn epdf-danger" phx-click="pages" phx-value-op="delete" title={t(assigns, "pages.delete")}><.icon name="trash" /></button>
    <button class="epdf-btn epdf-btn-text" phx-click="pages_select_all">{t(assigns, "pages.select_all")}</button>
    <span class="epdf-muted">{t(assigns, "pages.selected", %{count: MapSet.size(@selected_pages)})}</span>
    """
  end

  # ---------------------------------------------------------------- hint strip

  defp hint(assigns) do
    assigns = assign(assigns, :hint, hint_key(assigns))

    ~H"""
    <div :if={@hint} class="epdf-hint" role="status">
      <span>{t(assigns, @hint)}</span>
      <button :if={@tool in [:ink, :polygon, :polyline]} class="epdf-btn epdf-btn-text epdf-primary" phx-click="finish_tool" disabled={length(@points) < 2}>
        {t(assigns, "tool.finish")}
      </button>
      <button class="epdf-btn epdf-btn-text" phx-click="cancel_tool">{t(assigns, "tool.cancel")}</button>
    </div>
    """
  end

  defp hint_key(%{status: :ready} = a) do
    cond do
      a.moving? -> "annotation.move_hint"
      a.resizing? -> "annotation.resize_hint"
      a.tool in Viewer.text_tools() and a.anchor -> "hint.text_end"
      a.tool in Viewer.text_tools() -> "hint.text"
      a.tool in [:square, :circle, :redact_area] and a.points != [] -> "hint.second_point"
      a.tool in [:square, :circle, :redact_area, :link] -> "hint.two_points"
      a.tool in [:line, :arrow, :measure] -> "hint.line"
      a.tool in [:ink, :polygon, :polyline] -> "hint.points"
      a.tool in [:note, :stamp, :free_text] -> "hint.place"
      a.tool == :snapshot -> "hint.snapshot"
      a.tool == :zoom_area -> "hint.zoom"
      true -> nil
    end
  end

  defp hint_key(_), do: nil

  # ---------------------------------------------------------------- viewport & pages

  defp viewport(assigns) do
    a = assigns
    sizes = Enum.map(a.sizes, &Layout.rotated(&1, a.rotation))
    count = length(sizes)

    rows =
      case a.scroll do
        :paged -> [Layout.row_of(Layout.rows(count, a.spread), a.current_page)]
        :horizontal -> [Enum.to_list(0..(count - 1)//1)]
        :vertical -> Layout.rows(count, a.spread)
      end

    assigns = assign(assigns, rows: rows, rsizes: List.to_tuple(sizes))

    ~H"""
    <div
      class={["epdf-viewport", "epdf-scroll-#{@scroll}", @tool == :pan && "epdf-pan"]}
      id={"#{@viewer_id}-viewport"}
      tabindex="0"
      phx-keydown="key"
      style={"--epdf-scale:#{fmt(@scale)}"}
    >
      <div class="epdf-probe-w" aria-hidden="true"></div>
      <div class="epdf-probe-h" aria-hidden="true"></div>
      <div class="epdf-pages">
        <div :for={row <- @rows} class="epdf-row">
          <.live_component
            :for={i <- row}
            module={EmbedPdf.Live.PageComponent}
            id={"#{@viewer_id}-pc-#{i}"}
            {EmbedPdf.Live.PageComponent.assigns_for(assigns, i, elem(@rsizes, i))}
          />
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------- pager

  defp pager(assigns) do
    ~H"""
    <div class="epdf-pager" role="navigation">
      <button class="epdf-btn" phx-click="page" phx-value-to="first" title={t(assigns, "page.first")} aria-label={t(assigns, "page.first")}><.icon name="first" /></button>
      <button class="epdf-btn" phx-click="page" phx-value-to="prev" title={t(assigns, "page.previous")} aria-label={t(assigns, "page.previous")}><.icon name="chevron-left" /></button>
      <form phx-submit="goto_page" class="epdf-page-input">
        <input type="text" inputmode="numeric" name="page" value={@current_page + 1} aria-label={t(assigns, "page.label")} />
        <span>/ {length(@sizes)}</span>
      </form>
      <button class="epdf-btn" phx-click="page" phx-value-to="next" title={t(assigns, "page.next")} aria-label={t(assigns, "page.next")}><.icon name="chevron-right" /></button>
      <button class="epdf-btn" phx-click="page" phx-value-to="last" title={t(assigns, "page.last")} aria-label={t(assigns, "page.last")}><.icon name="last" /></button>
    </div>
    """
  end

  # ---------------------------------------------------------------- empty states

  defp empty(assigns) do
    ~H"""
    <div class="epdf-empty" phx-drop-target={@uploads.pdf.ref}>
      <div class="epdf-empty-card">
        <.icon name="file" class="epdf-icon-xl" />
        <p :if={@status == :error} class="epdf-error">{t(assigns, @error || "error.open")}</p>
        <h2>{t(assigns, "open.title")}</h2>
        <p>{t(assigns, "open.drop")}</p>
        <label :if={@f["documents.open"]} class="epdf-btn epdf-btn-text epdf-primary" for={@uploads.pdf.ref}>{t(assigns, "open.choose")}</label>
        <div :for={entry <- @uploads.pdf.entries} class="epdf-progress"><span style={"width:#{entry.progress}%"}></span></div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------- left panel

  defp left_panel(assigns) do
    ~H"""
    <aside class="epdf-panel epdf-panel-left">
      <div class="epdf-panel-tabs">
        <button :if={@f["thumbnails"]} class={["epdf-btn", @left == :thumbnails && "is-active"]} phx-click="panel" phx-value-side="left" phx-value-panel="thumbnails" title={t(assigns, "panel.thumbnails")}><.icon name="thumbnails" /></button>
        <button :if={@f["outline"]} class={["epdf-btn", @left == :outline && "is-active"]} phx-click="panel" phx-value-side="left" phx-value-panel="outline" title={t(assigns, "panel.outline")}><.icon name="outline" /></button>
        <button :if={@f["attachments"]} class={["epdf-btn", @left == :attachments && "is-active"]} phx-click="panel" phx-value-side="left" phx-value-panel="attachments" title={t(assigns, "panel.attachments")}><.icon name="paperclip" /></button>
        <button class="epdf-btn epdf-right" phx-click="close_panel" phx-value-side="left" title={t(assigns, "panel.close")}><.icon name="close" /></button>
      </div>
      <div class="epdf-panel-body">
        <.thumbnails :if={@left == :thumbnails} {assigns} />
        <.outline :if={@left == :outline} {assigns} />
        <.attachments :if={@left == :attachments} {assigns} />
      </div>
    </aside>
    """
  end

  defp thumbnails(assigns) do
    ~H"""
    <div class="epdf-thumbs">
      <a
        :for={{{w, h}, i} <- Enum.with_index(@sizes)}
        href={"##{@viewer_id}-page-#{i}"}
        class={["epdf-thumb", i == @current_page && "is-current", MapSet.member?(@selected_pages, i) && "is-selected"]}
        phx-click={if @mode == :pages, do: "page_select", else: "goto_page"}
        phx-value-page={if @mode == :pages, do: i, else: i + 1}
      >
        <img
          src={"#{@base}/d/#{@doc_id}/#{Map.get(@page_revs, i, 0)}/p/#{i}.svg?r=#{@rotation}"}
          loading="lazy"
          alt=""
          style={"aspect-ratio:#{fmt(elem(Layout.rotated({w, h}, @rotation), 0))}/#{fmt(elem(Layout.rotated({w, h}, @rotation), 1))}"}
        />
        <span>{i + 1}</span>
      </a>
    </div>
    """
  end

  defp outline(assigns) do
    ~H"""
    <div class="epdf-outline">
      <div class="epdf-panel-actions">
        <button class="epdf-btn epdf-btn-text" phx-click="outline_all" phx-value-open="true">{t(assigns, "outline.expand_all")}</button>
        <button class="epdf-btn epdf-btn-text" phx-click="outline_all" phx-value-open="false">{t(assigns, "outline.collapse_all")}</button>
      </div>
      <p :if={@outline == []} class="epdf-muted">{t(assigns, "outline.empty")}</p>
      <.outline_items :if={is_list(@outline)} items={@outline} {assigns} />
      <form :if={@f["outline.editing"]} class="epdf-inline-form" phx-submit="outline_add">
        <input type="text" name="title" placeholder={t(assigns, "outline.add")} />
        <button class="epdf-btn" type="submit" title={t(assigns, "outline.add")}><.icon name="bookmark" /></button>
      </form>
    </div>
    """
  end

  defp outline_items(assigns) do
    ~H"""
    <ul class="epdf-tree">
      <li :for={item <- @items}>
        <div class="epdf-tree-row">
          <button :if={(item.children || []) != []} class="epdf-tree-toggle" phx-click="outline_toggle" phx-value-id={item.id} aria-expanded={to_string(MapSet.member?(@outline_open, item.id))}>
            <.icon name={if MapSet.member?(@outline_open, item.id), do: "chevron-down", else: "chevron-right"} class="epdf-icon-sm" />
          </button>
          <span :if={(item.children || []) == []} class="epdf-tree-spacer"></span>
          <%= case outline_target(item) do %>
            <% {:page, p} -> %>
              <a href={"##{@viewer_id}-page-#{p}"} class={["epdf-tree-link", item[:bold?] && "is-bold", item[:italic?] && "is-italic"]} phx-click="outline_goto" phx-value-page={p}>{item.title}</a>
            <% {:uri, uri} -> %>
              <a href={EmbedPdf.Live.PageComponent.safe_url(uri)} target="_blank" rel="noopener noreferrer" class="epdf-tree-link">{item.title}</a>
            <% _ -> %>
              <span class="epdf-tree-link">{item.title}</span>
          <% end %>
          <div :if={@f["outline.editing"]} class="epdf-tree-actions">
            <button class="epdf-btn epdf-btn-sm" phx-click="outline_edit" phx-value-id={item.id} phx-value-action="up" title={t(assigns, "outline.up")}><.icon name="chevron-up" class="epdf-icon-sm" /></button>
            <button class="epdf-btn epdf-btn-sm" phx-click="outline_edit" phx-value-id={item.id} phx-value-action="down" title={t(assigns, "outline.down")}><.icon name="chevron-down" class="epdf-icon-sm" /></button>
            <button class="epdf-btn epdf-btn-sm epdf-danger" phx-click="outline_edit" phx-value-id={item.id} phx-value-action="delete" title={t(assigns, "outline.delete")}><.icon name="trash" class="epdf-icon-sm" /></button>
          </div>
        </div>
        <.outline_items :if={(item.children || []) != [] and MapSet.member?(@outline_open, item.id)} items={item.children} {Map.delete(assigns, :items)} />
      </li>
    </ul>
    """
  end

  defp outline_target(%{dest: %{page: p}}) when is_integer(p), do: {:page, p}
  defp outline_target(%{action: {:uri, uri}}), do: {:uri, uri}
  defp outline_target(%{action: {:goto, %{page: p}}}) when is_integer(p), do: {:page, p}
  defp outline_target(_), do: nil

  defp attachments(assigns) do
    ~H"""
    <div class="epdf-attachments">
      <p :if={@attachments == []} class="epdf-muted">{t(assigns, "attachments.empty")}</p>
      <div :for={a <- @attachments || []} class="epdf-attachment">
        <.icon name="paperclip" />
        <div class="epdf-attachment-info">
          <strong>{a.name}</strong>
          <span class="epdf-muted">{human_size(a[:size])}{if a[:description], do: " · " <> a.description}</span>
        </div>
        <a class="epdf-btn" href={"#{@base}/d/#{@doc_id}/attachment/#{a.id}"} download={a.name} title={t(assigns, "attachments.save")}><.icon name="download" /></a>
        <button :if={@f["attachments.adding"]} class="epdf-btn epdf-danger" phx-click="attachment_delete" phx-value-id={a.id} title={t(assigns, "attachments.delete")}><.icon name="trash" /></button>
      </div>
      <label :if={@f["attachments.adding"]} class="epdf-btn epdf-btn-text" for={@uploads.attachment.ref}><.icon name="paperclip" /> {t(assigns, "attachments.add")}</label>
    </div>
    """
  end

  defp human_size(nil), do: ""
  defp human_size(n) when n < 1024, do: "#{n} B"
  defp human_size(n) when n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KB"
  defp human_size(n), do: "#{Float.round(n / 1_048_576, 1)} MB"

  # ---------------------------------------------------------------- right panel

  defp right_panel(assigns) do
    ~H"""
    <aside class="epdf-panel epdf-panel-right">
      <div class="epdf-panel-head">
        <strong>{t(assigns, panel_title(@right))}</strong>
        <button class="epdf-btn" phx-click="close_panel" phx-value-side="right" title={t(assigns, "panel.close")}><.icon name="close" /></button>
      </div>
      <div class="epdf-panel-body">
        <.search_panel :if={@right == :search} {assigns} />
        <.comments_panel :if={@right == :comments} {assigns} />
        <.annotation_panel :if={@right == :annotation} {assigns} />
        <.redact_panel :if={@right == :redact} {assigns} />
      </div>
    </aside>
    """
  end

  defp panel_title(:search), do: "panel.search"
  defp panel_title(:comments), do: "panel.comments"
  defp panel_title(:annotation), do: "annotation.properties"
  defp panel_title(:redact), do: "redact.pending"
  defp panel_title(_), do: "panel.sidebar"

  defp search_panel(assigns) do
    assigns =
      assign(assigns,
        grouped:
          assigns.search.hits |> Enum.with_index() |> Enum.chunk_by(fn {h, _} -> h.page end)
      )

    ~H"""
    <form id={"#{@viewer_id}-search"} class="epdf-search" phx-change="search" phx-submit="search_nav">
      <div class="epdf-search-box">
        <.icon name="search" class="epdf-icon-sm" />
        <input type="search" name="q" value={@search.query} placeholder={t(assigns, "search.placeholder")} phx-debounce="300" autocomplete="off" phx-mounted={JS.focus()} />
      </div>
      <label class="epdf-check-label"><input type="hidden" name="case" value="false" /><input type="checkbox" name="case" value="true" checked={@search.case} /> {t(assigns, "search.case")}</label>
      <label class="epdf-check-label"><input type="hidden" name="whole" value="false" /><input type="checkbox" name="whole" value="true" checked={@search.whole} /> {t(assigns, "search.whole")}</label>
    </form>
    <div :if={@search.query != ""} class="epdf-search-nav">
      <span>{if @search.hits == [], do: t(assigns, "search.no_results"), else: t(assigns, "search.results", %{count: length(@search.hits)})}</span>
      <button class="epdf-btn" phx-click="search_nav" phx-value-dir="prev" disabled={@search.hits == []} title={t(assigns, "search.previous")}><.icon name="chevron-up" /></button>
      <button class="epdf-btn" phx-click="search_nav" phx-value-dir="next" disabled={@search.hits == []} title={t(assigns, "search.next")}><.icon name="chevron-down" /></button>
    </div>
    <div class="epdf-results">
      <div :for={group <- @grouped} class="epdf-result-group">
        <div class="epdf-result-page">{t(assigns, "comments.page", %{page: elem(hd(group), 0).page + 1})}</div>
        <button
          :for={{hit, idx} <- group}
          class={["epdf-result", idx == @search.current && "is-current"]}
          phx-click="search_goto"
          phx-value-i={idx}
        >
          <span>…{hit.before}</span><mark>{hit.text}</mark><span>{hit.after}…</span>
        </button>
      </div>
    </div>
    """
  end

  defp comments_panel(assigns) do
    all =
      for p <- 0..(length(assigns.sizes) - 1)//1,
          a <- Viewer.annotations_for(assigns, p),
          a.subtype not in [:popup, :widget, :link],
          a.in_reply_to == nil,
          do: {p, a}

    assigns = assign(assigns, comments: all)

    ~H"""
    <p :if={@comments == []} class="epdf-muted">{t(assigns, "comments.empty")}</p>
    <div :for={{p, a} <- @comments} class={["epdf-comment", @selected == {p, a.id} && "is-selected"]}>
      <button class="epdf-comment-head" phx-click="comment_goto" phx-value-page={p} phx-value-id={a.id}>
        <span class="epdf-comment-dot" style={"background:#{Viewer.color_hex(a.color) || "#999"}"}></span>
        <strong>{a.author || "—"}</strong>
        <span class="epdf-muted">{t(assigns, "comments.page", %{page: p + 1})} · {a.subtype}</span>
      </button>
      <p :if={a.contents not in [nil, ""]} class="epdf-comment-body">{a.contents}</p>
      <div :for={r <- a.replies || []} class="epdf-reply">
        <strong>{r.author || "—"}</strong>
        <p>{r.contents}</p>
      </div>
      <form :if={@f["comments.writing"]} class="epdf-inline-form" phx-submit="reply">
        <input type="hidden" name="aid" value={a.id} />
        <input type="text" name="text" placeholder={if a.contents in [nil, ""], do: t(assigns, "comments.placeholder"), else: t(assigns, "comments.reply")} />
        <button class="epdf-btn" type="submit" title={t(assigns, "comments.reply")}><.icon name="send" /></button>
      </form>
    </div>
    """
  end

  defp annotation_panel(assigns) do
    annot =
      case assigns.selected do
        {p, id} -> Enum.find(Viewer.annotations_for(assigns, p), &(&1.id == id))
        nil -> nil
      end

    assigns = assign(assigns, annot: annot)

    ~H"""
    <p :if={@annot == nil} class="epdf-muted">—</p>
    <div :if={@annot} class="epdf-props">
      <div class="epdf-props-type">{@annot.subtype}</div>
      <form id={"#{@viewer_id}-props-style"} phx-change="style" class="epdf-props-style">
        <div class="epdf-swatches">
          <label :for={c <- swatches()} class={["epdf-swatch", Viewer.color_hex(@annot.color) == c && "is-active"]} style={"--c:#{c}"}>
            <input type="radio" name="color" value={c} />
          </label>
        </div>
        <label class="epdf-field">{t(assigns, "style.opacity")}
          <input type="range" name="opacity" min="10" max="100" step="5" value={round((@annot.opacity || 1.0) * 100)} />
        </label>
        <label :if={@annot.subtype in [:ink, :square, :circle, :line, :polygon, :polyline]} class="epdf-field">{t(assigns, "style.stroke")}
          <input type="range" name="stroke" min="1" max="12" value={@annot.border_width || 1} />
        </label>
      </form>
      <form phx-submit="annotation_props" class="epdf-props-text">
        <label class="epdf-field">{t(assigns, "annotation.text")}
          <textarea name="contents" rows="4">{@annot.contents}</textarea>
        </label>
        <label :if={@annot.subtype == :free_text} class="epdf-field">{t(assigns, "style.font_size")}
          <input type="number" name="font_size" min="4" max="144" value={@annot.font_size || 12} />
        </label>
        <button type="submit" class="epdf-btn epdf-btn-text epdf-primary">{t(assigns, "annotation.save")}</button>
      </form>
      <div class="epdf-nudge" role="group" aria-label={t(assigns, "annotation.position")}>
        <span></span><button class="epdf-btn" phx-click="nudge" phx-value-dx="0" phx-value-dy="-5"><.icon name="chevron-up" /></button><span></span>
        <button class="epdf-btn" phx-click="nudge" phx-value-dx="-5" phx-value-dy="0"><.icon name="chevron-left" /></button>
        <button class={["epdf-btn", @moving? && "is-active"]} phx-click="move_annotation" title={t(assigns, "annotation.move")}><.icon name="move" /></button>
        <button class="epdf-btn" phx-click="nudge" phx-value-dx="5" phx-value-dy="0"><.icon name="chevron-right" /></button>
        <span></span><button class="epdf-btn" phx-click="nudge" phx-value-dx="0" phx-value-dy="5"><.icon name="chevron-down" /></button><span></span>
      </div>
      <div class="epdf-panel-actions">
        <button class="epdf-btn epdf-btn-text" phx-click="duplicate_annotation"><.icon name="copy" /> {t(assigns, "annotation.duplicate")}</button>
        <button class="epdf-btn epdf-btn-text epdf-danger" phx-click="delete_annotation"><.icon name="trash" /> {t(assigns, "annotation.delete")}</button>
      </div>
    </div>
    """
  end

  defp redact_panel(assigns) do
    marks =
      for p <- 0..(length(assigns.sizes) - 1)//1,
          a <- Viewer.annotations_for(assigns, p),
          a.subtype == :redact,
          do: {p, a}

    assigns = assign(assigns, marks: marks)

    ~H"""
    <p class="epdf-warning">{t(assigns, "redact.warning")}</p>
    <p :if={@marks == []} class="epdf-muted">{t(assigns, "redact.empty")}</p>
    <div :for={{p, a} <- @marks} class="epdf-comment">
      <button class="epdf-comment-head" phx-click="comment_goto" phx-value-page={p} phx-value-id={a.id}>
        <strong>{t(assigns, "comments.page", %{page: p + 1})}</strong>
        <span class="epdf-muted">{a.contents}</span>
      </button>
      <div class="epdf-panel-actions">
        <button class="epdf-btn epdf-btn-text epdf-danger" phx-click="redact_apply" phx-value-id={a.id}>{t(assigns, "redact.apply_one")}</button>
        <button class="epdf-btn epdf-btn-text" phx-click="delete_annotation" phx-value-id={a.id} phx-value-page={p}>{t(assigns, "annotation.delete")}</button>
      </div>
    </div>
    <button :if={@marks != []} class="epdf-btn epdf-btn-text epdf-danger epdf-block" phx-click="redact_apply">{t(assigns, "redact.apply")}</button>
    """
  end

  # ---------------------------------------------------------------- dialogs

  defp dialogs(assigns) do
    ~H"""
    <div :if={@dialog || @snapshot} class="epdf-backdrop">
      <div class="epdf-dialog" role="dialog" aria-modal="true" phx-click-away="close_dialog" phx-window-keydown="close_dialog" phx-key="Escape">
        <%= cond do %>
          <% @snapshot -> %>
            <.snapshot_dialog {assigns} />
          <% @dialog == :print -> %>
            <.print_dialog {assigns} />
          <% @dialog == :properties -> %>
            <.properties_dialog {assigns} />
          <% @dialog == :shortcuts -> %>
            <.shortcuts_dialog {assigns} />
          <% @dialog == :password -> %>
            <.password_dialog {assigns} />
          <% @dialog == :link -> %>
            <.link_dialog {assigns} />
          <% @dialog == :open -> %>
            <h3>{t(assigns, "open.title")}</h3>
            <div class="epdf-drop" phx-drop-target={@uploads.pdf.ref}>
              <p>{t(assigns, "open.drop")}</p>
              <label class="epdf-btn epdf-btn-text epdf-primary" for={@uploads.pdf.ref}>{t(assigns, "open.choose")}</label>
            </div>
          <% match?({:download, _}, @dialog) -> %>
            <h3>{t(assigns, "pages.extract")}</h3>
            <a class="epdf-btn epdf-btn-text epdf-primary" href={elem(@dialog, 1)} download>{t(assigns, "menu.download")}</a>
          <% true -> %>
        <% end %>
        <button class="epdf-btn epdf-dialog-close" phx-click="close_dialog" title={t(assigns, "close")}><.icon name="close" /></button>
      </div>
    </div>
    """
  end

  defp print_dialog(assigns) do
    base = "#{assigns.base}/d/#{assigns.doc_id}/#{assigns.rev}/print?r=#{assigns.rotation}"
    assigns = assign(assigns, print_base: base)

    ~H"""
    <h3>{t(assigns, "print.title")}</h3>
    <div class="epdf-dialog-actions epdf-column">
      <a class="epdf-btn epdf-btn-text" href={@print_base} target="_blank" rel="noopener">{t(assigns, "print.all")}</a>
      <a class="epdf-btn epdf-btn-text" href={@print_base <> "&pages=#{@current_page + 1}"} target="_blank" rel="noopener">{t(assigns, "print.current")} ({@current_page + 1})</a>
      <form method="get" action={"#{@base}/d/#{@doc_id}/#{@rev}/print"} target="_blank" class="epdf-inline-form">
        <input type="hidden" name="r" value={@rotation} />
        <input type="text" name="pages" placeholder="1-3, 5" aria-label={t(assigns, "print.range")} />
        <button class="epdf-btn epdf-btn-text epdf-primary" type="submit">{t(assigns, "print.open")}</button>
      </form>
    </div>
    """
  end

  defp properties_dialog(assigns) do
    meta = EmbedPdf.Metadata.get(assigns.doc)
    assigns = assign(assigns, meta: meta)

    ~H"""
    <h3>{t(assigns, "menu.properties")}</h3>
    <form phx-submit="save_props" class="epdf-props-form">
      <label :for={k <- ~w(title author subject keywords)} class="epdf-field">{t(assigns, "props.#{k}")}
        <input type="text" name={"props[#{k}]"} value={Map.get(@meta, String.to_existing_atom(k))} readonly={!@f["annotations"]} />
      </label>
      <dl class="epdf-dl">
        <dt>{t(assigns, "props.file")}</dt><dd>{@name}</dd>
        <dt>{t(assigns, "props.pages")}</dt><dd>{length(@sizes)}</dd>
        <dt>{t(assigns, "props.size")}</dt><dd>{human_size(@doc.byte_size)}</dd>
        <dt>{t(assigns, "props.version")}</dt><dd>{@doc.version}</dd>
        <dt>{t(assigns, "props.creator")}</dt><dd>{@meta[:creator]}</dd>
        <dt>{t(assigns, "props.producer")}</dt><dd>{@meta[:producer]}</dd>
        <dt>{t(assigns, "props.created")}</dt><dd>{@meta[:created] && Calendar.strftime(@meta[:created], "%Y-%m-%d %H:%M")}</dd>
        <dt>{t(assigns, "props.modified")}</dt><dd>{@meta[:modified] && Calendar.strftime(@meta[:modified], "%Y-%m-%d %H:%M")}</dd>
      </dl>
      <button :if={@f["annotations"]} type="submit" class="epdf-btn epdf-btn-text epdf-primary">{t(assigns, "props.save")}</button>
    </form>
    """
  end

  defp shortcuts_dialog(assigns) do
    ~H"""
    <h3>{t(assigns, "shortcuts.title")}</h3>
    <p class="epdf-muted">{t(assigns, "shortcuts.focus")}</p>
    <dl class="epdf-dl epdf-keys">
      <dt><kbd>→</kbd> <kbd>←</kbd></dt><dd>{t(assigns, "page.next")} / {t(assigns, "page.previous")}</dd>
      <dt><kbd>Home</kbd> <kbd>End</kbd></dt><dd>{t(assigns, "page.first")} / {t(assigns, "page.last")}</dd>
      <dt><kbd>+</kbd> <kbd>-</kbd></dt><dd>{t(assigns, "zoom.in")} / {t(assigns, "zoom.out")}</dd>
      <dt><kbd>0</kbd> <kbd>1</kbd></dt><dd>{t(assigns, "zoom.fit_page")} / {t(assigns, "zoom.fit_width")}</dd>
      <dt><kbd>r</kbd> <kbd>R</kbd></dt><dd>{t(assigns, "view.rotate_cw")} / {t(assigns, "view.rotate_ccw")}</dd>
      <dt><kbd>h</kbd></dt><dd>{t(assigns, "tool.pan")}</dd>
      <dt><kbd>f</kbd></dt><dd>{t(assigns, "panel.search")}</dd>
      <dt><kbd>Enter</kbd></dt><dd>{t(assigns, "tool.finish")}</dd>
      <dt><kbd>Esc</kbd></dt><dd>{t(assigns, "tool.cancel")}</dd>
      <dt><kbd>Delete</kbd></dt><dd>{t(assigns, "annotation.delete")}</dd>
      <dt><kbd>?</kbd></dt><dd>{t(assigns, "shortcuts.title")}</dd>
    </dl>
    """
  end

  defp password_dialog(assigns) do
    ~H"""
    <h3>{t(assigns, "password.title")}</h3>
    <p>{t(assigns, "password.text")}</p>
    <p :if={@pending_password && @pending_password.wrong?} class="epdf-error">{t(assigns, "password.wrong")}</p>
    <form phx-submit="password" class="epdf-inline-form">
      <input type="password" name="password" autocomplete="off" phx-mounted={JS.focus()} />
      <button class="epdf-btn epdf-btn-text epdf-primary" type="submit">{t(assigns, "password.open")}</button>
    </form>
    """
  end

  defp link_dialog(assigns) do
    ~H"""
    <h3>{t(assigns, "link.create")}</h3>
    <form phx-submit="link_create" class="epdf-column">
      <label class="epdf-field">{t(assigns, "link.url")}<input type="url" name="url" placeholder="https://" /></label>
      <label class="epdf-field">{t(assigns, "link.page")}<input type="number" name="page" min="1" max={length(@sizes)} /></label>
      <button class="epdf-btn epdf-btn-text epdf-primary" type="submit">{t(assigns, "ok")}</button>
    </form>
    """
  end

  defp snapshot_dialog(assigns) do
    %{page: page, rect: {x0, y0, x1, y1}} = assigns.snapshot
    size = Enum.at(assigns.sizes, page)
    {rx0, ry0, rx1, ry1} = Layout.rotate_rect({x0, y0, x1, y1}, size, assigns.rotation)

    url =
      "#{assigns.base}/d/#{assigns.doc_id}/#{assigns.rev}/snapshot/#{page}.svg?r=#{assigns.rotation}" <>
        "&x0=#{fmt(rx0)}&y0=#{fmt(ry0)}&x1=#{fmt(rx1)}&y1=#{fmt(ry1)}"

    assigns = assign(assigns, url: url)

    ~H"""
    <h3>{t(assigns, "snapshot.ready")}</h3>
    <img class="epdf-snapshot" src={@url} alt="" />
    <div class="epdf-dialog-actions">
      <a class="epdf-btn epdf-btn-text epdf-primary" href={@url} download={"snapshot-#{@snapshot.page + 1}.svg"}><.icon name="download" /> {t(assigns, "snapshot.save")}</a>
    </div>
    """
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(f), do: :erlang.float_to_binary(f / 1, decimals: 3)
end
