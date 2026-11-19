defmodule EmbedPdf.PDF.Document do
  @moduledoc """
  An opened PDF: every object parsed (and decrypted) into an immutable map,
  plus the trailer and the flattened page list.

  Because a document is a plain value, editing returns a new document and
  undo/redo is just keeping old ones.
  """

  alias EmbedPdf.PDF.{Crypt, Filter, Page, Parser, Stream, Xref}

  defstruct objects: %{},
            trailer: %{},
            version: "1.7",
            crypt: nil,
            pages: [],
            next_num: 1,
            permissions: nil,
            reconstructed?: false,
            byte_size: 0

  @type t :: %__MODULE__{
          objects: %{non_neg_integer() => term()},
          trailer: map(),
          version: String.t(),
          crypt: Crypt.t() | nil,
          pages: [Page.t()],
          next_num: pos_integer(),
          permissions: integer() | nil,
          reconstructed?: boolean(),
          byte_size: non_neg_integer()
        }

  @doc """
  Opens a PDF from its bytes.

  Options: `:password` (user or owner password, default `""`).
  Errors: `{:error, :not_a_pdf}`, `{:error, :password_required}`,
  `{:error, :bad_password}`, `{:error, :unsupported_encryption}`.
  """
  @spec open(binary(), keyword()) :: {:ok, t()} | {:error, atom()}
  def open(data, opts \\ []) when is_binary(data) do
    case header_offset(data) do
      nil ->
        {:error, :not_a_pdf}

      offset ->
        data = if offset > 0, do: binary_part(data, offset, byte_size(data) - offset), else: data
        do_open(data, opts)
    end
  rescue
    e -> {:error, {:malformed, Exception.message(e)}}
  end

  defp header_offset(data) do
    head = binary_part(data, 0, min(byte_size(data), 1024))

    case :binary.match(head, "%PDF-") do
      {pos, _} -> pos
      :nomatch -> if String.contains?(data, " obj"), do: 0, else: nil
    end
  end

  defp do_open(data, opts) do
    version =
      case Regex.run(~r/^%PDF-(\d\.\d)/, data) do
        [_, v] -> v
        _ -> "1.7"
      end

    {entries, trailer, reconstructed?} = Xref.load(data)

    with {:ok, crypt} <- setup_crypt(data, entries, trailer, opts) do
      objects = load_objects(data, entries, crypt, trailer, reconstructed?)

      {objects, trailer} =
        if reconstructed? or not Map.has_key?(objects, ref_num(trailer["Root"])) do
          retry_reconstructed(data, objects, trailer, crypt, reconstructed?)
        else
          {objects, trailer}
        end

      doc = %__MODULE__{
        objects: objects,
        trailer:
          Map.drop(trailer, [
            "Prev",
            "XRefStm",
            "Encrypt",
            "W",
            "Index",
            "Filter",
            "DecodeParms",
            "Length",
            "Type"
          ]),
        version: catalog_version(objects, trailer) || version,
        crypt: crypt,
        permissions: crypt && crypt.permissions,
        next_num: (objects |> Map.keys() |> Enum.max(fn -> 0 end)) + 1,
        reconstructed?: reconstructed?,
        byte_size: byte_size(data)
      }

      if doc |> catalog() |> is_map() do
        {:ok, refresh_pages(doc)}
      else
        {:error, :no_catalog}
      end
    end
  end

  defp ref_num({:ref, n, _}), do: n
  defp ref_num(_), do: nil

  defp retry_reconstructed(data, objects, trailer, crypt, true),
    do: expand_all(data, objects, trailer, crypt)

  defp retry_reconstructed(data, _objects, _trailer, crypt, false) do
    {entries, trailer, _} = Xref.reconstruct(data)
    objects = load_objects(data, entries, crypt, trailer, true)
    expand_all(data, objects, trailer, crypt)
  end

  # with a rebuilt table, objects living in object streams must be pulled out
  defp expand_all(_data, objects, trailer, _crypt) do
    objects =
      objects
      |> Enum.filter(fn {_, v} -> match?(%Stream{dict: %{"Type" => "ObjStm"}}, v) end)
      |> Enum.reduce(objects, fn {_, stm}, acc ->
        stm
        |> object_stream_objects()
        |> Enum.reduce(acc, fn {n, v}, acc -> Map.put_new(acc, n, v) end)
      end)

    trailer =
      if Map.has_key?(objects, ref_num(trailer["Root"])) do
        trailer
      else
        case Enum.find(objects, fn {_, v} -> match?(%{"Type" => "Catalog"}, v) end) do
          {n, _} -> Map.put(trailer, "Root", {:ref, n, 0})
          nil -> trailer
        end
      end

    {objects, trailer}
  end

  defp catalog_version(objects, trailer) do
    case objects[ref_num(trailer["Root"])] do
      %{"Version" => v} when is_binary(v) -> v
      _ -> nil
    end
  end

  # ---------------------------------------------------------------- encryption

  defp setup_crypt(data, entries, trailer, opts) do
    case trailer["Encrypt"] do
      nil ->
        {:ok, nil}

      enc ->
        enc =
          case enc do
            {:ref, n, _} -> load_raw(data, entries, n)
            dict -> dict
          end

        id =
          case trailer["ID"] do
            [{:string, id} | _] -> id
            _ -> <<>>
          end

        password = Keyword.get(opts, :password, "") || ""

        case Crypt.new(enc || %{}, id, password) do
          {:ok, crypt} -> {:ok, crypt}
          {:error, :bad_password} when password == "" -> {:error, :password_required}
          {:error, :bad_password} -> {:error, :bad_password}
          {:error, :unsupported} -> {:error, :unsupported_encryption}
        end
    end
  end

  defp load_raw(data, entries, num) do
    case entries[num] do
      {:offset, off, _} ->
        case Parser.parse_indirect(binary_part(data, off, byte_size(data) - off)) do
          {:ok, _, _, value} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------- objects

  defp load_objects(data, entries, crypt, trailer, reconstructed?) do
    encrypt_num = ref_num(trailer["Encrypt"])

    length_fun = fn {:ref, n, _} ->
      case load_raw(data, entries, n) do
        len when is_integer(len) -> len
        _ -> nil
      end
    end

    direct =
      for {num, {:offset, off, gen}} <- entries,
          off < byte_size(data),
          reduce: %{} do
        acc ->
          case Parser.parse_indirect(binary_part(data, off, byte_size(data) - off), length_fun) do
            {:ok, n, _g, value} when n == num or reconstructed? ->
              value =
                if crypt && num != encrypt_num,
                  do: decrypt_object(value, crypt, num, gen),
                  else: value

              Map.put(acc, num, value)

            _ ->
              acc
          end
      end

    compressed =
      entries
      |> Enum.filter(fn {_, e} -> match?({:compressed, _, _}, e) end)
      |> Enum.group_by(fn {_, {:compressed, stm, _}} -> stm end, fn {num, _} -> num end)

    Enum.reduce(compressed, direct, fn {stm_num, nums}, acc ->
      case direct[stm_num] do
        %Stream{} = stm ->
          wanted = MapSet.new(nums)

          stm
          |> object_stream_objects()
          |> Enum.reduce(acc, fn {n, v}, acc ->
            if MapSet.member?(wanted, n), do: Map.put(acc, n, v), else: acc
          end)

        _ ->
          acc
      end
    end)
  end

  @doc false
  def object_stream_objects(%Stream{dict: dict, raw: raw}) do
    decoded = Filter.decode!(raw, dict["Filter"], dict["DecodeParms"])
    n = Map.get(dict, "N", 0)
    first = Map.get(dict, "First", 0)

    if first > byte_size(decoded) do
      []
    else
      header = binary_part(decoded, 0, first)
      body = binary_part(decoded, first, byte_size(decoded) - first)
      pairs = read_pairs(header, n, [])

      Enum.flat_map(pairs, fn {num, off} ->
        if off <= byte_size(body) do
          case Parser.parse_value(binary_part(body, off, byte_size(body) - off)) do
            {value, _} -> [{num, value}]
            :eof -> []
          end
        else
          []
        end
      end)
    end
  end

  defp read_pairs(_input, 0, acc), do: Enum.reverse(acc)

  defp read_pairs(input, n, acc) do
    rest = Parser.skip_ws(input)

    with {num, r} when is_integer(num) <- Parser.parse_number(rest),
         {off, r} when is_integer(off) <- Parser.parse_number(Parser.skip_ws(r)) do
      read_pairs(r, n - 1, [{num, off} | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp decrypt_object(%Stream{dict: dict, raw: raw} = s, crypt, num, gen) do
    cond do
      dict["Type"] == "XRef" ->
        s

      dict["Type"] == "Metadata" and not crypt.encrypt_metadata ->
        s

      identity_crypt_filter?(dict) ->
        %{s | dict: decrypt_value(dict, crypt, num, gen)}

      true ->
        %{
          s
          | dict: decrypt_value(dict, crypt, num, gen),
            raw: Crypt.decrypt_stream(crypt, raw, num, gen)
        }
    end
  end

  defp decrypt_object(value, crypt, num, gen), do: decrypt_value(value, crypt, num, gen)

  defp identity_crypt_filter?(dict) do
    List.wrap(dict["Filter"]) |> List.first() == "Crypt" and
      match?(%{"Name" => "Identity"}, dict["DecodeParms"])
  end

  defp decrypt_value({:string, s}, crypt, num, gen),
    do: {:string, Crypt.decrypt_string(crypt, s, num, gen)}

  defp decrypt_value(list, crypt, num, gen) when is_list(list),
    do: Enum.map(list, &decrypt_value(&1, crypt, num, gen))

  defp decrypt_value(map, crypt, num, gen) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, decrypt_value(v, crypt, num, gen)} end)

  defp decrypt_value(v, _, _, _), do: v

  # ---------------------------------------------------------------- access

  @doc "Resolves an indirect reference (following chains); other values pass through."
  @spec resolve(t(), term()) :: term()
  def resolve(doc, value), do: resolve(doc, value, 0)

  defp resolve(doc, {:ref, n, _}, depth) when depth < 32,
    do: resolve(doc, Map.get(doc.objects, n), depth + 1)

  defp resolve(_doc, {:ref, _, _}, _), do: nil
  defp resolve(_doc, value, _), do: value

  @doc "Gets `key` from a dictionary (or stream dictionary), resolved."
  @spec get(t(), term(), String.t()) :: term()
  def get(doc, %Stream{dict: dict}, key), do: get(doc, dict, key)
  def get(doc, dict, key) when is_map(dict), do: resolve(doc, Map.get(dict, key))
  def get(doc, {:ref, _, _} = ref, key), do: get(doc, resolve(doc, ref), key)
  def get(_doc, _, _key), do: nil

  @doc "Follows a path of keys, resolving references at every step."
  @spec get_in(t(), term(), [String.t()]) :: term()
  def get_in(doc, value, keys), do: Enum.reduce(keys, resolve(doc, value), &get(doc, &2, &1))

  @doc "The document catalog."
  def catalog(doc), do: resolve(doc, doc.trailer["Root"])

  @doc "The `/Info` dictionary, or an empty map."
  def info(doc) do
    case resolve(doc, doc.trailer["Info"]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  @doc "Decodes a stream's data (`nil` for anything that is not a stream)."
  @spec stream_data(t(), term()) :: binary() | nil
  def stream_data(doc, value) do
    case resolve(doc, value) do
      %Stream{dict: dict, raw: raw} ->
        filters = resolve(doc, dict["Filter"]) |> resolve_list(doc)
        params = resolve(doc, dict["DecodeParms"] || dict["DP"]) |> resolve_list(doc)
        Filter.decode!(raw, filters, params)

      _ ->
        nil
    end
  end

  defp resolve_list(list, doc) when is_list(list), do: Enum.map(list, &resolve(doc, &1))
  defp resolve_list(v, _doc), do: v

  # ---------------------------------------------------------------- editing primitives

  @doc "Adds a new object and returns `{doc, ref}`."
  @spec add_object(t(), term()) :: {t(), {:ref, pos_integer(), 0}}
  def add_object(doc, value) do
    num = doc.next_num
    {%{doc | objects: Map.put(doc.objects, num, value), next_num: num + 1}, {:ref, num, 0}}
  end

  @doc "Replaces the object behind `ref`."
  @spec put_object(t(), {:ref, integer(), integer()} | integer(), term()) :: t()
  def put_object(doc, {:ref, n, _}, value), do: put_object(doc, n, value)

  def put_object(doc, n, value) when is_integer(n),
    do: %{doc | objects: Map.put(doc.objects, n, value), next_num: max(doc.next_num, n + 1)}

  @doc "Removes the object behind `ref`."
  def delete_object(doc, {:ref, n, _}), do: %{doc | objects: Map.delete(doc.objects, n)}

  # ---------------------------------------------------------------- pages

  @doc "Rebuilds the flattened page list after the page tree changed."
  @spec refresh_pages(t()) :: t()
  def refresh_pages(doc) do
    root = get(doc, catalog(doc), "Pages")
    root_ref = catalog(doc)["Pages"]

    pages =
      doc
      |> walk_pages(root_ref, root, %{}, MapSet.new(), [])
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {{ref, dict, inherited}, i} -> Page.new(doc, i, ref, dict, inherited) end)

    pages = if pages == [], do: fallback_pages(doc), else: pages
    %{doc | pages: pages}
  end

  @inheritable ~w(Resources MediaBox CropBox Rotate)

  defp walk_pages(doc, ref, node, inherited, seen, acc) when is_map(node) do
    key = ref || make_ref()

    if MapSet.member?(seen, key) do
      acc
    else
      seen = MapSet.put(seen, key)

      inherited =
        Enum.reduce(@inheritable, inherited, fn k, inh ->
          if Map.has_key?(node, k), do: Map.put(inh, k, node[k]), else: inh
        end)

      case {node["Type"], resolve(doc, node["Kids"])} do
        {type, kids} when is_list(kids) and type != "Page" ->
          Enum.reduce(kids, acc, fn kid, acc ->
            walk_pages(doc, kid, resolve(doc, kid), inherited, seen, acc)
          end)

        _ ->
          [{ref, node, inherited} | acc]
      end
    end
  end

  defp walk_pages(_doc, _ref, _node, _inherited, _seen, acc), do: acc

  # a broken page tree: collect every /Type /Page object in object order
  defp fallback_pages(doc) do
    doc.objects
    |> Enum.filter(fn {_, v} -> match?(%{"Type" => "Page"}, v) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.with_index()
    |> Enum.map(fn {{n, dict}, i} -> Page.new(doc, i, {:ref, n, 0}, dict, %{}) end)
  end

  @doc "The page at zero-based `index`."
  @spec page(t(), non_neg_integer()) :: Page.t() | nil
  def page(doc, index), do: Enum.at(doc.pages, index)

  @doc "Number of pages."
  def page_count(doc), do: length(doc.pages)

  @doc "The concatenated, decoded content stream(s) of a page."
  @spec page_content(t(), Page.t()) :: binary()
  def page_content(doc, %Page{dict: dict}) do
    case resolve(doc, dict["Contents"]) do
      %Stream{} = s ->
        stream_data(doc, s) || <<>>

      list when is_list(list) ->
        list
        |> Enum.map(&(stream_data(doc, &1) || <<>>))
        |> Enum.intersperse("\n")
        |> IO.iodata_to_binary()

      _ ->
        <<>>
    end
  end

  @doc "Index of the page whose object is `ref` (nil if none)."
  def page_index(doc, {:ref, n, _}),
    do: Enum.find_index(doc.pages, &match?(%Page{ref: {:ref, ^n, _}}, &1))

  def page_index(_doc, _), do: nil
end
