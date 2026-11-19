defmodule EmbedPdf.Writer do
  @moduledoc """
  Saving documents, and flattening annotations into page content (for
  printing or exporting a copy where annotations can no longer change).
  """

  alias EmbedPdf.{Edit, Forms, Metadata}
  alias EmbedPdf.PDF.{Document, Page, Serializer, Stream}
  alias EmbedPdf.Render.Matrix

  @doc """
  Writes the document to PDF bytes. Options:

    * `:metadata` – stamp `/ModDate` and `/Producer` (default true)
    * `:producer` – producer name (default `"EmbedPdf"`)
    * `:flatten` – flatten annotations first (default false)
    * the `EmbedPdf.PDF.Serializer.save/2` options
  """
  @spec save(Document.t(), keyword()) :: binary()
  def save(doc, opts \\ []) do
    doc =
      if Keyword.get(opts, :metadata, true) do
        Metadata.put(doc, %{
          modified: DateTime.utc_now() |> DateTime.truncate(:second),
          producer: Keyword.get(opts, :producer, "EmbedPdf")
        })
      else
        doc
      end

    doc = if Keyword.get(opts, :flatten, false), do: flatten_annotations(doc, :all), else: doc

    doc
    |> repair_acroform()
    |> Serializer.save(opts)
  end

  # an /AcroForm without /Fields is invalid and some readers complain
  defp repair_acroform(doc) do
    catalog = Document.catalog(doc)

    case catalog["AcroForm"] do
      nil ->
        doc

      {:ref, _, _} = r ->
        case Document.resolve(doc, r) do
          %{"Fields" => _} -> doc
          %{} = form -> Document.put_object(doc, r, Map.put(form, "Fields", []))
          _ -> Document.put_object(doc, doc.trailer["Root"], Map.delete(catalog, "AcroForm"))
        end

      %{} = form ->
        if Map.has_key?(form, "Fields"),
          do: doc,
          else:
            Document.put_object(
              doc,
              doc.trailer["Root"],
              Map.put(catalog, "AcroForm", Map.put(form, "Fields", []))
            )

      _ ->
        doc
    end
  end

  @doc """
  Bakes annotation appearances into page content and removes the
  annotations. `page_indices` is a list or `:all`. Options:

    * `:print` – only annotations marked for printing (default false)
    * `:keep_links` – keep link annotations (default true)
  """
  @spec flatten_annotations(Document.t(), [non_neg_integer()] | :all, keyword()) :: Document.t()
  def flatten_annotations(doc, page_indices, opts \\ []) do
    indices =
      if page_indices == :all, do: Enum.map(doc.pages, & &1.index), else: List.wrap(page_indices)

    Enum.reduce(indices, doc, fn i, d ->
      case Document.page(d, i) do
        nil -> d
        page -> flatten_page(d, page, opts)
      end
    end)
  end

  defp flatten_page(doc, page, opts) do
    print? = Keyword.get(opts, :print, false)
    keep_links? = Keyword.get(opts, :keep_links, true)

    entries =
      doc
      |> Edit.annots(page)
      |> Enum.map(fn v -> {v, Document.resolve(doc, v)} end)
      |> Enum.filter(fn {_v, d} -> is_map(d) end)

    {flatten, keep} =
      Enum.split_with(entries, fn {_v, d} ->
        subtype = Document.resolve(doc, d["Subtype"])
        not (subtype == "Link" and keep_links?)
      end)

    {doc, content, xobjects, _} =
      Enum.reduce(flatten, {doc, [], %{}, 1}, fn {_v, d}, {doc, content, xobjects, i} ->
        flags = Document.resolve(doc, d["F"]) || 0
        hidden? = Bitwise.band(flags, 2) != 0 or Bitwise.band(flags, 32) != 0
        printable? = Bitwise.band(flags, 4) != 0

        with false <- hidden?,
             true <- printable? or not print?,
             %Stream{} = ap <- appearance(doc, d),
             rect when rect != nil <- Page.normalize_rect(Document.resolve(doc, d["Rect"]), doc),
             m when m != nil <- placement(doc, ap, rect) do
          name = "Fl" <> Integer.to_string(i)
          {doc, ref} = form_ref(doc, d, ap)
          ops = ["q ", Enum.map_join(m, " ", &Edit.f/1), " cm /", name, " Do Q\n"]
          {doc, [content, ops], Map.put(xobjects, name, ref), i + 1}
        else
          _ -> {doc, content, xobjects, i}
        end
      end)

    flattened_ids = for {{:ref, n, _}, _} <- flatten, do: n
    widget_ids = for {{:ref, n, _}, %{"Subtype" => "Widget"}} <- flatten, do: n

    doc = Edit.put_annots(doc, page, Enum.map(keep, &elem(&1, 0)))
    doc = if widget_ids == [], do: doc, else: Forms.remove_widgets(doc, widget_ids)
    doc = Enum.reduce(flattened_ids, doc, &Document.delete_object(&2, {:ref, &1, 0}))

    if xobjects == %{},
      do: doc,
      else: Edit.append_content(doc, page.index, content, %{"XObject" => xobjects})
  end

  defp appearance(doc, dict) do
    case Document.get_in(doc, dict, ["AP", "N"]) do
      %Stream{} = s ->
        s

      %{} = states ->
        Document.resolve(doc, Map.get(states, Document.resolve(doc, dict["AS"])))

      _ ->
        nil
    end
  end

  # reuse the appearance object when it is indirect, making sure it is a form
  defp form_ref(doc, dict, %Stream{dict: sdict} = ap) do
    fixed = %{ap | dict: sdict |> Map.put("Type", "XObject") |> Map.put("Subtype", "Form")}

    ref =
      case Document.get_in(doc, dict, ["AP"]) |> then(&(&1 && Map.get(&1, "N"))) do
        {:ref, _, _} = r -> r
        %{} = states -> Map.get(states, Document.resolve(doc, dict["AS"]))
        _ -> nil
      end

    case ref do
      {:ref, _, _} -> {Document.put_object(doc, ref, fixed), ref}
      _ -> Document.add_object(doc, fixed)
    end
  end

  @doc false
  # Algorithm 8.1 (12.5.5): the matrix A placing an appearance in its rect.
  def placement(doc, %Stream{dict: sdict}, {x0, y0, x1, y1}) do
    bbox = Page.normalize_rect(Document.resolve(doc, sdict["BBox"]), doc)
    matrix = Matrix.from_pdf(Document.resolve(doc, sdict["Matrix"]))

    case bbox do
      nil ->
        nil

      bbox ->
        {bx0, by0, bx1, by1} = Matrix.transform_rect(matrix, bbox)
        sx = if bx1 - bx0 == 0, do: 1.0, else: (x1 - x0) / (bx1 - bx0)
        sy = if by1 - by0 == 0, do: 1.0, else: (y1 - y0) / (by1 - by0)
        # `Do` applies the form's own /Matrix; the cm only adds A
        [sx, 0.0, 0.0, sy, x0 - bx0 * sx, y0 - by0 * sy]
    end
  end
end
