# EmbedPdf

A PDF viewer and editor for Phoenix LiveView, written in pure Elixir. It follows the
feature set of [EmbedPDF](https://github.com/embedpdf/embed-pdf-viewer), with no
JavaScript to write, no WebAssembly and no native code.

- **Engine**: parses, decrypts, renders (to SVG), searches and edits PDFs in Elixir/OTP.
- **Viewer**: a complete LiveView UI: toolbar, modes, thumbnails, outline, search,
  annotations and shapes, stamps, comments, form filling and building, redaction,
  digital signatures, measurement, page editing and document tabs, in 15 languages.
- **No custom JavaScript**: the browser runs only LiveView's own client, which every
  LiveView app already loads.

## Installation

```elixir
def deps do
  [{:embedpdf_ex, "~> 0.1"}]
end
```

Mount the HTTP endpoints in your router, outside pipelines that require CSRF tokens:

```elixir
import EmbedPdf.Router

scope "/" do
  embed_pdf_routes "/embedpdf"
end
```

Render a viewer from any LiveView:

```heex
<EmbedPdf.Live.viewer socket={@socket} id="doc" path={@pdf_path} style="height: 90vh" />
```

Or open the document yourself and keep its id to read the edited version later:

```elixir
{:ok, doc} = EmbedPdf.open(bytes)
doc_id = EmbedPdf.Store.put(doc, name: "contract.pdf")
# ...after the user is done:
entry = EmbedPdf.Store.get(doc_id)
File.write!("contract-edited.pdf", EmbedPdf.Output.bytes(entry))
```

`EmbedPdf.Output.bytes/2` writes a document that was opened signed as an incremental
update, so its signatures stay valid; anything else is written as a fresh file.

Options: `locale` (`en`, `es`, `de`, `fr`, `it`, `pt`, `nl`, `sv`, `pl`, `ja`, `ko`,
`zh-CN`, `zh-TW`, `ar`, `he`, or your own `translations`), `theme`
(`"light"`, `"dark"`, `"system"`), `features` (same names as EmbedPDF, such as
`%{"redaction" => true, "annotations.drawing" => false}`), `read_only`, `mode`,
`zoom`, `page`.

Try the demo with `mix run dev.exs`, then open http://localhost:4000. Set
`EMBEDPDF_DEMO_DIR` to browse another folder of PDFs.

### Sealing signatures

Filling signature fields works out of the box. To seal them with a digital signature,
configure a signer:

```elixir
config :embedpdf_ex, signer: {:pem, File.read!("cert.pem"), File.read!("key.pem")}
```

You can also pass `{:remote, cert_der, fun}` to sign with a key held elsewhere (an HSM
or signing service): `fun` receives the digest to sign and returns the raw signature.
See `EmbedPdf.Signatures.sign/3`.

## Using the engine directly

```elixir
{:ok, doc} = EmbedPdf.open("manual.pdf", password: "secret")
EmbedPdf.page_count(doc)
EmbedPdf.text(doc, 0)
EmbedPdf.search(doc, "warranty", whole_word: true)
svg = EmbedPdf.render_svg(doc, 0, rotation: 90)
```

## How it works without JavaScript

Several viewer features normally rely on JavaScript. EmbedPdf gets the same
information from standard browser behavior instead:

| Need | How EmbedPdf does it |
| --- | --- |
| Viewport size (fit width, fit page) | The viewport is a CSS size container. A generated stylesheet holds one container query per 16 px bucket, each giving a hidden probe a different `background-image` URL. The browser fetches only the matching URL, which tells the server the size. |
| Click position on a page (notes, shapes, ink, stamps, snapshots, measuring) | In point tools each page carries a plain `<form>` with an `<input type="image">`. Browsers submit the click coordinates; the form posts into a hidden iframe and the server answers `204`, so the page does not navigate and no history entry is added. |
| Current page while scrolling | Each page holds invisible markers driven by a CSS scroll-driven animation (`animation-timeline: view()`). A marker only gets its `background-image`, a per-page URL, while it crosses the middle of the viewport, so the browser fetches that URL as the page passes the center. Browsers without scroll timelines (Firefox, for now) update the page on navigation, clicks and page loads instead. |
| Lazy page loading | Pages are `<img loading="lazy">` SVGs. Each image request tells the viewer that the page is near the screen, which then loads that page's text layer and annotations. |
| Text selection and copy | A transparent text layer over each page, positioned in percentages and stretched to the PDF's line widths, so native selection and copy work. |
| Scrolling to a page or search hit | A hidden anchor rendered with `phx-mounted={JS.dispatch("click")}` follows a `#fragment` link. |
| Menus, dialogs, keyboard | Server state with `phx-click`, `phx-click-away` and `phx-keydown`. |
| Print | A print view (HTML, one page image per sheet) opens in a new tab; press Ctrl/⌘+P. |
| Full screen | A fixed full-window layout (the browser Fullscreen API needs JavaScript). |

## Differences from EmbedPDF

Some interactions cannot be identical without JavaScript:

- **Pointer gestures**: dragging is not available. Shapes are made with two clicks,
  ink and polygons by clicking points then **Finish**, and annotations move with
  **Move** plus a click, nudge buttons or arrow keys. Text markup is made by clicking
  the first and last word.
- **Current page while scrolling** needs CSS scroll-driven animations (Chrome, Edge,
  Safari 26+). Elsewhere the indicator updates on navigation, clicks and page loads.
- **Shortcuts with modifier keys** (Ctrl+Z, Ctrl+F…) are not detectable, since LiveView
  sends only the key. The viewer uses plain keys (`+`, `-`, `←`, `→`, `Home`, `End`,
  `r`, `h`, `f`, `?`, `Esc`, `Delete`).
- **Clipboard**: copying text uses the browser's own selection. Snapshots download as SVG.
- **Not implemented yet**: JavaScript in PDFs (form calculations and actions), JPEG 2000
  and JBIG2 images (shown as placeholders), certificate trust and revocation checks for
  signatures, and saving with editing restrictions or encryption.
- **Rendering**: SVG drawn by an Elixir renderer; it matches PDFium on common
  documents but may differ on complex ones.

## License

Apache-2.0. Ships Adobe's Core 14 AFM metrics, the Adobe Glyph List and the Adobe
CMap resources under their own permissive licenses (see `priv/`).
