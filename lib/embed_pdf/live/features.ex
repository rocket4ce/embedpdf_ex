defmodule EmbedPdf.Live.Features do
  @moduledoc """
  Which features the viewer offers, with the same names as EmbedPDF:
  a feature (`"annotations"`) or one of its parts (`"annotations.highlight"`).
  A part wins over its feature; `read_only` turns off everything that
  changes the document.
  """

  @parts %{
    "annotations" => ~w(highlight markup drawing text notes links),
    "shapes" => [],
    "stamps" => [],
    "comments" => ~w(writing),
    "forms" => ~w(filling building),
    "signatures" => ~w(signing checking),
    "redaction" => [],
    "measurement" => [],
    "pages" => [],
    "attachments" => ~w(adding),
    "text" => ~w(selection copy),
    "snapshots" => [],
    "search" => [],
    "thumbnails" => [],
    "outline" => ~w(editing),
    "documents" => ~w(open download print tabs)
  }

  @start_off ~w(forms.building redaction measurement snapshots)
  @read_only ~w(annotations shapes stamps comments.writing forms signatures.signing redaction measurement pages attachments.adding outline.editing)

  @doc "Every feature and part name."
  def all, do: Enum.flat_map(@parts, fn {f, parts} -> [f | Enum.map(parts, &"#{f}.#{&1}")] end)

  @doc "Resolves the effective on/off map from the user's choices."
  @spec resolve(map() | list(), boolean() | list()) :: %{String.t() => boolean()}
  def resolve(choices, read_only) do
    choices = normalize(choices)
    base = Map.new(all(), &{&1, &1 not in @start_off})

    with_choices =
      choices
      |> Enum.sort_by(fn {k, _} -> String.contains?(k, ".") end)
      |> Enum.reduce(base, fn {name, on?}, acc ->
        if String.contains?(name, "."),
          do: Map.put(acc, name, on?),
          else:
            Enum.reduce(
              Map.get(@parts, name, []),
              Map.put(acc, name, on?),
              &Map.put(&2, "#{name}.#{&1}", on?)
            )
      end)

    except = if is_list(read_only), do: read_only, else: []

    with_ro =
      if read_only in [false, nil] do
        with_choices
      else
        Enum.reduce(@read_only, with_choices, fn f, acc ->
          if f in except, do: acc, else: off(acc, f)
        end)
      end

    # a feature with any part on stays on (its tab is still needed)
    Enum.reduce(@parts, with_ro, fn {f, parts}, acc ->
      if parts != [] and Enum.any?(parts, &acc["#{f}.#{&1}"]),
        do: Map.put(acc, f, true),
        else: acc
    end)
  end

  defp off(acc, name) do
    acc = Map.put(acc, name, false)

    if String.contains?(name, "."),
      do: acc,
      else: Enum.reduce(Map.get(@parts, name, []), acc, &Map.put(&2, "#{name}.#{&1}", false))
  end

  defp normalize(list) when is_list(list), do: Map.new(list, fn {k, v} -> {to_string(k), v} end)

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v in [true, "true"]} end)

  defp normalize(_), do: %{}

  @doc "Whether `name` is on."
  def on?(features, name), do: Map.get(features, name, false)
end
