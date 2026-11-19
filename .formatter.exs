# Used by "mix format"
[
  import_deps: [:phoenix, :phoenix_live_view, :plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [embed_pdf_routes: 1, embed_pdf_routes: 2],
  export: [locals_without_parens: [embed_pdf_routes: 1, embed_pdf_routes: 2]]
]
