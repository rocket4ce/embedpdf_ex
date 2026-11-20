defmodule EmbedPdf.PDF.NameTree do
  @moduledoc "Name trees and number trees (ISO 32000-1, 7.9.6 and 7.9.7)."

  alias EmbedPdf.PDF.Document

  # Deeper trees and trees with more entries than this are cut there.
  @max_depth 64
  @max_entries 1_000_000

  @doc "All `{key, value}` pairs of a name tree (keys as raw byte strings), in order."
  @spec entries(Document.t(), term()) :: [{binary(), term()}]
  def entries(doc, node), do: walk(doc, node, "Names")

  @doc "All `{integer, value}` pairs of a number tree."
  @spec number_entries(Document.t(), term()) :: [{integer(), term()}]
  def number_entries(doc, node), do: walk(doc, node, "Nums")

  # A node is read once, however many `/Kids` arrays list it: the entries
  # cannot outnumber what the file holds.
  defp walk(doc, node, key) do
    seen =
      case node do
        {:ref, n, _} -> MapSet.new([n])
        _ -> MapSet.new()
      end

    {acc, _count, _seen} = collect(doc, Document.resolve(doc, node), key, {[], 0, seen}, 0)
    Enum.reverse(acc)
  end

  defp collect(_doc, _node, _key, state, depth) when depth > @max_depth, do: state

  defp collect(doc, node, key, {acc, count, seen}, depth)
       when is_map(node) and not is_struct(node) do
    # an array of pairs that several nodes point at is read once too
    {own, seen} =
      case node[key] do
        {:ref, n, _} = ref ->
          if MapSet.member?(seen, {:pairs, n}),
            do: {nil, seen},
            else: {Document.resolve(doc, ref), MapSet.put(seen, {:pairs, n})}

        own ->
          {own, seen}
      end

    {acc, count} = if is_list(own), do: pairs(own, acc, count), else: {acc, count}

    case Document.resolve(doc, node["Kids"]) do
      list when is_list(list) ->
        Enum.reduce(list, {acc, count, seen}, fn
          _kid, {_acc, count, _seen} = state when count >= @max_entries ->
            state

          {:ref, n, _} = kid, {acc, count, seen} = state ->
            if MapSet.member?(seen, n) do
              state
            else
              state = {acc, count, MapSet.put(seen, n)}
              collect(doc, Document.resolve(doc, kid), key, state, depth + 1)
            end

          kid, state ->
            collect(doc, kid, key, state, depth + 1)
        end)

      _ ->
        {acc, count, seen}
    end
  end

  defp collect(_doc, _node, _key, state, _depth), do: state

  defp pairs([k, v | rest], acc, count) when count < @max_entries do
    k = with {:string, s} <- k, do: s
    pairs(rest, [{k, v} | acc], count + 1)
  end

  defp pairs(_, acc, count), do: {acc, count}

  @doc "Looks up `name` in a name tree."
  @spec lookup(Document.t(), term(), binary()) :: term()
  def lookup(doc, node, name) do
    doc |> entries(node) |> Enum.find_value(fn {k, v} -> if k == name, do: v end)
  end

  @doc "Builds a flat name tree dictionary from `{key, value}` pairs."
  @spec build([{binary(), term()}]) :: map()
  def build(pairs) do
    names =
      pairs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {k, v} -> [{:string, k}, v] end)

    %{"Names" => names}
  end
end
