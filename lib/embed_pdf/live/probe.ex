defmodule EmbedPdf.Live.Probe do
  @moduledoc """
  Measures the viewer's viewport without JavaScript.

  The viewport is a CSS size container. A generated stylesheet holds one
  container query per size bucket, each giving a 1-pixel probe element a
  different `background-image` URL. The browser fetches only the URL of
  the bucket that matches, and that request tells the server the width
  (or height). When the size changes another rule matches and another URL
  is fetched; the stylesheet's nonce changes after every report so a
  bucket seen before is fetched again.
  """

  @step 16
  @widths 160..4000//@step
  @heights 120..3000//@step

  @doc "The probe stylesheet for `viewer` and `nonce`."
  @spec css(String.t(), String.t(), String.t()) :: String.t()
  def css(base, viewer, nonce) do
    sel = "[data-epdf-viewer=\"#{viewer}\"]"
    url = fn key, v -> "#{base}/probe?v=#{viewer}&n=#{nonce}&#{key}=#{v}" end

    widths =
      for w <- @widths do
        "@container epdfvp (min-width:#{w}px){#{sel} .epdf-probe-w{background-image:url(\"#{url.("w", w)}\")}}"
      end

    heights =
      for h <- @heights do
        "@container epdfvp (min-height:#{h}px){#{sel} .epdf-probe-h{background-image:url(\"#{url.("h", h)}\")}}"
      end

    IO.iodata_to_binary([
      Enum.intersperse(widths, "\n"),
      "\n",
      Enum.intersperse(heights, "\n"),
      "\n"
    ])
  end

  @doc "Bucket size in pixels (the probe reports the lower bound)."
  def step, do: @step
end
