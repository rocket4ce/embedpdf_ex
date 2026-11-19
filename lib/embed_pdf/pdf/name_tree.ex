defmodule EmbedPdf.PDF.NameTree do
  @moduledoc "Name trees and number trees (ISO 32000-1, 7.9.6 and 7.9.7)."

  alias EmbedPdf.PDF.Document

  @doc "All `{key, value}` pairs of a name tree (keys as raw byte strings), in order."
  @spec entries(Document.t(), term()) :: [{binary(), term()}]
  def entries(doc, node), do: collect(doc, Document.resolve(doc, node), "Names", MapSet.new(), 0)

  @doc "All `{integer, value}` pairs of a number tree."
  @spec number_entries(Document.t(), term()) :: [{integer(), term()}]
  def number_entries(doc, node),
    do: collect(doc, Document.resolve(doc, node), "Nums", MapSet.new(), 0)

  defp collect(_doc, _node, _key, _seen, depth) when depth > 64, do: []

  defp collect(doc, node, key, seen, depth) when is_map(node) do
    own =
      case Document.resolve(doc, node[key]) do
        list when is_list(list) ->
          list
          |> Enum.chunk_every(2, 2, :discard)
          |> Enum.map(fn
            [{:string, k}, v] -> {k, v}
            [k, v] -> {k, v}
          end)

        _ ->
          []
      end

    kids =
      case Document.resolve(doc, node["Kids"]) do
        list when is_list(list) ->
          Enum.flat_map(list, fn kid ->
            id = with {:ref, n, _} <- kid, do: n

            if MapSet.member?(seen, id),
              do: [],
              else: collect(doc, Document.resolve(doc, kid), key, MapSet.put(seen, id), depth + 1)
          end)

        _ ->
          []
      end

    own ++ kids
  end

  defp collect(_doc, _node, _key, _seen, _depth), do: []

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
