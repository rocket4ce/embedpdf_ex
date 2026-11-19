defmodule EmbedPdf.Links do
  @moduledoc """
  Link annotations of a page with their targets resolved:
  `%{id, rect, quads, action}` where `action` is `{:goto, dest}`,
  `{:uri, url}`, `{:named, name}`, `{:external, %{file:, dest:}}`,
  `{:launch, file}`, `{:javascript, code}` or nil.
  """

  alias EmbedPdf.{Destinations, Edit}
  alias EmbedPdf.PDF.{Document, Page}

  @doc "Links on page `index` (rects in PDF user space)."
  @spec list(Document.t(), non_neg_integer()) :: [map()]
  def list(doc, index) do
    case Document.page(doc, index) do
      nil ->
        []

      page ->
        doc
        |> Edit.annots(page)
        |> Enum.flat_map(fn value ->
          case Document.resolve(doc, value) do
            %{"Subtype" => "Link"} = dict ->
              rect = Page.normalize_rect(Document.resolve(doc, dict["Rect"]), doc)
              id = with {:ref, n, _} <- value, do: n

              if rect do
                [
                  %{
                    id: if(is_integer(id), do: id),
                    rect: rect,
                    quads: quads(doc, dict),
                    action: Destinations.of_item(doc, dict)
                  }
                ]
              else
                []
              end

            _ ->
              []
          end
        end)
    end
  end

  defp quads(doc, dict) do
    case Document.resolve(doc, dict["QuadPoints"]) do
      list when is_list(list) ->
        list
        |> Enum.map(&Document.resolve(doc, &1))
        |> Enum.filter(&is_number/1)
        |> Enum.chunk_every(8, 8, :discard)
        |> Enum.map(fn q ->
          q |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1) |> Edit.bbox()
        end)

      _ ->
        []
    end
  end

  @doc """
  Adds a link. `target` is `{:uri, url}` or `{:page, index}` (optionally
  `{:page, index, top}`). Returns `{doc, link}`.
  """
  @spec add(Document.t(), non_neg_integer(), tuple(), tuple()) :: {Document.t(), map()}
  def add(doc, index, rect, target) do
    {doc, annot} =
      EmbedPdf.Annotations.add(doc, index, %{subtype: :link, rect: rect, border_width: 0.0})

    {doc, _} = set_target(doc, annot.id, target)
    {doc, Enum.find(list(doc, index), &(&1.id == annot.id))}
  end

  @doc "Changes where a link goes."
  def set_target(doc, id, target) do
    dict = Document.resolve(doc, {:ref, id, 0})

    action =
      case target do
        {:uri, url} ->
          %{"Type" => "Action", "S" => "URI", "URI" => {:string, url}}

        {:page, p} ->
          %{"Type" => "Action", "S" => "GoTo", "D" => Destinations.build(doc, p)}

        {:page, p, top} ->
          %{"Type" => "Action", "S" => "GoTo", "D" => Destinations.build(doc, p, top: top)}

        {:named, name} ->
          %{"Type" => "Action", "S" => "Named", "N" => name}
      end

    doc =
      Document.put_object(doc, {:ref, id, 0}, dict |> Map.delete("Dest") |> Map.put("A", action))

    {doc, id}
  end

  @doc "Removes a link."
  def delete(doc, id), do: EmbedPdf.Annotations.delete(doc, id)
end
