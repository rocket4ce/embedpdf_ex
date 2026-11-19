defmodule EmbedPdf.Attachments do
  @moduledoc """
  Files embedded in a PDF: document-level attachments (the `/EmbeddedFiles`
  name tree) and file attachment annotations.

  An attachment's `id` is the object number of its embedded file stream.
  """

  alias EmbedPdf.{Edit}
  alias EmbedPdf.PDF.{Document, NameTree, Stream, TextString}

  @doc """
  Lists attachments:
  `%{id, name, description, size, mime, created, modified, source}` where
  `source` is `:document` or `{:annotation, annotation_id}`.
  """
  @spec list(Document.t()) :: [map()]
  def list(doc) do
    document =
      doc
      |> tree_entries()
      |> Enum.flat_map(fn {key, spec} ->
        case describe(doc, spec, key) do
          nil -> []
          info -> [Map.put(info, :source, :document)]
        end
      end)

    annots =
      Enum.flat_map(doc.pages, fn page ->
        doc
        |> Edit.annots(page)
        |> Enum.flat_map(fn value ->
          dict = Document.resolve(doc, value)

          with %{"Subtype" => "FileAttachment"} <- dict,
               {:ref, aid, _} <- value,
               info when info != nil <- describe(doc, dict["FS"], nil) do
            [info |> Map.put(:source, {:annotation, aid}) |> Map.put(:page, page.index)]
          else
            _ -> []
          end
        end)
      end)

    document ++ annots
  end

  defp tree_entries(doc) do
    case Document.get_in(doc, Document.catalog(doc), ["Names", "EmbeddedFiles"]) do
      %{} = tree -> NameTree.entries(doc, tree)
      _ -> []
    end
  end

  defp describe(doc, spec_value, key) do
    spec = Document.resolve(doc, spec_value)

    with %{} <- spec,
         %{} = ef <- Document.resolve(doc, spec["EF"]),
         {:ref, id, _} = ref <- ef["UF"] || ef["F"],
         %Stream{dict: sdict} <- Document.resolve(doc, ref) do
      params = Document.resolve(doc, sdict["Params"]) || %{}

      name =
        Edit.untext(Document.resolve(doc, spec["UF"])) ||
          Edit.untext(Document.resolve(doc, spec["F"])) ||
          (key && TextString.decode(key)) || "attachment"

      size =
        case Document.resolve(doc, params["Size"]) do
          n when is_integer(n) -> n
          _ -> byte_size(Document.stream_data(doc, ref) || "")
        end

      %{
        id: id,
        name: name,
        key: key,
        description: Edit.untext(Document.resolve(doc, spec["Desc"])),
        size: size,
        mime: mime(Document.resolve(doc, sdict["Subtype"]), name),
        created: TextString.parse_date(Document.resolve(doc, params["CreationDate"])),
        modified: TextString.parse_date(Document.resolve(doc, params["ModDate"]))
      }
    else
      _ -> nil
    end
  end

  defp mime(subtype, _name) when is_binary(subtype) and subtype != "", do: subtype

  defp mime(_, name) do
    if Code.ensure_loaded?(MIME), do: MIME.from_path(name || ""), else: "application/octet-stream"
  end

  @doc "The bytes of attachment `id`."
  @spec data(Document.t(), integer()) :: binary() | nil
  def data(doc, id) do
    case Document.resolve(doc, {:ref, id, 0}) do
      %Stream{} = s -> Document.stream_data(doc, s)
      _ -> nil
    end
  end

  @doc """
  Builds an embedded file stream and file specification; returns
  `{doc, filespec_ref}`. Options: `:description`, `:mime`, `:created`.
  """
  @spec filespec(Document.t(), String.t(), binary(), keyword()) :: {Document.t(), tuple()}
  def filespec(doc, name, bytes, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    mime = Keyword.get(opts, :mime) || mime(nil, name)

    stream = %Stream{
      dict: %{
        "Type" => "EmbeddedFile",
        "Subtype" => mime,
        "Params" => %{
          "Size" => byte_size(bytes),
          "CreationDate" => Edit.date(Keyword.get(opts, :created, now)),
          "ModDate" => Edit.date(now),
          "CheckSum" => {:string, :crypto.hash(:md5, bytes)}
        }
      },
      raw: bytes
    }

    {doc, sref} = Document.add_object(doc, stream)

    spec =
      %{
        "Type" => "Filespec",
        "F" => {:string, Edit.winansi(name)},
        "UF" => Edit.text(name),
        "EF" => %{"F" => sref, "UF" => sref}
      }
      |> then(fn s ->
        case Keyword.get(opts, :description) do
          nil -> s
          d -> Map.put(s, "Desc", Edit.text(d))
        end
      end)

    Document.add_object(doc, spec)
  end

  @doc "Attaches a file to the document. Returns `{doc, id}`."
  @spec add(Document.t(), String.t(), binary(), keyword()) :: {Document.t(), integer()}
  def add(doc, name, bytes, opts \\ []) do
    {doc, spec_ref} = filespec(doc, name, bytes, opts)
    %{"EF" => %{"F" => {:ref, id, _}}} = Document.resolve(doc, spec_ref)

    existing = tree_entries(doc)
    key = unique_key(Enum.map(existing, &elem(&1, 0)), TextString.encode(name))
    doc = write_tree(doc, existing ++ [{key, spec_ref}])

    {doc, id}
  end

  defp unique_key(keys, key) do
    if key in keys, do: unique_key(keys, key <> "_"), else: key
  end

  @doc "Removes attachment `id` (document-level or annotation)."
  @spec delete(Document.t(), integer()) :: Document.t()
  def delete(doc, id) do
    case Enum.find(list(doc), &(&1.id == id)) do
      nil ->
        doc

      %{source: :document} ->
        entries =
          doc
          |> tree_entries()
          |> Enum.reject(fn {_key, spec} ->
            case describe(doc, spec, nil) do
              %{id: ^id} -> true
              _ -> false
            end
          end)

        write_tree(doc, entries)

      %{source: {:annotation, aid}} ->
        EmbedPdf.Annotations.delete(doc, aid)
    end
  end

  defp write_tree(doc, entries) do
    catalog_ref = doc.trailer["Root"]
    catalog = Document.catalog(doc)
    names = Document.resolve(doc, catalog["Names"]) || %{}

    {doc, names} =
      if entries == [] do
        {doc, Map.delete(names, "EmbeddedFiles")}
      else
        {doc, tree_ref} = Document.add_object(doc, NameTree.build(entries))
        {doc, Map.put(names, "EmbeddedFiles", tree_ref)}
      end

    case catalog["Names"] do
      {:ref, _, _} = nref ->
        Document.put_object(doc, nref, names)

      _ ->
        catalog =
          if names == %{},
            do: Map.delete(catalog, "Names"),
            else: Map.put(catalog, "Names", names)

        Document.put_object(doc, catalog_ref, catalog)
    end
  end
end
