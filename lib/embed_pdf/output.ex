defmodule EmbedPdf.Output do
  @moduledoc """
  The bytes of a stored document as it should be downloaded or signed.

  A document that was opened signed is written as an incremental update
  appended to its original bytes, so the signatures keep covering exactly
  what was signed; anything else is written as a fresh, compact file.
  """

  alias EmbedPdf.PDF.Incremental
  alias EmbedPdf.Store

  @doc """
  Bytes for a store entry. Options: `flatten: true` bakes annotations into
  the page content (always a full rewrite).
  """
  @spec bytes(Store.Entry.t(), keyword()) :: binary()
  def bytes(%Store.Entry{doc: doc, meta: meta}, opts \\ []) do
    original = meta[:original]
    original_doc = meta[:original_doc]

    cond do
      opts[:flatten] ->
        doc |> EmbedPdf.Writer.flatten_annotations(:all) |> EmbedPdf.Writer.save([])

      is_binary(original) and original_doc != nil and meta[:signed?] == true ->
        if doc == original_doc do
          original
        else
          case Incremental.append_diff(original, original_doc, doc) do
            bytes when is_binary(bytes) -> bytes
            _ -> EmbedPdf.Writer.save(doc, [])
          end
        end

      true ->
        EmbedPdf.Writer.save(doc, [])
    end
  end

  @doc "Metadata to keep with a document opened from `bytes`."
  @spec original_meta(binary(), EmbedPdf.PDF.Document.t()) :: map()
  def original_meta(bytes, doc) do
    signed? =
      try do
        doc |> EmbedPdf.Signatures.fields() |> Enum.any?(& &1.signed?)
      rescue
        _ -> false
      end

    %{original: bytes, original_doc: doc, signed?: signed?}
  end
end
