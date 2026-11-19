defmodule EmbedPdf.PdfCheck do
  @moduledoc false
  # Saves a document, re-opens it with EmbedPdf and checks that poppler
  # (pdftotext / pdftoppm, when installed) reads it without failing.

  import ExUnit.Assertions

  def out_dir do
    dir = Path.join([Mix.Project.build_path(), "pdf_check"])
    File.mkdir_p!(dir)
    dir
  end

  @doc "Saves, re-opens and validates; returns the re-opened document."
  def roundtrip!(doc, name \\ "out") do
    bytes = EmbedPdf.Writer.save(doc)
    path = Path.join(out_dir(), "#{name}-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, bytes)
    assert {:ok, again} = EmbedPdf.open(bytes)
    poppler!(path)
    again
  end

  def poppler!(path) do
    for {tool, args} <- [
          {"pdftotext", [path, "-"]},
          {"pdftoppm", ["-r", "10", "-png", path, Path.rootname(path)]}
        ] do
      case System.find_executable(tool) do
        nil ->
          :skip

        exe ->
          {out, status} = System.cmd(exe, args, stderr_to_stdout: true)
          assert status == 0, "#{tool} failed on #{path}: #{String.slice(out, 0, 500)}"

          refute out =~ ~r/Syntax Error: (?!Can't get Fields array)/,
                 "#{tool} reported errors: #{String.slice(out, 0, 500)}"
      end
    end

    :ok
  end
end
