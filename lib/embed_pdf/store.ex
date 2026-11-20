defmodule EmbedPdf.Store do
  @moduledoc """
  Holds opened documents so the HTTP side (page images, downloads, print)
  can serve what a LiveView is showing.

  Each document lives under a random id with a `revision` that grows on
  every edit; page URLs carry the revision, so browsers cache them safely.
  A document is dropped some time after the last process that keeps it
  (`keep/2`) exits, which leaves room for LiveView reconnects.

  Rendered pages are memoized up to a memory budget (128 MB by default):

      config :embedpdf_ex, render_cache_bytes: 256_000_000
  """

  use GenServer

  @docs :embed_pdf_docs
  @cache :embed_pdf_render_cache
  @grace_ms 120_000
  @cache_limit 4_000

  defmodule Entry do
    @moduledoc false
    defstruct [:id, :doc, :name, revision: 0, meta: %{}]
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Stores a document and returns its id."
  @spec put(EmbedPdf.PDF.Document.t(), keyword()) :: String.t()
  def put(doc, opts \\ []) do
    id =
      Keyword.get_lazy(opts, :id, fn ->
        16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      end)

    entry = %Entry{
      id: id,
      doc: doc,
      name: Keyword.get(opts, :name, "document.pdf"),
      revision: 0,
      meta: Keyword.get(opts, :meta, %{})
    }

    :ets.insert(@docs, {id, entry})
    if owner = Keyword.get(opts, :owner), do: keep(id, owner)
    id
  end

  @doc "Fetches an entry."
  @spec get(String.t()) :: Entry.t() | nil
  def get(id) do
    case :ets.lookup(@docs, id) do
      [{^id, entry}] -> entry
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Replaces the document of `id`, bumping its revision. Returns the new revision."
  @spec update(String.t(), EmbedPdf.PDF.Document.t()) :: non_neg_integer()
  def update(id, doc) do
    case get(id) do
      nil ->
        0

      entry ->
        revision = entry.revision + 1
        :ets.insert(@docs, {id, %{entry | doc: doc, revision: revision}})
        revision
    end
  end

  @doc "Renames the stored document."
  def rename(id, name) do
    if entry = get(id), do: :ets.insert(@docs, {id, %{entry | name: name}})
    :ok
  end

  @doc "Removes a document."
  def delete(id) do
    :ets.delete(@docs, id)
    freed = @cache |> :ets.select([{{{id, :_, :_}, :_, :"$1"}, [], [:"$1"]}]) |> Enum.sum()
    :ets.match_delete(@cache, {{id, :_, :_}, :_, :_})
    if freed > 0, do: :ets.update_counter(@cache, :bytes, {2, -freed, 0, 0}, {:bytes, 0})
    :ok
  end

  @doc "Keeps `id` alive while `pid` lives."
  def keep(id, pid \\ self()), do: GenServer.cast(__MODULE__, {:keep, id, pid})

  @doc "Memoizes `fun` under `{id, key}` in the render cache."
  @spec cached(String.t(), term(), (-> term())) :: term()
  def cached(id, key, fun) do
    case :ets.lookup(@cache, {id, key, :v}) do
      [{_, value, _size}] ->
        value

      [] ->
        value = fun.()
        size = if is_binary(value), do: byte_size(value), else: :erlang.external_size(value)

        if size <= cache_bytes() do
          total = :ets.update_counter(@cache, :bytes, size, {:bytes, 0})

          # past the budget everything goes; pages in view are rendered again on demand
          if total > cache_bytes() or :ets.info(@cache, :size) > @cache_limit do
            :ets.delete_all_objects(@cache)
            :ets.insert(@cache, {:bytes, size})
          end

          :ets.insert(@cache, {{id, key, :v}, value, size})
        end

        value
    end
  end

  defp cache_bytes, do: Application.get_env(:embedpdf_ex, :render_cache_bytes, 128_000_000)

  # ---------------------------------------------------------------- server

  @impl true
  def init(_) do
    :ets.new(@docs, [:named_table, :public, :set, read_concurrency: true])

    :ets.new(@cache, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    # parsed font programs (see EmbedPdf.Font.Program), owned here so they outlive renders
    :ets.new(:embed_pdf_font_programs, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{monitors: %{}, owners: %{}}}
  end

  @impl true
  def handle_cast({:keep, id, pid}, state) do
    ref = Process.monitor(pid)
    owners = Map.update(state.owners, id, MapSet.new([ref]), &MapSet.put(&1, ref))
    {:noreply, %{state | monitors: Map.put(state.monitors, ref, id), owners: owners}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {id, monitors} = Map.pop(state.monitors, ref)
    owners = Map.update(state.owners, id, MapSet.new(), &MapSet.delete(&1, ref))

    if id && MapSet.size(owners[id]) == 0,
      do: Process.send_after(self(), {:expire, id}, @grace_ms)

    {:noreply, %{state | monitors: monitors, owners: owners}}
  end

  def handle_info({:expire, id}, state) do
    if MapSet.size(Map.get(state.owners, id, MapSet.new())) == 0 do
      delete(id)
      {:noreply, %{state | owners: Map.delete(state.owners, id)}}
    else
      {:noreply, state}
    end
  end
end
