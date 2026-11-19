defmodule EmbedPdf.Live.Icons do
  @moduledoc "Inline SVG icons for the viewer (24×24 strokes in `currentColor`)."
  use Phoenix.Component

  @paths %{
    "menu" => "M4 6h16M4 12h16M4 18h16",
    "sidebar" => "M4 5h16v14H4zM9 5v14",
    "chevron-left" => "M15 6l-6 6 6 6",
    "chevron-right" => "M9 6l6 6-6 6",
    "chevron-up" => "M6 15l6-6 6 6",
    "chevron-down" => "M6 9l6 6 6-6",
    "first" => "M11 6l-6 6 6 6M18 6l-6 6 6 6",
    "last" => "M13 6l6 6-6 6M6 6l6 6-6 6",
    "plus" => "M12 5v14M5 12h14",
    "minus" => "M5 12h14",
    "search" => "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4",
    "comment" => "M4 5h16v11H9l-5 4z",
    "fullscreen" => "M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5",
    "fullscreen-exit" => "M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5",
    "rotate-cw" => "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
    "rotate-ccw" => "M4 11a8 8 0 1 1 2.3 5.7M4 4v7h7",
    "pointer" => "M6 3l12 9-6 1-3 6z",
    "hand" =>
      "M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4.5a1.5 1.5 0 0 1 3 0V12M14 11V6.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-1a6 6 0 0 1-5-2.7L3.5 15a1.5 1.5 0 0 1 2.4-1.8L8 15",
    "highlight" => "M4 20h6M14 4l6 6-8 8H6v-6zM12 6l6 6",
    "underline" => "M7 4v7a5 5 0 0 0 10 0V4M5 20h14",
    "strikeout" =>
      "M5 12h14M16 7a4 3 0 0 0-4-2c-2.2 0-4 1.1-4 3 0 4 8 2.5 8 7 0 1.9-1.8 3-4 3a4 3 0 0 1-4-2",
    "squiggly" => "M3 17c2-3 3-3 4.5 0s2.5 3 4.5 0 3-3 4.5 0 2.5 3 4.5 0M7 4v6a5 5 0 0 0 10 0V4",
    "pen" => "M4 20l4-1 11-11-3-3L5 16zM14 7l3 3",
    "text" => "M5 6V4h14v2M12 4v16M9 20h6",
    "note" => "M5 4h14v11l-5 5H5zM14 20v-5h5",
    "square" => "M5 5h14v14H5z",
    "circle" => "M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16z",
    "line" => "M5 19L19 5",
    "arrow" => "M5 19L19 5M10 5h9v9",
    "polygon" => "M12 3l9 7-3.5 10h-11L3 10z",
    "polyline" => "M3 17l5-8 5 6 4-9 4 5",
    "stamp" => "M9 4h6l-1 7h4a2 2 0 0 1 2 2v3H4v-3a2 2 0 0 1 2-2h4zM5 20h14",
    "link" =>
      "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
    "paperclip" =>
      "M15 7l-6.5 6.5a1.5 1.5 0 0 0 2.1 2.1L17 9.2a3 3 0 0 0-4.2-4.2l-6.4 6.4a4.5 4.5 0 0 0 6.4 6.4L19 11.5",
    "redact" => "M4 6h16v5H4zM4 15h10M4 19h7",
    "download" => "M12 4v11M7 10l5 5 5-5M5 20h14",
    "print" => "M7 9V4h10v5M7 17H5v-6h14v6h-2M7 14h10v6H7z",
    "file" => "M6 3h8l4 4v14H6zM14 3v4h4",
    "close" => "M6 6l12 12M18 6L6 18",
    "trash" => "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
    "copy" => "M8 8h12v12H8zM16 8V4H4v12h4",
    "undo" => "M9 14L4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3",
    "redo" => "M15 14l5-5-5-5M20 9H10a6 6 0 0 0 0 12h3",
    "check" => "M5 12l5 5 9-10",
    "camera" => "M4 8h3l2-3h6l2 3h3v11H4zM12 10a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z",
    "zoom-area" => "M10 4a6 6 0 1 0 0 12 6 6 0 0 0 0-12zM20 20l-5.5-5.5M8 10h4M10 8v4",
    "ruler" => "M3 17L17 3l4 4L7 21zM7 13l2 2M10 10l2 2M13 7l2 2",
    "dots" => "M5 12h.01M12 12h.01M19 12h.01",
    "info" => "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v6M12 7.5v.01",
    "upload" => "M12 20V9M7 14l5-5 5 5M5 4h14",
    "sun" =>
      "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4",
    "moon" => "M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z",
    "keyboard" => "M3 6h18v12H3zM7 10h.01M11 10h.01M15 10h.01M7 14h10",
    "bookmark" => "M7 4h10v16l-5-4-5 4z",
    "resize" => "M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7",
    "move" => "M12 3v18M3 12h18M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3",
    "thumbnails" => "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
    "outline" => "M9 6h11M9 12h11M9 18h11M5 6h.01M5 12h.01M5 18h.01",
    "pages" => "M8 4h10v13H8zM5 7v13h10",
    "layout" => "M4 5h7v14H4zM13 5h7v14h-7z",
    "eye" => "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
    "form" => "M4 5h16v4H4zM4 13h16v4H4zM7 7h.01M7 15h.01",
    "caret" => "M6 18l6-12 6 12",
    "send" => "M4 12l16-8-6 16-3-7z"
  }

  attr :name, :string, required: true
  attr :class, :string, default: "epdf-icon"

  @doc "Renders an icon by name."
  def icon(assigns) do
    assigns = assign(assigns, :d, Map.get(@paths, assigns.name, @paths["dots"]))

    ~H"""
    <svg class={@class} viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor"
      stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={@d} /></svg>
    """
  end

  @doc "All icon names."
  def names, do: Map.keys(@paths)
end
