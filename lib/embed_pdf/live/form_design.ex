defmodule EmbedPdf.Live.FormDesign do
  @moduledoc """
  The viewer's form design mode (EmbedPDF's `forms.building`): the field
  tools, selecting fields on the page, the field properties panel and the
  move / resize / nudge / duplicate / delete actions.

  The viewer delegates every `"field_*"` event here, and pointer clicks
  while a field tool or a field move/resize is active. State lives in the
  viewer's assigns: `form_design?`, `field` (`{page, widget_id}` or nil)
  and `field_action` (`:move`, `:resize` or nil).
  """
  use Phoenix.Component

  import EmbedPdf.Live.Icons

  alias EmbedPdf.{Forms, I18n}
  alias EmbedPdf.Live.{Layout, Viewer}
  alias EmbedPdf.PDF.{Document, Page}

  @tools [
    form_text: {:text, "text"},
    form_checkbox: {:checkbox, "check"},
    form_radio: {:radio, "circle"},
    form_combo: {:combo, "chevron-down"},
    form_list: {:list, "outline"},
    form_button: {:button, "square"},
    form_signature: {:signature, "pen"}
  ]

  # size of a field placed with a single click (or a tiny drag), in points
  @click_size %{
    text: {160, 24},
    checkbox: {18, 18},
    radio: {18, 18},
    combo: {140, 24},
    list: {140, 72},
    button: {100, 28},
    signature: {160, 48}
  }

  @doc "The field tools (viewer tool atoms)."
  def tools, do: Keyword.keys(@tools)

  @doc "Whether a pointer click belongs to form design."
  def handles?(a) do
    a.mode == :form and
      (a.tool in tools() or (a[:field_action] != nil and a[:field] != nil))
  end

  # ---------------------------------------------------------------- events

  @doc "Handles a `\"field_*\"` event; returns `{:noreply, socket}`."
  def event("field_design", %{"on" => on}, socket) do
    design? = on == "true"

    {:noreply,
     socket
     |> Phoenix.Component.assign(
       form_design?: design?,
       field: nil,
       field_action: nil,
       tool: :pointer,
       points: [],
       right: if(socket.assigns.right == :field, do: nil, else: socket.assigns.right)
     )}
  end

  def event("field_select", %{"page" => p, "id" => id}, socket) do
    page = to_int(p)

    {:noreply,
     Phoenix.Component.assign(socket,
       field: {page, to_int(id)},
       field_action: nil,
       current_page: page,
       right: :field
     )}
  end

  def event("field_deselect", _, socket) do
    {:noreply,
     Phoenix.Component.assign(socket,
       field: nil,
       field_action: nil,
       right: if(socket.assigns.right == :field, do: nil, else: socket.assigns.right)
     )}
  end

  def event("field_action", %{"action" => action}, socket) do
    action = if action == "resize", do: :resize, else: :move
    action = if socket.assigns[:field_action] == action, do: nil, else: action
    {:noreply, Phoenix.Component.assign(socket, field_action: action, tool: :pointer, points: [])}
  end

  def event("field_update", %{"f" => params}, socket) do
    case selected(socket) do
      {page, _wid, field} ->
        {doc, _} = Forms.update_field(socket.assigns.doc, field.id, attrs(field, params))
        {:noreply, commit(socket, doc, [page])}

      nil ->
        {:noreply, socket}
    end
  end

  def event("field_nudge", %{"dx" => dx, "dy" => dy}, socket) do
    case selected(socket) do
      {page, wid, _field} ->
        pg = Document.page(socket.assigns.doc, page)
        {ux0, uy0} = Page.to_user(pg, {0, 0})
        {ux1, uy1} = Page.to_user(pg, {to_float(dx), to_float(dy)})
        {doc, _} = Forms.move_field(socket.assigns.doc, wid, ux1 - ux0, uy1 - uy0)
        {:noreply, commit(socket, doc, [page])}

      nil ->
        {:noreply, socket}
    end
  end

  def event("field_duplicate", _, socket) do
    case selected(socket) do
      {page, wid, _field} ->
        {doc, copy} = Forms.duplicate_field(socket.assigns.doc, wid)
        new_widget = copy.widgets |> Enum.max_by(& &1.id)

        {:noreply,
         socket
         |> commit(doc, [page])
         |> Phoenix.Component.assign(field: {new_widget.page || page, new_widget.id})}

      nil ->
        {:noreply, socket}
    end
  end

  def event("field_delete", _, socket) do
    case selected(socket) do
      {page, _wid, field} ->
        doc = Forms.delete_field(socket.assigns.doc, field.id)
        pages = field.widgets |> Enum.map(& &1.page) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        {:noreply,
         socket
         |> commit(doc, if(pages == [], do: [page], else: pages))
         |> Phoenix.Component.assign(field: nil, field_action: nil, right: nil)}

      nil ->
        {:noreply, socket}
    end
  end

  def event(_, _, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------- pointer

  @doc "A click on page `page` at `point` (displayed points, unrotated view)."
  def pointer(socket, page, point) do
    a = socket.assigns

    cond do
      a[:field_action] != nil and match?({^page, _}, a[:field]) ->
        field_action(socket, page, point)

      a.tool in tools() ->
        case a.points do
          [{^page, first}] -> create(socket, page, first, point)
          _ -> Phoenix.Component.assign(socket, points: [{page, point}])
        end

      true ->
        socket
    end
  end

  defp create(socket, page, {x0, y0}, {x1, y1}) do
    {type, _icon} = @tools[socket.assigns.tool]
    pg = Document.page(socket.assigns.doc, page)

    display =
      if abs(x1 - x0) < 4 and abs(y1 - y0) < 4 do
        {w, h} = @click_size[type]
        {x0, y0, x0 + w, y0 + h}
      else
        {min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)}
      end

    {doc, field} =
      Forms.add_field(
        socket.assigns.doc,
        page,
        Page.rect_to_user(pg, display),
        type,
        defaults(type)
      )

    widget = field.widgets |> Enum.max_by(& &1.id)

    socket
    |> commit(doc, [page])
    |> Phoenix.Component.assign(
      points: [],
      tool: :pointer,
      field: {page, widget.id},
      right: :field
    )
  end

  defp defaults(t) when t in [:combo, :list], do: [options: ["Option 1", "Option 2", "Option 3"]]
  defp defaults(:button), do: [caption: "Button"]
  defp defaults(_), do: []

  defp field_action(socket, page, point) do
    case selected(socket) do
      {^page, wid, field} ->
        pg = Document.page(socket.assigns.doc, page)
        w = Enum.find(field.widgets, &(&1.id == wid))

        {doc, _} =
          case socket.assigns.field_action do
            :move ->
              {x0, y0, x1, y1} = w.rect
              {tx, ty} = Page.to_user(pg, point)
              Forms.move_field(socket.assigns.doc, wid, tx - (x0 + x1) / 2, ty - (y0 + y1) / 2)

            :resize ->
              {dx0, dy0, _, _} = Page.rect_to_display(pg, w.rect)
              {px, py} = point
              display = {min(dx0, px), min(dy0, py), max(dx0 + 4, px), max(dy0 + 4, py)}
              Forms.resize_field(socket.assigns.doc, wid, Page.rect_to_user(pg, display))
          end

        socket |> commit(doc, [page]) |> Phoenix.Component.assign(field_action: nil)

      _ ->
        Phoenix.Component.assign(socket, field_action: nil)
    end
  end

  # ---------------------------------------------------------------- helpers

  defp commit(socket, doc, pages) do
    socket
    |> Viewer.commit(doc, pages)
    |> Phoenix.Component.assign(fields: Forms.fields(doc))
  end

  @doc false
  # {page, widget_id, field} of the selected field, or nil
  def selected(%{assigns: a}), do: selected(a)

  def selected(a) do
    with {page, wid} <- a[:field],
         fields when is_list(fields) <- a.fields || (a.doc && Forms.fields(a.doc)),
         %{} = field <- Enum.find(fields, fn f -> Enum.any?(f.widgets, &(&1.id == wid)) end) do
      {page, wid, field}
    else
      _ -> nil
    end
  end

  defp attrs(field, params) do
    bool = fn key -> params[key] == "true" end
    text = fn key -> if params[key] in [nil, ""], do: nil, else: params[key] end

    common = %{required?: bool.("required"), read_only?: bool.("read_only")}
    common = if text.("name"), do: Map.put(common, :name, params["name"]), else: common

    specific =
      case field.type do
        :text ->
          %{
            multiline?: bool.("multiline"),
            password?: bool.("password"),
            comb?: bool.("comb"),
            max_len: positive(params["max_len"]),
            font_size: to_float(params["font_size"]) || 0.0,
            text_align: align(params["align"]),
            default: text.("default")
          }

        t when t in [:combo, :list] ->
          %{
            options: parse_options(params["options"] || ""),
            font_size: to_float(params["font_size"]) || 0.0,
            text_align: align(params["align"]),
            editable?: t == :combo and bool.("editable"),
            multi_select?: t == :list and bool.("multi_select"),
            default: text.("default")
          }

        :checkbox ->
          %{default: bool.("default")}
          |> then(
            &if(text.("export"),
              do: Map.put(&1, :export, String.trim(params["export"])),
              else: &1
            )
          )

        :button ->
          %{caption: params["caption"] || "", font_size: to_float(params["font_size"]) || 0.0}

        _ ->
          %{}
      end

    Map.merge(common, specific)
  end

  @doc false
  # one option per line: "label" or "export|label"
  def parse_options(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, "|", parts: 2) do
        [e, l] -> {String.trim(e), String.trim(l)}
        [l] -> l
      end
    end)
  end

  @doc false
  def format_options(options) do
    Enum.map_join(options, "\n", fn
      {e, l} when e == l -> l
      {e, l} -> "#{e}|#{l}"
    end)
  end

  defp align("center"), do: :center
  defp align("right"), do: :right
  defp align(_), do: :left

  defp positive(v) do
    case Integer.parse(to_string(v || "")) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_float(v) when is_number(v), do: v / 1

  defp to_float(v) do
    case Float.parse(to_string(v || "")) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp t(assigns, key, bindings \\ %{}),
    do: I18n.t(assigns.locale, key, bindings, assigns.overrides)

  # ---------------------------------------------------------------- components

  @doc "Fill / Design toggle and, in design, the field tools (mode bar)."
  def toolbar(assigns) do
    assigns = assign(assigns, tools: @tools)

    ~H"""
    <span class="epdf-sep"></span>
    <div class="epdf-segmented" role="group">
      <button class={["epdf-btn epdf-btn-text", !@form_design? && "is-active"]} phx-click="field_design" phx-value-on="false">
        {t(assigns, "form.fill")}
      </button>
      <button class={["epdf-btn epdf-btn-text", @form_design? && "is-active"]} phx-click="field_design" phx-value-on="true">
        {t(assigns, "form.design")}
      </button>
    </div>
    <%= if @form_design? do %>
      <span class="epdf-sep"></span>
      <button
        :for={{tool, {_type, icon}} <- @tools}
        class={["epdf-btn", @tool == tool && "is-active"]}
        phx-click="tool"
        phx-value-tool={tool}
        title={t(assigns, "tool.#{tool}")}
        aria-label={t(assigns, "tool.#{tool}")}
        aria-pressed={to_string(@tool == tool)}
      >
        <.icon name={icon} />
      </button>
    <% end %>
    """
  end

  @doc "Outlines of the fields on a page, selectable in design mode (inside a page)."
  def outlines(assigns) do
    widgets =
      for field <- assigns.design_fields, w <- field.widgets, w.page == assigns.i, w.rect do
        rect = Page.rect_to_display(assigns.pg, w.rect)
        rotated = Layout.rotate_rect(rect, assigns.usize, assigns.rotation)
        {field, w, Layout.percent_style(rotated, assigns.size)}
      end

    assigns = assign(assigns, widgets: widgets)

    ~H"""
    <button
      :for={{field, w, style} <- @widgets}
      id={"#{@viewer_id}-field-#{w.id}"}
      type="button"
      class={["epdf-field-outline", "epdf-field-#{field.type}", @selected_field == {@i, w.id} && "is-selected"]}
      style={style}
      phx-click="field_select"
      phx-value-page={@i}
      phx-value-id={w.id}
      title={field.name}
      aria-label={field.name}
    ><span class="epdf-field-name">{field.name}</span></button>
    """
  end

  @doc "The field properties panel (right panel `:field`)."
  def panel(assigns) do
    sel = selected(assigns)

    assigns =
      assign(assigns,
        sel: sel,
        font_size: (sel && Forms.Builder.font_size(assigns.doc, elem(sel, 2))) || 0.0
      )

    ~H"""
    <p :if={@sel == nil} class="epdf-muted">{t(assigns, "field.none")}</p>
    <div :if={@sel} class="epdf-props">
      <% {_page, _wid, field} = @sel %>
      <div class="epdf-props-type">{t(assigns, "field.type.#{field.type}")}</div>
      <form id={"#{@viewer_id}-field-props"} phx-submit="field_update" class="epdf-props-text">
        <label class="epdf-field">{t(assigns, "field.name")}
          <input type="text" name="f[name]" value={field.name} />
        </label>
        <label :if={field.type in [:combo, :list]} class="epdf-field">{t(assigns, "field.options")}
          <textarea name="f[options]" rows="5" placeholder={t(assigns, "field.options_hint")}>{format_options(field.options)}</textarea>
        </label>
        <label :if={field.type in [:text, :combo, :list]} class="epdf-field">{t(assigns, "field.default")}
          <input type="text" name="f[default]" value={if is_binary(field.default), do: field.default} />
        </label>
        <label :if={field.type == :checkbox} class="epdf-field">{t(assigns, "field.export")}
          <input type="text" name="f[export]" value={Enum.find_value(field.widgets, & &1.on_state)} />
        </label>
        <label :if={field.type == :button} class="epdf-field">{t(assigns, "field.caption")}
          <input type="text" name="f[caption]" value={caption(@doc, field)} />
        </label>
        <label :if={field.type == :text} class="epdf-field">{t(assigns, "field.max_len")}
          <input type="number" name="f[max_len]" min="0" value={field.max_len} />
        </label>
        <label :if={field.type in [:text, :combo, :list, :button]} class="epdf-field">{t(assigns, "field.font_size")}
          <select name="f[font_size]">
            <option value="0" selected={@font_size == 0}>{t(assigns, "field.auto")}</option>
            <option :for={s <- [6, 8, 9, 10, 11, 12, 14, 16, 18, 24]} value={s} selected={round(@font_size) == s and @font_size > 0}>{s}</option>
          </select>
        </label>
        <label :if={field.type in [:text, :combo, :list]} class="epdf-field">{t(assigns, "style.align")}
          <select name="f[align]">
            <option :for={a <- [:left, :center, :right]} value={a} selected={field.text_align == a}>{t(assigns, "field.align_#{a}")}</option>
          </select>
        </label>
        <.check :if={field.type == :text} name="multiline" checked={field.multiline?} label={t(assigns, "field.multiline")} />
        <.check :if={field.type == :text} name="password" checked={field.password?} label={t(assigns, "field.password")} />
        <.check :if={field.type == :text} name="comb" checked={field.comb?} label={t(assigns, "field.comb")} />
        <.check :if={field.type == :combo} name="editable" checked={field.editable?} label={t(assigns, "field.editable")} />
        <.check :if={field.type == :list} name="multi_select" checked={field.multi_select?} label={t(assigns, "field.multi_select")} />
        <.check :if={field.type == :checkbox} name="default" checked={field.default == true} label={t(assigns, "field.checked_default")} />
        <.check name="required" checked={field.required?} label={t(assigns, "field.required")} />
        <.check name="read_only" checked={field.read_only?} label={t(assigns, "field.read_only")} />
        <button type="submit" class="epdf-btn epdf-btn-text epdf-primary">{t(assigns, "field.save")}</button>
      </form>
      <div class="epdf-nudge" role="group" aria-label={t(assigns, "annotation.position")}>
        <span></span><button class="epdf-btn" phx-click="field_nudge" phx-value-dx="0" phx-value-dy="-2"><.icon name="chevron-up" /></button><span></span>
        <button class="epdf-btn" phx-click="field_nudge" phx-value-dx="-2" phx-value-dy="0"><.icon name="chevron-left" /></button>
        <button class={["epdf-btn", @field_action == :move && "is-active"]} phx-click="field_action" phx-value-action="move" title={t(assigns, "field.move")}><.icon name="move" /></button>
        <button class="epdf-btn" phx-click="field_nudge" phx-value-dx="2" phx-value-dy="0"><.icon name="chevron-right" /></button>
        <span></span><button class="epdf-btn" phx-click="field_nudge" phx-value-dx="0" phx-value-dy="2"><.icon name="chevron-down" /></button><span></span>
      </div>
      <div class="epdf-panel-actions">
        <button class={["epdf-btn epdf-btn-text", @field_action == :resize && "is-active"]} phx-click="field_action" phx-value-action="resize"><.icon name="square" /> {t(assigns, "field.resize")}</button>
        <button class="epdf-btn epdf-btn-text" phx-click="field_duplicate"><.icon name="copy" /> {t(assigns, "field.duplicate")}</button>
        <button class="epdf-btn epdf-btn-text epdf-danger" phx-click="field_delete"><.icon name="trash" /> {t(assigns, "field.delete")}</button>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :label, :string, required: true

  defp check(assigns) do
    ~H"""
    <label class="epdf-check-label">
      <input type="hidden" name={"f[#{@name}]"} value="false" />
      <input type="checkbox" name={"f[#{@name}]"} value="true" checked={@checked} />
      {@label}
    </label>
    """
  end

  defp caption(doc, field) do
    with %{id: wid} <- List.first(field.widgets),
         %{} = dict <- Document.resolve(doc, {:ref, wid, 0}),
         %{} = mk <- Document.resolve(doc, dict["MK"]) do
      EmbedPdf.Edit.untext(Document.resolve(doc, mk["CA"]))
    else
      _ -> nil
    end
  end

  @doc "Hint key for the hint strip, or nil."
  def hint_key(a) do
    cond do
      a.mode != :form -> nil
      a[:field_action] == :move -> "hint.field_move"
      a[:field_action] == :resize -> "hint.field_resize"
      a.tool in tools() and a.points != [] -> "hint.second_point"
      a.tool in tools() -> "hint.field_place"
      true -> nil
    end
  end
end
