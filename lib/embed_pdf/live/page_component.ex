defmodule EmbedPdf.Live.PageComponent do
  @moduledoc """
  One page of the viewer: the page image, the selectable text layer, and
  the overlays (search hits, annotations, links, form fields, the click
  catcher of point tools). A LiveComponent so a page only re-renders when
  something on that page changed. Its events go to the parent viewer.
  """
  use Phoenix.LiveComponent

  import EmbedPdf.Live.Icons
  alias EmbedPdf.I18n
  alias EmbedPdf.Live.{Layout, Viewer}
  alias EmbedPdf.PDF.{Document, Page}
  alias Phoenix.LiveView.JS

  @pixel "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

  @doc false
  # The assigns a page needs, taken from the viewer's: only what concerns page `i`.
  def assigns_for(a, i, size) do
    on_page = fn
      {^i, _} = v -> v
      _ -> nil
    end

    design? = a.mode == :form and a[:form_design?] == true and a.f["forms.building"] == true

    pointer? =
      a.tool in Viewer.point_tools() or
        ((a.moving? or a.resizing?) and match?({^i, _}, a.selected)) or
        (a[:field_action] != nil and match?({^i, _}, a[:field]))

    forms? = a.mode == :form and a.f["forms.filling"] == true and not design?

    hits =
      a.search.hits
      |> Enum.with_index()
      |> Enum.filter(fn {h, _} -> h.page == i end)
      |> Enum.map(fn {h, idx} -> {h.rects, idx} end)

    anchor_rects =
      case a.anchor do
        {^i, from, to} -> EmbedPdf.Text.rects(Viewer.page_text(a, i), from, to)
        _ -> []
      end

    [
      i: i,
      size: size,
      usize: Enum.at(a.sizes, i),
      rotation: a.rotation,
      viewer_id: a.viewer_id,
      base: a.base,
      doc_id: a.doc_id,
      page_rev: Map.get(a.page_revs, i, 0),
      pg: Document.page(a.doc, i),
      text: Map.get(a.text, i),
      annots: Map.get(a.annots, i),
      hits: hits,
      current_hit: a.search.current,
      anchor_rects: anchor_rects,
      selected: on_page.(a.selected),
      moving?: a.moving?,
      resizing?: a.resizing?,
      editing_text: on_page.(a.editing_text),
      points: for({^i, p} <- a.points, do: p),
      measure: if(a.measure && a.measure.page == i, do: a.measure),
      measure_scale: a.measure_scale,
      fields: if(forms?, do: a.fields || [], else: []),
      forms?: forms?,
      design?: design?,
      design_fields: if(design?, do: a.fields || [], else: []),
      selected_field: on_page.(a[:field]),
      pointer?: pointer?,
      px: if(pointer?, do: {elem(size, 0) * Viewer.scale(a), elem(size, 1) * Viewer.scale(a)}),
      mode: a.mode,
      tool: a.tool,
      f: a.f,
      locale: a.locale,
      overrides: a.overrides,
      current?: a.current_page == i,
      picked?: a.mode == :pages and MapSet.member?(a.selected_pages, i)
    ]
  end

  @impl true
  def render(assigns) do
    {w, h} = assigns.size

    src =
      "#{assigns.base}/d/#{assigns.doc_id}/#{assigns.page_rev}/p/#{assigns.i}.svg?r=#{assigns.rotation}&v=#{assigns.viewer_id}" <>
        if(assigns.forms?, do: "&f=0", else: "")

    assigns = assign(assigns, w: w, h: h, src: src)

    ~H"""
    <div
      id={"#{@viewer_id}-page-#{@i}"}
      class={["epdf-page", @current? && "is-current", @picked? && "is-selected"]}
      style={"width:calc(var(--epdf-scale) * #{fmt(@w)}px);height:calc(var(--epdf-scale) * #{fmt(@h)}px)"}
      phx-click={if @mode == :pages, do: "page_select", else: "page_click"}
      phx-value-page={@i}
      aria-label={"#{t(assigns, "page.label")} #{@i + 1}"}
    >
      <img class="epdf-page-img" src={@src} loading="lazy" decoding="async" alt="" draggable="false" />
      <div :for={k <- 1..7} class={"epdf-seen epdf-seen-#{k}"} aria-hidden="true"></div>
      <div :if={@text && @f["text.selection"]} class="epdf-text-layer"><%= for line <- @text do %><span class="epdf-tl" style={line.style}><%= for part <- line.words do %><%= case part do %><% {:word, text, from, to} -> %><span class="epdf-w" phx-click="word" phx-value-p={@i} phx-value-i={from} phx-value-j={to}>{text}</span><% {:space, text} -> %>{text}<% end %><% end %></span><br /><% end %></div>
      <div class="epdf-overlay">
        <%= for {rects, idx} <- @hits, {rect, k} <- Enum.with_index(rects) do %>
          <div id={if idx == @current_hit and k == 0, do: "#{@viewer_id}-hit"} class={["epdf-hit", idx == @current_hit && "is-current"]} style={rect_style(rect, assigns)}></div>
        <% end %>
        <div :for={rect <- @anchor_rects} class="epdf-anchor" style={rect_style(rect, assigns)}></div>
        <.annotation_marks :if={@annots} {assigns} />
        <.points_preview :if={@points != []} {assigns} />
        <.measure_mark :if={@measure} {assigns} />
        <.form_fields :if={@fields != []} {assigns} />
        <EmbedPdf.Live.FormDesign.outlines :if={@design? and @design_fields != []} {assigns} />
      </div>
      <form :if={@pointer?} class="epdf-pointer" method="get" action={"#{@base}/pointer"} target={"#{@viewer_id}-sink"}>
        <input type="hidden" name="v" value={@viewer_id} />
        <input type="hidden" name="p" value={@i} />
        <input type="hidden" name="w" value={fmt(elem(@px, 0))} />
        <input type="hidden" name="h" value={fmt(elem(@px, 1))} />
        <input type="image" name="pt" alt={t(assigns, "hint.place")} src={pixel()} style={"width:#{fmt(elem(@px, 0))}px;height:#{fmt(elem(@px, 1))}px"} />
      </form>
      <span class="epdf-page-number">{@i + 1}</span>
    </div>
    """
  end

  defp pixel, do: @pixel

  defp t(assigns, key, bindings \\ %{}),
    do: I18n.t(assigns.locale, key, bindings, assigns.overrides)

  # ---------------------------------------------------------------- annotations

  defp annotation_marks(assigns) do
    items =
      for a <- assigns.annots, a.subtype not in [:popup, :widget] do
        {a, rect_style(Page.rect_to_display(assigns.pg, a.rect), assigns)}
      end

    selectable? =
      assigns.tool in [:pointer, :pan] and assigns.mode != :pages and not assigns.forms?

    assigns = assign(assigns, items: items, selectable?: selectable?)

    ~H"""
    <%= for {a, style} <- @items do %>
      <%= cond do %>
        <% a.subtype == :link and @tool in [:pointer, :pan] -> %>
          <.link_mark annot={a} style={style} viewer_id={@viewer_id} />
        <% @selectable? and a.subtype != :link -> %>
          <button
            id={"#{@viewer_id}-annot-#{a.id}"}
            type="button"
            class={["epdf-annot", "epdf-annot-#{a.subtype}", @selected == {@i, a.id} && "is-selected"]}
            style={style}
            phx-click="select_annotation"
            phx-value-page={@i}
            phx-value-id={a.id}
            title={annotation_title(a)}
            aria-label={annotation_title(a) || to_string(a.subtype)}
          ></button>
        <% true -> %>
      <% end %>
    <% end %>
    <.selection_strip :if={@selected} {assigns} />
    """
  end

  defp link_mark(assigns) do
    ~H"""
    <%= case @annot.action do %>
      <% {:uri, url} -> %>
        <a class="epdf-link" style={@style} href={safe_url(url)} target="_blank" rel="noopener noreferrer" title={url}></a>
      <% {:goto, %{page: p}} when is_integer(p) -> %>
        <a class="epdf-link" style={@style} href={"##{@viewer_id}-page-#{p}"} phx-click="goto_page" phx-value-page={p + 1}></a>
      <% {:named, name} -> %>
        <button type="button" class="epdf-link" style={@style} phx-click="page" phx-value-to={named_target(name)} title={name}></button>
      <% _ -> %>
    <% end %>
    """
  end

  defp named_target("PrevPage"), do: "prev"
  defp named_target("FirstPage"), do: "first"
  defp named_target("LastPage"), do: "last"
  defp named_target(_), do: "next"

  @doc false
  def safe_url(url) when is_binary(url) do
    if String.match?(url, ~r/\A(https?:\/\/|mailto:|tel:)[^\s]/i), do: url, else: "#"
  end

  def safe_url(_), do: "#"

  defp annotation_title(a) do
    case [a.contents, a.author] |> Enum.reject(&(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " — ")
    end
  end

  defp selection_strip(assigns) do
    {_page, id} = assigns.selected
    annot = Enum.find(assigns.annots || [], &(&1.id == id))

    assigns =
      assign(assigns,
        annot: annot,
        display: annot && Page.rect_to_display(assigns.pg, annot.rect)
      )

    ~H"""
    <div :if={@annot} class="epdf-strip" style={strip_style(@display, assigns)} role="toolbar">
      <button :if={@annot.subtype == :free_text} class="epdf-btn" phx-click="edit_text" phx-value-id={@annot.id} phx-value-page={@i} title={t(assigns, "annotation.text")}><.icon name="text" /></button>
      <button :if={@f["comments"]} class="epdf-btn" phx-click="panel" phx-value-side="right" phx-value-panel="comments" title={t(assigns, "annotation.comment")}><.icon name="comment" /></button>
      <button class="epdf-btn" phx-click="panel" phx-value-side="right" phx-value-panel="annotation" title={t(assigns, "annotation.style")}><.icon name="highlight" /></button>
      <button class={["epdf-btn", @moving? && "is-active"]} phx-click="move_annotation" title={t(assigns, "annotation.move")}><.icon name="move" /></button>
      <button :if={@annot.subtype not in [:highlight, :underline, :strikeout, :squiggly, :text]} class={["epdf-btn", @resizing? && "is-active"]} phx-click="resize_annotation" title={t(assigns, "annotation.resize")}><.icon name="resize" /></button>
      <button class="epdf-btn" phx-click="duplicate_annotation" title={t(assigns, "annotation.duplicate")}><.icon name="copy" /></button>
      <button :if={@annot.subtype == :redact} class="epdf-btn epdf-danger" phx-click="redact_apply" phx-value-id={@annot.id} title={t(assigns, "redact.apply_one")}><.icon name="check" /></button>
      <button class="epdf-btn epdf-danger" phx-click="delete_annotation" title={t(assigns, "annotation.delete")}><.icon name="trash" /></button>
    </div>
    <form
      :if={@annot && @annot.subtype == :free_text && @editing_text == {@i, @annot.id}}
      id={"#{@viewer_id}-freetext-#{@annot.id}"}
      class="epdf-freetext-editor"
      style={rect_style(@display, assigns)}
      phx-submit="free_text"
    >
      <input type="hidden" name="aid" value={@annot.id} />
      <input type="hidden" name="page" value={@i} />
      <textarea name="text" phx-mounted={JS.focus()}>{@annot.contents}</textarea>
      <button type="submit" class="epdf-btn epdf-btn-text epdf-primary">{t(assigns, "annotation.save")}</button>
    </form>
    """
  end

  # ---------------------------------------------------------------- previews

  defp points_preview(assigns) do
    pts = Enum.map(assigns.points, &Layout.rotate_point(&1, assigns.usize, assigns.rotation))
    assigns = assign(assigns, pts: pts)

    ~H"""
    <svg class="epdf-preview" viewBox={"0 0 #{fmt(@w)} #{fmt(@h)}"} preserveAspectRatio="none">
      <polyline points={Enum.map_join(@pts, " ", fn {x, y} -> "#{fmt(x)},#{fmt(y)}" end)} />
      <circle :for={{x, y} <- @pts} cx={fmt(x)} cy={fmt(y)} r="3" />
    </svg>
    """
  end

  defp measure_mark(assigns) do
    {x0, y0} = Layout.rotate_point(assigns.measure.from, assigns.usize, assigns.rotation)
    {x1, y1} = Layout.rotate_point(assigns.measure.to, assigns.usize, assigns.rotation)
    label = Viewer.measure_label(assigns.measure_scale, assigns.measure.points)

    assigns = assign(assigns, x0: x0, y0: y0, x1: x1, y1: y1, label: label)

    ~H"""
    <svg class="epdf-preview epdf-measure" viewBox={"0 0 #{fmt(@w)} #{fmt(@h)}"} preserveAspectRatio="none">
      <line x1={fmt(@x0)} y1={fmt(@y0)} x2={fmt(@x1)} y2={fmt(@y1)} />
    </svg>
    <span class="epdf-measure-label" style={"left:#{Layout.pct((@x0 + @x1) / 2 / @w)};top:#{Layout.pct((@y0 + @y1) / 2 / @h)}"}>{@label}</span>
    """
  end

  # ---------------------------------------------------------------- form fields

  defp form_fields(assigns) do
    widgets =
      for field <- assigns.fields, w <- field.widgets, w.page == assigns.i do
        {field, w, rect_style(Page.rect_to_display(assigns.pg, w.rect), assigns)}
      end

    assigns = assign(assigns, widgets: widgets)

    ~H"""
    <form :if={@widgets != []} id={"#{@viewer_id}-form-#{@i}"} class="epdf-form" phx-change="form_change" phx-submit="noop">
      <%= for {field, w, style} <- @widgets do %>
        <%= case field.type do %>
          <% :text -> %>
            <%= if field.multiline? do %>
              <textarea name={"field[#{field.id}]"} class="epdf-input" style={style} readonly={field.read_only?} maxlength={field.max_len} phx-debounce="400">{field.value}</textarea>
            <% else %>
              <input
                type={if field.password?, do: "password", else: "text"}
                name={"field[#{field.id}]"}
                value={field.value}
                class="epdf-input"
                style={style}
                readonly={field.read_only?}
                maxlength={field.max_len}
                phx-debounce="400"
              />
            <% end %>
          <% :checkbox -> %>
            <label class="epdf-input epdf-check" style={style}>
              <input type="hidden" name={"field[#{field.id}]"} value="false" />
              <input type="checkbox" name={"field[#{field.id}]"} value="true" checked={w.checked?} disabled={field.read_only?} />
            </label>
          <% :radio -> %>
            <label class="epdf-input epdf-check" style={style}>
              <input type="radio" name={"field[#{field.id}]"} value={w.on_state} checked={w.checked?} disabled={field.read_only?} />
            </label>
          <% type when type in [:combo, :list] -> %>
            <select
              name={if field.multi_select?, do: "field[#{field.id}][]", else: "field[#{field.id}]"}
              class="epdf-input"
              style={style}
              disabled={field.read_only?}
              multiple={field.multi_select?}
              size={if type == :list, do: max(length(field.options), 2)}
            >
              <option :if={type == :combo and field.value in [nil, ""]} value="" selected></option>
              <option :for={{export, label} <- field.options} value={export} selected={export == field.value or (is_list(field.value) and export in field.value)}>{label}</option>
            </select>
          <% _ -> %>
        <% end %>
      <% end %>
    </form>
    """
  end

  # ---------------------------------------------------------------- geometry

  defp rect_style(rect, assigns) do
    rotated = Layout.rotate_rect(rect, assigns.usize, assigns.rotation)
    Layout.percent_style(rotated, assigns.size)
  end

  defp strip_style(rect, assigns) do
    {w, h} = assigns.size
    {x0, y0, _x1, _y1} = Layout.rotate_rect(rect, assigns.usize, assigns.rotation)
    "left:#{Layout.pct(x0 / w)};top:#{Layout.pct(y0 / h)}"
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt(f), do: :erlang.float_to_binary(f / 1, decimals: 3)
end
