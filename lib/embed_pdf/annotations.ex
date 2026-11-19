defmodule EmbedPdf.Annotations do
  @moduledoc """
  Reading, creating, changing and deleting annotations.

  Every function returns a new document; ids are annotation object
  numbers. Creating or changing an annotation regenerates its appearance
  stream (see `EmbedPdf.Annotation.Appearance`).

      {doc, note} = EmbedPdf.Annotations.add(doc, 0, %{subtype: :text, at: {72, 720}, contents: "Check this"})
      {doc, hl} = EmbedPdf.Annotations.add(doc, 0, %{subtype: :highlight, quad_points: [{72, 700, 200, 714}]})
      doc = EmbedPdf.Annotations.delete(doc, note.id)
  """

  alias EmbedPdf.{Annotation, Attachments, Edit, Stamps}
  alias EmbedPdf.Annotation.Appearance
  alias EmbedPdf.PDF.{Document, Page, Stream}

  @red {0.894, 0.259, 0.204}
  @yellow {1.0, 0.804, 0.271}

  @markup [:highlight, :underline, :strikeout, :squiggly]

  # ---------------------------------------------------------------- reading

  @doc "Annotations of a page, without popups; replies are nested under `replies`."
  @spec list(Document.t(), non_neg_integer()) :: [Annotation.t()]
  def list(doc, page_index) do
    all = all_on_page(doc, page_index)
    ids = all |> Enum.map(& &1.id) |> MapSet.new()

    {replies, top} =
      Enum.split_with(all, fn a ->
        a.in_reply_to != nil and a.reply_type != "Group" and MapSet.member?(ids, a.in_reply_to)
      end)

    by_parent = Enum.group_by(replies, & &1.in_reply_to)
    Enum.map(top, &nest(&1, by_parent, 0))
  end

  defp nest(a, by_parent, depth) when depth < 16 do
    replies =
      by_parent
      |> Map.get(a.id, [])
      |> Enum.sort_by(&(&1.created && DateTime.to_unix(&1.created)))
      |> Enum.map(&nest(&1, by_parent, depth + 1))

    %{a | replies: replies}
  end

  defp nest(a, _, _), do: a

  @doc "Every annotation of a page, flat, popups excluded."
  @spec all_on_page(Document.t(), non_neg_integer()) :: [Annotation.t()]
  def all_on_page(doc, page_index) do
    case Document.page(doc, page_index) do
      nil ->
        []

      page ->
        doc
        |> Edit.annots(page)
        |> Enum.flat_map(fn value ->
          id = with {:ref, n, _} <- value, do: n

          case Document.resolve(doc, value) do
            %{} = dict ->
              [Annotation.from_dict(doc, if(is_integer(id), do: id), dict, page_index)]

            _ ->
              []
          end
        end)
        |> Enum.reject(&(&1.subtype == :popup))
    end
  end

  @doc "Every annotation of the document, by page."
  def all(doc), do: Enum.flat_map(doc.pages, &list(doc, &1.index))

  @doc "One annotation by id (nil when missing)."
  @spec get(Document.t(), integer()) :: Annotation.t() | nil
  def get(doc, id) do
    case page_of(doc, id) do
      nil ->
        case Document.resolve(doc, {:ref, id, 0}) do
          %{"Subtype" => _} = dict -> Annotation.from_dict(doc, id, dict, nil)
          _ -> nil
        end

      index ->
        doc |> list(index) |> find_nested(id) ||
          Enum.find(all_on_page(doc, index), &(&1.id == id))
    end
  end

  defp find_nested([], _id), do: nil

  defp find_nested([a | rest], id) do
    if a.id == id, do: a, else: find_nested(a.replies, id) || find_nested(rest, id)
  end

  @doc "Index of the page whose `/Annots` holds annotation `id`."
  @spec page_of(Document.t(), integer()) :: non_neg_integer() | nil
  def page_of(doc, id) do
    Enum.find_value(doc.pages, fn page ->
      if Enum.any?(Edit.annots(doc, page), &match?({:ref, ^id, _}, &1)), do: page.index
    end)
  end

  @doc "The normal appearance stream of an annotation (nil when it has none)."
  @spec appearance(Document.t(), integer()) :: Stream.t() | nil
  def appearance(doc, id) do
    dict = Document.resolve(doc, {:ref, id, 0}) || %{}

    case Document.get_in(doc, dict, ["AP", "N"]) do
      %Stream{} = s ->
        s

      %{} = states ->
        state = Document.resolve(doc, dict["AS"])
        Document.resolve(doc, Map.get(states, state))

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------- creating

  @doc """
  Adds an annotation to page `page_index`. `attrs` use `EmbedPdf.Annotation`
  field names; besides `rect`, geometry can be given as `quad_points`
  (rectangles), `ink_list`, `vertices` or `line`, and point-like
  annotations (notes, stamps, carets, attachments) accept `at: {x, y}`.
  A file attachment takes `file: %{name:, data:, mime:}`.
  """
  @spec add(Document.t(), non_neg_integer(), map() | keyword()) :: {Document.t(), Annotation.t()}
  def add(doc, page_index, attrs) do
    attrs = Map.new(attrs)
    page = Document.page(doc, page_index) || raise ArgumentError, "no page #{page_index}"
    subtype = Map.get(attrs, :subtype, :square)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    a =
      Annotation
      |> struct(Map.merge(defaults(subtype), fields(attrs)))
      |> Map.merge(%{page: page_index, created: Map.get(attrs, :created, now), modified: now})
      |> then(&%{&1 | name: &1.name || Edit.unique_name()})
      |> stamp_defaults(attrs)
      |> place(attrs)
      |> derive_rect(attrs, true)

    {doc, ref} = Document.add_object(doc, %{})
    {:ref, id, _} = ref
    a = %{a | id: id}

    dict = a |> Annotation.to_dict(%{}) |> Map.put("P", page.ref)

    {doc, dict} =
      case Map.get(attrs, :file) do
        %{name: name, data: data} = file when subtype == :file_attachment ->
          {doc, fs} = Attachments.filespec(doc, name, data, Map.to_list(file))
          {doc, Map.put(dict, "FS", fs)}

        _ ->
          {doc, dict}
      end

    {doc, dict} = put_appearance(doc, a, dict, Map.get(attrs, :appearance))
    doc = Document.put_object(doc, ref, dict)

    doc =
      Edit.put_annots(
        doc,
        Document.page(doc, page_index),
        Edit.annots(doc, Document.page(doc, page_index)) ++ [ref]
      )

    {doc, get(doc, id)}
  end

  defp fields(attrs) do
    keys = Annotation.__struct__() |> Map.keys() |> MapSet.new()

    attrs
    |> Enum.filter(fn {k, _} -> MapSet.member?(keys, k) and k != :__struct__ end)
    |> Map.new()
  end

  defp defaults(:highlight), do: %{subtype: :highlight, color: @yellow}
  defp defaults(s) when s in [:underline, :strikeout, :squiggly], do: %{subtype: s, color: @red}
  defp defaults(:ink), do: %{subtype: :ink, color: @red, border_width: 6.0}

  defp defaults(s) when s in [:square, :circle, :polygon],
    do: %{subtype: s, color: @red, border_width: 6.0}

  defp defaults(s) when s in [:line, :polyline], do: %{subtype: s, color: @red, border_width: 6.0}

  defp defaults(:free_text),
    do: %{subtype: :free_text, border_width: 0.0, font_size: 14.0, font_color: {0.0, 0.0, 0.0}}

  defp defaults(:text), do: %{subtype: :text, color: @yellow, icon: "Comment", flags: 28}
  defp defaults(:stamp), do: %{subtype: :stamp, icon: "Approved"}

  defp defaults(:redact),
    do: %{subtype: :redact, color: {1.0, 0.0, 0.0}, interior_color: {0.0, 0.0, 0.0}}

  defp defaults(:link), do: %{subtype: :link, border_width: 0.0}
  defp defaults(:caret), do: %{subtype: :caret, color: {0.0, 0.3, 0.9}}

  defp defaults(:file_attachment),
    do: %{subtype: :file_attachment, color: {0.2, 0.2, 0.2}, icon: "PushPin"}

  defp defaults(s), do: %{subtype: s}

  defp stamp_defaults(%Annotation{subtype: :stamp} = a, _attrs) do
    case Stamps.get(a.icon) do
      nil -> a
      s -> %{a | icon: s.name, subject: a.subject || s.label}
    end
  end

  defp stamp_defaults(a, _), do: a

  # point-like annotations: turn `at` into a rect
  defp place(%Annotation{rect: nil} = a, %{at: {x, y}}) do
    rect =
      case a.subtype do
        :text -> {x, y - 20, x + 20, y}
        :file_attachment -> {x, y - 20, x + 14, y}
        :caret -> {x - 5, y - 7, x + 5, y + 7}
        :stamp -> stamp_rect(a, {x, y})
        _ -> {x - 10, y - 10, x + 10, y + 10}
      end

    %{a | rect: Edit.normalize(rect)}
  end

  defp place(a, _), do: a

  defp stamp_rect(a, {cx, cy}) do
    {w, h} =
      case Stamps.get(a.icon) do
        nil -> {150.0, 45.0}
        s -> s.size
      end

    rad = (a.rotation || 0) * :math.pi() / 180
    c = abs(:math.cos(rad))
    s = abs(:math.sin(rad))
    bw = w * c + h * s
    bh = w * s + h * c
    {cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2}
  end

  # rect from geometry, unless the caller gave one
  defp derive_rect(a, attrs, creating?) do
    given? = Map.has_key?(attrs, :rect) and attrs.rect != nil
    lw = a.border_width || 1.0

    a =
      if Map.has_key?(attrs, :quad_points) and not Map.has_key?(attrs, :quad_points_raw),
        do: %{a | quad_points_raw: []},
        else: a

    a =
      if a.quad_points == [] and a.quad_points_raw != [] do
        quads =
          a.quad_points_raw
          |> Enum.chunk_every(8, 8, :discard)
          |> Enum.map(fn q ->
            q |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1) |> Edit.bbox()
          end)

        %{a | quad_points: quads}
      else
        a
      end

    rect =
      cond do
        given? ->
          Edit.normalize(attrs.rect)

        a.subtype in @markup or (a.subtype in [:redact, :link] and a.quad_points != []) ->
          if a.quad_points != [], do: Edit.union(a.quad_points), else: a.rect

        a.subtype == :ink and a.ink_list != [] ->
          a.ink_list |> List.flatten() |> Edit.bbox(lw / 2 + 1)

        a.subtype == :line and a.line != nil ->
          {x1, y1, x2, y2} = a.line
          Edit.bbox([{x1, y1}, {x2, y2}], lw + max(lw * 4.5, 6.0))

        a.subtype in [:polygon, :polyline] and a.vertices != [] ->
          pad = if a.subtype == :polyline, do: lw + max(lw * 4.5, 6.0), else: lw
          Edit.bbox(a.vertices, pad)

        true ->
          a.rect
      end

    if rect == nil and creating?,
      do: raise(ArgumentError, "annotation needs a rect or geometry"),
      else: %{a | rect: rect && Edit.normalize(rect)}
  end

  # writes /AP unless the appearance cannot be generated (imported stamps,
  # unknown subtypes keep their own)
  defp put_appearance(doc, a, dict, override) do
    ap =
      cond do
        override != nil -> override
        a.in_reply_to != nil -> Edit.form(a.rect, [], %{})
        regenerable?(a) -> Appearance.build(a)
        true -> nil
      end

    case ap do
      nil ->
        {doc, dict}

      %Stream{} = stream ->
        {doc, ref} = Document.add_object(doc, stream)
        {doc, Map.put(dict, "AP", %{"N" => ref})}

      {:ref, _, _} = ref ->
        {doc, Map.put(dict, "AP", %{"N" => ref})}
    end
  end

  defp regenerable?(%Annotation{subtype: :stamp, icon: icon, has_appearance?: had}),
    do: Stamps.get(icon) != nil or not had

  defp regenerable?(%Annotation{subtype: s}) when s in [:unknown, :widget, :popup], do: false
  defp regenerable?(_), do: true

  # ---------------------------------------------------------------- changing

  @doc "Changes fields of an annotation and regenerates its appearance."
  @spec update(Document.t(), integer(), map() | keyword()) :: {Document.t(), Annotation.t()}
  def update(doc, id, attrs) do
    attrs = Map.new(attrs)

    case get(doc, id) do
      nil ->
        {doc, nil}

      a ->
        existing = Document.resolve(doc, {:ref, id, 0})
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        changes = fields(attrs) |> Map.drop([:id, :page, :replies])

        new =
          a
          |> Map.merge(changes)
          |> Map.put(:modified, now)
          |> then(fn n ->
            if Map.has_key?(changes, :quad_points), do: %{n | quad_points_raw: []}, else: n
          end)
          |> derive_rect(attrs, false)

        dict = Annotation.to_dict(new, existing)

        {doc, dict} =
          put_appearance(doc, new, dict, Map.get(attrs, :appearance) || keep_ap(a, existing))

        doc = Document.put_object(doc, {:ref, id, 0}, dict)
        {doc, get(doc, id)}
    end
  end

  # if the appearance cannot be regenerated, keep the old one
  defp keep_ap(a, existing) do
    if regenerable?(a) and a.subtype != :unknown, do: nil, else: get_in(existing, ["AP", "N"])
  end

  @doc "Moves an annotation by `dx`, `dy` (user space)."
  @spec move(Document.t(), integer(), number(), number()) :: {Document.t(), Annotation.t()}
  def move(doc, id, dx, dy) do
    case get(doc, id) do
      nil -> {doc, nil}
      a -> update(doc, id, transform_attrs(a, fn {x, y} -> {x + dx, y + dy} end))
    end
  end

  @doc "Resizes an annotation to `new_rect`, scaling its geometry."
  @spec resize(Document.t(), integer(), Annotation.rect()) :: {Document.t(), Annotation.t()}
  def resize(doc, id, new_rect) do
    case get(doc, id) do
      nil ->
        {doc, nil}

      %Annotation{rect: {ox0, oy0, ox1, oy1}} = a ->
        {nx0, ny0, nx1, ny1} = Edit.normalize(new_rect)
        sx = if ox1 - ox0 == 0, do: 1.0, else: (nx1 - nx0) / (ox1 - ox0)
        sy = if oy1 - oy0 == 0, do: 1.0, else: (ny1 - ny0) / (oy1 - oy0)
        fun = fn {x, y} -> {nx0 + (x - ox0) * sx, ny0 + (y - oy0) * sy} end
        attrs = a |> transform_attrs(fun) |> Map.put(:rect, {nx0, ny0, nx1, ny1})
        update(doc, id, attrs)
    end
  end

  defp transform_attrs(a, fun) do
    tr = fn {x0, y0, x1, y1} ->
      {a0, b0} = fun.({x0, y0})
      {a1, b1} = fun.({x1, y1})
      Edit.normalize({a0, b0, a1, b1})
    end

    attrs = %{rect: tr.(a.rect)}

    attrs =
      if a.quad_points != [],
        do: Map.put(attrs, :quad_points, Enum.map(a.quad_points, tr)),
        else: attrs

    attrs =
      if a.quad_points_raw != [] do
        raw =
          a.quad_points_raw
          |> Enum.chunk_every(2, 2, :discard)
          |> Enum.flat_map(fn [x, y] ->
            {nx, ny} = fun.({x, y})
            [nx, ny]
          end)

        Map.put(attrs, :quad_points_raw, raw)
      else
        attrs
      end

    attrs =
      if a.ink_list != [],
        do: Map.put(attrs, :ink_list, Enum.map(a.ink_list, &Enum.map(&1, fun))),
        else: attrs

    attrs =
      if a.vertices != [], do: Map.put(attrs, :vertices, Enum.map(a.vertices, fun)), else: attrs

    if a.line do
      {x1, y1, x2, y2} = a.line
      {a1, b1} = fun.({x1, y1})
      {a2, b2} = fun.({x2, y2})
      Map.put(attrs, :line, {a1, b1, a2, b2})
    else
      attrs
    end
  end

  @doc "Copies an annotation (offset by 10pt right and down) on the same page."
  @spec duplicate(Document.t(), integer(), {number(), number()}) :: {Document.t(), Annotation.t()}
  def duplicate(doc, id, {dx, dy} \\ {10, -10}) do
    case get(doc, id) do
      nil ->
        {doc, nil}

      a ->
        existing = Document.resolve(doc, {:ref, id, 0})

        attrs =
          a
          |> Map.from_struct()
          |> Map.drop([:id, :name, :replies, :popup, :in_reply_to, :created, :modified, :page])
          |> Map.merge(transform_attrs(a, fn {x, y} -> {x + dx, y + dy} end))

        ap = if regenerable?(a), do: nil, else: get_in(existing, ["AP", "N"])
        attrs = if ap, do: Map.put(attrs, :appearance, ap), else: attrs
        add(doc, a.page, attrs)
    end
  end

  @doc "Adds a reply (a Text annotation with `/IRT`) to annotation `id`."
  @spec reply(Document.t(), integer(), String.t(), String.t() | nil) ::
          {Document.t(), Annotation.t()}
  def reply(doc, id, text, author \\ nil) do
    parent = get(doc, id) || raise ArgumentError, "no annotation #{id}"

    add(doc, parent.page, %{
      subtype: :text,
      rect: parent.rect,
      contents: text,
      author: author,
      in_reply_to: id,
      reply_type: "R",
      flags: 28,
      subject: "Reply"
    })
  end

  @doc "Deletes an annotation, its popup and its replies."
  @spec delete(Document.t(), integer()) :: Document.t()
  def delete(doc, id) do
    case page_of(doc, id) do
      nil ->
        doc

      index ->
        page = Document.page(doc, index)
        flat = all_with_popups(doc, page)
        doomed = doomed(flat, MapSet.new([id]))

        annots =
          Enum.reject(Edit.annots(doc, page), fn
            {:ref, n, _} -> MapSet.member?(doomed, n)
            _ -> false
          end)

        doc = Edit.put_annots(doc, page, annots)
        Enum.reduce(doomed, doc, fn n, d -> Document.delete_object(d, {:ref, n, 0}) end)
    end
  end

  @doc "Deletes several annotations."
  def delete_many(doc, ids), do: Enum.reduce(ids, doc, &delete(&2, &1))

  defp all_with_popups(doc, page) do
    doc
    |> Edit.annots(page)
    |> Enum.flat_map(fn
      {:ref, n, _} = ref ->
        case Document.resolve(doc, ref) do
          %{} = d -> [{n, d}]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp doomed(flat, set) do
    grown =
      Enum.reduce(flat, set, fn {n, d}, acc ->
        cond do
          MapSet.member?(acc, n) ->
            case d["Popup"] do
              {:ref, p, _} -> MapSet.put(acc, p)
              _ -> acc
            end

          match?({:ref, _, _}, d["IRT"]) and MapSet.member?(acc, elem(d["IRT"], 1)) ->
            MapSet.put(acc, n)

          match?({:ref, _, _}, d["Parent"]) and d["Subtype"] == "Popup" and
              MapSet.member?(acc, elem(d["Parent"], 1)) ->
            MapSet.put(acc, n)

          true ->
            acc
        end
      end)

    if MapSet.size(grown) == MapSet.size(set), do: grown, else: doomed(flat, grown)
  end

  @doc "Converts a displayed rectangle (page points, top-left origin) to user space for page `index`."
  def to_user_rect(doc, index, rect, rotation \\ 0),
    do: Page.rect_to_user(Document.page(doc, index), rect, rotation)
end
