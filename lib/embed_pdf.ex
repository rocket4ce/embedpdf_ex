defmodule EmbedPdf do
  @moduledoc """
  A PDF viewer and editor for Phoenix LiveView, in pure Elixir.

  The engine opens, reads, renders (to SVG), searches and changes PDFs
  without native code; `EmbedPdf.Live.Viewer` puts a complete viewer in a
  LiveView without any JavaScript of your own.

      {:ok, doc} = EmbedPdf.open("manual.pdf")
      EmbedPdf.page_count(doc)
      EmbedPdf.search(doc, "warranty")
      svg = EmbedPdf.render_svg(doc, 0)
      File.write!("out.pdf", EmbedPdf.save(doc))
  """

  alias EmbedPdf.PDF.{Document, Page, Serializer}

  @type doc :: Document.t()

  @doc """
  Opens a PDF from bytes or a file path. Options: `:password`.
  """
  @spec open(binary() | Path.t(), keyword()) :: {:ok, doc()} | {:error, term()}
  def open(source, opts \\ []) do
    bytes =
      cond do
        is_binary(source) and String.starts_with?(source, "%PDF") ->
          source

        is_binary(source) and byte_size(source) < 4096 and File.regular?(source) ->
          File.read!(source)

        true ->
          source
      end

    Document.open(bytes, opts)
  end

  @doc "Writes the document to PDF bytes."
  @spec save(doc(), keyword()) :: binary()
  def save(doc, opts \\ []), do: Serializer.save(doc, opts)

  @doc "Number of pages."
  @spec page_count(doc()) :: non_neg_integer()
  def page_count(doc), do: Document.page_count(doc)

  @doc "Displayed size `{width, height}` in points of page `index` (zero-based)."
  @spec page_size(doc(), non_neg_integer()) :: {float(), float()}
  def page_size(doc, index), do: doc |> Document.page(index) |> Page.display_size()

  @doc "The text of page `index`."
  @spec text(doc(), non_neg_integer()) :: String.t()
  def text(doc, index), do: doc |> EmbedPdf.Text.page(index) |> EmbedPdf.Text.text()

  @doc """
  Searches every page. Options: `:case_sensitive`, `:whole_word`.
  Returns the hits in document order (see `EmbedPdf.Text.search/3`).
  """
  @spec search(doc(), String.t(), keyword()) :: [map()]
  def search(doc, query, opts \\ []) do
    0..(page_count(doc) - 1)//1
    |> Task.async_stream(
      fn i -> doc |> EmbedPdf.Text.page(i) |> EmbedPdf.Text.search(query, opts) end,
      ordered: true,
      timeout: 60_000
    )
    |> Enum.flat_map(fn {:ok, hits} -> hits end)
  end

  @doc "Renders page `index` to an SVG document (see `EmbedPdf.Render.SVG`)."
  @spec render_svg(doc(), non_neg_integer(), keyword()) :: iodata()
  def render_svg(doc, index, opts \\ []), do: EmbedPdf.Render.SVG.render_page(doc, index, opts)

  @doc "Document metadata (`title`, `author`, ...)."
  def metadata(doc), do: EmbedPdf.Metadata.get(doc)
end
