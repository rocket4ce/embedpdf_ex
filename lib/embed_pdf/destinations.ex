defmodule EmbedPdf.Destinations do
  @moduledoc """
  Destinations (ISO 32000-1, 12.3.2) and actions (12.6).

  A resolved destination is `%{page: index, left:, top:, zoom:, fit:, rect:}`
  where `fit` is one of `:xyz`, `:fit`, `:fit_h`, `:fit_v`, `:fit_r`,
  `:fit_b`, `:fit_bh`, `:fit_bv`; coordinates are PDF user space and may be
  nil ("keep the current value").
  """

  alias EmbedPdf.PDF.{Document, NameTree, TextString}

  @fits %{
    "XYZ" => :xyz,
    "Fit" => :fit,
    "FitH" => :fit_h,
    "FitV" => :fit_v,
    "FitR" => :fit_r,
    "FitB" => :fit_b,
    "FitBH" => :fit_bh,
    "FitBV" => :fit_bv
  }

  @doc "Resolves an explicit or named destination."
  @spec resolve(Document.t(), term()) :: map() | nil
  def resolve(doc, dest), do: do_resolve(doc, dest, 0)

  defp do_resolve(_doc, _dest, depth) when depth > 8, do: nil

  defp do_resolve(doc, {:ref, _, _} = ref, depth) do
    case Document.resolve(doc, ref) do
      list when is_list(list) -> explicit(doc, list)
      %{"D" => d} -> do_resolve(doc, d, depth + 1)
      other when is_binary(other) or is_tuple(other) -> do_resolve(doc, other, depth + 1)
      _ -> nil
    end
  end

  defp do_resolve(doc, list, _depth) when is_list(list), do: explicit(doc, list)
  defp do_resolve(doc, %{"D" => d}, depth), do: do_resolve(doc, d, depth + 1)

  defp do_resolve(doc, name, depth) when is_binary(name) do
    case named(doc, name) do
      nil -> nil
      value -> do_resolve(doc, value, depth + 1)
    end
  end

  defp do_resolve(doc, {:string, name}, depth) do
    case named(doc, name) do
      nil -> nil
      value -> do_resolve(doc, value, depth + 1)
    end
  end

  defp do_resolve(_doc, _, _), do: nil

  @doc "Looks up a named destination (in `/Dests` and in the `/Names /Dests` tree)."
  @spec named(Document.t(), binary()) :: term()
  def named(doc, name) do
    catalog = Document.catalog(doc)

    from_dict =
      case Document.get(doc, catalog, "Dests") do
        %{} = dests -> Map.get(dests, name)
        _ -> nil
      end

    from_dict ||
      case Document.get_in(doc, catalog, ["Names", "Dests"]) do
        %{} = tree -> NameTree.lookup(doc, tree, name)
        _ -> nil
      end
  end

  @doc "All named destinations as `[{name, raw_value}]`."
  def all_named(doc) do
    catalog = Document.catalog(doc)

    dict =
      case Document.get(doc, catalog, "Dests") do
        %{} = dests -> Map.to_list(dests)
        _ -> []
      end

    tree =
      case Document.get_in(doc, catalog, ["Names", "Dests"]) do
        %{} = t -> NameTree.entries(doc, t)
        _ -> []
      end

    dict ++ tree
  end

  defp explicit(doc, [page | rest]) do
    page_index =
      case page do
        {:ref, _, _} = ref -> Document.page_index(doc, ref)
        n when is_integer(n) -> if n >= 0 and n < Document.page_count(doc), do: n, else: nil
        _ -> nil
      end

    rest = Enum.map(rest, &Document.resolve(doc, &1))

    if page_index == nil do
      nil
    else
      {fit, args} =
        case rest do
          [kind | args] when is_binary(kind) -> {Map.get(@fits, kind, :xyz), args}
          _ -> {:fit, []}
        end

      n = fn i -> with v when is_number(v) <- Enum.at(args, i), do: v / 1, else: (_ -> nil) end

      base = %{page: page_index, fit: fit, left: nil, top: nil, zoom: nil, rect: nil}

      case fit do
        :xyz ->
          zoom = n.(2)
          %{base | left: n.(0), top: n.(1), zoom: if(zoom && zoom > 0, do: zoom, else: nil)}

        f when f in [:fit_h, :fit_bh] ->
          %{base | top: n.(0)}

        f when f in [:fit_v, :fit_bv] ->
          %{base | left: n.(0)}

        :fit_r ->
          rect = if Enum.all?(0..3, &n.(&1)), do: {n.(0), n.(1), n.(2), n.(3)}, else: nil
          %{base | rect: rect, left: n.(0), top: n.(3)}

        _ ->
          base
      end
    end
  end

  defp explicit(_doc, _), do: nil

  @doc "Builds an explicit `/XYZ` destination array for a page."
  @spec build(Document.t(), non_neg_integer(), keyword()) :: list()
  def build(doc, page_index, opts \\ []) do
    page = Document.page(doc, page_index)
    {_, _, _, y1} = page.box

    [
      page.ref,
      "XYZ",
      Keyword.get(opts, :left),
      Keyword.get(opts, :top, y1),
      Keyword.get(opts, :zoom)
    ]
  end

  @doc """
  Interprets an action dictionary:
  `{:goto, dest}` | `{:uri, url}` | `{:named, name}` | `{:external, %{file:, dest:}}`
  | `{:launch, file}` | `{:javascript, code}` | `{:other, type}` | nil.
  """
  @spec action(Document.t(), term()) :: tuple() | nil
  def action(doc, value) do
    case Document.resolve(doc, value) do
      %{} = a ->
        case Document.resolve(doc, a["S"]) do
          "GoTo" ->
            case resolve(doc, a["D"]) do
              nil -> nil
              dest -> {:goto, dest}
            end

          "URI" ->
            case Document.resolve(doc, a["URI"]) do
              {:string, url} -> {:uri, url |> String.trim_trailing(<<0>>) |> to_utf8()}
              _ -> nil
            end

          "Named" ->
            {:named, Document.resolve(doc, a["N"])}

          "GoToR" ->
            {:external, %{file: file_name(doc, a["F"]), dest: raw_dest(doc, a["D"])}}

          "Launch" ->
            {:launch, file_name(doc, a["F"])}

          "JavaScript" ->
            js = Document.resolve(doc, a["JS"])

            code =
              if match?({:string, _}, js),
                do: TextString.decode(js),
                else: Document.stream_data(doc, js)

            {:javascript, code}

          type when is_binary(type) ->
            {:other, type}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp to_utf8(s), do: if(String.valid?(s), do: s, else: TextString.decode(s))

  defp raw_dest(doc, d) do
    case Document.resolve(doc, d) do
      {:string, s} -> s
      name when is_binary(name) -> name
      [p | rest] when is_integer(p) -> %{page: p, view: rest}
      _ -> nil
    end
  end

  defp file_name(doc, f) do
    case Document.resolve(doc, f) do
      {:string, _} = s ->
        TextString.decode(s)

      %{} = spec ->
        Enum.find_value(["UF", "F", "Unix", "DOS", "Mac"], fn k ->
          case Document.resolve(doc, spec[k]) do
            {:string, _} = s -> TextString.decode(s)
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc "The action (or `/Dest`) of an annotation or outline item dictionary."
  @spec of_item(Document.t(), map()) :: tuple() | nil
  def of_item(doc, dict) do
    cond do
      Map.has_key?(dict, "Dest") ->
        case resolve(doc, dict["Dest"]) do
          nil -> nil
          dest -> {:goto, dest}
        end

      Map.has_key?(dict, "A") ->
        action(doc, dict["A"])

      true ->
        nil
    end
  end
end
