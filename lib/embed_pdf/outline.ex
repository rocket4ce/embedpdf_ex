defmodule EmbedPdf.Outline do
  @moduledoc """
  The document outline (bookmarks): reading it as a tree and editing it.

  Items are `%{id, title, dest, action, open?, bold?, italic?, color,
  children}`; `id` is the item's object number and `dest` the resolved
  destination (`EmbedPdf.Destinations`) when the item goes to a page.
  Editing rewrites the `First`/`Last`/`Prev`/`Next`/`Parent`/`Count` links
  of the whole tree, so the result is always consistent.
  """

  alias EmbedPdf.{Destinations, Edit}
  alias EmbedPdf.PDF.Document

  @max_depth 64
  @max_siblings 100_000

  # ---------------------------------------------------------------- reading

  @doc "The outline as a tree."
  @spec tree(Document.t()) :: [map()]
  def tree(doc) do
    case Document.get(doc, Document.catalog(doc), "Outlines") do
      %{"First" => {:ref, _, _} = first} ->
        # the named destinations are looked up once for all the items
        ctx = Destinations.context(doc)
        doc |> read(first, MapSet.new(), 0, ctx) |> elem(0)

      _ ->
        []
    end
  end

  defp read(_doc, nil, seen, _depth, _ctx), do: {[], seen}
  defp read(_doc, _ref, seen, depth, _ctx) when depth > @max_depth, do: {[], seen}

  defp read(doc, first, seen, depth, ctx) do
    read_siblings(doc, first, seen, depth, ctx, [], 0)
  end

  defp read_siblings(doc, {:ref, n, _} = ref, seen, depth, ctx, acc, count) do
    if MapSet.member?(seen, n) or count > @max_siblings do
      {Enum.reverse(acc), seen}
    else
      seen = MapSet.put(seen, n)

      case Document.resolve(doc, ref) do
        %{} = dict ->
          {children, seen} = read(doc, dict["First"], seen, depth + 1, ctx)
          item = item(doc, n, dict, children, ctx)
          read_siblings(doc, dict["Next"], seen, depth, ctx, [item | acc], count + 1)

        _ ->
          {Enum.reverse(acc), seen}
      end
    end
  end

  defp read_siblings(_doc, _, seen, _depth, _ctx, acc, _count), do: {Enum.reverse(acc), seen}

  defp item(doc, id, dict, children, ctx) do
    action = Destinations.of_item(doc, dict, ctx)
    flags = Document.resolve(doc, dict["F"]) || 0
    count = Document.resolve(doc, dict["Count"]) || 0

    %{
      id: id,
      title:
        (Edit.untext(Document.resolve(doc, dict["Title"])) || "") |> String.replace(<<0>>, ""),
      dest: with({:goto, d} <- action, do: d, else: (_ -> nil)),
      action: action,
      open?: is_integer(count) and count > 0,
      bold?: is_integer(flags) and Bitwise.band(flags, 2) != 0,
      italic?: is_integer(flags) and Bitwise.band(flags, 1) != 0,
      color: Edit.uncolor(Document.resolve(doc, dict["C"])),
      children: children
    }
  end

  @doc "Finds an item by id."
  def find(doc, id), do: doc |> tree() |> find_in(id)

  defp find_in([], _), do: nil
  defp find_in([%{id: id} = i | _], id), do: i
  defp find_in([i | rest], id), do: find_in(i.children, id) || find_in(rest, id)

  # ---------------------------------------------------------------- editing

  @doc """
  Adds an item under `parent_id` (nil for the top level) going to page
  `page_index`. Options: `:top`, `:left`, `:zoom`, `:position` (index among
  siblings, default last), `:bold`, `:italic`, `:color`. Returns `{doc, id}`.
  """
  @spec add(Document.t(), integer() | nil, String.t(), non_neg_integer() | nil, keyword()) ::
          {Document.t(), integer()}
  def add(doc, parent_id, title, page_index, opts \\ []) do
    dict =
      %{"Title" => Edit.text(title)}
      |> put_dest(doc, page_index, opts)
      |> put_style(opts)

    {doc, {:ref, id, _}} = Document.add_object(doc, dict)
    nodes = skeleton(doc)
    node = %{id: id, open?: false, children: []}

    nodes =
      if parent_id == nil do
        insert_at(nodes, node, Keyword.get(opts, :position))
      else
        update_node(nodes, parent_id, fn p ->
          %{p | children: insert_at(p.children, node, Keyword.get(opts, :position))}
        end)
      end

    {write(doc, nodes), id}
  end

  defp insert_at(list, node, nil), do: list ++ [node]
  defp insert_at(list, node, pos), do: List.insert_at(list, pos, node)

  defp put_dest(dict, _doc, nil, _opts), do: dict

  defp put_dest(dict, doc, page_index, opts) do
    dest = Destinations.build(doc, page_index, Keyword.take(opts, [:top, :left, :zoom]))
    dict |> Map.delete("A") |> Map.put("Dest", dest)
  end

  defp put_style(dict, opts) do
    flags =
      if(Keyword.get(opts, :italic), do: 1, else: 0) +
        if(Keyword.get(opts, :bold), do: 2, else: 0)

    dict = if flags > 0, do: Map.put(dict, "F", flags), else: Map.delete(dict, "F")

    case Keyword.get(opts, :color) do
      nil -> dict
      c -> Map.put(dict, "C", Edit.color(c))
    end
  end

  @doc "Renames an item."
  def rename(doc, id, title), do: update_dict(doc, id, &Map.put(&1, "Title", Edit.text(title)))

  @doc "Points an item at page `page_index` (options as in `add/5`)."
  def set_destination(doc, id, page_index, opts \\ []),
    do: update_dict(doc, id, &put_dest(&1, doc, page_index, opts))

  @doc "Sets bold/italic/color (options as in `add/5`)."
  def set_style(doc, id, opts), do: update_dict(doc, id, &put_style(&1, opts))

  @doc "Expands or collapses an item."
  def set_open(doc, id, open?) do
    doc |> skeleton() |> update_node(id, &%{&1 | open?: open?}) |> then(&write(doc, &1))
  end

  @doc "Deletes an item and its subtree."
  @spec delete(Document.t(), integer()) :: Document.t()
  def delete(doc, id) do
    nodes = skeleton(doc) |> remove_node(id)
    write(doc, nodes)
  end

  @doc "Deletes items whose destination is on one of the given pages (keeping items with children)."
  def drop_destinations(doc, page_refs) do
    refs = MapSet.new(page_refs, fn {:ref, n, _} -> n end)
    # deleting items leaves the named destinations as they are
    ctx = Destinations.context(doc)

    doc
    |> tree()
    |> flatten()
    |> Enum.reduce(doc, fn item, d ->
      raw = Document.resolve(d, {:ref, item.id, 0}) || %{}

      if points_to?(d, raw, refs, ctx) do
        if item.children == [],
          do: delete(d, item.id),
          else: Document.put_object(d, {:ref, item.id, 0}, Map.drop(raw, ["Dest", "A"]))
      else
        d
      end
    end)
  end

  defp points_to?(doc, dict, refs, ctx) do
    dest =
      cond do
        Map.has_key?(dict, "Dest") ->
          dict["Dest"]

        match?(%{"S" => "GoTo"}, Document.resolve(doc, dict["A"])) ->
          Document.resolve(doc, dict["A"])["D"]

        true ->
          nil
      end

    dest =
      case Document.resolve(doc, dest) do
        name when is_binary(name) -> Destinations.named(doc, name, ctx)
        {:string, s} -> Destinations.named(doc, s, ctx)
        other -> other
      end

    case Document.resolve(doc, dest) do
      [{:ref, n, _} | _] -> MapSet.member?(refs, n)
      %{"D" => [{:ref, n, _} | _]} -> MapSet.member?(refs, n)
      _ -> false
    end
  end

  defp flatten(items), do: Enum.flat_map(items, &[&1 | flatten(&1.children)])

  @doc "Moves an item `:up`, `:down`, `:indent` (into the previous sibling) or `:outdent`."
  @spec move(Document.t(), integer(), :up | :down | :indent | :outdent) :: Document.t()
  def move(doc, id, direction) do
    nodes = skeleton(doc)
    write(doc, do_move(nodes, id, direction))
  end

  defp do_move(nodes, id, dir) do
    case Enum.find_index(nodes, &(&1.id == id)) do
      nil ->
        nodes
        |> Enum.map(fn n -> %{n | children: do_move(n.children, id, dir)} end)
        |> outdent_pass(id, dir)

      i ->
        node = Enum.at(nodes, i)

        case dir do
          :up when i > 0 ->
            nodes |> List.delete_at(i) |> List.insert_at(i - 1, node)

          :down when i < length(nodes) - 1 ->
            nodes |> List.delete_at(i) |> List.insert_at(i + 1, node)

          :indent when i > 0 ->
            prev = Enum.at(nodes, i - 1)

            nodes
            |> List.delete_at(i)
            |> List.replace_at(i - 1, %{prev | children: prev.children ++ [node]})

          _ ->
            nodes
        end
    end
  end

  # an outdent moves a child out of its parent, right after the parent
  defp outdent_pass(nodes, id, :outdent) do
    Enum.flat_map(nodes, fn n ->
      case Enum.find_index(n.children, &(&1.id == id)) do
        nil -> [n]
        i -> [%{n | children: List.delete_at(n.children, i)}, Enum.at(n.children, i)]
      end
    end)
  end

  defp outdent_pass(nodes, _id, _), do: nodes

  defp update_dict(doc, id, fun) do
    case Document.resolve(doc, {:ref, id, 0}) do
      %{} = dict -> Document.put_object(doc, {:ref, id, 0}, fun.(dict))
      _ -> doc
    end
  end

  # ---------------------------------------------------------------- structure

  defp skeleton(doc), do: doc |> tree() |> Enum.map(&strip/1)
  defp strip(i), do: %{id: i.id, open?: i.open?, children: Enum.map(i.children, &strip/1)}

  defp update_node(nodes, id, fun) do
    Enum.map(nodes, fn n ->
      if n.id == id, do: fun.(n), else: %{n | children: update_node(n.children, id, fun)}
    end)
  end

  defp remove_node(nodes, id) do
    nodes
    |> Enum.reject(&(&1.id == id))
    |> Enum.map(&%{&1 | children: remove_node(&1.children, id)})
  end

  defp visible(node),
    do:
      Enum.reduce(node.children, 0, fn c, acc ->
        acc + 1 + if(c.open?, do: visible(c), else: 0)
      end)

  defp write(doc, nodes) do
    catalog_ref = doc.trailer["Root"]
    catalog = Document.catalog(doc)

    {doc, root_ref} =
      case catalog["Outlines"] do
        {:ref, _, _} = r -> {doc, r}
        _ -> Document.add_object(doc, %{"Type" => "Outlines"})
      end

    if nodes == [] do
      doc |> Document.put_object(catalog_ref, Map.delete(catalog, "Outlines"))
    else
      doc = link_level(doc, nodes, root_ref)

      total =
        Enum.reduce(nodes, 0, fn n, acc -> acc + 1 + if(n.open?, do: visible(n), else: 0) end)

      root =
        (Document.resolve(doc, root_ref) || %{})
        |> Map.merge(%{
          "Type" => "Outlines",
          "First" => ref(hd(nodes)),
          "Last" => ref(List.last(nodes)),
          "Count" => total
        })

      doc
      |> Document.put_object(root_ref, root)
      |> Document.put_object(catalog_ref, Map.put(Document.catalog(doc), "Outlines", root_ref))
    end
  end

  defp ref(%{id: id}), do: {:ref, id, 0}

  defp link_level(doc, nodes, parent_ref) do
    count = length(nodes)

    nodes
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {node, i}, doc ->
      dict = Document.resolve(doc, ref(node)) || %{}

      dict =
        dict
        |> Map.put("Parent", parent_ref)
        |> put_link("Prev", if(i > 0, do: ref(Enum.at(nodes, i - 1))))
        |> put_link("Next", if(i < count - 1, do: ref(Enum.at(nodes, i + 1))))

      dict =
        case node.children do
          [] ->
            Map.drop(dict, ["First", "Last", "Count"])

          kids ->
            v = visible(node)

            dict
            |> Map.put("First", ref(hd(kids)))
            |> Map.put("Last", ref(List.last(kids)))
            |> Map.put("Count", if(node.open?, do: v, else: -v))
        end

      doc = Document.put_object(doc, ref(node), dict)
      link_level(doc, node.children, ref(node))
    end)
  end

  defp put_link(dict, key, nil), do: Map.delete(dict, key)
  defp put_link(dict, key, value), do: Map.put(dict, key, value)
end
