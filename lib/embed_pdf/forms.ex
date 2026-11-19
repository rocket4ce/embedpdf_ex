defmodule EmbedPdf.Forms do
  @moduledoc """
  Interactive form fields (AcroForm): reading them and filling them in.

  `fields/1` returns the terminal fields with their widgets; `set_value/3`
  changes a value and regenerates the widget appearances, so the filled
  form looks the same in every viewer.
  """

  import EmbedPdf.Edit, only: [f: 1]

  alias EmbedPdf.{Edit, Font}
  alias EmbedPdf.PDF.{Document, Page, Serializer, Stream}

  @inheritable ~w(FT Ff V DV DA Q Opt MaxLen)

  # ---------------------------------------------------------------- reading

  @doc """
  Every terminal field:
  `%{id, name, type, value, default, options, multiline?, password?, comb?,
  max_len, read_only?, required?, multi_select?, widgets}` where each
  widget is `%{id, page, rect, on_state, checked?}`.
  """
  @spec fields(Document.t()) :: [map()]
  def fields(doc) do
    case acroform(doc) do
      %{} = form ->
        pages = annot_pages(doc)

        form["Fields"]
        |> then(&Document.resolve(doc, &1))
        |> List.wrap()
        |> walk(doc, nil, %{}, MapSet.new(), pages, 0)
        |> elem(0)

      _ ->
        []
    end
  end

  @doc "A field by id or fully qualified name."
  def get(doc, id_or_name) do
    Enum.find(fields(doc), &(&1.id == id_or_name or &1.name == id_or_name))
  end

  defp acroform(doc), do: Document.get(doc, Document.catalog(doc), "AcroForm")

  defp annot_pages(doc) do
    for page <- doc.pages, {:ref, n, _} <- Edit.annots(doc, page), into: %{}, do: {n, page.index}
  end

  defp walk(refs, doc, prefix, inherited, seen, pages, depth) do
    Enum.reduce(refs, {[], seen}, fn ref, {acc, seen} ->
      n = with {:ref, n, _} <- ref, do: n

      if depth > 32 or (is_integer(n) and MapSet.member?(seen, n)) do
        {acc, seen}
      else
        seen = if is_integer(n), do: MapSet.put(seen, n), else: seen
        dict = Document.resolve(doc, ref)

        if is_map(dict) do
          name = join(prefix, Edit.untext(Document.resolve(doc, dict["T"])))

          inh =
            Enum.reduce(@inheritable, inherited, fn k, i ->
              if Map.has_key?(dict, k), do: Map.put(i, k, Document.resolve(doc, dict[k])), else: i
            end)

          kids = List.wrap(Document.resolve(doc, dict["Kids"]))
          field_kids = Enum.filter(kids, &Map.has_key?(Document.resolve(doc, &1) || %{}, "T"))

          if field_kids != [] do
            {more, seen} = walk(field_kids, doc, name, inh, seen, pages, depth + 1)
            {acc ++ more, seen}
          else
            widgets = if kids == [], do: [ref], else: kids
            {acc ++ [field(doc, n, name, inh, widgets, pages)], seen}
          end
        else
          {acc, seen}
        end
      end
    end)
  end

  defp join(nil, name), do: name
  defp join(prefix, nil), do: prefix
  defp join(prefix, name), do: prefix <> "." <> name

  defp field(doc, id, name, inh, widget_refs, pages) do
    ff = int(inh["Ff"])
    type = type(inh["FT"], ff)

    widgets =
      Enum.flat_map(widget_refs, fn ref ->
        case Document.resolve(doc, ref) do
          %{} = w ->
            wid = with {:ref, n, _} <- ref, do: n
            on = on_state(doc, w)
            as = Document.resolve(doc, w["AS"])

            page =
              case w["P"] do
                {:ref, _, _} = p -> Document.page_index(doc, p)
                _ -> nil
              end || Map.get(pages, wid)

            [
              %{
                id: wid,
                page: page,
                rect: Page.normalize_rect(Document.resolve(doc, w["Rect"]), doc),
                on_state: on,
                checked?: on != nil and as == on
              }
            ]

          _ ->
            []
        end
      end)

    options = options(doc, inh["Opt"], type, widgets)

    %{
      id: id,
      name: name || "",
      type: type,
      value: value(doc, type, inh["V"], widgets),
      default: value(doc, type, inh["DV"], widgets),
      options: options,
      multiline?: bit?(ff, 13),
      password?: bit?(ff, 14),
      comb?: bit?(ff, 25),
      max_len: if(is_integer(inh["MaxLen"]), do: inh["MaxLen"]),
      read_only?: bit?(ff, 1),
      required?: bit?(ff, 2),
      multi_select?: bit?(ff, 22),
      editable?: bit?(ff, 19),
      text_align:
        case(inh["Q"],
          do: (
            1 -> :center
            2 -> :right
            _ -> :left
          )
        ),
      widgets: widgets
    }
  end

  defp int(v) when is_integer(v), do: v
  defp int(_), do: 0

  defp bit?(ff, n), do: Bitwise.band(ff, Bitwise.bsl(1, n - 1)) != 0

  defp type("Tx", _), do: :text
  defp type("Sig", _), do: :signature

  defp type("Btn", ff) do
    cond do
      bit?(ff, 17) -> :button
      bit?(ff, 16) -> :radio
      true -> :checkbox
    end
  end

  defp type("Ch", ff), do: if(bit?(ff, 18), do: :combo, else: :list)
  defp type(_, _), do: :text

  defp on_state(doc, w) do
    case Document.get_in(doc, w, ["AP", "N"]) do
      %{} = states when not is_struct(states) -> states |> Map.keys() |> Enum.find(&(&1 != "Off"))
      _ -> nil
    end
  end

  defp value(doc, :text, v, _), do: text_value(doc, v) || ""
  defp value(doc, t, v, _) when t in [:combo], do: text_value(doc, v)

  defp value(doc, :list, v, _) do
    case Document.resolve(doc, v) do
      list when is_list(list) -> Enum.map(list, &text_value(doc, &1))
      other -> text_value(doc, other)
    end
  end

  defp value(_doc, :checkbox, v, _), do: is_binary(v) and v != "Off"
  defp value(_doc, :radio, v, _), do: if(is_binary(v) and v != "Off", do: v)
  defp value(_doc, :signature, v, _), do: if(v, do: :signed)
  defp value(_doc, _, _, _), do: nil

  defp text_value(doc, v) do
    case Document.resolve(doc, v) do
      {:string, _} = s -> Edit.untext(s)
      %Stream{} = s -> Document.stream_data(doc, s)
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp options(doc, opt, type, widgets) do
    from_opt =
      case Document.resolve(doc, opt) do
        list when is_list(list) ->
          Enum.map(list, fn o ->
            case Document.resolve(doc, o) do
              [e, l] -> {text_value(doc, e), text_value(doc, l)}
              other -> {text_value(doc, other), text_value(doc, other)}
            end
          end)

        _ ->
          []
      end

    if type in [:radio, :checkbox] do
      states = widgets |> Enum.map(& &1.on_state) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      states
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        label =
          case Integer.parse(s) do
            {idx, ""} -> with({_, l} <- Enum.at(from_opt, idx), do: l, else: (_ -> s))
            _ -> with({_, l} <- Enum.at(from_opt, i), do: l, else: (_ -> s))
          end

        {s, label}
      end)
    else
      from_opt
    end
  end

  # ---------------------------------------------------------------- writing

  @doc """
  Sets a field's value and regenerates its widgets' appearances.
  Text and combo boxes take a string, check boxes a boolean, radio groups
  the on-state (or label) of the button to select, list boxes a string or
  a list of strings.
  """
  @spec set_value(Document.t(), integer() | String.t(), term()) :: Document.t()
  def set_value(doc, id_or_name, value) do
    case get(doc, id_or_name) do
      nil -> doc
      field -> doc |> write_value(field, value) |> no_need_appearances()
    end
  end

  @doc "Sets several fields: a map of id or name → value."
  def set_values(doc, values),
    do: Enum.reduce(values, doc, fn {k, v}, d -> set_value(d, k, v) end)

  @doc "Resets every field to its default value."
  @spec reset(Document.t()) :: Document.t()
  def reset(doc) do
    Enum.reduce(fields(doc), doc, fn field, d ->
      default =
        case field.type do
          :text -> field.default || ""
          :checkbox -> field.default || false
          :radio -> field.default
          :combo -> field.default
          :list -> field.default
          _ -> :skip
        end

      if default == :skip,
        do: d,
        else: d |> write_value(field, default) |> clear_value_if_nil(field, default)
    end)
    |> no_need_appearances()
  end

  defp clear_value_if_nil(doc, field, nil), do: update_dict(doc, field.id, &Map.delete(&1, "V"))
  defp clear_value_if_nil(doc, _field, _), do: doc

  defp write_value(doc, %{type: :text} = field, value) do
    text = to_string(value || "")
    text = if field.max_len, do: String.slice(text, 0, field.max_len), else: text
    doc = update_dict(doc, field.id, &Map.put(&1, "V", Edit.text(text)))
    Enum.reduce(field.widgets, doc, &text_appearance(&2, field, &1, text))
  end

  defp write_value(doc, %{type: :combo} = field, value) do
    export = to_string(value || "")

    label =
      Enum.find_value(field.options, export, fn {e, l} -> if e == export or l == export, do: l end)

    export =
      Enum.find_value(field.options, export, fn {e, l} -> if e == export or l == export, do: e end)

    doc = update_dict(doc, field.id, &Map.put(&1, "V", Edit.text(export)))
    Enum.reduce(field.widgets, doc, &text_appearance(&2, field, &1, label))
  end

  defp write_value(doc, %{type: :list} = field, value) do
    selected = value |> List.wrap() |> Enum.map(&to_string/1)
    exports = Enum.map(field.options, &elem(&1, 0))

    indices =
      selected
      |> Enum.map(fn s -> Enum.find_index(field.options, fn {e, l} -> e == s or l == s end) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    chosen = Enum.map(indices, &Enum.at(exports, &1))

    v =
      case chosen do
        [] -> nil
        [one] -> Edit.text(one)
        many -> Enum.map(many, &Edit.text/1)
      end

    doc =
      update_dict(doc, field.id, fn d ->
        d = if v, do: Map.put(d, "V", v), else: Map.delete(d, "V")
        if indices == [], do: Map.delete(d, "I"), else: Map.put(d, "I", indices)
      end)

    Enum.reduce(field.widgets, doc, &list_appearance(&2, field, &1, indices))
  end

  defp write_value(doc, %{type: :checkbox} = field, value) do
    on? =
      value in [true, "true", "on", "On", "Yes", "yes", 1] or
        (is_binary(value) and Enum.any?(field.widgets, &(&1.on_state == value)))

    widget_on = if is_binary(value) and value not in ["true", "on"], do: value, else: nil
    state = if on?, do: widget_on || first_on(field) || "Yes", else: "Off"
    doc = update_dict(doc, field.id, &Map.put(&1, "V", state))

    Enum.reduce(field.widgets, doc, fn w, d ->
      on_state = w.on_state || "Yes"
      d = ensure_button_ap(d, w, on_state, :check)

      update_dict(
        d,
        w.id,
        &Map.put(
          &1,
          "AS",
          if(on? and (widget_on == nil or widget_on == on_state), do: on_state, else: "Off")
        )
      )
    end)
  end

  defp write_value(doc, %{type: :radio} = field, value) do
    state =
      case value do
        nil ->
          "Off"

        v ->
          Enum.find_value(field.options, to_string(v), fn {s, l} ->
            if s == to_string(v) or l == to_string(v), do: s
          end)
      end

    doc = update_dict(doc, field.id, &Map.put(&1, "V", state))

    Enum.reduce(field.widgets, doc, fn w, d ->
      d = ensure_button_ap(d, w, w.on_state || state, :circle)
      update_dict(d, w.id, &Map.put(&1, "AS", if(w.on_state == state, do: state, else: "Off")))
    end)
  end

  defp write_value(doc, _field, _value), do: doc

  defp first_on(field), do: Enum.find_value(field.widgets, & &1.on_state)

  defp update_dict(doc, id, fun) do
    case Document.resolve(doc, {:ref, id, 0}) do
      %{} = d -> Document.put_object(doc, {:ref, id, 0}, fun.(d))
      _ -> doc
    end
  end

  defp no_need_appearances(doc) do
    catalog = Document.catalog(doc)

    case catalog["AcroForm"] do
      {:ref, _, _} = r ->
        Document.put_object(doc, r, Map.put(Document.resolve(doc, r), "NeedAppearances", false))

      %{} = form ->
        Document.put_object(
          doc,
          doc.trailer["Root"],
          Map.put(catalog, "AcroForm", Map.put(form, "NeedAppearances", false))
        )

      _ ->
        doc
    end
  end

  # ---------------------------------------------------------------- appearances

  # the font a widget writes with: {resource name, font ref or dict, size, color ops, font}
  defp da_font(doc, widget_dict, field) do
    form = acroform(doc) || %{}

    da =
      Edit.untext(Document.resolve(doc, widget_dict["DA"])) ||
        inherited_da(doc, field.id) ||
        Edit.untext(Document.resolve(doc, form["DA"])) || "/Helv 0 Tf 0 g"

    {name, size} =
      case Regex.run(~r{/([^\s/]+)\s+([\d.]+)\s+Tf}, da) do
        [_, n, s] -> {n, s |> Float.parse() |> elem(0)}
        _ -> {"Helv", 0.0}
      end

    color_ops =
      case Regex.run(
             ~r/([\d.]+\s+[\d.]+\s+[\d.]+\s+rg|[\d.]+\s+g|[\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+k)\b/,
             da
           ) do
        [op | _] -> op
        _ -> "0 g"
      end

    dr = Document.resolve(doc, form["DR"]) || %{}
    font_ref = Document.get(doc, dr, "Font") |> then(&if is_map(&1), do: Map.get(&1, name))

    font =
      case font_ref && Font.load(doc, font_ref) do
        %Font{type: t} = font when t in ["Type1", "TrueType", "MMType1"] -> font
        _ -> nil
      end

    if font do
      {name, font_ref, size, color_ops, font}
    else
      {"Helv", Edit.std_font_dict("Helvetica"), size, color_ops, nil}
    end
  end

  defp inherited_da(doc, id) do
    case Document.resolve(doc, {:ref, id, 0}) do
      %{} = d ->
        Edit.untext(Document.resolve(doc, d["DA"])) ||
          (d["Parent"] && inherited_da_ref(doc, d["Parent"], 0))

      _ ->
        nil
    end
  end

  defp inherited_da_ref(_doc, _ref, depth) when depth > 16, do: nil

  defp inherited_da_ref(doc, ref, depth) do
    case Document.resolve(doc, ref) do
      %{} = d ->
        Edit.untext(Document.resolve(doc, d["DA"])) ||
          (d["Parent"] && inherited_da_ref(doc, d["Parent"], depth + 1))

      _ ->
        nil
    end
  end

  # width (points) and encoded bytes of text in the widget font
  defp measure(nil, text, size),
    do: {Edit.text_width(text, "Helvetica", size), Edit.winansi(text)}

  defp measure(%Font{} = font, text, size) do
    bytes = Edit.winansi(text)
    w = for <<c <- bytes>>, reduce: 0.0, do: (acc -> acc + Map.get(font.widths, c, 0.5))
    {w * size, bytes}
  end

  defp widget_box(doc, w) do
    dict = Document.resolve(doc, {:ref, w.id, 0})
    {x0, y0, x1, y1} = w.rect || {0, 0, 0, 0}
    mk = Document.resolve(doc, dict["MK"]) || %{}
    bs = Document.resolve(doc, dict["BS"]) || %{}
    rot = Document.resolve(doc, mk["R"]) || 0
    {ww, hh} = if rot in [90, 270], do: {y1 - y0, x1 - x0}, else: {x1 - x0, y1 - y0}
    border = if Map.has_key?(mk, "BC"), do: Document.resolve(doc, bs["W"]) || 1, else: 0

    {dict, ww, hh, rot, Edit.uncolor(Document.resolve(doc, mk["BG"])),
     Edit.uncolor(Document.resolve(doc, mk["BC"])), border}
  end

  defp frame(w, h, bg, bc, border) do
    bg_ops = if bg, do: [color(bg, "rg"), "0 0 ", f(w), " ", f(h), " re f\n"], else: []

    bc_ops =
      if bc && border > 0,
        do: [
          color(bc, "RG"),
          f(border),
          " w ",
          f(border / 2),
          " ",
          f(border / 2),
          " ",
          f(w - border),
          " ",
          f(h - border),
          " re S\n"
        ],
        else: []

    [bg_ops, bc_ops]
  end

  defp color({r, g, b}, op),
    do: [f(Edit.num(r)), " ", f(Edit.num(g)), " ", f(Edit.num(b)), " ", op, "\n"]

  defp rotation_matrix(0, _w, _h), do: %{}
  defp rotation_matrix(90, _w, h), do: %{"Matrix" => [0, 1, -1, 0, Edit.num(h), 0]}
  defp rotation_matrix(180, w, h), do: %{"Matrix" => [-1, 0, 0, -1, Edit.num(w), Edit.num(h)]}
  defp rotation_matrix(270, w, _h), do: %{"Matrix" => [0, -1, 1, 0, 0, Edit.num(w)]}
  defp rotation_matrix(_, _, _), do: %{}

  defp text_appearance(doc, field, w, text) do
    {dict, ww, hh, rot, bg, bc, border} = widget_box(doc, w)
    {res_name, font_value, da_size, color_ops, font} = da_font(doc, dict, field)
    pad = border + 2
    text = if field.password?, do: String.duplicate("*", String.length(text)), else: text
    avail_w = max(ww - 2 * pad, 1)
    avail_h = max(hh - 2 * border, 1)

    size =
      cond do
        da_size > 0 -> da_size
        field.multiline? -> 12.0
        true -> min(avail_h * 0.7, 12.0) |> fit_width(font, text, avail_w)
      end

    size = max(size, 4.0)

    body =
      cond do
        (field.comb? and field.max_len) && field.max_len > 0 ->
          cell = ww / field.max_len

          text
          |> String.graphemes()
          |> Enum.with_index()
          |> Enum.map(fn {g, i} ->
            {gw, bytes} = measure(font, g, size)
            x = i * cell + (cell - gw) / 2
            y = (hh - size * 0.72) / 2
            ["1 0 0 1 ", f(x), " ", f(y), " Tm ", Serializer.serialize({:string, bytes}), " Tj\n"]
          end)

        field.multiline? ->
          base = "Helvetica"

          lines =
            if font,
              do: wrap_font(font, text, size, avail_w),
              else: Edit.wrap(text, base, size, avail_w)

          lines
          |> Enum.with_index()
          |> Enum.map(fn {line, i} ->
            {lw, bytes} = measure(font, line, size)
            x = align_x(field.text_align, pad, avail_w, lw)
            y = hh - pad - size * 0.9 - i * size * 1.15
            ["1 0 0 1 ", f(x), " ", f(y), " Tm ", Serializer.serialize({:string, bytes}), " Tj\n"]
          end)

        true ->
          {tw, bytes} = measure(font, text, size)
          x = align_x(field.text_align, pad, avail_w, tw)
          y = (hh - size * 0.72) / 2
          ["1 0 0 1 ", f(x), " ", f(y), " Tm ", Serializer.serialize({:string, bytes}), " Tj\n"]
      end

    content = [
      frame(ww, hh, bg, bc, border),
      "/Tx BMC\nq ",
      f(border),
      " ",
      f(border),
      " ",
      f(max(ww - 2 * border, 0)),
      " ",
      f(max(hh - 2 * border, 0)),
      " re W n\n",
      "BT /",
      res_name,
      " ",
      f(size),
      " Tf ",
      color_ops,
      "\n",
      body,
      "ET\nQ\nEMC\n"
    ]

    put_widget_ap(
      doc,
      w.id,
      dict,
      Edit.form(
        {0, 0, ww, hh},
        content,
        %{"Font" => %{res_name => font_value}},
        rotation_matrix(rot, ww, hh)
      )
    )
  end

  defp align_x(:center, pad, avail, tw), do: pad + (avail - tw) / 2
  defp align_x(:right, pad, avail, tw), do: pad + avail - tw
  defp align_x(_, pad, _avail, _tw), do: pad

  defp fit_width(size, font, text, avail_w) do
    {tw, _} = measure(font, text, size)
    if tw > avail_w and tw > 0, do: size * avail_w / tw, else: size
  end

  defp wrap_font(font, text, size, max_w) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.flat_map(fn para ->
      {lines, cur} =
        para
        |> String.split(" ")
        |> Enum.reduce({[], nil}, fn word, {lines, cur} ->
          cand = if cur, do: cur <> " " <> word, else: word
          {cw, _} = measure(font, cand, size)
          if cw <= max_w or cur == nil, do: {lines, cand}, else: {[cur | lines], word}
        end)

      Enum.reverse([cur || "" | lines])
    end)
  end

  defp list_appearance(doc, field, w, indices) do
    {dict, ww, hh, rot, bg, bc, border} = widget_box(doc, w)
    {res_name, font_value, da_size, color_ops, font} = da_font(doc, dict, field)
    size = if da_size > 0, do: da_size, else: 12.0
    line_h = size * 1.15
    top = Document.resolve(doc, dict["TI"]) || 0
    top = if indices != [] and hd(indices) * line_h > hh, do: hd(indices), else: top

    rows =
      field.options
      |> Enum.with_index()
      |> Enum.drop(top)
      |> Enum.take(max(trunc(hh / line_h) + 1, 1))
      |> Enum.with_index()
      |> Enum.map(fn {{{_e, label}, idx}, row} ->
        y_top = hh - border - row * line_h
        sel = idx in indices
        {_tw, bytes} = measure(font, label || "", size)

        [
          if(sel,
            do: [
              "0.6 0.75 0.93 rg ",
              f(border),
              " ",
              f(y_top - line_h),
              " ",
              f(ww - 2 * border),
              " ",
              f(line_h),
              " re f\n"
            ],
            else: []
          ),
          "BT /",
          res_name,
          " ",
          f(size),
          " Tf ",
          color_ops,
          " 1 0 0 1 ",
          f(border + 2),
          " ",
          f(y_top - size),
          " Tm ",
          Serializer.serialize({:string, bytes}),
          " Tj ET\n"
        ]
      end)

    content = [
      frame(ww, hh, bg, bc, border),
      "/Tx BMC\nq ",
      f(border),
      " ",
      f(border),
      " ",
      f(max(ww - 2 * border, 0)),
      " ",
      f(max(hh - 2 * border, 0)),
      " re W n\n",
      rows,
      "Q\nEMC\n"
    ]

    put_widget_ap(
      doc,
      w.id,
      dict,
      Edit.form(
        {0, 0, ww, hh},
        content,
        %{"Font" => %{res_name => font_value}},
        rotation_matrix(rot, ww, hh)
      )
    )
  end

  defp put_widget_ap(doc, id, dict, stream) do
    {doc, ref} = Document.add_object(doc, stream)
    ap = Document.resolve(doc, dict["AP"]) || %{}
    Document.put_object(doc, {:ref, id, 0}, Map.put(dict, "AP", Map.put(ap, "N", ref)))
  end

  # check boxes and radio buttons without appearances get simple ones
  defp ensure_button_ap(doc, w, on_state, kind) do
    dict = Document.resolve(doc, {:ref, w.id, 0})

    case Document.get_in(doc, dict, ["AP", "N"]) do
      %{} = states when not is_struct(states) and is_map_key(states, on_state) ->
        if blank?(doc, states[on_state]),
          do: build_button_ap(doc, w, dict, on_state, kind),
          else: doc

      _ ->
        build_button_ap(doc, w, dict, on_state, kind)
    end
  end

  # an appearance that draws nothing ("q Q") is as good as none
  defp blank?(doc, ref) do
    data = Document.stream_data(doc, ref) || ""
    data |> String.replace(~r/[\sqQ]/, "") == ""
  end

  defp build_button_ap(doc, w, dict, on_state, kind) do
    {_d, ww, hh, _rot, bg, bc, border} = widget_box(doc, w)
    frame_ops = frame(ww, hh, bg, bc || {0.0, 0.0, 0.0}, max(border, 1))
    m = min(ww, hh)

    mark =
      case kind do
        :check ->
          [
            "0 g 1 J 1 j ",
            f(m * 0.12),
            " w ",
            f(ww * 0.22),
            " ",
            f(hh * 0.52),
            " m ",
            f(ww * 0.42),
            " ",
            f(hh * 0.28),
            " l ",
            f(ww * 0.8),
            " ",
            f(hh * 0.76),
            " l S\n"
          ]

        :circle ->
          r = m * 0.25
          k = r * 0.5523
          cx = ww / 2
          cy = hh / 2

          [
            "0 g ",
            f(cx + r),
            " ",
            f(cy),
            " m ",
            f(cx + r),
            " ",
            f(cy + k),
            " ",
            f(cx + k),
            " ",
            f(cy + r),
            " ",
            f(cx),
            " ",
            f(cy + r),
            " c ",
            f(cx - k),
            " ",
            f(cy + r),
            " ",
            f(cx - r),
            " ",
            f(cy + k),
            " ",
            f(cx - r),
            " ",
            f(cy),
            " c ",
            f(cx - r),
            " ",
            f(cy - k),
            " ",
            f(cx - k),
            " ",
            f(cy - r),
            " ",
            f(cx),
            " ",
            f(cy - r),
            " c ",
            f(cx + k),
            " ",
            f(cy - r),
            " ",
            f(cx + r),
            " ",
            f(cy - k),
            " ",
            f(cx + r),
            " ",
            f(cy),
            " c f\n"
          ]
      end

    {doc, on_ref} = Document.add_object(doc, Edit.form({0, 0, ww, hh}, [frame_ops, mark]))
    {doc, off_ref} = Document.add_object(doc, Edit.form({0, 0, ww, hh}, frame_ops))
    ap = Document.resolve(doc, dict["AP"]) || %{}

    Document.put_object(
      doc,
      {:ref, w.id, 0},
      Map.put(dict, "AP", Map.put(ap, "N", %{on_state => on_ref, "Off" => off_ref}))
    )
  end

  # ---------------------------------------------------------------- building

  defdelegate add_field(doc, page_index, rect, type, opts \\ []), to: EmbedPdf.Forms.Builder
  defdelegate update_field(doc, id, attrs), to: EmbedPdf.Forms.Builder
  defdelegate move_field(doc, widget_id, dx, dy), to: EmbedPdf.Forms.Builder
  defdelegate resize_field(doc, widget_id, rect), to: EmbedPdf.Forms.Builder
  defdelegate delete_field(doc, id), to: EmbedPdf.Forms.Builder
  defdelegate duplicate_field(doc, id), to: EmbedPdf.Forms.Builder

  @doc false
  # Redraws a field's widgets for `value` (used by the form builder after
  # creating or changing a field). Check boxes and radio buttons get fresh
  # appearances for the on-states their widget maps carry.
  def regenerate(doc, field, value) do
    doc =
      if field.type in [:checkbox, :radio],
        do:
          Enum.reduce(field.widgets, doc, fn w, d ->
            update_dict(d, w.id, &Map.delete(&1, "AP"))
          end),
        else: doc

    doc |> write_value(field, value) |> no_need_appearances()
  end

  @doc "Removes widget annotations (by id) from the field tree, dropping fields left without widgets."
  @spec remove_widgets(Document.t(), [integer()]) :: Document.t()
  def remove_widgets(doc, ids) do
    ids = MapSet.new(ids)
    catalog = Document.catalog(doc)

    case Document.resolve(doc, catalog["AcroForm"]) do
      %{} = form ->
        {fields, doc} = prune(doc, List.wrap(Document.resolve(doc, form["Fields"])), ids, 0)
        form = Map.put(form, "Fields", fields)

        case catalog["AcroForm"] do
          {:ref, _, _} = r -> Document.put_object(doc, r, form)
          _ -> Document.put_object(doc, doc.trailer["Root"], Map.put(catalog, "AcroForm", form))
        end

      _ ->
        doc
    end
  end

  defp prune(doc, refs, _ids, depth) when depth > 32, do: {refs, doc}

  defp prune(doc, refs, ids, depth) do
    Enum.reduce(refs, {[], doc}, fn ref, {acc, d} ->
      n = with {:ref, n, _} <- ref, do: n
      dict = Document.resolve(d, ref)

      cond do
        is_integer(n) and MapSet.member?(ids, n) ->
          {acc, d}

        is_map(dict) and is_list(Document.resolve(d, dict["Kids"])) ->
          {kids, d} = prune(d, Document.resolve(d, dict["Kids"]), ids, depth + 1)

          if kids == [],
            do: {acc, d},
            else: {acc ++ [ref], Document.put_object(d, ref, Map.put(dict, "Kids", kids))}

        true ->
          {acc ++ [ref], d}
      end
    end)
  end
end
