defmodule EmbedPdf.Pages do
  @moduledoc """
  Page editing: rotate, delete, reorder, duplicate, insert blank pages,
  insert pages from another document, and extract pages.

  The page tree is rewritten flat (one `/Pages` node) with inherited
  attributes copied onto each page, so every result is a valid tree.
  Bookmarks, links and named destinations that pointed at deleted pages
  are dropped.
  """

  alias EmbedPdf.{Annotations, Destinations, Edit, Outline}
  alias EmbedPdf.PDF.{Document, NameTree, Page}

  @inheritable ~w(Resources MediaBox CropBox Rotate)

  @doc "Rotates pages by `degrees` (a multiple of 90, clockwise)."
  @spec rotate(Document.t(), [non_neg_integer()] | non_neg_integer(), integer()) :: Document.t()
  def rotate(doc, indices, degrees) do
    indices = List.wrap(indices)

    doc =
      Enum.reduce(indices, doc, fn i, d ->
        case Document.page(d, i) do
          %Page{ref: ref} = page when ref != nil ->
            rot = Integer.mod(page.rotate + degrees, 360) |> div(90) |> Kernel.*(90)
            dict = d |> materialize(page) |> Map.put("Rotate", rot)
            Document.put_object(d, ref, dict)

          _ ->
            d
        end
      end)

    Document.refresh_pages(doc)
  end

  @doc "Deletes pages. Raises when asked to delete every page."
  @spec delete(Document.t(), [non_neg_integer()] | non_neg_integer()) :: Document.t()
  def delete(doc, indices) do
    drop = indices |> List.wrap() |> MapSet.new()
    {removed, kept} = doc.pages |> Enum.split_with(&MapSet.member?(drop, &1.index))

    cond do
      removed == [] -> doc
      kept == [] -> raise ArgumentError, "a PDF needs at least one page"
      true -> doc |> rebuild(Enum.map(kept, & &1.ref)) |> cleanup(Enum.map(removed, & &1.ref))
    end
  end

  @doc """
  Moves the pages at `from_indices` (kept in their order) so the first of
  them ends up at `to_index` of the result.
  """
  @spec move(Document.t(), [non_neg_integer()] | non_neg_integer(), non_neg_integer()) ::
          Document.t()
  def move(doc, from_indices, to_index) do
    set = from_indices |> List.wrap() |> MapSet.new()
    {moved, rest} = Enum.split_with(doc.pages, &MapSet.member?(set, &1.index))
    at = to_index |> max(0) |> min(length(rest))
    {before, after_} = Enum.split(rest, at)
    rebuild(doc, Enum.map(before ++ moved ++ after_, & &1.ref))
  end

  @doc "Duplicates a page (with its annotations, without form fields) right after it."
  @spec duplicate(Document.t(), non_neg_integer()) :: Document.t()
  def duplicate(doc, index) do
    page = Document.page(doc, index) || raise ArgumentError, "no page #{index}"
    {doc, new_ref} = Document.add_object(doc, %{})
    dict = materialize(doc, page)

    {doc, annots} =
      doc
      |> Edit.annots(page)
      |> Enum.reduce({doc, %{}, []}, fn value, {d, map, acc} ->
        case Document.resolve(d, value) do
          %{"Subtype" => s} when s in ["Widget", "Popup"] ->
            {d, map, acc}

          %{} = a ->
            {d, ref} =
              Document.add_object(
                d,
                Map.put(a, "P", new_ref) |> Map.put("NM", Edit.text(Edit.unique_name()))
              )

            old = with {:ref, n, _} <- value, do: n
            {d, Map.put(map, old, ref), [ref | acc]}

          _ ->
            {d, map, acc}
        end
      end)
      |> then(fn {d, map, acc} -> {remap_irt(d, Enum.reverse(acc), map), Enum.reverse(acc)} end)

    dict = if annots == [], do: Map.delete(dict, "Annots"), else: Map.put(dict, "Annots", annots)
    doc = Document.put_object(doc, new_ref, dict)
    refs = Enum.map(doc.pages, & &1.ref) |> List.insert_at(index + 1, new_ref)
    rebuild(doc, refs)
  end

  defp remap_irt(doc, refs, map) do
    Enum.reduce(refs, doc, fn ref, d ->
      dict = Document.resolve(d, ref)

      case dict["IRT"] do
        {:ref, n, _} ->
          Document.put_object(
            d,
            ref,
            if(map[n], do: Map.put(dict, "IRT", map[n]), else: Map.delete(dict, "IRT"))
          )

        _ ->
          d
      end
    end)
  end

  @doc "Inserts a blank page of `{width, height}` points at `at_index`."
  @spec insert_blank(Document.t(), non_neg_integer(), {number(), number()}) :: Document.t()
  def insert_blank(doc, at_index, {w, h} \\ {612, 792}) do
    {doc, ref} =
      Document.add_object(doc, %{
        "Type" => "Page",
        "MediaBox" => [0, 0, Edit.num(w), Edit.num(h)],
        "Resources" => %{}
      })

    refs =
      Enum.map(doc.pages, & &1.ref)
      |> List.insert_at(at_index |> max(0) |> min(length(doc.pages)), ref)

    rebuild(doc, refs)
  end

  @doc """
  Inserts pages of `other` (all, or the given indices) at `at_index`.
  Objects are deep-copied with fresh numbers; named destinations in copied
  links are made explicit, and form fields are merged into this document.
  """
  @spec insert_document(Document.t(), non_neg_integer(), Document.t(), :all | [non_neg_integer()]) ::
          Document.t()
  def insert_document(doc, at_index, %Document{} = other, other_indices \\ :all) do
    pages =
      case other_indices do
        :all -> other.pages
        list -> list |> Enum.map(&Document.page(other, &1)) |> Enum.reject(&is_nil/1)
      end

    other_page_nums = MapSet.new(other.pages, fn %Page{ref: {:ref, n, _}} -> n end)

    # pre-allocate numbers for the copied pages so links between them survive
    {doc, mapping} =
      Enum.reduce(pages, {doc, %{}}, fn %Page{ref: {:ref, n, _}}, {d, m} ->
        {d, {:ref, new, _}} = Document.add_object(d, %{})
        {d, Map.put(m, n, new)}
      end)

    ctx = %{
      other: other,
      mapping: mapping,
      page_nums: other_page_nums,
      selected: MapSet.new(Map.keys(mapping))
    }

    {doc, ctx} =
      Enum.reduce(pages, {doc, ctx}, fn %Page{ref: {:ref, n, _}} = page, {d, c} ->
        dict = other |> materialize(page) |> Map.drop(["Parent", "StructParents", "B", "Tabs"])
        {copied, d, c} = copy(dict, d, c)
        {Document.put_object(d, {:ref, c.mapping[n], 0}, copied), c}
      end)

    new_refs = Enum.map(pages, fn %Page{ref: {:ref, n, _}} -> {:ref, mapping[n], 0} end)
    at = at_index |> max(0) |> min(length(doc.pages))
    refs = Enum.map(doc.pages, & &1.ref) |> List.insert_at(at, new_refs) |> List.flatten()

    doc
    |> rebuild(refs)
    |> merge_fields(other, new_refs, ctx.mapping)
  end

  # ---------------------------------------------------------------- deep copy

  defp copy({:ref, n, _}, doc, ctx) do
    cond do
      Map.has_key?(ctx.mapping, n) ->
        {{:ref, ctx.mapping[n], 0}, doc, ctx}

      MapSet.member?(ctx.page_nums, n) ->
        # a page that is not being copied
        {nil, doc, ctx}

      true ->
        {doc, {:ref, new, _} = ref} = Document.add_object(doc, nil)
        ctx = %{ctx | mapping: Map.put(ctx.mapping, n, new)}
        value = Document.resolve(ctx.other, {:ref, n, 0})
        {copied, doc, ctx} = copy(explicit_dests(value, ctx.other), doc, ctx)
        {ref, Document.put_object(doc, ref, copied), ctx}
    end
  end

  defp copy(list, doc, ctx) when is_list(list) do
    {items, doc, ctx} =
      Enum.reduce(list, {[], doc, ctx}, fn v, {acc, d, c} ->
        {cv, d, c} = copy(v, d, c)
        {[cv | acc], d, c}
      end)

    {Enum.reverse(items), doc, ctx}
  end

  defp copy(%EmbedPdf.PDF.Stream{dict: dict} = s, doc, ctx) do
    {d, doc, ctx} = copy(dict, doc, ctx)
    {%{s | dict: d}, doc, ctx}
  end

  defp copy(map, doc, ctx) when is_map(map) do
    Enum.reduce(map, {%{}, doc, ctx}, fn {k, v}, {acc, d, c} ->
      {cv, d, c} = copy(v, d, c)
      {Map.put(acc, k, cv), d, c}
    end)
  end

  defp copy(v, doc, ctx), do: {v, doc, ctx}

  # named destinations do not exist in the target document: make them explicit
  defp explicit_dests(%{"Dest" => d} = dict, other) when is_binary(d) or is_tuple(d) do
    case Document.resolve(other, d) do
      list when is_list(list) -> dict
      _ -> Map.put(dict, "Dest", named_array(other, d))
    end
  end

  defp explicit_dests(%{"A" => a} = dict, other) do
    case Document.resolve(other, a) do
      %{"S" => "GoTo", "D" => d} = action
      when is_binary(d) or (is_tuple(d) and elem(d, 0) == :string) ->
        Map.put(dict, "A", Map.put(action, "D", named_array(other, d)))

      _ ->
        dict
    end
  end

  defp explicit_dests(value, _other), do: value

  defp named_array(other, d) do
    key = with {:string, s} <- d, do: s

    case Document.resolve(other, Destinations.named(other, key)) do
      list when is_list(list) -> list
      %{"D" => list} -> Document.resolve(other, list)
      _ -> nil
    end
  end

  defp merge_fields(doc, other, new_refs, mapping) do
    widgets =
      Enum.flat_map(new_refs, fn ref ->
        page = Enum.find(doc.pages, &(&1.ref == ref))

        doc
        |> Edit.annots(page)
        |> Enum.filter(&match?(%{"Subtype" => "Widget"}, Document.resolve(doc, &1)))
      end)

    if widgets == [] do
      doc
    else
      tops =
        widgets
        |> Enum.map(&top_field(doc, &1, 0))
        |> Enum.uniq()

      catalog = Document.catalog(doc)
      form = Document.resolve(doc, catalog["AcroForm"]) || %{}
      existing = List.wrap(Document.resolve(doc, form["Fields"]))
      names = existing |> Enum.map(&Edit.untext(Document.get(doc, &1, "T"))) |> MapSet.new()

      doc =
        Enum.reduce(tops, doc, fn ref, d ->
          dict = Document.resolve(d, ref)
          name = Edit.untext(dict["T"])

          if name && MapSet.member?(names, name),
            do:
              Document.put_object(
                d,
                ref,
                Map.put(dict, "T", Edit.text(name <> "_" <> Integer.to_string(elem(ref, 1))))
              ),
            else: d
        end)

      other_form = Document.get(other, Document.catalog(other), "AcroForm") || %{}

      form =
        form
        |> Map.put("Fields", existing ++ (tops -- existing))
        |> Map.put_new("DA", other_form["DA"] || {:string, "/Helv 0 Tf 0 g"})

      {dr, doc, _} =
        copy(Document.resolve(other, other_form["DR"]) || %{}, doc, %{
          other: other,
          mapping: mapping,
          page_nums: MapSet.new(),
          selected: MapSet.new()
        })

      form =
        Map.put(
          form,
          "DR",
          Edit.merge_resources(doc, dr, Document.resolve(doc, form["DR"]) || %{})
        )

      case catalog["AcroForm"] do
        {:ref, _, _} = r -> Document.put_object(doc, r, form)
        _ -> Document.put_object(doc, doc.trailer["Root"], Map.put(catalog, "AcroForm", form))
      end
    end
  end

  defp top_field(doc, ref, depth) do
    case Document.resolve(doc, ref) do
      %{"Parent" => {:ref, _, _} = p} when depth < 32 -> top_field(doc, p, depth + 1)
      _ -> ref
    end
  end

  @doc "A new document holding only the pages at `indices` (in that order)."
  @spec extract(Document.t(), [non_neg_integer()]) :: Document.t()
  def extract(doc, indices) do
    keep = indices |> Enum.uniq() |> Enum.map(&Document.page(doc, &1)) |> Enum.reject(&is_nil/1)
    if keep == [], do: raise(ArgumentError, "no pages to extract")
    keep_set = MapSet.new(keep, & &1.ref)
    removed = doc.pages |> Enum.reject(&MapSet.member?(keep_set, &1.ref)) |> Enum.map(& &1.ref)

    doc
    |> rebuild(Enum.map(keep, & &1.ref))
    |> cleanup(removed)
    |> Edit.collect_garbage()
  end

  # ---------------------------------------------------------------- tree

  @doc false
  # A page dictionary with its inherited attributes copied in.
  def materialize(doc, %Page{ref: ref, dict: dict}) do
    dict = Document.resolve(doc, ref) || dict

    Enum.reduce(@inheritable, dict, fn key, acc ->
      if Map.has_key?(acc, key) do
        acc
      else
        case inherited(doc, dict["Parent"], key, 0) do
          nil -> if key == "MediaBox", do: Map.put(acc, key, [0, 0, 612, 792]), else: acc
          value -> Map.put(acc, key, value)
        end
      end
    end)
  end

  defp inherited(_doc, nil, _key, _), do: nil
  defp inherited(_doc, _, _key, depth) when depth > 32, do: nil

  defp inherited(doc, parent, key, depth) do
    case Document.resolve(doc, parent) do
      %{} = node -> Map.get(node, key) || inherited(doc, node["Parent"], key, depth + 1)
      _ -> nil
    end
  end

  @doc false
  # Rewrites the page tree as one flat /Pages node holding `refs`.
  def rebuild(doc, refs) do
    catalog = Document.catalog(doc)
    pages_by_ref = Map.new(doc.pages, &{&1.ref, &1})

    {doc, root_ref} =
      case catalog["Pages"] do
        {:ref, _, _} = r -> {doc, r}
        _ -> Document.add_object(doc, %{})
      end

    doc =
      Enum.reduce(refs, doc, fn ref, d ->
        dict =
          case Map.fetch(pages_by_ref, ref) do
            {:ok, page} -> materialize(d, page)
            :error -> Document.resolve(d, ref)
          end

        Document.put_object(
          d,
          ref,
          dict |> Map.put("Type", "Page") |> Map.put("Parent", root_ref)
        )
      end)

    doc
    |> Document.put_object(root_ref, %{"Type" => "Pages", "Kids" => refs, "Count" => length(refs)})
    |> Document.put_object(doc.trailer["Root"], Map.put(Document.catalog(doc), "Pages", root_ref))
    |> Document.refresh_pages()
  end

  # after pages were removed: drop what pointed at them
  defp cleanup(doc, removed_refs) do
    removed = MapSet.new(removed_refs, fn {:ref, n, _} -> n end)

    doc
    |> Outline.drop_destinations(removed_refs)
    |> drop_links(removed)
    |> drop_named_dests(removed)
    |> drop_widgets(removed)
    |> drop_catalog_entries(removed)
  end

  defp pointing?(doc, dest, removed) do
    case Document.resolve(doc, dest) do
      [{:ref, n, _} | _] -> MapSet.member?(removed, n)
      %{"D" => [{:ref, n, _} | _]} -> MapSet.member?(removed, n)
      name when is_binary(name) -> pointing?(doc, Destinations.named(doc, name), removed)
      {:string, s} -> pointing?(doc, Destinations.named(doc, s), removed)
      _ -> false
    end
  end

  defp drop_links(doc, removed) do
    Enum.reduce(doc.pages, doc, fn page, d ->
      d
      |> Edit.annots(page)
      |> Enum.flat_map(fn
        {:ref, n, _} = ref ->
          case Document.resolve(d, ref) do
            %{"Subtype" => "Link"} = l ->
              dest =
                l["Dest"] ||
                  with(
                    %{"S" => "GoTo", "D" => dd} <- Document.resolve(d, l["A"]),
                    do: dd,
                    else: (_ -> nil)
                  )

              if dest && pointing?(d, dest, removed), do: [n], else: []

            _ ->
              []
          end

        _ ->
          []
      end)
      |> Enum.reduce(d, &Annotations.delete(&2, &1))
    end)
  end

  defp drop_named_dests(doc, removed) do
    catalog = Document.catalog(doc)

    doc =
      case catalog["Dests"] do
        nil ->
          doc

        dests_ref ->
          dests = Document.resolve(doc, dests_ref) || %{}
          kept = dests |> Enum.reject(fn {_, v} -> pointing?(doc, v, removed) end) |> Map.new()

          case dests_ref do
            {:ref, _, _} -> Document.put_object(doc, dests_ref, kept)
            _ -> Document.put_object(doc, doc.trailer["Root"], Map.put(catalog, "Dests", kept))
          end
      end

    catalog = Document.catalog(doc)
    names = Document.resolve(doc, catalog["Names"])

    case names && Document.resolve(doc, names["Dests"]) do
      %{} = tree ->
        kept =
          doc
          |> NameTree.entries(tree)
          |> Enum.reject(fn {_, v} -> pointing?(doc, v, removed) end)

        {doc, tref} = Document.add_object(doc, NameTree.build(kept))
        names = Map.put(names, "Dests", tref)

        case catalog["Names"] do
          {:ref, _, _} = r -> Document.put_object(doc, r, names)
          _ -> Document.put_object(doc, doc.trailer["Root"], Map.put(catalog, "Names", names))
        end

      _ ->
        doc
    end
  end

  defp drop_widgets(doc, removed) do
    catalog = Document.catalog(doc)

    case Document.resolve(doc, catalog["AcroForm"]) do
      %{"Fields" => _} = form ->
        {fields, doc} =
          prune_fields(doc, List.wrap(Document.resolve(doc, form["Fields"])), removed, 0)

        form = Map.put(form, "Fields", fields)

        case catalog["AcroForm"] do
          {:ref, _, _} = r -> Document.put_object(doc, r, form)
          _ -> Document.put_object(doc, doc.trailer["Root"], Map.put(catalog, "AcroForm", form))
        end

      _ ->
        doc
    end
  end

  # removes widgets whose /P is a removed page; drops fields left empty
  defp prune_fields(doc, refs, _removed, depth) when depth > 32, do: {refs, doc}

  defp prune_fields(doc, refs, removed, depth) do
    Enum.reduce(refs, {[], doc}, fn ref, {acc, d} ->
      dict = Document.resolve(d, ref)

      cond do
        not is_map(dict) ->
          {acc, d}

        is_list(Document.resolve(d, dict["Kids"])) ->
          {kids, d} = prune_fields(d, Document.resolve(d, dict["Kids"]), removed, depth + 1)

          if kids == [],
            do: {acc, d},
            else: {acc ++ [ref], Document.put_object(d, ref, Map.put(dict, "Kids", kids))}

        match?({:ref, _, _}, dict["P"]) and MapSet.member?(removed, elem(dict["P"], 1)) ->
          {acc, d}

        true ->
          {acc ++ [ref], d}
      end
    end)
  end

  defp drop_catalog_entries(doc, removed) do
    catalog = Document.catalog(doc)

    catalog =
      case Document.resolve(doc, catalog["OpenAction"]) do
        [{:ref, n, _} | _] ->
          if MapSet.member?(removed, n), do: Map.delete(catalog, "OpenAction"), else: catalog

        _ ->
          catalog
      end

    # the structure tree would keep the removed pages alive and is now stale
    catalog =
      if Map.has_key?(catalog, "StructTreeRoot"),
        do: catalog |> Map.delete("StructTreeRoot") |> Map.delete("MarkInfo"),
        else: catalog

    Document.put_object(doc, doc.trailer["Root"], catalog)
  end
end
