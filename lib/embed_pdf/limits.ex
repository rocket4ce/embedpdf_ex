defmodule EmbedPdf.Limits do
  @moduledoc """
  Bounds the work done on untrusted PDF content.

  A hostile file can ask for far more memory or time than its size
  suggests. The engine has limits of its own (decoded stream size, image
  size, operators per page, nesting), and `run/2` adds a last line of
  defence: the work happens in its own process with a heap limit and a
  deadline, so the worst a file can do is fail.

  `EmbedPdf.open/2` and everything the viewer and its HTTP endpoints do
  with a document go through it. Defaults: 1 GB of heap and 30 seconds per
  operation.

      config :embedpdf_ex, max_heap_bytes: 512_000_000, max_operation_ms: 10_000

  Set either to `:infinity` to turn that limit off.
  """

  @type failure :: :timeout | :memory | {:crash, term()}

  @doc """
  Runs `fun` within the limits. Returns `{:ok, result}`, or `{:error, reason}`
  when it ran out of time (`:timeout`), of memory (`:memory`) or raised
  (`{:crash, reason}`). Options `:memory` (bytes) and `:time` (ms) override
  the configured limits.
  """
  @spec run((-> result), keyword()) :: {:ok, result} | {:error, failure()} when result: var
  def run(fun, opts \\ []) when is_function(fun, 0) do
    memory = Keyword.get_lazy(opts, :memory, fn -> config(:max_heap_bytes, 1_000_000_000) end)
    time = Keyword.get_lazy(opts, :time, fn -> config(:max_operation_ms, 30_000) end)
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, fun.()}
            catch
              kind, reason -> {:error, {:crash, {kind, reason}}}
            end

          send(parent, {ref, result})
        end,
        [:monitor | heap_option(memory)]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :memory}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:crash, reason}}
    after
      time ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, result} -> result
        after
          0 -> {:error, :timeout}
        end
    end
  end

  @doc "Like `run/2`, returning `default` when a limit is hit."
  @spec run_or((-> result), result, keyword()) :: result when result: var
  def run_or(fun, default, opts \\ []) do
    case run(fun, opts) do
      {:ok, result} -> result
      {:error, _} -> default
    end
  end

  @doc """
  Puts the heap limit on the calling process itself (the viewer does this
  for its LiveView process, which holds the open document).
  """
  @spec limit_self() :: :ok
  def limit_self do
    case heap_option(config(:max_heap_bytes, 1_000_000_000)) do
      [{:max_heap_size, limit}] -> Process.flag(:max_heap_size, limit)
      [] -> :ok
    end

    :ok
  end

  defp heap_option(:infinity), do: []

  defp heap_option(bytes) when is_integer(bytes) and bytes > 0 do
    words = div(bytes, :erlang.system_info(:wordsize))
    [{:max_heap_size, %{size: words, kill: true, error_logger: false}}]
  end

  defp heap_option(_), do: []

  defp config(key, default), do: Application.get_env(:embedpdf_ex, key, default)
end
