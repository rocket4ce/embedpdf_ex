defmodule EmbedPdf.Live.Access do
  @moduledoc """
  Enforces the viewer's features on the server.

  Turning a feature off (or setting `read_only`) hides its controls, but a
  client can still send any event over the LiveView socket. Every event
  therefore passes through `allowed?/3` before its handler runs, uploads
  are only accepted for features that are on, and a viewer with no feature
  that changes the document never writes to `EmbedPdf.Store`.
  """

  alias EmbedPdf.Live.FormDesign

  # features that change the document
  @changing ~w(annotations shapes stamps comments.writing forms.filling forms.building
               signatures.signing redaction measurement pages attachments.adding outline.editing)

  # features whose marks are annotations the user may then move, restyle or delete
  @annotating ~w(annotations shapes stamps measurement redaction signatures.signing)

  @modes %{
    "view" => :any,
    "annotate" => "annotations",
    "shapes" => "shapes",
    "insert" => ~w(stamps annotations.links attachments.adding signatures.signing measurement),
    "form" => "forms",
    "redact" => "redaction",
    "pages" => "pages"
  }

  @tools %{
    "pointer" => :any,
    "pan" => :any,
    "snapshot" => "snapshots",
    "highlight" => "annotations.highlight",
    "underline" => "annotations.markup",
    "strikeout" => "annotations.markup",
    "squiggly" => "annotations.markup",
    "ink" => "annotations.drawing",
    "free_text" => "annotations.text",
    "note" => "annotations.notes",
    "square" => "shapes",
    "circle" => "shapes",
    "line" => "shapes",
    "arrow" => "shapes",
    "polygon" => "shapes",
    "polyline" => "shapes",
    "link" => "annotations.links",
    "measure" => "measurement",
    "redact_text" => "redaction",
    "redact_area" => "redaction",
    "stamp" => "stamps",
    "signature" => "signatures.signing"
  }

  @panels %{
    "thumbnails" => "thumbnails",
    "outline" => "outline",
    "attachments" => "attachments",
    "search" => "search",
    "comments" => "comments",
    "signatures" => "signatures",
    "annotation" => :any,
    "redact" => "redaction",
    "field" => "forms.building"
  }

  @dialogs %{
    "print" => "documents.print",
    "open" => "documents.open",
    "properties" => :any,
    "shortcuts" => :any
  }

  @events %{
    "stamp" => "stamps",
    "delete_annotation" => @annotating,
    "duplicate_annotation" => @annotating,
    "resize_annotation" => @annotating,
    "move_annotation" => @annotating,
    "nudge" => @annotating,
    "annotation_props" => @annotating,
    "free_text" => "annotations.text",
    "edit_text" => "annotations.text",
    "reply" => "comments.writing",
    "undo" => @changing,
    "redo" => @changing,
    "outline_add" => "outline.editing",
    "outline_rename" => "outline.editing",
    "outline_rename_cancel" => "outline.editing",
    "outline_edit" => "outline.editing",
    "attachment_delete" => "attachments.adding",
    "form_change" => "forms.filling",
    "form_reset" => "forms.filling",
    "redact_apply" => "redaction",
    "pages" => "pages",
    "pages_extract" => "pages",
    "save_props" => "annotations",
    "sign_field" => "signatures.signing",
    "sign" => "signatures.signing",
    "signature_text" => "signatures.signing",
    "calibrate" => "measurement",
    "measure_dialog" => "measurement",
    "measure_save" => "measurement",
    "link_create" => "annotations.links",
    "close_document" => "documents.open",
    "search" => "search",
    "search_nav" => "search",
    "search_goto" => "search",
    "search_clear" => "search"
  }

  @uploads %{pdf: "documents.open", insert: "pages", attachment: "attachments.adding"}

  @doc "Whether the features allow `event` with `params`."
  @spec allowed?(map(), String.t(), map()) :: boolean()
  def allowed?(features, event, params) do
    on?(features, requirement(event, params))
  end

  @doc "Whether any feature that changes the document is on."
  @spec changes?(map()) :: boolean()
  def changes?(features), do: on?(features, @changing)

  @doc "Whether the upload `name` (`:pdf`, `:insert`, `:attachment`) is accepted."
  @spec upload?(map(), atom()) :: boolean()
  def upload?(features, name), do: on?(features, Map.get(@uploads, name, :none))

  @doc "The mode, tool, panel or dialog name as the atom the viewer uses, or nil when unknown."
  @spec known(:mode | :tool | :panel | :dialog, term()) :: atom() | nil
  def known(kind, name) when is_binary(name) do
    table =
      case kind do
        :mode -> @modes
        :tool -> @tools
        :panel -> @panels
        :dialog -> @dialogs
      end

    cond do
      Map.has_key?(table, name) -> String.to_existing_atom(name)
      kind == :tool -> Enum.find(FormDesign.tools(), &(Atom.to_string(&1) == name))
      true -> nil
    end
  end

  def known(_, _), do: nil

  defp requirement("mode", %{"mode" => m}), do: Map.get(@modes, m, :none)

  defp requirement("tool", %{"tool" => t}) do
    cond do
      Map.has_key?(@tools, t) -> Map.fetch!(@tools, t)
      is_binary(t) and known(:tool, t) != nil -> "forms.building"
      true -> :none
    end
  end

  defp requirement("panel", %{"panel" => p}), do: Map.get(@panels, p, :none)
  defp requirement("dialog", %{"dialog" => d}), do: Map.get(@dialogs, d, :none)
  defp requirement("field_" <> _, _params), do: "forms.building"
  defp requirement(event, _params), do: Map.get(@events, event, :any)

  defp on?(_features, :any), do: true
  defp on?(_features, :none), do: false
  defp on?(features, name) when is_binary(name), do: Map.get(features, name, false) == true
  defp on?(features, names) when is_list(names), do: Enum.any?(names, &on?(features, &1))
end
