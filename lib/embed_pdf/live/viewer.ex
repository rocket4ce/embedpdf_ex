defmodule EmbedPdf.Live.Viewer do
  @moduledoc """
  The PDF viewer as a LiveView, with no JavaScript beyond LiveView's own
  client. Mount it with `EmbedPdf.Live.viewer/1` (recommended) or
  `live_render/3`, or route to it directly.

  Session keys (all optional):

    * `"doc_id"` – a document already put in `EmbedPdf.Store`
    * `"path"` – a PDF file on the server to open
    * `"name"` – file name shown and used for downloads
    * `"password"` – password for protected files
    * `"base_path"` – where `EmbedPdf.Router.embed_pdf_routes/2` is mounted (default `"/embedpdf"`)
    * `"locale"`, `"translations"` – see `EmbedPdf.I18n`
    * `"theme"` – `"light"`, `"dark"` or `"system"`
    * `"features"` – map of feature name → boolean (see `EmbedPdf.Live.Features`)
    * `"read_only"` – turn off everything that changes the document
    * `"mode"`, `"zoom"`, `"page"` – initial state

  The viewer tells its parent LiveView about changes with
  `{:embed_pdf, viewer_id, event}` messages (`:saved`, `{:changed, doc_id}`,
  `{:page, n}`).
  """
  use Phoenix.LiveView

  alias EmbedPdf.{I18n, Store, Text}
  alias EmbedPdf.Live.{Features, Layout}
  alias EmbedPdf.PDF.{Document, Page}

  @history_limit 50

  # ---------------------------------------------------------------- mount

  @impl true
  def mount(params, session, socket) do
    session = Map.merge(params_from(params), session || %{})
    viewer_id = "v" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(EmbedPdf.PubSub, "embed_pdf:viewer:" <> viewer_id)

    features = Features.resolve(session["features"] || %{}, session["read_only"] || false)

    socket =
      socket
      |> assign(
        viewer_id: viewer_id,
        base: String.trim_trailing(session["base_path"] || "/embedpdf", "/"),
        locale: session["locale"] || "en",
        overrides: session["translations"] || %{},
        theme: session["theme"] || "system",
        features: features,
        status: :empty,
        error: nil,
        doc: nil,
        doc_id: nil,
        name: session["name"] || "document.pdf",
        rev: 0,
        page_revs: %{},
        sizes: [],
        history: %{undo: [], redo: []},
        dirty?: false,
        container: {1000, 800},
        probe_nonce: 1,
        seen: %{nonce: 1, settle_until: nil, settling: []},
        zoom: parse_zoom(session["zoom"]),
        scroll: :vertical,
        spread: :none,
        rotation: 0,
        current_page: 0,
        loaded: MapSet.new(),
        text: %{},
        annots: %{},
        mode: :view,
        tool: :pointer,
        points: [],
        anchor: nil,
        selected: nil,
        moving?: false,
        resizing?: false,
        editing_page?: false,
        refocus: 0,
        # form design (EmbedPdf.Live.FormDesign)
        form_design?: false,
        field: nil,
        field_action: nil,
        editing_text: nil,
        style: default_style(),
        stamp: "approved",
        left: nil,
        right: nil,
        menu: nil,
        dialog: nil,
        search: %{query: "", case: false, whole: false, hits: [], current: nil},
        scroll_to: nil,
        scroll_nonce: 0,
        outline: nil,
        outline_open: MapSet.new(),
        outline_renaming: nil,
        attachments: nil,
        fields: nil,
        fullscreen?: false,
        selected_pages: MapSet.new(),
        snapshot: nil,
        measure: nil,
        # real-world units per PDF point, set by calibrating (default: millimetres)
        measure_scale: %{factor: 25.4 / 72, unit: "mm"},
        flash_msg: nil,
        pending_password: nil,
        signatures: nil,
        signature_text: "",
        signing: nil,
        tabs: [],
        tab_state: %{},
        parent: socket.parent_pid
      )
      |> allow_upload(:pdf,
        accept: ~w(.pdf application/pdf),
        max_entries: 1,
        max_file_size: 300_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> allow_upload(:insert,
        accept: ~w(.pdf application/pdf),
        max_entries: 1,
        max_file_size: 300_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> allow_upload(:attachment,
        accept: :any,
        max_entries: 1,
        max_file_size: 100_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    socket = load_initial(socket, session)

    socket =
      case session["mode"] do
        m when m in ~w(view annotate shapes insert form redact pages) ->
          assign(socket, mode: String.to_existing_atom(m))

        _ ->
          socket
      end

    socket =
      case session["page"] do
        p when is_integer(p) -> goto(socket, p - 1)
        _ -> socket
      end

    {:ok, socket, layout: false}
  end

  defp params_from(params) when is_map(params), do: Map.take(params, [])
  defp params_from(_), do: %{}

  defp load_initial(socket, session) do
    cond do
      id = session["doc_id"] ->
        case Store.get(id) do
          %Store.Entry{doc: doc, name: name} -> use_doc(socket, doc, name, id)
          nil -> assign(socket, status: :error, error: "error.open")
        end

      path = session["path"] ->
        case File.read(path) do
          {:ok, bytes} ->
            open_bytes(socket, bytes, session["name"] || Path.basename(path), session["password"])

          {:error, _} ->
            assign(socket, status: :error, error: "error.open")
        end

      true ->
        socket
    end
  end

  defp open_bytes(socket, bytes, name, password) do
    case EmbedPdf.open(bytes, password: password || "") do
      {:ok, doc} ->
        id = Store.put(doc, name: name, meta: EmbedPdf.Output.original_meta(bytes, doc))
        use_doc(socket, doc, name, id)

      {:error, reason} when reason in [:password_required, :bad_password] ->
        assign(socket,
          status: :password,
          pending_password: %{bytes: bytes, name: name, wrong?: reason == :bad_password},
          dialog: :password
        )

      {:error, _} ->
        assign(socket, status: :error, error: "error.open")
    end
  end

  defp use_doc(socket, doc, name, id) do
    id = id || Store.put(doc, name: name)
    if connected?(socket), do: Store.keep(id, self())
    sizes = Enum.map(doc.pages, &Page.display_size/1)
    socket = stash_tab(socket)
    saved = Map.get(socket.assigns.tab_state, id, %{})

    tabs =
      if Enum.any?(socket.assigns.tabs, &(&1.id == id)),
        do: socket.assigns.tabs,
        else: socket.assigns.tabs ++ [%{id: id, name: name}]

    socket
    |> assign(
      status: :ready,
      doc: doc,
      doc_id: id,
      name: name,
      rev: (Store.get(id) || %{revision: 0}).revision,
      page_revs: Map.get(saved, :page_revs, %{}),
      sizes: sizes,
      history: Map.get(saved, :history, %{undo: [], redo: []}),
      dirty?: Map.get(saved, :dirty?, false),
      current_page: Map.get(saved, :current_page, 0),
      loaded: MapSet.new(),
      text: %{},
      annots: %{},
      outline: nil,
      attachments: nil,
      fields: nil,
      selected: nil,
      search: %{socket.assigns.search | hits: [], current: nil},
      dialog: nil,
      pending_password: nil,
      tabs: tabs,
      signatures: nil,
      signing: nil
    )
    |> load_signatures()
  end

  # validation of the document's signatures, from the bytes it would be saved as
  defp load_signatures(%{assigns: %{doc_id: id}} = socket) when is_binary(id) do
    if socket.assigns.features["signatures.checking"] do
      entry = Store.get(id)

      results =
        if entry && entry.meta[:signed?] do
          try do
            entry |> EmbedPdf.Output.bytes() |> EmbedPdf.Signatures.validate()
          rescue
            _ -> []
          end
        else
          []
        end

      assign(socket, signatures: results)
    else
      assign(socket, signatures: [])
    end
  end

  defp load_signatures(socket), do: socket

  # remembers the open document's history and position before another tab takes over
  defp stash_tab(%{assigns: %{doc_id: nil}} = socket), do: socket

  defp stash_tab(socket) do
    a = socket.assigns

    state = %{
      history: a.history,
      dirty?: a.dirty?,
      current_page: a.current_page,
      page_revs: a.page_revs
    }

    assign(socket, tab_state: Map.put(a.tab_state, a.doc_id, state))
  end

  # ---------------------------------------------------------------- render

  @impl true
  def render(assigns), do: EmbedPdf.Live.UI.viewer(assigns)

  # ---------------------------------------------------------------- uploads

  def handle_progress(:pdf, entry, socket) do
    if entry.done? do
      [{bytes, name}] =
        consume_uploaded_entries(socket, :pdf, fn %{path: path}, e ->
          {:ok, {File.read!(path), e.client_name}}
        end)

      {:noreply, open_bytes(socket, bytes, name, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_progress(:insert, entry, socket) do
    if entry.done? do
      [bytes] =
        consume_uploaded_entries(socket, :insert, fn %{path: path}, _ ->
          {:ok, File.read!(path)}
        end)

      case EmbedPdf.open(bytes) do
        {:ok, other} ->
          at = socket.assigns.current_page + 1

          {:noreply,
           socket
           |> commit(EmbedPdf.Pages.insert_document(socket.assigns.doc, at, other), :all)
           |> goto(at)}

        _ ->
          {:noreply, flash(socket, "error.open")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_progress(:attachment, entry, socket) do
    if entry.done? do
      [{bytes, name}] =
        consume_uploaded_entries(socket, :attachment, fn %{path: path}, e ->
          {:ok, {File.read!(path), e.client_name}}
        end)

      doc = EmbedPdf.Attachments.add(socket.assigns.doc, name, bytes, [])

      {:noreply,
       socket
       |> commit(doc, [])
       |> assign(attachments: nil, left: :attachments)
       |> refresh_lists()}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------- events: navigation & view

  @impl true
  def handle_event("noop", _, socket), do: {:noreply, socket}

  def handle_event("validate_upload", _, socket), do: {:noreply, socket}

  def handle_event("page", %{"to" => to}, socket) do
    a = socket.assigns
    last = length(a.sizes) - 1
    rows = Layout.rows(length(a.sizes), a.spread)
    row = Layout.row_of(rows, a.current_page)
    row_idx = Enum.find_index(rows, &(&1 == row)) || 0

    target =
      case to do
        "first" -> 0
        "last" -> last
        "next" -> rows |> Enum.at(min(row_idx + 1, length(rows) - 1), [last]) |> hd()
        "prev" -> rows |> Enum.at(max(row_idx - 1, 0), [0]) |> hd()
        n -> parse_int(n, 1) - 1
      end

    {:noreply, goto(socket, target)}
  end

  def handle_event("edit_page", _, socket), do: {:noreply, assign(socket, editing_page?: true)}

  def handle_event("stop_page_edit", _, socket),
    do: {:noreply, assign(socket, editing_page?: false)}

  def handle_event("goto_page", %{"page" => n}, socket) when socket.assigns.editing_page?,
    do:
      {:noreply,
       socket
       |> assign(editing_page?: false)
       |> goto(parse_int(n, 1) - 1)
       |> tap(fn _ -> send(self(), :refocus_viewport) end)}

  def handle_event("goto_page", %{"page" => n}, socket),
    do: {:noreply, goto(socket, parse_int(n, 1) - 1)}

  def handle_event("page_click", %{"page" => n}, socket) do
    n = parse_int(n, 0)

    socket =
      if n != socket.assigns.current_page,
        do: assign(socket, current_page: n) |> notify_parent({:page, n + 1}),
        else: socket

    {:noreply, ensure_loaded(socket, n)}
  end

  def handle_event("zoom", %{"to" => to}, socket) do
    a = socket.assigns
    current = scale(a)

    zoom =
      case to do
        "in" -> %{mode: :absolute, factor: Layout.step(current, :in)}
        "out" -> %{mode: :absolute, factor: Layout.step(current, :out)}
        "fit_width" -> %{mode: :fit_width, factor: 1.0}
        "fit_page" -> %{mode: :fit_page, factor: 1.0}
        "automatic" -> %{mode: :automatic, factor: 1.0}
        pct -> %{mode: :absolute, factor: parse_int(pct, 100) / 100}
      end

    {:noreply, socket |> assign(zoom: zoom, menu: nil) |> keep_page_in_view()}
  end

  def handle_event("rotate", %{"dir" => dir}, socket) do
    delta = if dir == "ccw", do: 270, else: 90

    {:noreply,
     socket
     |> assign(rotation: rem(socket.assigns.rotation + delta, 360), text: %{}, menu: nil)
     |> reload_text()
     |> keep_page_in_view()}
  end

  def handle_event("scroll_mode", %{"mode" => m}, socket) when m in ~w(vertical horizontal paged),
    do:
      {:noreply,
       socket |> assign(scroll: String.to_existing_atom(m), menu: nil) |> keep_page_in_view()}

  def handle_event("spread", %{"mode" => m}, socket) when m in ~w(none odd even),
    do:
      {:noreply,
       socket |> assign(spread: String.to_existing_atom(m), menu: nil) |> keep_page_in_view()}

  def handle_event("theme", %{"theme" => t}, socket) when t in ~w(light dark system),
    do: {:noreply, assign(socket, theme: t, menu: nil)}

  def handle_event("fullscreen", _, socket),
    do: {:noreply, assign(socket, fullscreen?: not socket.assigns.fullscreen?, menu: nil)}

  def handle_event("menu", %{"menu" => m}, socket) do
    m = if socket.assigns.menu == m, do: nil, else: m
    {:noreply, assign(socket, menu: m)}
  end

  def handle_event("close_menu", _, socket), do: {:noreply, assign(socket, menu: nil)}

  def handle_event("dialog", %{"dialog" => d}, socket)
      when d in ~w(print properties shortcuts open) do
    {:noreply, assign(socket, dialog: String.to_existing_atom(d), menu: nil)}
  end

  def handle_event("close_dialog", _, socket),
    do: {:noreply, assign(socket, dialog: nil, snapshot: nil)}

  def handle_event("panel", %{"side" => side, "panel" => panel}, socket) do
    key = if side == "left", do: :left, else: :right
    panel = String.to_existing_atom(panel)
    panel = if Map.get(socket.assigns, key) == panel, do: nil, else: panel
    {:noreply, socket |> assign(key, panel) |> refresh_lists()}
  end

  def handle_event("close_panel", %{"side" => side}, socket) do
    {:noreply, assign(socket, if(side == "left", do: :left, else: :right), nil)}
  end

  def handle_event("key", %{"key" => key}, socket) do
    # following a #fragment link drops focus; the key came from the document area,
    # so give the keyboard back to it after navigating
    if key in ~w(ArrowRight ArrowLeft + = - 0 1 r R) or
         (key in ~w(PageDown PageUp Home End) and socket.assigns.scroll == :paged),
       do: send(self(), :refocus_viewport)

    {:noreply, handle_key(socket, key)}
  end

  # ---------------------------------------------------------------- events: modes & tools

  def handle_event("mode", %{"mode" => m}, socket) do
    mode = String.to_existing_atom(m)
    socket = socket |> clear_tool() |> assign(mode: mode, tool: :pointer, menu: nil)

    socket =
      case mode do
        :form -> assign(socket, fields: nil) |> refresh_lists()
        :redact -> assign(socket, right: :redact)
        :pages -> assign(socket, left: :thumbnails)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("tool", %{"tool" => t}, socket) do
    tool = String.to_existing_atom(t)
    tool = if socket.assigns.tool == tool, do: :pointer, else: tool
    {:noreply, socket |> clear_tool() |> assign(tool: tool, menu: nil)}
  end

  def handle_event("cancel_tool", _, socket), do: {:noreply, socket |> clear_tool()}
  def handle_event("finish_tool", _, socket), do: {:noreply, finish_points(socket)}

  def handle_event("stamp", %{"stamp" => id}, socket),
    do: {:noreply, assign(socket, stamp: id, tool: :stamp, menu: nil)}

  def handle_event("style", params, socket) do
    tool = style_key(socket.assigns.tool, socket)
    current = Map.get(socket.assigns.style, tool, %{})

    updated =
      Enum.reduce(params, current, fn
        {"color", v}, acc -> Map.put(acc, :color, v)
        {"fill", v}, acc -> Map.put(acc, :fill, v)
        {"opacity", v}, acc -> Map.put(acc, :opacity, parse_int(v, 100) / 100)
        {"stroke", v}, acc -> Map.put(acc, :stroke, parse_float(v, 2.0))
        {"font_size", v}, acc -> Map.put(acc, :font_size, parse_float(v, 14.0))
        {"font", v}, acc when v in ~w(helvetica times courier) -> Map.put(acc, :font, v)
        _, acc -> acc
      end)

    socket = assign(socket, style: Map.put(socket.assigns.style, tool, updated))

    # restyle the selected annotation too
    socket =
      case socket.assigns.selected do
        {page, id} when tool == :selected ->
          update_annotation(socket, page, id, style_attrs(updated))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # a click on a word of the text layer
  def handle_event("word", %{"p" => p, "i" => i, "j" => j}, socket) do
    page = parse_int(p, 0)
    from = parse_int(i, 0)
    to = parse_int(j, from)
    socket = assign(socket, current_page: page)

    if socket.assigns.tool in text_tools() do
      {:noreply, text_tool_click(socket, page, from, to)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------- events: annotations

  def handle_event("select_annotation", %{"page" => p, "id" => id}, socket) do
    page = parse_int(p, 0)
    id = parse_int(id, 0)

    socket =
      if socket.assigns.tool in [:pointer, :pan] or socket.assigns.mode == :view do
        assign(socket,
          selected: {page, id},
          current_page: page,
          moving?: false,
          right:
            if(socket.assigns.features["annotations"],
              do: :annotation,
              else: socket.assigns.right
            )
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("deselect", _, socket),
    do:
      {:noreply,
       assign(socket,
         selected: nil,
         moving?: false,
         right: if(socket.assigns.right == :annotation, do: nil, else: socket.assigns.right)
       )}

  def handle_event("delete_annotation", params, socket) do
    case target_annotation(socket, params) do
      {page, id} ->
        doc = EmbedPdf.Annotations.delete(socket.assigns.doc, id)

        {:noreply,
         socket |> commit(doc, [page]) |> assign(selected: nil, right: nil) |> refresh_lists()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("duplicate_annotation", _, socket) do
    case socket.assigns.selected do
      {page, id} ->
        {doc, annot} = EmbedPdf.Annotations.duplicate(socket.assigns.doc, id)
        {:noreply, socket |> commit(doc, [page]) |> assign(selected: {page, annot.id})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("resize_annotation", _, socket),
    do: {:noreply, assign(socket, resizing?: not socket.assigns.resizing?, moving?: false)}

  def handle_event("switch_tab", %{"id" => id}, socket) do
    case Store.get(id) do
      %Store.Entry{doc: doc, name: name} when id != socket.assigns.doc_id ->
        {:noreply,
         socket |> clear_tool() |> use_doc(doc, name, id) |> goto(socket_page(socket, id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_tab", %{"id" => id}, socket) do
    tabs = Enum.reject(socket.assigns.tabs, &(&1.id == id))
    socket = assign(socket, tabs: tabs, tab_state: Map.delete(socket.assigns.tab_state, id))

    cond do
      id != socket.assigns.doc_id ->
        {:noreply, socket}

      tabs == [] ->
        {:noreply, assign(socket, status: :empty, doc: nil, doc_id: nil, sizes: [], menu: nil)}

      true ->
        %{id: next} = List.last(tabs)
        %Store.Entry{doc: doc, name: name} = Store.get(next)
        socket = assign(socket, doc_id: nil)
        {:noreply, socket |> clear_tool() |> use_doc(doc, name, next)}
    end
  end

  def handle_event("move_annotation", _, socket),
    do: {:noreply, assign(socket, moving?: not socket.assigns.moving?, resizing?: false)}

  def handle_event("nudge", %{"dx" => dx, "dy" => dy}, socket) do
    case socket.assigns.selected do
      {page, id} ->
        # nudges are given in displayed points; convert to user space
        pg = Document.page(socket.assigns.doc, page)
        {ux0, uy0} = Page.to_user(pg, {0, 0})
        {ux1, uy1} = Page.to_user(pg, {parse_float(dx, 0.0), parse_float(dy, 0.0)})
        {doc, _} = EmbedPdf.Annotations.move(socket.assigns.doc, id, ux1 - ux0, uy1 - uy0)
        {:noreply, commit(socket, doc, [page])}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("annotation_props", params, socket) do
    case socket.assigns.selected do
      {page, id} ->
        attrs =
          %{}
          |> put_if(params, "contents", :contents, & &1)
          |> put_if(params, "author", :author, & &1)
          |> put_if(params, "font_size", :font_size, &parse_float(&1, 12.0))

        {:noreply, update_annotation(socket, page, id, attrs)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("free_text", %{"text" => text, "aid" => id, "page" => p}, socket) do
    socket = update_annotation(socket, parse_int(p, 0), parse_int(id, 0), %{contents: text})
    {:noreply, assign(socket, editing_text: nil)}
  end

  def handle_event("edit_text", %{"id" => id, "page" => p}, socket),
    do: {:noreply, assign(socket, editing_text: {parse_int(p, 0), parse_int(id, 0)})}

  def handle_event("reply", %{"aid" => id, "text" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      id = parse_int(id, 0)
      {doc, _} = EmbedPdf.Annotations.reply(socket.assigns.doc, id, text, nil)
      page = annotation_page(socket, id)
      {:noreply, socket |> commit(doc, [page]) |> refresh_lists()}
    end
  end

  def handle_event("comment_goto", %{"page" => p, "id" => id}, socket) do
    page = parse_int(p, 0)
    {:noreply, socket |> assign(selected: {page, parse_int(id, 0)}) |> goto(page, "annot-#{id}")}
  end

  # ---------------------------------------------------------------- events: history

  def handle_event("undo", _, socket), do: {:noreply, undo(socket)}
  def handle_event("redo", _, socket), do: {:noreply, redo(socket)}

  # ---------------------------------------------------------------- events: search

  def handle_event("search", params, socket) do
    s = socket.assigns.search
    query = Map.get(params, "q", s.query)
    case? = Map.get(params, "case", if(s.case, do: "true", else: "false")) == "true"
    whole? = Map.get(params, "whole", if(s.whole, do: "true", else: "false")) == "true"

    hits =
      if String.length(String.trim(query)) >= 1 and socket.assigns.doc,
        do: search_all(socket, query, case_sensitive: case?, whole_word: whole?),
        else: []

    current = if hits == [], do: nil, else: first_hit_from(hits, socket.assigns.current_page)

    socket =
      assign(socket,
        search: %{query: query, case: case?, whole: whole?, hits: hits, current: current}
      )

    {:noreply, scroll_to_hit(socket)}
  end

  def handle_event("search_nav", params, socket) do
    dir = Map.get(params, "dir", "next")

    s = socket.assigns.search
    n = length(s.hits)

    if n == 0 do
      {:noreply, socket}
    else
      current = Integer.mod((s.current || 0) + if(dir == "prev", do: -1, else: 1), n)
      {:noreply, socket |> assign(search: %{s | current: current}) |> scroll_to_hit()}
    end
  end

  def handle_event("search_goto", %{"i" => i}, socket) do
    s = socket.assigns.search
    {:noreply, socket |> assign(search: %{s | current: parse_int(i, 0)}) |> scroll_to_hit()}
  end

  def handle_event("search_clear", _, socket) do
    {:noreply,
     assign(socket, search: %{socket.assigns.search | query: "", hits: [], current: nil})}
  end

  # ---------------------------------------------------------------- events: outline, attachments, forms

  def handle_event("outline_goto", %{"page" => p} = params, socket) do
    page = parse_int(p, 0)
    socket = goto(socket, page)

    socket =
      case params do
        %{"uri" => uri} when is_binary(uri) and uri != "" -> socket
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("outline_toggle", %{"id" => id}, socket) do
    id = parse_int(id, 0)
    open = socket.assigns.outline_open
    open = if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)
    {:noreply, assign(socket, outline_open: open)}
  end

  def handle_event("outline_all", %{"open" => open}, socket) do
    ids = if open == "true", do: outline_ids(socket.assigns.outline || []), else: []
    {:noreply, assign(socket, outline_open: MapSet.new(ids))}
  end

  def handle_event("outline_add", params, socket) do
    title = String.trim(params["title"] || "")

    title =
      if title == "",
        do: "#{I18n.t(socket.assigns.locale, "page.label")} #{socket.assigns.current_page + 1}",
        else: title

    parent = if params["parent"] in [nil, ""], do: nil, else: parse_int(params["parent"], 0)

    {doc, _id} =
      EmbedPdf.Outline.add(socket.assigns.doc, parent, title, socket.assigns.current_page, [])

    {:noreply, socket |> commit(doc, []) |> assign(outline: nil) |> refresh_lists()}
  end

  def handle_event("outline_rename", %{"id" => id}, socket),
    do: {:noreply, assign(socket, outline_renaming: parse_int(id, 0))}

  def handle_event("outline_rename_cancel", _, socket),
    do: {:noreply, assign(socket, outline_renaming: nil)}

  def handle_event("outline_edit", %{"oid" => id} = params, socket),
    do: handle_event("outline_edit", params |> Map.delete("oid") |> Map.put("id", id), socket)

  def handle_event("outline_edit", %{"id" => id, "action" => action} = params, socket) do
    id = parse_int(id, 0)
    doc = socket.assigns.doc

    doc =
      case action do
        "rename" -> EmbedPdf.Outline.rename(doc, id, params["title"] || "")
        "delete" -> EmbedPdf.Outline.delete(doc, id)
        "up" -> EmbedPdf.Outline.move(doc, id, :up)
        "down" -> EmbedPdf.Outline.move(doc, id, :down)
        "indent" -> EmbedPdf.Outline.move(doc, id, :indent)
        "outdent" -> EmbedPdf.Outline.move(doc, id, :outdent)
        "here" -> EmbedPdf.Outline.set_destination(doc, id, socket.assigns.current_page)
        _ -> doc
      end

    {:noreply,
     socket
     |> commit(normalize_doc(doc), [])
     |> assign(outline: nil, outline_renaming: nil)
     |> refresh_lists()}
  end

  def handle_event("attachment_delete", %{"id" => id}, socket) do
    doc = EmbedPdf.Attachments.delete(socket.assigns.doc, parse_int(id, 0))
    {:noreply, socket |> commit(doc, :annotations) |> assign(attachments: nil) |> refresh_lists()}
  end

  def handle_event("form_change", %{"_target" => [_, key]} = params, socket) do
    with %{} = values <- params["field"],
         {:ok, value} <- Map.fetch(values, key) do
      field_id = parse_int(key, 0)
      field = Enum.find(socket.assigns.fields || [], &(&1.id == field_id))

      value =
        case field do
          %{type: :checkbox} -> value == "true"
          %{type: :list, multi_select?: true} -> List.wrap(value)
          _ -> value
        end

      doc = EmbedPdf.Forms.set_value(socket.assigns.doc, field_id, value)
      pages = if field, do: field.widgets |> Enum.map(& &1.page) |> Enum.uniq(), else: :all
      {:noreply, socket |> commit(doc, pages) |> assign(fields: nil) |> refresh_lists()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("form_change", _, socket), do: {:noreply, socket}

  # form design: every "field_*" event (EmbedPdf.Live.FormDesign)
  def handle_event("field_" <> _ = event, params, socket),
    do: EmbedPdf.Live.FormDesign.event(event, params, socket)

  def handle_event("form_reset", _, socket) do
    {:noreply,
     socket
     |> commit(EmbedPdf.Forms.reset(socket.assigns.doc), :all)
     |> assign(fields: nil)
     |> refresh_lists()}
  end

  # ---------------------------------------------------------------- events: redaction

  def handle_event("redact_apply", params, socket) do
    doc = socket.assigns.doc

    doc =
      case params do
        %{"id" => id} ->
          id = parse_int(id, 0)
          page = annotation_page(socket, id)
          annot = Enum.find(annotations_for(socket, page), &(&1.id == id))
          rects = redaction_rects(annot)

          doc =
            EmbedPdf.Redaction.apply(doc, page, rects,
              fill: annot.interior_color || {0.0, 0.0, 0.0},
              overlay_text: annot.contents
            )

          EmbedPdf.Annotations.delete(doc, id)

        _ ->
          EmbedPdf.Redaction.apply_marked(doc)
      end

    {:noreply,
     socket |> commit(doc, :all, text: true) |> assign(selected: nil) |> refresh_lists()}
  end

  # ---------------------------------------------------------------- events: pages mode

  def handle_event("page_select", %{"page" => p}, socket) do
    p = parse_int(p, 0)
    sel = socket.assigns.selected_pages
    sel = if MapSet.member?(sel, p), do: MapSet.delete(sel, p), else: MapSet.put(sel, p)
    {:noreply, assign(socket, selected_pages: sel, current_page: p)}
  end

  def handle_event("pages_select_all", _, socket) do
    all = MapSet.new(0..(length(socket.assigns.sizes) - 1)//1)
    sel = if MapSet.equal?(all, socket.assigns.selected_pages), do: MapSet.new(), else: all
    {:noreply, assign(socket, selected_pages: sel)}
  end

  def handle_event("pages", %{"op" => op}, socket) do
    a = socket.assigns

    sel =
      if MapSet.size(a.selected_pages) == 0,
        do: [a.current_page],
        else: a.selected_pages |> Enum.sort()

    doc = a.doc

    {doc, changed, keep_sel} =
      case op do
        "rotate_cw" ->
          {EmbedPdf.Pages.rotate(doc, sel, 90), sel, true}

        "rotate_ccw" ->
          {EmbedPdf.Pages.rotate(doc, sel, -90), sel, true}

        "delete" ->
          if length(sel) >= length(a.sizes),
            do: {doc, [], true},
            else: {EmbedPdf.Pages.delete(doc, sel), :all, false}

        "duplicate" ->
          {EmbedPdf.Pages.duplicate(doc, hd(sel)), :all, false}

        "blank" ->
          {EmbedPdf.Pages.insert_blank(
             doc,
             a.current_page + 1,
             Enum.at(a.sizes, a.current_page, {612.0, 792.0})
           ), :all, false}

        "up" ->
          {EmbedPdf.Pages.move(doc, sel, max(hd(sel) - 1, 0)), :all, false}

        "down" ->
          {EmbedPdf.Pages.move(doc, sel, min(List.last(sel) + 2, length(a.sizes))), :all, false}

        _ ->
          {doc, [], true}
      end

    socket =
      if changed == [], do: socket, else: commit(socket, doc, changed, text: changed == :all)

    socket = if keep_sel, do: socket, else: assign(socket, selected_pages: MapSet.new())

    {:noreply,
     socket
     |> assign(current_page: min(socket.assigns.current_page, length(socket.assigns.sizes) - 1))}
  end

  def handle_event("pages_extract", _, socket) do
    a = socket.assigns

    sel =
      if MapSet.size(a.selected_pages) == 0,
        do: [a.current_page],
        else: Enum.sort(a.selected_pages)

    extracted = EmbedPdf.Pages.extract(a.doc, sel)

    id =
      Store.put(extracted,
        name: String.replace_suffix(a.name, ".pdf", "") <> "-extract.pdf",
        owner: self()
      )

    {:noreply, push_navigate_download(socket, "#{a.base}/d/#{id}/download")}
  end

  # ---------------------------------------------------------------- events: properties & password

  def handle_event("save_props", %{"props" => props}, socket) do
    meta =
      for {k, v} <- props, k in ~w(title author subject keywords), into: %{} do
        {String.to_existing_atom(k), v}
      end

    doc = EmbedPdf.Metadata.put(socket.assigns.doc, meta)
    {:noreply, socket |> commit(doc, []) |> assign(dialog: nil)}
  end

  def handle_event("password", %{"password" => pw}, socket) do
    case socket.assigns.pending_password do
      %{bytes: bytes, name: name} -> {:noreply, open_bytes(socket, bytes, name, pw)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_document", _, %{assigns: %{doc_id: id}} = socket) when is_binary(id) do
    {:noreply, socket} = handle_event("close_tab", %{"id" => id}, socket)
    {:noreply, assign(socket, menu: nil, dialog: if(socket.assigns.status == :empty, do: :open))}
  end

  def handle_event("close_document", _, socket) do
    {:noreply,
     assign(socket, status: :empty, doc: nil, doc_id: nil, sizes: [], menu: nil, dialog: :open)}
  end

  def handle_event("snapshot_close", _, socket), do: {:noreply, assign(socket, snapshot: nil)}

  # ---------------------------------------------------------------- signatures

  def handle_event("signature_text", %{"text" => text}, socket),
    do: {:noreply, assign(socket, signature_text: String.slice(text, 0, 80))}

  def handle_event("sign_field", %{"field" => field}, socket),
    do: {:noreply, assign(socket, signing: parse_int(field, 0), dialog: :sign)}

  def handle_event("sign", %{"name" => name, "how" => how} = params, socket) do
    a = socket.assigns
    name = String.trim(name)
    mark = {:text, if(name == "", do: "Signed", else: name), date: true}

    case {how, a.signing} do
      {"visual", field} when is_integer(field) ->
        doc = EmbedPdf.Signatures.fill_visual(a.doc, field, mark)
        socket = if is_map(doc), do: commit(socket, doc, :all), else: socket

        {:noreply,
         assign(socket, dialog: nil, signing: nil, signature_text: name) |> refresh_lists()}

      {"seal", field} when is_integer(field) ->
        {:noreply, seal(socket, field, mark, params)}

      _ ->
        {:noreply, assign(socket, dialog: nil, signing: nil)}
    end
  end

  # the measured distance is worth `length` `unit`: derive the scale from it
  def handle_event("calibrate", %{"length" => length, "unit" => unit}, socket) do
    case {socket.assigns.measure, parse_float(length, 0.0)} do
      {%{points: pts}, real} when real > 0 and pts > 0 ->
        {:noreply,
         assign(socket,
           measure_scale: %{factor: real / pts, unit: String.slice(unit, 0, 8)},
           dialog: nil
         )}

      _ ->
        {:noreply, assign(socket, dialog: nil)}
    end
  end

  def handle_event("measure_dialog", _, socket),
    do: {:noreply, assign(socket, dialog: :calibrate)}

  # keep the measurement in the document as a line-dimension annotation
  def handle_event("measure_save", _, socket) do
    case socket.assigns.measure do
      %{page: page, from: p1, to: p2, points: pts} ->
        {x1, y1} = to_user(socket, page, p1)
        {x2, y2} = to_user(socket, page, p2)

        attrs = %{
          subtype: :line,
          line: {x1, y1, x2, y2},
          line_endings: {:butt, :butt},
          rect: bounds([{x1, y1}, {x2, y2}], 8),
          color: {0.894, 0.259, 0.204},
          border_width: 1.5,
          contents: measure_label(socket.assigns.measure_scale, pts),
          custom: %{"IT" => "LineDimension", "Cap" => true}
        }

        {:noreply, socket |> add_annotation(page, attrs) |> assign(measure: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("link_create", params, socket) do
    case socket.assigns.points do
      [{page, p1}, {page, p2}] ->
        rect = user_rect(socket, page, p1, p2)

        target =
          case params do
            %{"url" => url} when url != "" ->
              {:uri, url}

            %{"page" => n} ->
              {:page, (parse_int(n, 1) - 1) |> max(0) |> min(length(socket.assigns.sizes) - 1)}
          end

        {doc, _} = EmbedPdf.Links.add(socket.assigns.doc, page, rect, target)
        {:noreply, socket |> commit(doc, [page]) |> clear_tool() |> assign(dialog: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------- PubSub from HTTP

  @impl true
  def handle_info({:embed_pdf, {:probe, :width, w}}, socket) do
    {_, h} = socket.assigns.container
    {:noreply, resize(socket, {w + EmbedPdf.Live.Probe.step() / 2, h})}
  end

  def handle_info({:embed_pdf, {:probe, :height, h}}, socket) do
    {w, _} = socket.assigns.container
    {:noreply, resize(socket, {w, h + EmbedPdf.Live.Probe.step() / 2})}
  end

  def handle_info({:embed_pdf, {:page_loaded, n}}, socket),
    do: {:noreply, ensure_loaded(socket, n)}

  def handle_info({:embed_pdf, {:seen, n, nonce}}, socket), do: {:noreply, seen(socket, n, nonce)}

  def handle_info({:embed_pdf, {:pointer, page, fx, fy, _kind}}, socket) do
    {:noreply, pointer(socket, page, fx, fy)}
  end

  # after a page typed in the pager: give the keyboard back to the document area,
  # one patch after the form went away so LiveView's own focus restore is done
  def handle_info(:refocus_viewport, socket),
    do: {:noreply, assign(socket, refocus: socket.assigns.refocus + 1)}

  def handle_info(_, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------- scroll position

  # A page's marker crossed the middle of the viewport. After every real
  # change the stylesheet's nonce is bumped so markers report again when
  # they come back; the reports that the new stylesheet triggers at once
  # (pages already in the middle) are "settling" reports that update the
  # page without bumping again, so two pages in the band cannot ping-pong.
  defp seen(socket, n, nonce) do
    %{seen: seen, current_page: current, status: status} = socket.assigns
    now = System.monotonic_time(:millisecond)

    cond do
      status != :ready or nonce != seen.nonce or n >= length(socket.assigns.sizes) ->
        socket

      seen.settle_until != nil and now < seen.settle_until ->
        # settling reports never bump the nonce, so following the latest one
        # cannot ping-pong; it is also the page where a fast scroll ended
        socket = assign(socket, seen: %{seen | settling: [n | seen.settling]})

        socket =
          if n != current,
            do: socket |> assign(current_page: n) |> notify_parent({:page, n + 1}),
            else: socket

        ensure_loaded(socket, n)

      n == current ->
        ensure_loaded(socket, n)

      true ->
        socket
        |> assign(
          current_page: n,
          seen: %{nonce: seen.nonce + 1, settle_until: now + 400, settling: []}
        )
        |> notify_parent({:page, n + 1})
        |> ensure_loaded(n)
    end
  end

  # ---------------------------------------------------------------- pointer tools

  defp pointer(%{assigns: %{status: :ready}} = socket, page, fx, fy) do
    a = socket.assigns
    {w, h} = a.sizes |> Enum.at(page, {612.0, 792.0}) |> Layout.rotated(a.rotation)
    # the point in displayed page points, back to the unrotated view
    point = Layout.unrotate_point({fx * w, fy * h}, Enum.at(a.sizes, page), a.rotation)
    socket = assign(socket, current_page: page)

    cond do
      EmbedPdf.Live.FormDesign.handles?(a) ->
        EmbedPdf.Live.FormDesign.pointer(socket, page, point)

      a.resizing? and a.selected ->
        resize_selected_to(socket, page, point)

      a.moving? and a.selected ->
        move_selected_to(socket, page, point)

      a.tool in [:note, :stamp, :free_text, :signature] ->
        place(socket, page, point)

      a.tool in [
        :square,
        :circle,
        :line,
        :arrow,
        :redact_area,
        :snapshot,
        :zoom_area,
        :link,
        :measure,
        :signature
      ] ->
        two_points(socket, page, point)

      a.tool in [:ink, :polygon, :polyline] ->
        points = Enum.filter(a.points, fn {p, _} -> p == page end)
        assign(socket, points: points ++ [{page, point}])

      true ->
        socket
    end
  end

  defp pointer(socket, _, _, _), do: socket

  defp two_points(socket, page, point) do
    case socket.assigns.points do
      [{^page, first}] ->
        socket
        |> assign(points: [{page, first}, {page, point}])
        |> complete_two(page, first, point)

      _ ->
        assign(socket, points: [{page, point}])
    end
  end

  defp complete_two(socket, page, p1, p2) do
    a = socket.assigns
    st = current_style(socket)

    case a.tool do
      t when t in [:square, :circle] ->
        rect = user_rect(socket, page, p1, p2)
        attrs = Map.merge(%{subtype: t, rect: rect}, style_attrs(st))
        add_annotation(socket, page, attrs)

      t when t in [:line, :arrow] ->
        {x1, y1} = to_user(socket, page, p1)
        {x2, y2} = to_user(socket, page, p2)
        endings = if t == :arrow, do: {:none, :open_arrow}, else: {:none, :none}

        attrs =
          Map.merge(
            %{
              subtype: :line,
              line: {x1, y1, x2, y2},
              line_endings: endings,
              rect: bounds([{x1, y1}, {x2, y2}], 8)
            },
            style_attrs(st)
          )

        add_annotation(socket, page, attrs)

      :redact_area ->
        add_annotation(socket, page, %{
          subtype: :redact,
          rect: user_rect(socket, page, p1, p2),
          interior_color: {0.0, 0.0, 0.0},
          color: {0.9, 0.1, 0.1}
        })

      :snapshot ->
        socket |> assign(snapshot: %{page: page, rect: display_rect(p1, p2)}, points: [])

      :zoom_area ->
        zoom_to_area(socket, page, display_rect(p1, p2))

      :measure ->
        {x0, y0} = p1
        {x1, y1} = p2
        pts = :math.sqrt(:math.pow(x1 - x0, 2) + :math.pow(y1 - y0, 2))
        assign(socket, measure: %{page: page, from: p1, to: p2, points: pts}, points: [])

      :link ->
        # keep the points: the link dialog asks for the target
        assign(socket, dialog: :link)

      _ ->
        assign(socket, points: [])
    end
  end

  defp place(socket, page, {x, y} = point) do
    st = current_style(socket)

    case socket.assigns.tool do
      :note ->
        rect = user_rect(socket, page, {x, y}, {x + 20, y + 20})

        socket =
          add_annotation(socket, page, %{
            subtype: :text,
            rect: rect,
            color: parse_color(st[:color] || "#ffcd45"),
            contents: "",
            icon: "Comment"
          })

        assign(socket, right: :comments) |> refresh_lists()

      :signature ->
        text = socket.assigns.signature_text
        text = if String.trim(text) == "", do: "Signed", else: text
        rect = user_rect(socket, page, {x - 90, y - 28}, {x + 90, y + 28})

        {doc, annot} =
          EmbedPdf.Signatures.place_mark(
            socket.assigns.doc,
            page,
            rect,
            {:text, text, date: true}
          )

        socket
        |> commit(doc, [page])
        |> assign(points: [], selected: {page, annot.id})
        |> refresh_lists()

      :stamp ->
        rect = user_rect(socket, page, {x - 80, y - 25}, {x + 80, y + 25})
        add_annotation(socket, page, %{subtype: :stamp, rect: rect, icon: socket.assigns.stamp})

      :free_text ->
        size = st[:font_size] || 14.0
        rect = user_rect(socket, page, point, {x + 180, y + size * 2.2})

        attrs = %{
          subtype: :free_text,
          rect: rect,
          contents: "Text",
          font_size: size,
          font_color: parse_color(st[:color] || "#e44234"),
          font_family: String.to_existing_atom(st[:font] || "helvetica"),
          opacity: st[:opacity] || 1.0
        }

        socket = add_annotation(socket, page, attrs)

        case socket.assigns.selected do
          {p, id} -> assign(socket, editing_text: {p, id})
          _ -> socket
        end
    end
  end

  defp finish_points(socket) do
    a = socket.assigns

    case a.points do
      [{page, _} | _] = pts when length(pts) >= 2 ->
        user_pts = Enum.map(pts, fn {_, p} -> to_user(socket, page, p) end)
        st = current_style(socket)
        base = style_attrs(st)

        attrs =
          case a.tool do
            :ink ->
              Map.merge(
                %{
                  subtype: :ink,
                  ink_list: [user_pts],
                  rect: bounds(user_pts, (st[:stroke] || 2) + 2)
                },
                base
              )

            :polygon ->
              Map.merge(%{subtype: :polygon, vertices: user_pts, rect: bounds(user_pts, 4)}, base)

            :polyline ->
              Map.merge(
                %{subtype: :polyline, vertices: user_pts, rect: bounds(user_pts, 4)},
                base
              )

            _ ->
              nil
          end

        if attrs,
          do: add_annotation(socket, page, attrs) |> assign(points: []),
          else: assign(socket, points: [])

      _ ->
        assign(socket, points: [])
    end
  end

  defp text_tool_click(socket, page, from, to) do
    case socket.assigns.anchor do
      {^page, a_from, a_to} ->
        lo = min(a_from, from)
        hi = max(a_to, to)
        socket |> assign(anchor: nil) |> create_text_markup(page, lo, hi)

      _ ->
        assign(socket, anchor: {page, from, to})
    end
  end

  defp create_text_markup(socket, page, from, to) do
    pt = page_text(socket, page)
    rects = Text.rects(pt, from, to)
    pg = Document.page(socket.assigns.doc, page)
    user_rects = Enum.map(rects, &Page.rect_to_user(pg, &1))
    text = Text.slice(pt, from, to)
    st = current_style(socket)

    case socket.assigns.tool do
      :redact_text ->
        add_annotation(socket, page, %{
          subtype: :redact,
          quad_points: user_rects,
          rect: union_rects(user_rects),
          interior_color: {0.0, 0.0, 0.0},
          color: {0.9, 0.1, 0.1},
          contents: nil
        })

      tool ->
        attrs = %{
          subtype: tool,
          quad_points: user_rects,
          rect: union_rects(user_rects),
          color: parse_color(st[:color] || "#ffcd45"),
          opacity: st[:opacity] || 1.0,
          contents: text
        }

        add_annotation(socket, page, attrs)
    end
  end

  # keeps the displayed top-left corner and moves the opposite one to the click
  defp resize_selected_to(socket, page, {px, py}) do
    {sel_page, id} = socket.assigns.selected

    with true <- sel_page == page,
         %{} = annot <- Enum.find(annotations_for(socket, page), &(&1.id == id)) do
      pg = Document.page(socket.assigns.doc, page)
      {x0, y0, _x1, _y1} = Page.rect_to_display(pg, annot.rect)

      display =
        {min(x0, px), min(y0, py), max(max(x0, px), min(x0, px) + 4),
         max(max(y0, py), min(y0, py) + 4)}

      {doc, _} =
        EmbedPdf.Annotations.resize(socket.assigns.doc, id, Page.rect_to_user(pg, display))

      socket |> commit(doc, [page]) |> assign(resizing?: false)
    else
      _ -> assign(socket, resizing?: false)
    end
  end

  defp socket_page(socket, id) do
    case socket.assigns.tab_state do
      %{^id => %{current_page: p}} -> p
      _ -> 0
    end
  end

  defp move_selected_to(socket, page, point) do
    {sel_page, id} = socket.assigns.selected

    if sel_page != page do
      assign(socket, moving?: false)
    else
      annot = Enum.find(annotations_for(socket, page), &(&1.id == id))
      pg = Document.page(socket.assigns.doc, page)
      {x0, y0, x1, y1} = annot.rect
      {cx, cy} = {(x0 + x1) / 2, (y0 + y1) / 2}
      {tx, ty} = Page.to_user(pg, point)
      {doc, _} = EmbedPdf.Annotations.move(socket.assigns.doc, id, tx - cx, ty - cy)
      socket |> commit(doc, [page]) |> assign(moving?: false)
    end
  end

  defp zoom_to_area(socket, page, {x0, y0, x1, y1}) do
    {cw, ch} = socket.assigns.container
    w = max(x1 - x0, 10)
    h = max(y1 - y0, 10)
    factor = min((cw - 40) / w, (ch - 40) / h) |> min(10.0)

    socket
    |> assign(zoom: %{mode: :absolute, factor: factor}, points: [], tool: :pointer)
    |> goto(page)
  end

  # ---------------------------------------------------------------- annotation helpers

  defp add_annotation(socket, page, attrs) do
    {doc, annot} = EmbedPdf.Annotations.add(socket.assigns.doc, page, attrs)

    socket
    |> commit(doc, [page])
    |> assign(points: [], selected: {page, annot.id})
    |> refresh_lists()
  end

  defp update_annotation(socket, page, id, attrs) do
    {doc, _} = EmbedPdf.Annotations.update(socket.assigns.doc, id, attrs)
    socket |> commit(doc, [page]) |> refresh_lists()
  end

  defp target_annotation(_socket, %{"id" => id, "page" => p}),
    do: {parse_int(p, 0), parse_int(id, 0)}

  defp target_annotation(socket, _), do: socket.assigns.selected

  defp annotation_page(socket, id) do
    Enum.find_value(0..(length(socket.assigns.sizes) - 1)//1, 0, fn p ->
      if Enum.any?(
           annotations_for(socket, p),
           &(&1.id == id or Enum.any?(&1.replies || [], fn r -> r.id == id end))
         ),
         do: p
    end)
  end

  @doc false
  def annotations_for(socket_or_assigns, page) do
    a = assigns_of(socket_or_assigns)

    case Map.fetch(a.annots, page) do
      {:ok, list} -> list
      :error -> safe_list_annotations(a.doc, page)
    end
  end

  defp safe_list_annotations(nil, _), do: []

  defp safe_list_annotations(doc, page) do
    EmbedPdf.Annotations.list(doc, page)
  rescue
    _ -> []
  end

  defp redaction_rects(%{quad_points: [_ | _] = quads}), do: quads
  defp redaction_rects(%{rect: rect}), do: [rect]

  # ---------------------------------------------------------------- history

  @doc false
  def commit(socket, doc, pages, opts \\ []) do
    a = socket.assigns
    doc = normalize_doc(doc)
    rev = Store.update(a.doc_id, doc)
    count_changed? = length(doc.pages) != length(a.sizes)
    pages = if count_changed?, do: :all, else: pages

    page_revs =
      case pages do
        :all -> Map.new(0..(length(doc.pages) - 1)//1, &{&1, rev})
        :annotations -> Map.new(0..(length(doc.pages) - 1)//1, &{&1, rev})
        list -> Enum.reduce(list, a.page_revs, &Map.put(&2, &1, rev))
      end

    # each step remembers what it touched, so undoing it redraws only that
    step = {a.doc, pages, opts[:text] == true}
    undo = Enum.take([step | a.history.undo], @history_limit)

    socket
    |> assign(
      doc: doc,
      rev: rev,
      page_revs: page_revs,
      history: %{undo: undo, redo: []},
      dirty?: true
    )
    |> after_change(pages, opts)
    |> notify_parent({:changed, a.doc_id})
  end

  defp after_change(socket, pages, opts) do
    doc = socket.assigns.doc
    sizes = Enum.map(doc.pages, &Page.display_size/1)

    annots =
      case pages do
        p when p in [:all, :annotations] -> %{}
        list -> Map.drop(socket.assigns.annots, list)
      end

    text =
      cond do
        pages == :all or opts[:text] -> %{}
        true -> socket.assigns.text
      end

    socket
    |> assign(
      sizes: sizes,
      annots: annots,
      text: text,
      outline: nil,
      attachments: nil,
      fields: nil
    )
    |> reload_loaded()
  end

  defp undo(%{assigns: %{history: %{undo: [{prev, pages, text?} | rest]}}} = socket) do
    a = socket.assigns

    restore(socket, prev, pages, text?, %{
      undo: rest,
      redo: [{a.doc, pages, text?} | a.history.redo]
    })
  end

  defp undo(socket), do: socket

  defp redo(%{assigns: %{history: %{redo: [{next, pages, text?} | rest]}}} = socket) do
    a = socket.assigns

    restore(socket, next, pages, text?, %{
      undo: [{a.doc, pages, text?} | a.history.undo],
      redo: rest
    })
  end

  defp redo(socket), do: socket

  # puts back `doc`, a step away in the history; `pages` is what that step touched
  defp restore(socket, doc, pages, text?, history) do
    a = socket.assigns
    rev = Store.update(a.doc_id, doc)
    last = length(doc.pages) - 1
    pages = if length(doc.pages) != length(a.sizes), do: :all, else: pages

    page_revs =
      case pages do
        list when is_list(list) -> Enum.reduce(list, a.page_revs, &Map.put(&2, &1, rev))
        _ -> Map.new(0..last//1, &{&1, rev})
      end

    socket
    |> assign(doc: doc, rev: rev, page_revs: page_revs, history: history, selected: nil)
    |> after_change(pages, text: text?)
  end

  defp normalize_doc({doc, _}), do: doc
  defp normalize_doc(doc), do: doc

  # ---------------------------------------------------------------- layout & loading

  defp resize(socket, {w, h}) do
    if {w, h} == socket.assigns.container,
      do: socket,
      else: assign(socket, container: {w, h}, probe_nonce: socket.assigns.probe_nonce + 1)
  end

  @doc false
  def scale(a) do
    sizes = Enum.map(a.sizes, &Layout.rotated(&1, a.rotation))

    rows =
      if a.scroll == :horizontal,
        do: [Enum.to_list(0..(length(sizes) - 1)//1)],
        else: Layout.rows(length(sizes), a.spread)

    rows =
      if a.scroll == :horizontal and a.zoom.mode == :fit_width,
        do: Layout.rows(length(sizes), a.spread),
        else: rows

    if sizes == [], do: 1.0, else: Layout.scale(a.zoom, sizes, rows, a.container)
  end

  defp ensure_loaded(socket, n) do
    if MapSet.member?(socket.assigns.loaded, n) or socket.assigns.status != :ready or
         n >= length(socket.assigns.sizes) do
      socket
    else
      socket
      |> assign(loaded: MapSet.put(socket.assigns.loaded, n))
      |> load_page_data(n)
    end
  end

  defp load_page_data(socket, n) do
    a = socket.assigns
    pt = page_text(socket, n)
    layer = EmbedPdf.Live.TextLayer.build(pt, Enum.at(a.sizes, n), a.rotation)
    annots = safe_list_annotations(a.doc, n)
    assign(socket, text: Map.put(a.text, n, layer), annots: Map.put(a.annots, n, annots))
  end

  defp reload_loaded(socket) do
    Enum.reduce(socket.assigns.loaded, socket, fn n, s ->
      cond do
        n >= length(s.assigns.sizes) -> s
        Map.has_key?(s.assigns.text, n) and Map.has_key?(s.assigns.annots, n) -> s
        true -> load_page_data(s, n)
      end
    end)
  end

  defp reload_text(socket), do: socket |> assign(text: %{}) |> reload_loaded()

  @doc false
  def page_text(socket_or_assigns, n) do
    a = assigns_of(socket_or_assigns)
    rev = Map.get(a.page_revs, n, 0)
    Store.cached(a.doc_id, {:text, rev, n, a.rev}, fn -> Text.page(a.doc, n) end)
  end

  defp search_all(socket, query, opts) do
    a = socket.assigns

    0..(length(a.sizes) - 1)//1
    |> Task.async_stream(fn n -> page_text(a, n) |> Text.search(query, opts) end,
      ordered: true,
      timeout: 120_000
    )
    |> Enum.flat_map(fn {:ok, hits} -> hits end)
    |> Enum.take(5000)
  end

  defp first_hit_from(hits, page), do: Enum.find_index(hits, &(&1.page >= page)) || 0

  defp scroll_to_hit(socket) do
    s = socket.assigns.search

    case s.current && Enum.at(s.hits, s.current) do
      %{page: page} -> socket |> ensure_loaded(page) |> goto(page, "hit")
      _ -> socket
    end
  end

  @doc false
  def goto(socket, n, anchor \\ nil) do
    count = length(socket.assigns.sizes)

    if count == 0 do
      socket
    else
      n = n |> max(0) |> min(count - 1)

      target =
        if anchor,
          do: "#{socket.assigns.viewer_id}-#{anchor}",
          else: "#{socket.assigns.viewer_id}-page-#{n}"

      socket
      |> assign(
        current_page: n,
        scroll_to: target,
        scroll_nonce: socket.assigns.scroll_nonce + 1
      )
      |> ensure_loaded(n)
      |> notify_parent({:page, n + 1})
    end
  end

  defp keep_page_in_view(socket), do: goto(socket, socket.assigns.current_page)

  defp handle_key(socket, key) do
    a = socket.assigns

    case key do
      k when k in ["ArrowRight", "PageDown"] and a.scroll == :paged ->
        elem(handle_event("page", %{"to" => "next"}, socket), 1)

      k when k in ["ArrowLeft", "PageUp"] and a.scroll == :paged ->
        elem(handle_event("page", %{"to" => "prev"}, socket), 1)

      "ArrowRight" ->
        elem(handle_event("page", %{"to" => "next"}, socket), 1)

      "ArrowLeft" ->
        elem(handle_event("page", %{"to" => "prev"}, socket), 1)

      # the browser scrolls a focused scroll area itself on Home/End;
      # an anchor jump on top would race with its smooth scrolling
      "Home" when a.scroll != :paged ->
        assign(socket, current_page: 0)

      "End" when a.scroll != :paged ->
        assign(socket, current_page: length(a.sizes) - 1)

      "Home" ->
        goto(socket, 0)

      "End" ->
        goto(socket, length(a.sizes) - 1)

      k when k in ["+", "="] ->
        elem(handle_event("zoom", %{"to" => "in"}, socket), 1)

      "-" ->
        elem(handle_event("zoom", %{"to" => "out"}, socket), 1)

      "0" ->
        elem(handle_event("zoom", %{"to" => "fit_page"}, socket), 1)

      "1" ->
        elem(handle_event("zoom", %{"to" => "fit_width"}, socket), 1)

      "Escape" ->
        socket
        |> clear_tool()
        |> assign(
          selected: nil,
          menu: nil,
          dialog: nil,
          moving?: false,
          snapshot: nil,
          measure: nil
        )

      k when k in ["Delete", "Backspace"] and a.field != nil and a.mode == :form ->
        elem(EmbedPdf.Live.FormDesign.event("field_delete", %{}, socket), 1)

      k when k in ["Delete", "Backspace"] and a.selected != nil ->
        elem(handle_event("delete_annotation", %{}, socket), 1)

      "?" ->
        assign(socket, dialog: :shortcuts)

      "r" ->
        elem(handle_event("rotate", %{"dir" => "cw"}, socket), 1)

      "R" ->
        elem(handle_event("rotate", %{"dir" => "ccw"}, socket), 1)

      "h" ->
        assign(socket, tool: if(a.tool == :pan, do: :pointer, else: :pan))

      "f" ->
        assign(socket, right: :search)

      "Enter" when a.points != [] ->
        finish_points(socket)

      _ ->
        socket
    end
  end

  # Seals a signature field through the signer the host configured
  # (`config :embedpdf_ex, signer: ...`, see EmbedPdf.Signatures.sign/3).
  # The signed file is reopened in place of the current one.
  defp seal(socket, field, mark, params) do
    a = socket.assigns

    with signer when signer != nil <- signer(),
         %Store.Entry{} = entry <- Store.get(a.doc_id),
         {:ok, signed} <-
           EmbedPdf.Signatures.sign(EmbedPdf.Output.bytes(entry), field,
             signer: signer,
             mark: mark,
             reason: blank_nil(params["reason"]),
             location: blank_nil(params["location"])
           ),
         {:ok, doc} <- EmbedPdf.open(signed) do
      old = a.doc_id
      id = Store.put(doc, name: a.name, meta: EmbedPdf.Output.original_meta(signed, doc))

      socket
      |> assign(tabs: Enum.reject(a.tabs, &(&1.id == old)), doc_id: nil)
      |> use_doc(doc, a.name, id)
      |> assign(right: :signatures)
    else
      _ -> assign(socket, dialog: nil, signing: nil, flash_msg: "signature.failed")
    end
  end

  @doc false
  def signer, do: Application.get_env(:embedpdf_ex, :signer)

  defp blank_nil(nil), do: nil
  defp blank_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  @doc false
  def measure_label(%{factor: f, unit: unit}, points) do
    value = points * f
    digits = if value >= 100, do: 0, else: if(value >= 10, do: 1, else: 2)
    "#{:erlang.float_to_binary(value / 1, decimals: digits)} #{unit}"
  end

  defp clear_tool(socket),
    do:
      assign(socket,
        points: [],
        anchor: nil,
        moving?: false,
        resizing?: false,
        measure: nil,
        field_action: nil
      )

  defp refresh_lists(%{assigns: %{right: :signatures, status: :ready}} = socket) do
    socket |> load_signatures() |> assign(right: :signatures) |> refresh_other_lists()
  end

  defp refresh_lists(socket), do: refresh_other_lists(socket)

  defp refresh_other_lists(socket) do
    a = socket.assigns

    if a.status != :ready do
      socket
    else
      socket
      |> then(fn s ->
        if s.assigns.left == :outline and s.assigns.outline == nil,
          do: assign(s, outline: safe(fn -> EmbedPdf.Outline.tree(a.doc) end, [])),
          else: s
      end)
      |> then(fn s ->
        if s.assigns.left == :attachments and s.assigns.attachments == nil,
          do: assign(s, attachments: safe(fn -> EmbedPdf.Attachments.list(a.doc) end, [])),
          else: s
      end)
      |> then(fn s ->
        if s.assigns.mode == :form and s.assigns.fields == nil,
          do: assign(s, fields: safe(fn -> EmbedPdf.Forms.fields(a.doc) end, [])),
          else: s
      end)
    end
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp outline_ids(items),
    do: Enum.flat_map(items, fn i -> [i.id | outline_ids(i.children || [])] end)

  defp notify_parent(socket, event) do
    if pid = socket.assigns[:parent], do: send(pid, {:embed_pdf, socket.assigns.viewer_id, event})
    socket
  end

  defp flash(socket, key), do: assign(socket, flash_msg: key)

  defp push_navigate_download(socket, url) do
    assign(socket, flash_msg: nil, dialog: {:download, url})
  end

  # ---------------------------------------------------------------- geometry & style helpers

  defp to_user(socket, page, point),
    do: socket.assigns.doc |> Document.page(page) |> Page.to_user(point)

  defp user_rect(socket, page, p1, p2) do
    pg = Document.page(socket.assigns.doc, page)
    Page.rect_to_user(pg, display_rect(p1, p2))
  end

  defp display_rect({x0, y0}, {x1, y1}), do: {min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)}

  defp bounds(points, pad) do
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))
    {Enum.min(xs) - pad, Enum.min(ys) - pad, Enum.max(xs) + pad, Enum.max(ys) + pad}
  end

  defp union_rects([]), do: {0, 0, 0, 0}

  defp union_rects(rects) do
    Enum.reduce(rects, fn {a, b, c, d}, {e, f, g, h} ->
      {min(a, e), min(b, f), max(c, g), max(d, h)}
    end)
  end

  @doc false
  def text_tools, do: [:highlight, :underline, :strikeout, :squiggly, :redact_text]

  @doc false
  def point_tools,
    do:
      [
        :note,
        :stamp,
        :free_text,
        :square,
        :circle,
        :line,
        :arrow,
        :redact_area,
        :snapshot,
        :zoom_area,
        :link,
        :ink,
        :polygon,
        :polyline,
        :measure
      ] ++ EmbedPdf.Live.FormDesign.tools()

  defp default_style do
    %{
      highlight: %{color: "#ffcd45", opacity: 1.0},
      underline: %{color: "#e44234", opacity: 1.0},
      strikeout: %{color: "#e44234", opacity: 1.0},
      squiggly: %{color: "#e44234", opacity: 1.0},
      ink: %{color: "#e44234", opacity: 1.0, stroke: 3.0},
      square: %{color: "#e44234", fill: "", opacity: 1.0, stroke: 2.0},
      circle: %{color: "#e44234", fill: "", opacity: 1.0, stroke: 2.0},
      line: %{color: "#e44234", opacity: 1.0, stroke: 2.0},
      arrow: %{color: "#e44234", opacity: 1.0, stroke: 2.0},
      polygon: %{color: "#e44234", fill: "", opacity: 1.0, stroke: 2.0},
      polyline: %{color: "#e44234", opacity: 1.0, stroke: 2.0},
      free_text: %{color: "#e44234", opacity: 1.0, font_size: 14.0, font: "helvetica"},
      note: %{color: "#ffcd45"},
      selected: %{}
    }
  end

  defp style_key(tool, socket) do
    if socket.assigns.selected != nil and tool == :pointer, do: :selected, else: tool
  end

  defp current_style(socket), do: Map.get(socket.assigns.style, socket.assigns.tool, %{})

  defp style_attrs(st) do
    %{}
    |> then(fn m -> if c = st[:color], do: Map.put(m, :color, parse_color(c)), else: m end)
    |> then(fn m ->
      case st[:fill] do
        nil -> m
        "" -> Map.put(m, :interior_color, nil)
        f -> Map.put(m, :interior_color, parse_color(f))
      end
    end)
    |> then(fn m -> if o = st[:opacity], do: Map.put(m, :opacity, o), else: m end)
    |> then(fn m -> if w = st[:stroke], do: Map.put(m, :border_width, w), else: m end)
    |> then(fn m -> if s = st[:font_size], do: Map.put(m, :font_size, s), else: m end)
  end

  @doc false
  def parse_color("#" <> hex) when byte_size(hex) == 6 do
    <<r::8, g::8, b::8>> = Base.decode16!(hex, case: :mixed)
    {r / 255, g / 255, b / 255}
  end

  def parse_color(_), do: {0.0, 0.0, 0.0}

  @doc false
  def color_hex(nil), do: nil

  def color_hex({r, g, b}),
    do: "#" <> Base.encode16(<<round(r * 255), round(g * 255), round(b * 255)>>, case: :lower)

  defp put_if(map, params, key, field, fun) do
    case Map.fetch(params, key) do
      {:ok, v} -> Map.put(map, field, fun.(v))
      :error -> map
    end
  end

  defp parse_int(v, _default) when is_integer(v), do: v

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_float(v, default) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(v, _default) when is_number(v), do: v / 1
  defp parse_float(_, default), do: default

  defp parse_zoom("fit_page"), do: %{mode: :fit_page, factor: 1.0}
  defp parse_zoom("automatic"), do: %{mode: :automatic, factor: 1.0}
  defp parse_zoom(n) when is_integer(n), do: %{mode: :absolute, factor: n / 100}
  defp parse_zoom(_), do: %{mode: :fit_width, factor: 1.0}

  defp assigns_of(%Phoenix.LiveView.Socket{assigns: a}), do: a
  defp assigns_of(a), do: a
end
