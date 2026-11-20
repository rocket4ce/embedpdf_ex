defmodule EmbedPdf.Annotation do
  @moduledoc """
  An annotation, read from its dictionary into plain Elixir values.

  Geometry is in PDF user space: `rect` and `quad_points` are
  `{x0, y0, x1, y1}`, `ink_list` and `vertices` lists of `{x, y}`, `line`
  `{x1, y1, x2, y2}`. Colors are `{r, g, b}` floats. `id` is the object
  number of the annotation dictionary.
  """

  alias EmbedPdf.{Destinations, Edit}
  alias EmbedPdf.PDF.{Document, Page}

  defstruct id: nil,
            page: nil,
            subtype: :unknown,
            pdf_subtype: nil,
            rect: nil,
            color: nil,
            interior_color: nil,
            opacity: 1.0,
            border_width: 1.0,
            border_style: :solid,
            cloudy_intensity: nil,
            dash: nil,
            contents: nil,
            author: nil,
            subject: nil,
            name: nil,
            created: nil,
            modified: nil,
            flags: 4,
            quad_points: [],
            quad_points_raw: [],
            ink_list: [],
            vertices: [],
            line: nil,
            line_endings: {:none, :none},
            font_size: nil,
            font_color: nil,
            font_family: :helvetica,
            text_align: :left,
            icon: nil,
            in_reply_to: nil,
            reply_type: nil,
            replies: [],
            state: nil,
            state_model: nil,
            open?: false,
            action: nil,
            hidden?: false,
            has_appearance?: false,
            rotation: 0,
            overlay_text: nil,
            popup: nil,
            file: nil,
            custom: %{}

  @type rect :: {float(), float(), float(), float()}
  @type t :: %__MODULE__{}

  @subtypes %{
    "Highlight" => :highlight,
    "Underline" => :underline,
    "StrikeOut" => :strikeout,
    "Squiggly" => :squiggly,
    "Text" => :text,
    "FreeText" => :free_text,
    "Ink" => :ink,
    "Square" => :square,
    "Circle" => :circle,
    "Line" => :line,
    "Polygon" => :polygon,
    "PolyLine" => :polyline,
    "Stamp" => :stamp,
    "Link" => :link,
    "Redact" => :redact,
    "FileAttachment" => :file_attachment,
    "Caret" => :caret,
    "Popup" => :popup,
    "Widget" => :widget
  }
  @pdf_subtypes Map.new(@subtypes, fn {k, v} -> {v, k} end)

  @endings %{
    "None" => :none,
    "Square" => :square,
    "Circle" => :circle,
    "Diamond" => :diamond,
    "OpenArrow" => :open_arrow,
    "ClosedArrow" => :closed_arrow,
    "Butt" => :butt,
    "ROpenArrow" => :r_open_arrow,
    "RClosedArrow" => :r_closed_arrow,
    "Slash" => :slash
  }
  @pdf_endings Map.new(@endings, fn {k, v} -> {v, k} end)

  @known ~w(Type Subtype Rect C IC CA BS Border BE Contents T Subj NM CreationDate M F QuadPoints
            InkList Vertices L LE DA DS Q Name IRT RT State StateModel Open A Dest Rotate
            OverlayText P AP AS Popup FS RC)

  @doc "Subtype atom for a PDF subtype name."
  def subtype_atom(name), do: Map.get(@subtypes, name, :unknown)

  @doc "PDF subtype name for an atom."
  def pdf_subtype(atom), do: Map.get(@pdf_subtypes, atom)

  @doc "Reads an annotation dictionary."
  @spec from_dict(Document.t(), integer() | nil, map(), non_neg_integer() | nil) :: t()
  def from_dict(doc, id, dict, page_index) do
    r = fn key -> Document.resolve(doc, dict[key]) end
    pdf_subtype = r.("Subtype")
    subtype = subtype_atom(pdf_subtype)
    flags = int(r.("F"), 0)
    {bw, bstyle, dash} = border(doc, dict)
    {font_size, font_color, font_family} = default_appearance(doc, dict)

    be = r.("BE")

    {style, intensity} =
      case be do
        %{"S" => "C"} = be -> {:cloudy, num(Document.resolve(doc, be["I"]), 1.0)}
        _ -> {bstyle, nil}
      end

    %__MODULE__{
      id: id,
      page: page_index,
      subtype: subtype,
      pdf_subtype: pdf_subtype,
      rect: Page.normalize_rect(r.("Rect"), doc),
      color: Edit.uncolor(numbers(doc, r.("C"))),
      interior_color: Edit.uncolor(numbers(doc, r.("IC"))),
      opacity: num(r.("CA"), 1.0),
      border_width: bw,
      border_style: style,
      cloudy_intensity: intensity,
      dash: dash,
      contents: Edit.untext(r.("Contents")),
      author: Edit.untext(r.("T")),
      subject: Edit.untext(r.("Subj")),
      name: Edit.untext(r.("NM")),
      created: EmbedPdf.PDF.TextString.parse_date(r.("CreationDate")),
      modified: EmbedPdf.PDF.TextString.parse_date(r.("M")),
      flags: flags,
      hidden?: Bitwise.band(flags, 2) != 0 or Bitwise.band(flags, 32) != 0,
      quad_points: quads(doc, r.("QuadPoints")),
      quad_points_raw: numbers(doc, r.("QuadPoints")) || [],
      ink_list: ink(doc, r.("InkList")),
      vertices: points(numbers(doc, r.("Vertices")) || []),
      line: line(numbers(doc, r.("L"))),
      line_endings: endings(r.("LE")),
      font_size: font_size,
      font_color: font_color,
      font_family: font_family,
      text_align: align(r.("Q")),
      icon: r.("Name") |> name_value(),
      in_reply_to: ref_num(dict["IRT"]),
      reply_type: r.("RT"),
      state: Edit.untext(r.("State")) || name_value(r.("State")),
      state_model: Edit.untext(r.("StateModel")) || name_value(r.("StateModel")),
      open?: r.("Open") == true,
      action: if(subtype in [:link, :widget], do: Destinations.of_item(doc, dict), else: nil),
      has_appearance?: match?(%{"N" => _}, r.("AP")),
      rotation: int(r.("Rotate"), 0),
      overlay_text: Edit.untext(r.("OverlayText")),
      popup: ref_num(dict["Popup"]),
      file: file_info(doc, r.("FS")),
      custom: Map.drop(dict, @known)
    }
  end

  defp name_value(v) when is_binary(v), do: v
  defp name_value(_), do: nil

  defp ref_num({:ref, n, _}), do: n
  defp ref_num(_), do: nil

  defp int(v, _) when is_integer(v), do: v
  defp int(v, _) when is_float(v), do: trunc(v)
  defp int(_, d), do: d

  defp num(v, _) when is_number(v), do: v / 1
  defp num(_, d), do: d

  defp numbers(doc, list) when is_list(list) do
    list = Enum.map(list, &Document.resolve(doc, &1))
    if Enum.all?(list, &is_number/1), do: Enum.map(list, &(&1 / 1)), else: nil
  end

  defp numbers(_, _), do: nil

  defp points(list),
    do: list |> Enum.chunk_every(2, 2, :discard) |> Enum.map(fn [x, y] -> {x, y} end)

  defp quads(doc, list) do
    case numbers(doc, list) do
      nil ->
        []

      nums ->
        nums
        |> Enum.chunk_every(8, 8, :discard)
        |> Enum.map(fn q -> q |> points() |> Edit.bbox() end)
    end
  end

  defp ink(doc, list) when is_list(list) do
    list
    |> Enum.map(&numbers(doc, Document.resolve(doc, &1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&points/1)
  end

  defp ink(_, _), do: []

  defp line([x1, y1, x2, y2 | _]), do: {x1, y1, x2, y2}
  defp line(_), do: nil

  defp endings([a, b | _]), do: {Map.get(@endings, a, :none), Map.get(@endings, b, :none)}
  defp endings(_), do: {:none, :none}

  defp align(1), do: :center
  defp align(2), do: :right
  defp align(_), do: :left

  defp border(doc, dict) do
    case Document.resolve(doc, dict["BS"]) do
      %{} = bs ->
        w = num(Document.resolve(doc, bs["W"]), 1.0)
        style = if Document.resolve(doc, bs["S"]) == "D", do: :dashed, else: :solid
        dash = numbers(doc, Document.resolve(doc, bs["D"]))
        {w, style, if(style == :dashed, do: dash || [3.0], else: nil)}

      _ ->
        case Document.resolve(doc, dict["Border"]) do
          [_, _, w | rest] when is_number(w) ->
            dash =
              case rest do
                [d | _] when is_list(d) -> numbers(doc, d)
                _ -> nil
              end

            {w / 1, if(dash, do: :dashed, else: :solid), dash}

          _ ->
            {1.0, :solid, nil}
        end
    end
  end

  defp default_appearance(doc, dict) do
    da = Edit.untext(Document.resolve(doc, dict["DA"])) || ""
    # the patterns below backtrack: a real /DA is a few dozen bytes
    da = binary_part(da, 0, min(byte_size(da), 1024))
    ds = Edit.untext(Document.resolve(doc, dict["DS"])) || ""

    size =
      case Regex.run(~r/([\d.]+)\s+Tf/, da) do
        [_, s] ->
          parse_float(s)

        _ ->
          case Regex.run(~r/font-size:\s*([\d.]+)/i, ds) do
            [_, s] -> parse_float(s)
            _ -> nil
          end
      end

    color =
      case Regex.run(~r/([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+rg/, da) do
        [_, r, g, b] ->
          {parse_float(r), parse_float(g), parse_float(b)}

        _ ->
          case Regex.run(~r/([\d.]+)\s+g(\s|$)/, da) do
            [_, g, _] -> {parse_float(g), parse_float(g), parse_float(g)}
            _ -> ds_color(ds)
          end
      end

    family =
      case Regex.run(~r{/([^\s/]+)\s+[\d.]+\s+Tf}, da) do
        [_, name] ->
          family_of(name)

        _ ->
          if ds =~ ~r/times/i,
            do: :times,
            else: if(ds =~ ~r/courier/i, do: :courier, else: :helvetica)
      end

    {size, color, family}
  end

  defp ds_color(ds) do
    case Regex.run(~r/color:\s*#([0-9a-fA-F]{6})/, ds) do
      [_, hex] ->
        <<r, g, b>> = Base.decode16!(hex, case: :mixed)
        {r / 255, g / 255, b / 255}

      _ ->
        nil
    end
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  @doc false
  def family_of(name) do
    lower = String.downcase(name)

    cond do
      String.contains?(lower, ["cour", "mono"]) -> :courier
      String.contains?(lower, ["tiro", "times", "serif", "roman"]) -> :times
      true -> :helvetica
    end
  end

  defp file_info(doc, %{} = fs) do
    ef = Document.resolve(doc, fs["EF"]) || %{}
    stream_ref = ef["UF"] || ef["F"]

    name =
      Edit.untext(Document.resolve(doc, fs["UF"])) || Edit.untext(Document.resolve(doc, fs["F"]))

    %{name: name, stream: ref_num(stream_ref)}
  end

  defp file_info(_, _), do: nil

  # ---------------------------------------------------------------- writing

  @doc """
  Writes the annotation's fields into `base` (the existing dictionary or
  an empty map) and returns the new dictionary. Keys the struct does not
  model are kept.
  """
  @spec to_dict(t(), map()) :: map()
  def to_dict(%__MODULE__{} = a, base \\ %{}) do
    pdf_subtype = a.pdf_subtype || pdf_subtype(a.subtype) || "Square"

    base
    |> Map.merge(a.custom)
    |> Map.put("Type", "Annot")
    |> Map.put("Subtype", pdf_subtype)
    |> put("Rect", a.rect && Edit.rect_array(a.rect))
    |> put("C", Edit.color(a.color))
    |> put("IC", Edit.color(a.interior_color))
    |> put("CA", if(a.opacity && a.opacity < 1.0, do: Edit.num(a.opacity), else: nil))
    |> put_border(a)
    |> put("Contents", Edit.text(a.contents))
    |> put("T", Edit.text(a.author))
    |> put("Subj", Edit.text(a.subject))
    |> put("NM", Edit.text(a.name))
    |> put("CreationDate", a.created && Edit.date(a.created))
    |> put("M", Edit.date(a.modified))
    |> Map.put("F", flags(a))
    |> put("QuadPoints", quad_array(a))
    |> put("InkList", if(a.ink_list != [], do: Enum.map(a.ink_list, &flat_points/1), else: nil))
    |> put("Vertices", if(a.vertices != [], do: flat_points(a.vertices), else: nil))
    |> put("L", a.line && a.line |> Tuple.to_list() |> Enum.map(&Edit.num/1))
    |> put("LE", line_endings(a))
    |> put_text_style(a)
    |> put("Name", a.icon)
    |> put("IRT", a.in_reply_to && {:ref, a.in_reply_to, 0})
    |> put("RT", a.in_reply_to && a.reply_type)
    |> put("State", a.state && Edit.text(a.state))
    |> put("StateModel", a.state_model && Edit.text(a.state_model))
    |> put("Open", if(a.subtype == :text or a.subtype == :popup, do: a.open?, else: nil))
    |> put("Rotate", if(a.rotation != 0, do: a.rotation, else: nil))
    |> put("OverlayText", a.overlay_text && Edit.text(a.overlay_text))
    |> Map.delete("RC")
  end

  defp put(map, key, nil), do: Map.delete(map, key)
  defp put(map, key, value), do: Map.put(map, key, value)

  defp flags(a) do
    base = Bitwise.band(a.flags || 4, Bitwise.bnot(2))
    if a.hidden?, do: Bitwise.bor(base, 2), else: base
  end

  defp put_border(map, a) do
    cond do
      a.subtype in [:link] and (a.border_width || 0) == 0 ->
        map |> Map.put("Border", [0, 0, 0]) |> Map.delete("BS")

      a.subtype in [
        :square,
        :circle,
        :line,
        :ink,
        :polygon,
        :polyline,
        :free_text,
        :link,
        :redact
      ] ->
        bs = %{
          "Type" => "Border",
          "W" => Edit.num(a.border_width || 1.0),
          "S" => if(a.border_style == :dashed, do: "D", else: "S")
        }

        bs =
          if a.border_style == :dashed,
            do: Map.put(bs, "D", Enum.map(a.dash || [3.0], &Edit.num/1)),
            else: bs

        map = map |> Map.put("BS", bs) |> Map.delete("Border")

        if a.border_style == :cloudy,
          do: Map.put(map, "BE", %{"S" => "C", "I" => Edit.num(a.cloudy_intensity || 1.0)}),
          else: Map.delete(map, "BE")

      true ->
        map
    end
  end

  defp quad_array(%__MODULE__{subtype: s} = a)
       when s in [:highlight, :underline, :strikeout, :squiggly, :redact, :link] do
    cond do
      a.quad_points_raw != [] -> Enum.map(a.quad_points_raw, &Edit.num/1)
      a.quad_points != [] -> Enum.flat_map(a.quad_points, &rect_quad/1)
      true -> nil
    end
  end

  defp quad_array(_), do: nil

  @doc "The 8-number QuadPoints of a rectangle (top-left, top-right, bottom-left, bottom-right)."
  def rect_quad({x0, y0, x1, y1}), do: Enum.map([x0, y1, x1, y1, x0, y0, x1, y0], &Edit.num/1)

  defp flat_points(points), do: Enum.flat_map(points, fn {x, y} -> [Edit.num(x), Edit.num(y)] end)

  defp line_endings(%__MODULE__{subtype: s, line_endings: {a, b}}) when s in [:line, :polyline] do
    [Map.get(@pdf_endings, a, "None"), Map.get(@pdf_endings, b, "None")]
  end

  defp line_endings(_), do: nil

  defp put_text_style(map, %__MODULE__{subtype: :free_text} = a) do
    {res, _} = Edit.std_font(a.font_family || :helvetica)
    {r, g, b} = a.font_color || {0.0, 0.0, 0.0}
    size = a.font_size || 12

    da =
      "/#{res} #{Edit.f(size)} Tf #{Edit.f(Edit.num(r))} #{Edit.f(Edit.num(g))} #{Edit.f(Edit.num(b))} rg"

    hex = EmbedPdf.Render.ColorSpace.hex({r, g, b})

    family =
      case a.font_family do
        :times -> "Times New Roman"
        :courier -> "Courier"
        _ -> "Helvetica"
      end

    map
    |> Map.put("DA", {:string, da})
    |> Map.put(
      "DS",
      {:string, "font: #{Edit.f(size)}pt #{family}; color: #{hex}; text-align: #{a.text_align}"}
    )
    |> Map.put(
      "Q",
      case(a.text_align,
        do: (
          :center -> 1
          :right -> 2
          _ -> 0
        )
      )
    )
  end

  defp put_text_style(map, _), do: map

  @doc "Geometry points of an annotation (for bounding boxes and transforms)."
  def geometry_points(%__MODULE__{} = a) do
    quads = Enum.flat_map(a.quad_points, fn {x0, y0, x1, y1} -> [{x0, y0}, {x1, y1}] end)
    ink = List.flatten(a.ink_list)

    line =
      if a.line,
        do: [{elem(a.line, 0), elem(a.line, 1)}, {elem(a.line, 2), elem(a.line, 3)}],
        else: []

    quads ++ ink ++ a.vertices ++ line
  end
end
