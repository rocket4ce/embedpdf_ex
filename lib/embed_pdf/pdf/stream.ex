defmodule EmbedPdf.PDF.Stream do
  @moduledoc """
  A PDF stream object: its dictionary and its raw (still encoded, already
  decrypted) bytes.

  Object model used across the engine:

    * `nil`, `true`, `false`, integers and floats are themselves
    * a name is a plain binary: `"Type"`
    * a string is `{:string, bytes}`
    * an array is a list, a dictionary a map with binary keys
    * an indirect reference is `{:ref, number, generation}`
    * a stream is this struct
  """
  defstruct dict: %{}, raw: <<>>

  @type t :: %__MODULE__{dict: map(), raw: binary()}
end
