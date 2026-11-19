defmodule EmbedPdf.Forms.Builder do
  @moduledoc """
  Building forms: creating, changing, moving, resizing, duplicating and
  deleting AcroForm fields (EmbedPDF's `forms.building` feature).

  Every function returns a new document. New fields get Acrobat-style
  names (`Text1`, `Check Box1`, `Group1`, `Dropdown1`, `List Box1`,
  `Button1`, `Signature1`), a widget with a white box and a gray border,
  and appearance streams, so they show in every viewer. The public entry
  points are delegated from `EmbedPdf.Forms`.
  """

  import EmbedPdf.Edit, only: [f: 1]

  alias EmbedPdf.{Edit, Forms}
  alias EmbedPdf.PDF.{Document, Page}

  @types [:text, :checkbox, :radio, :combo, :list, :button, :signature]

  @prefix %{
    text: "Text",
    checkbox: "Check Box",
    radio: "Group",
    combo: "Dropdown",
    list: "List Box",
    button: "Button",
    signature: "Signature"
  }

  @border {0.42, 0.45, 0.5}
  @white {1.0, 1.0, 1.0}
  @button_bg {0.9, 0.91, 0.92}

  # field flag bits (ISO 32000-1, tables 226, 228, 230)
  @flags %{
    read_only?: 1,
    required?: 2,
    multiline?: 13,
    password?: 14,
    comb?: 25,
    editable?: 19,
    multi_select?: 22
  }

  @doc "The field types `add_field/5` can create."
  def types, do: @types

  # ---------------------------------------------------------------- add

  @doc """
  Adds a field of `type` with one widget at `rect` (user space) on page
  `page_index`. Options:

    * all types: `:name`, `:read_only?`, `:required?`, `:border_color`,
      `:background_color` (`{r, g, b}` or nil), `:font_size` (0 = auto)
    * `:text`: `:value`, `:default`, `:multiline?`, `:password?`, `:comb?`,
      `:max_len`, `:text_align` (`:left | :center | :right`)
    * `:checkbox`: `:export` (on-state, default `"Yes"`), `:checked`
    * `:radio`: `:name` of an existing group adds a button to it; `:export`
      (default the next free `Choice<n>`), `:checked`
    * `:combo` / `:list`: `:options` (`[{export, label}]` or labels),
      `:value`, `:editable?` (combo), `:multi_select?` (list)
    * `:button`: `:caption`

  Returns `{doc, field}` with the field as `EmbedPdf.Forms.fields/1` lists it.
  """
  @spec add_field(Document.t(), non_neg_integer(), Page.rect(), atom(), keyword() | map()) ::
          {Document.t(), map()}
  def add_field(doc, page_index, rect, type, opts \\ []) when type in @types do
    opts = Map.new(opts)
    page = Document.page(doc, page_index) || raise ArgumentError, "no page #{page_index}"
    rect = Edit.normalize(rect)
    doc = ensure_acroform(doc)

    existing_radio =
      if type == :radio and is_binary(opts[:name]) do
        Enum.find(Forms.fields(doc), &(&1.type == :radio and &1.name == opts[:name]))
      end

    if existing_radio do
      add_radio_button(doc, existing_radio, page, rect, opts)
    else
      create_field(doc, page, rect, type, opts)
    end
  end

  defp create_field(doc, page, rect, type, opts) do
    name = unique_name(doc, opts[:name] || @prefix[type])
    widget = widget_dict(page, rect, type, opts)

    {doc, field_id, widget_id} =
      if type == :radio do
        parent = Map.merge(field_dict(type, name, opts), %{"Kids" => []})
        {doc, parent_ref} = Document.add_object(doc, parent)
        {doc, wref} = Document.add_object(doc, Map.put(widget, "Parent", parent_ref))
        doc = Document.put_object(doc, parent_ref, Map.put(parent, "Kids", [wref]))
        {doc, elem(parent_ref, 1), elem(wref, 1)}
      else
        {doc, ref} = Document.add_object(doc, Map.merge(widget, field_dict(type, name, opts)))
        {doc, elem(ref, 1), elem(ref, 1)}
      end

    doc =
      doc
      |> add_to_annots(page, {:ref, widget_id, 0})
      |> add_to_fields({:ref, field_id, 0})

    on_state =
      case type do
        :checkbox -> opts[:export] || "Yes"
        :radio -> opts[:export] || "Choice1"
        _ -> nil
      end

    doc = draw(doc, field_id, %{widget_id => on_state}, initial_value(type, on_state, opts))
    {doc, Forms.get(doc, field_id)}
  end

  defp add_radio_button(doc, field, page, rect, opts) do
    {doc, parent_ref} = split_merged(doc, field)
    taken = Enum.map(field.widgets, & &1.on_state)
    on_state = opts[:export] || next_choice(taken)
    widget = page |> widget_dict(rect, :radio, opts) |> Map.put("Parent", parent_ref)
    {doc, wref} = Document.add_object(doc, widget)
    parent = Document.resolve(doc, parent_ref)
    kids = List.wrap(Document.resolve(doc, parent["Kids"]))
    doc = Document.put_object(doc, parent_ref, Map.put(parent, "Kids", kids ++ [wref]))
    doc = add_to_annots(doc, page, wref)

    states = Map.new(field.widgets, &{&1.id, &1.on_state}) |> Map.put(elem(wref, 1), on_state)
    value = if opts[:checked], do: on_state, else: field.value
    doc = draw(doc, field.id, states, value)
    {doc, Forms.get(doc, field.id)}
  end

  @doc "The next free radio export value (`Choice<n>`), as EmbedPDF names them."
  def next_choice(taken) do
    taken = taken |> Enum.reject(&is_nil/1) |> MapSet.new()

    n =
      Stream.iterate(MapSet.size(taken) + 1, &(&1 + 1))
      |> Enum.find(&(not MapSet.member?(taken, "Choice#{&1}")))

    "Choice#{n}"
  end

  # A field whose dictionary is also its only widget is split into a parent
  # field and a kid widget, so another widget can join it.
  defp split_merged(doc, %{id: id} = field) do
    dict = Document.resolve(doc, {:ref, id, 0})

    if dict["Subtype"] == "Widget" do
      widget_keys = ~w(Type Subtype Rect P AP AS MK F BS Border DA H NM M C CA Q)
      widget = dict |> Map.take(widget_keys) |> Map.put("Parent", {:ref, id, 0})
      {doc, wref} = Document.add_object(doc, widget)
      parent = dict |> Map.drop(widget_keys -- ["DA", "Q"]) |> Map.put("Kids", [wref])
      doc = Document.put_object(doc, {:ref, id, 0}, parent)
      page = Enum.find_value(field.widgets, & &1.page)

      doc =
        case page && Document.page(doc, page) do
          %Page{} = pg ->
            annots =
              Edit.annots(doc, pg)
              |> Enum.map(&if(match?({:ref, ^id, _}, &1), do: wref, else: &1))

            Edit.put_annots(doc, pg, annots)

          _ ->
            doc
        end

      {doc, {:ref, id, 0}}
    else
      {doc, {:ref, id, 0}}
    end
  end

  defp initial_value(:checkbox, _on, opts), do: opts[:checked] == true
  defp initial_value(:radio, on, opts), do: if(opts[:checked], do: on)
  defp initial_value(:text, _on, opts), do: to_string(opts[:value] || opts[:default] || "")
  defp initial_value(:combo, _on, opts), do: opts[:value]
  defp initial_value(:list, _on, opts), do: opts[:value]
  defp initial_value(_, _, _), do: nil

  # ---------------------------------------------------------------- dictionaries

  defp widget_dict(page, rect, type, opts) do
    bg =
      Map.get(opts, :background_color, if(type == :button, do: @button_bg, else: @white))

    bc = Map.get(opts, :border_color, @border)

    mk =
      %{}
      |> put_color("BG", bg)
      |> put_color("BC", bc)
      |> then(fn mk ->
        case type do
          :checkbox -> Map.put(mk, "CA", Edit.text("4"))
          :radio -> Map.put(mk, "CA", Edit.text("l"))
          :button -> Map.put(mk, "CA", Edit.text(opts[:caption] || "Button"))
          _ -> mk
        end
      end)

    %{
      "Type" => "Annot",
      "Subtype" => "Widget",
      "Rect" => Edit.rect_array(rect),
      "P" => page.ref,
      "F" => 4,
      "MK" => mk,
      "BS" => %{"W" => 1, "S" => "S"},
      "DA" => da(type, opts),
      "NM" => {:string, Edit.unique_name()}
    }
    |> then(&if(type == :button, do: Map.put(&1, "H", "P"), else: &1))
  end

  defp field_dict(type, name, opts) do
    {ft, base_ff} =
      case type do
        :text -> {"Tx", 0}
        :checkbox -> {"Btn", 0}
        :radio -> {"Btn", bit(15) + bit(16)}
        :combo -> {"Ch", bit(18)}
        :list -> {"Ch", 0}
        :button -> {"Btn", bit(17)}
        :signature -> {"Sig", 0}
      end

    ff =
      Enum.reduce(@flags, base_ff, fn {k, n}, acc -> if opts[k], do: acc + bit(n), else: acc end)

    %{"FT" => ft, "T" => Edit.text(name)}
    |> then(&if(ff != 0, do: Map.put(&1, "Ff", ff), else: &1))
    |> then(
      &if(type == :text and opts[:max_len], do: Map.put(&1, "MaxLen", opts[:max_len]), else: &1)
    )
    |> then(
      &if(type in [:text, :combo, :list],
        do: Map.put(&1, "Q", align(opts[:text_align])),
        else: &1
      )
    )
    |> then(
      &if(type in [:combo, :list],
        do: Map.put(&1, "Opt", opt_array(opts[:options] || [])),
        else: &1
      )
    )
    |> then(
      &if(type == :text and opts[:default],
        do: Map.put(&1, "DV", Edit.text(to_string(opts[:default]))),
        else: &1
      )
    )
    |> then(&if(type in [:checkbox, :radio], do: Map.put(&1, "V", "Off"), else: &1))
  end

  defp da(type, _opts) when type in [:checkbox, :radio], do: {:string, "/ZaDb 0 Tf 0 g"}

  defp da(_type, opts) do
    size = Map.get(opts, :font_size, 12)
    {:string, "/Helv #{f(size)} Tf 0 g"}
  end

  defp align(:center), do: 1
  defp align(:right), do: 2
  defp align(_), do: 0

  defp bit(n), do: Bitwise.bsl(1, n - 1)

  defp put_color(map, _key, nil), do: map
  defp put_color(map, key, rgb), do: Map.put(map, key, Edit.color(rgb))

  defp opt_array(options) do
    Enum.map(options, fn
      {e, l} when e == l -> Edit.text(to_string(e))
      {e, l} -> [Edit.text(to_string(e)), Edit.text(to_string(l))]
      label -> Edit.text(to_string(label))
    end)
  end

  # ---------------------------------------------------------------- AcroForm

  defp ensure_acroform(doc) do
    catalog = Document.catalog(doc)
    form = Document.resolve(doc, catalog["AcroForm"])
    form = if is_map(form), do: form, else: %{}
    dr = Document.resolve(doc, form["DR"])
    dr = if is_map(dr), do: dr, else: %{}
    fonts = Document.resolve(doc, dr["Font"])
    fonts = if is_map(fonts), do: fonts, else: %{}

    {doc, fonts} =
      [
        {"Helv", Edit.std_font_dict("Helvetica")},
        {"ZaDb", %{"Type" => "Font", "Subtype" => "Type1", "BaseFont" => "ZapfDingbats"}}
      ]
      |> Enum.reduce({doc, fonts}, fn {name, dict}, {d, fs} ->
        if Map.has_key?(fs, name) do
          {d, fs}
        else
          {d, ref} = Document.add_object(d, dict)
          {d, Map.put(fs, name, ref)}
        end
      end)

    fields = Document.resolve(doc, form["Fields"])

    form =
      form
      |> Map.put("Fields", if(is_list(fields), do: fields, else: []))
      |> Map.put("DR", Map.put(dr, "Font", fonts))
      |> Map.put_new("DA", {:string, "/Helv 0 Tf 0 g"})

    case catalog["AcroForm"] do
      {:ref, _, _} = r ->
        Document.put_object(doc, r, form)

      _ ->
        {doc, ref} = Document.add_object(doc, form)
        Document.put_object(doc, doc.trailer["Root"], Map.put(catalog, "AcroForm", ref))
    end
  end

  defp acroform_ref(doc), do: Document.catalog(doc)["AcroForm"]

  defp add_to_fields(doc, ref) do
    form_ref = acroform_ref(doc)
    form = Document.resolve(doc, form_ref)
    fields = List.wrap(Document.resolve(doc, form["Fields"]))
    Document.put_object(doc, form_ref, Map.put(form, "Fields", fields ++ [ref]))
  end

  defp add_to_annots(doc, page, ref) do
    page = Document.page(doc, page.index)
    Edit.put_annots(doc, page, Edit.annots(doc, page) ++ [ref])
  end

  @doc """
  A field name not used yet. A specific name is kept when free; the default
  prefixes (`"Text"`, `"Check Box"`…) and taken names get the first free
  number (`Text1`, `Text2`…).
  """
  @spec unique_name(Document.t(), String.t(), integer() | nil) :: String.t()
  def unique_name(doc, wanted, except_id \\ nil) do
    taken =
      doc
      |> Forms.fields()
      |> Enum.reject(&(&1.id == except_id))
      |> Enum.flat_map(fn fld -> [fld.name | String.split(fld.name, ".")] end)
      |> MapSet.new()

    wanted = String.trim(wanted)

    if wanted != "" and wanted not in Map.values(@prefix) and not MapSet.member?(taken, wanted) do
      wanted
    else
      base = String.replace(wanted, ~r/\d+$/, "")
      base = if base == "", do: "Field", else: base

      n = Stream.iterate(1, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(taken, "#{base}#{&1}")))
      "#{base}#{n}"
    end
  end

  # ---------------------------------------------------------------- update

  @doc """
  Changes a field's settings. `attrs` (map or keyword) takes `:name`,
  `:options`, `:value`, `:default`, `:max_len`, `:font_size`, `:text_align`,
  `:caption`, `:export` (check box on-state), `:border_color`,
  `:background_color` and the flags `:read_only?`, `:required?`,
  `:multiline?`, `:password?`, `:comb?`, `:editable?`, `:multi_select?`.
  Appearances are regenerated. Returns `{doc, field}`.
  """
  @spec update_field(Document.t(), integer() | String.t(), keyword() | map()) ::
          {Document.t(), map()}
  def update_field(doc, id, attrs) do
    attrs = Map.new(attrs)

    case field_for(doc, id) do
      nil ->
        {doc, nil}

      field ->
        doc =
          doc
          |> update_field_dict(field, attrs)
          |> update_widgets(field, attrs)
          |> rename_export(field, attrs)

        fresh = Forms.get(doc, field.id)
        value = if Map.has_key?(attrs, :value), do: attrs[:value], else: fresh.value

        value =
          if fresh.type in [:combo, :list] and Map.has_key?(attrs, :options) and
               not Map.has_key?(attrs, :value),
             do: keep_valid(value, fresh.options),
             else: value

        export =
          if field.type == :checkbox and is_binary(attrs[:export]) and attrs[:export] != "",
            do: attrs[:export]

        states = Map.new(fresh.widgets, &{&1.id, export || &1.on_state})
        doc = draw(doc, field.id, states, value)
        {doc, Forms.get(doc, field.id)}
    end
  end

  defp keep_valid(nil, _), do: nil

  defp keep_valid(values, options) when is_list(values),
    do: Enum.filter(values, &Enum.any?(options, fn {e, l} -> e == &1 or l == &1 end))

  defp keep_valid(value, options),
    do: if(Enum.any?(options, fn {e, l} -> e == value or l == value end), do: value)

  defp update_field_dict(doc, field, attrs) do
    update(doc, field.id, fn dict ->
      dict
      |> then(fn d ->
        case attrs[:name] do
          name when is_binary(name) and name != "" ->
            leaf =
              if String.contains?(field.name, "."),
                do: name |> String.split(".") |> List.last(),
                else: name

            Map.put(d, "T", Edit.text(unique_name(doc, leaf, field.id)))

          _ ->
            d
        end
      end)
      |> then(fn d ->
        ff =
          case Document.resolve(doc, d["Ff"]) do
            n when is_integer(n) -> n
            _ -> 0
          end

        ff =
          Enum.reduce(@flags, ff, fn {k, n}, acc ->
            case Map.fetch(attrs, k) do
              {:ok, true} -> Bitwise.bor(acc, bit(n))
              {:ok, false} -> Bitwise.band(acc, Bitwise.bnot(bit(n)))
              _ -> acc
            end
          end)

        if ff == 0, do: Map.delete(d, "Ff"), else: Map.put(d, "Ff", ff)
      end)
      |> then(fn d ->
        case Map.fetch(attrs, :max_len) do
          {:ok, n} when is_integer(n) and n > 0 -> Map.put(d, "MaxLen", n)
          {:ok, _} -> Map.delete(d, "MaxLen")
          :error -> d
        end
      end)
      |> then(fn d ->
        case Map.fetch(attrs, :options) do
          {:ok, opts} when is_list(opts) -> Map.put(d, "Opt", opt_array(opts))
          _ -> d
        end
      end)
      |> then(fn d ->
        case Map.fetch(attrs, :text_align) do
          {:ok, a} -> Map.put(d, "Q", align(a))
          :error -> d
        end
      end)
      |> then(fn d ->
        case Map.fetch(attrs, :default) do
          {:ok, nil} ->
            Map.delete(d, "DV")

          {:ok, ""} ->
            Map.delete(d, "DV")

          {:ok, v} when field.type in [:text, :combo, :list] ->
            Map.put(d, "DV", Edit.text(to_string(v)))

          {:ok, v} when field.type == :checkbox ->
            Map.put(d, "DV", if(v in [true, "true"], do: on_of(field), else: "Off"))

          {:ok, v} when field.type == :radio ->
            Map.put(d, "DV", to_string(v))

          _ ->
            d
        end
      end)
      |> then(fn d ->
        case Map.fetch(attrs, :font_size) do
          {:ok, size} when is_number(size) and field.type not in [:checkbox, :radio] ->
            Map.put(d, "DA", {:string, set_da_size(da_of(doc, d), size)})

          _ ->
            d
        end
      end)
    end)
  end

  defp on_of(field), do: Enum.find_value(field.widgets, & &1.on_state) || "Yes"

  defp da_of(doc, dict), do: Edit.untext(Document.resolve(doc, dict["DA"])) || "/Helv 12 Tf 0 g"

  defp set_da_size(da, size) do
    if Regex.match?(~r{/[^\s/]+\s+[\d.]+\s+Tf}, da),
      do: Regex.replace(~r{(/[^\s/]+)\s+[\d.]+\s+Tf}, da, "\\1 #{f(size)} Tf", global: false),
      else: "/Helv #{f(size)} Tf " <> da
  end

  defp update_widgets(doc, field, attrs) do
    Enum.reduce(field.widgets, doc, fn w, d ->
      update(d, w.id, fn dict ->
        mk = Document.resolve(d, dict["MK"]) || %{}

        mk =
          mk
          |> then(&color_attr(&1, "BC", attrs, :border_color))
          |> then(&color_attr(&1, "BG", attrs, :background_color))
          |> then(fn mk ->
            case attrs[:caption] do
              c when is_binary(c) and field.type == :button -> Map.put(mk, "CA", Edit.text(c))
              _ -> mk
            end
          end)

        dict = Map.put(dict, "MK", mk)

        # the size lives in the field's /DA; a widget's own /DA would win, so update both
        case Map.fetch(attrs, :font_size) do
          {:ok, size} when is_number(size) and field.type not in [:checkbox, :radio] ->
            if Map.has_key?(dict, "DA"),
              do: Map.put(dict, "DA", {:string, set_da_size(da_of(d, dict), size)}),
              else: dict

          _ ->
            dict
        end
      end)
    end)
  end

  defp color_attr(mk, key, attrs, attr) do
    case Map.fetch(attrs, attr) do
      {:ok, nil} -> Map.delete(mk, key)
      {:ok, rgb} -> Map.put(mk, key, Edit.color(rgb))
      :error -> mk
    end
  end

  # a check box's export value is the name of its on appearance state
  defp rename_export(doc, %{type: :checkbox} = field, %{export: export})
       when is_binary(export) and export != "" do
    old = on_of(field)

    if old == export do
      doc
    else
      doc =
        Enum.reduce(field.widgets, doc, fn w, d ->
          update(d, w.id, fn dict ->
            dict = Map.delete(dict, "AP")
            if Document.resolve(d, dict["AS"]) == old, do: Map.put(dict, "AS", export), else: dict
          end)
        end)

      update(doc, field.id, fn dict ->
        if Document.resolve(doc, dict["V"]) == old, do: Map.put(dict, "V", export), else: dict
      end)
    end
  end

  defp rename_export(doc, _field, _attrs), do: doc

  # ---------------------------------------------------------------- geometry

  @doc "Moves one widget by `dx`/`dy` (user space). Returns `{doc, field}`."
  @spec move_field(Document.t(), integer(), number(), number()) :: {Document.t(), map() | nil}
  def move_field(doc, widget_id, dx, dy) do
    case widget_and_field(doc, widget_id) do
      {w, field} ->
        {x0, y0, x1, y1} = w.rect

        doc =
          update(
            doc,
            w.id,
            &Map.put(&1, "Rect", Edit.rect_array({x0 + dx, y0 + dy, x1 + dx, y1 + dy}))
          )

        {doc, Forms.get(doc, field.id)}

      nil ->
        {doc, nil}
    end
  end

  @doc "Gives one widget a new rectangle (user space) and redraws it. Returns `{doc, field}`."
  @spec resize_field(Document.t(), integer(), Page.rect()) :: {Document.t(), map() | nil}
  def resize_field(doc, widget_id, rect) do
    case widget_and_field(doc, widget_id) do
      {w, field} ->
        doc = update(doc, w.id, &Map.put(&1, "Rect", Edit.rect_array(Edit.normalize(rect))))
        fresh = Forms.get(doc, field.id)
        doc = draw(doc, field.id, Map.new(fresh.widgets, &{&1.id, &1.on_state}), fresh.value)
        {doc, Forms.get(doc, field.id)}

      nil ->
        {doc, nil}
    end
  end

  # ---------------------------------------------------------------- delete & duplicate

  @doc "Deletes a field (by field or widget id, or name) with all its widgets."
  @spec delete_field(Document.t(), integer() | String.t()) :: Document.t()
  def delete_field(doc, id) do
    case field_for(doc, id) do
      nil ->
        doc

      field ->
        ids = Enum.map(field.widgets, & &1.id)
        id_set = MapSet.new([field.id | ids])

        doc =
          field.widgets
          |> Enum.map(& &1.page)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.reduce(doc, fn p, d ->
            page = Document.page(d, p)

            annots =
              Enum.reject(
                Edit.annots(d, page),
                &(match?({:ref, n, _} when is_integer(n), &1) and ref_in?(&1, id_set))
              )

            Edit.put_annots(d, page, annots)
          end)

        doc = Forms.remove_widgets(doc, ids)
        # a field with kids is gone from /Fields once its widgets are; a merged one goes directly
        form_ref = acroform_ref(doc)
        form = Document.resolve(doc, form_ref)

        fields =
          List.wrap(Document.resolve(doc, form["Fields"])) |> Enum.reject(&ref_in?(&1, id_set))

        doc = Document.put_object(doc, form_ref, Map.put(form, "Fields", fields))
        Enum.reduce([field.id | ids], doc, &Document.delete_object(&2, {:ref, &1, 0}))
    end
  end

  defp ref_in?({:ref, n, _}, set), do: MapSet.member?(set, n)
  defp ref_in?(_, _), do: false

  @doc """
  Duplicates a field next to the original (offset `{dx, dy}`, default
  `{10, -10}`). A radio button gets a new button in the same group; other
  fields get a new field with the same settings and a new name.
  """
  @spec duplicate_field(Document.t(), integer() | String.t(), {number(), number()}) ::
          {Document.t(), map()}
  def duplicate_field(doc, id, {dx, dy} \\ {10, -10}) do
    case field_for(doc, id) do
      nil ->
        {doc, nil}

      field ->
        w = widget_for(field, id)
        {x0, y0, x1, y1} = w.rect
        rect = {x0 + dx, y0 + dy, x1 + dx, y1 + dy}
        dict = Document.resolve(doc, {:ref, w.id, 0})
        mk = Document.resolve(doc, dict["MK"]) || %{}

        common = %{
          border_color: Edit.uncolor(Document.resolve(doc, mk["BC"])),
          background_color: Edit.uncolor(Document.resolve(doc, mk["BG"])),
          read_only?: field.read_only?,
          required?: field.required?
        }

        opts =
          case field.type do
            :radio ->
              Map.merge(common, %{name: field.name})

            :checkbox ->
              Map.merge(common, %{
                name: field.name,
                export: on_of(field),
                checked: field.value == true
              })

            :text ->
              Map.merge(common, %{
                name: field.name,
                value: field.value,
                multiline?: field.multiline?,
                password?: field.password?,
                comb?: field.comb?,
                max_len: field.max_len,
                text_align: field.text_align,
                font_size: font_size(doc, field)
              })

            t when t in [:combo, :list] ->
              Map.merge(common, %{
                name: field.name,
                options: field.options,
                value: field.value,
                editable?: field.editable?,
                multi_select?: field.multi_select?,
                text_align: field.text_align,
                font_size: font_size(doc, field)
              })

            :button ->
              Map.merge(common, %{
                name: field.name,
                caption: Edit.untext(Document.resolve(doc, mk["CA"]))
              })

            :signature ->
              Map.merge(common, %{name: field.name})
          end

        # a duplicate of a non-radio field must not join the original by name
        opts = if field.type == :radio, do: opts, else: Map.put(opts, :name, base_of(field.name))
        add_field(doc, w.page, rect, field.type, opts)
    end
  end

  defp base_of(name), do: name |> String.split(".") |> List.last() |> String.replace(~r/\d+$/, "")

  @doc "The font size of a field's `/DA` (0 = auto)."
  def font_size(doc, field) do
    dict = Document.resolve(doc, {:ref, field.id, 0}) || %{}

    da =
      Edit.untext(Document.resolve(doc, dict["DA"])) ||
        Enum.find_value(field.widgets, fn w ->
          Edit.untext(
            Document.resolve(doc, (Document.resolve(doc, {:ref, w.id, 0}) || %{})["DA"])
          )
        end) || ""

    case Regex.run(~r{/[^\s/]+\s+([\d.]+)\s+Tf}, da) do
      [_, s] -> s |> Float.parse() |> elem(0)
      _ -> 0.0
    end
  end

  # ---------------------------------------------------------------- lookup

  @doc "The field owning `id`: a field id, a widget id or a field name."
  def field_for(doc, id) do
    fields = Forms.fields(doc)

    Enum.find(fields, &(&1.id == id or &1.name == id)) ||
      Enum.find(fields, fn fld -> Enum.any?(fld.widgets, &(&1.id == id)) end)
  end

  defp widget_for(field, id), do: Enum.find(field.widgets, hd(field.widgets), &(&1.id == id))

  defp widget_and_field(doc, widget_id) do
    case field_for(doc, widget_id) do
      nil -> nil
      field -> {widget_for(field, widget_id), field}
    end
  end

  defp update(doc, id, fun) do
    case Document.resolve(doc, {:ref, id, 0}) do
      %{} = d -> Document.put_object(doc, {:ref, id, 0}, fun.(d))
      _ -> doc
    end
  end

  # ---------------------------------------------------------------- drawing

  # Redraws every widget of a field; `states` gives each widget's on-state
  # (check boxes and radio buttons), `value` the value to show.
  defp draw(doc, field_id, states, value) do
    field = Forms.get(doc, field_id)
    widgets = Enum.map(field.widgets, &%{&1 | on_state: Map.get(states, &1.id) || &1.on_state})

    field = %{field | widgets: widgets}

    case field.type do
      :button -> Enum.reduce(widgets, doc, &push_button_ap(&2, &1))
      :signature -> Enum.reduce(widgets, doc, &box_ap(&2, &1))
      _ -> Forms.regenerate(doc, field, value)
    end
  end

  defp push_button_ap(doc, w) do
    {dict, ww, hh, bg, bc} = box(doc, w)

    caption =
      Edit.untext(Document.resolve(doc, (Document.resolve(doc, dict["MK"]) || %{})["CA"])) || ""

    da = da_of(doc, dict)

    size =
      case Regex.run(~r{/[^\s/]+\s+([\d.]+)\s+Tf}, da) do
        [_, s] -> s |> Float.parse() |> elem(0)
        _ -> 0.0
      end

    size = if size > 0, do: size, else: min(hh * 0.6, 12.0)
    tw = Edit.text_width(caption, "Helvetica", size)

    size = if tw > ww - 4 and tw > 0, do: size * (ww - 4) / tw, else: size
    tw = Edit.text_width(caption, "Helvetica", size)

    content = [
      frame(ww, hh, bg, bc),
      "BT /Helv ",
      f(size),
      " Tf 0 g 1 0 0 1 ",
      f((ww - tw) / 2),
      " ",
      f((hh - size * 0.72) / 2),
      " Tm ",
      Edit.tj(caption),
      " ET\n"
    ]

    put_ap(
      doc,
      w.id,
      dict,
      Edit.form({0, 0, ww, hh}, content, %{"Font" => %{"Helv" => Edit.std_font_dict("Helvetica")}})
    )
  end

  defp box_ap(doc, w) do
    {dict, ww, hh, bg, bc} = box(doc, w)
    put_ap(doc, w.id, dict, Edit.form({0, 0, ww, hh}, frame(ww, hh, bg, bc)))
  end

  defp box(doc, w) do
    dict = Document.resolve(doc, {:ref, w.id, 0})
    {x0, y0, x1, y1} = w.rect
    mk = Document.resolve(doc, dict["MK"]) || %{}

    {dict, x1 - x0, y1 - y0, Edit.uncolor(Document.resolve(doc, mk["BG"])),
     Edit.uncolor(Document.resolve(doc, mk["BC"]))}
  end

  defp frame(w, h, bg, bc) do
    [
      if(bg, do: [rgb(bg, "rg"), "0 0 ", f(w), " ", f(h), " re f\n"], else: []),
      if(bc, do: [rgb(bc, "RG"), "1 w 0.5 0.5 ", f(w - 1), " ", f(h - 1), " re S\n"], else: [])
    ]
  end

  defp rgb({r, g, b}, op),
    do: [f(Edit.num(r)), " ", f(Edit.num(g)), " ", f(Edit.num(b)), " ", op, "\n"]

  defp put_ap(doc, id, dict, stream) do
    {doc, ref} = Document.add_object(doc, stream)
    Document.put_object(doc, {:ref, id, 0}, Map.put(dict, "AP", %{"N" => ref}))
  end
end
