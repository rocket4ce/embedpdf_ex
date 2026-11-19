defmodule EmbedPdf.Live.CSS do
  @moduledoc """
  The viewer's stylesheet, served at `<base>/assets/viewer.css`. Every rule
  is scoped under `.epdf`; colors are CSS variables you can override.
  """

  @css """
  .epdf{
    --epdf-bg:#e9eaee;--epdf-surface:#ffffff;--epdf-surface-2:#f5f6f8;--epdf-border:#dcdee3;
    --epdf-text:#1f2328;--epdf-muted:#6a717c;--epdf-accent:#3b6cf6;--epdf-accent-soft:rgba(59,108,246,.12);
    --epdf-danger:#d93838;--epdf-hit:rgba(255,200,0,.35);--epdf-hit-current:rgba(255,120,0,.55);
    --epdf-select:rgba(59,108,246,.28);--epdf-shadow:0 1px 3px rgba(0,0,0,.18),0 4px 14px rgba(0,0,0,.08);
    --epdf-radius:8px;--epdf-gap:12px;
    position:relative;display:flex;flex-direction:column;height:100%;min-height:360px;width:100%;
    background:var(--epdf-bg);color:var(--epdf-text);overflow:hidden;
    font:14px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    box-sizing:border-box;-webkit-font-smoothing:antialiased;
  }
  .epdf *,.epdf *::before,.epdf *::after{box-sizing:border-box}
  @media (prefers-color-scheme:dark){.epdf[data-theme="system"]{
    --epdf-bg:#18191c;--epdf-surface:#232428;--epdf-surface-2:#2b2d31;--epdf-border:#383a40;
    --epdf-text:#e8e9ec;--epdf-muted:#9aa0aa;--epdf-accent:#6f94ff;--epdf-accent-soft:rgba(111,148,255,.18);
    --epdf-shadow:0 1px 3px rgba(0,0,0,.6),0 4px 16px rgba(0,0,0,.35)}}
  .epdf[data-theme="dark"]{
    --epdf-bg:#18191c;--epdf-surface:#232428;--epdf-surface-2:#2b2d31;--epdf-border:#383a40;
    --epdf-text:#e8e9ec;--epdf-muted:#9aa0aa;--epdf-accent:#6f94ff;--epdf-accent-soft:rgba(111,148,255,.18);
    --epdf-shadow:0 1px 3px rgba(0,0,0,.6),0 4px 16px rgba(0,0,0,.35)}
  .epdf.epdf-fullscreen{position:fixed;inset:0;z-index:2147483000;height:100vh;height:100dvh}
  .epdf .epdf-hidden,.epdf .epdf-sink{position:absolute!important;width:1px!important;height:1px!important;border:0!important;opacity:0;pointer-events:none;overflow:hidden;clip:rect(0 0 0 0)}

  /* bars */
  .epdf-topbar,.epdf-modebar{display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--epdf-surface);border-bottom:1px solid var(--epdf-border);min-height:48px;flex-wrap:wrap}
  .epdf-modebar{min-height:44px;background:var(--epdf-surface-2)}
  .epdf-group{display:flex;align-items:center;gap:2px;min-width:0}
  .epdf-right{margin-left:auto}
  .epdf-title{font-weight:600;margin-left:6px;max-width:28ch;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .epdf-dirty{color:var(--epdf-accent);margin-left:4px}
  .epdf-tabs{display:flex;gap:2px;margin:0 auto;padding:3px;background:var(--epdf-surface-2);border-radius:999px;overflow-x:auto;max-width:100%}
  .epdf-tab{border:0;background:none;color:var(--epdf-muted);font:inherit;font-weight:500;padding:5px 14px;border-radius:999px;cursor:pointer;white-space:nowrap}
  .epdf-tab:hover{color:var(--epdf-text)}
  .epdf-tab.is-active{background:var(--epdf-surface);color:var(--epdf-text);box-shadow:0 1px 2px rgba(0,0,0,.12)}
  .epdf-btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;min-width:34px;height:34px;padding:0 7px;border:0;border-radius:6px;background:none;color:var(--epdf-text);font:inherit;cursor:pointer;text-decoration:none;white-space:nowrap}
  .epdf-btn:hover{background:var(--epdf-surface-2)}
  .epdf-modebar .epdf-btn:hover{background:var(--epdf-border)}
  .epdf-btn.is-active,.epdf-btn[aria-pressed="true"]{background:var(--epdf-accent-soft);color:var(--epdf-accent)}
  .epdf-btn:disabled{opacity:.4;cursor:default;background:none}
  .epdf-btn:focus-visible,.epdf-tab:focus-visible{outline:2px solid var(--epdf-accent);outline-offset:1px}
  .epdf-btn-text{padding:0 12px}
  .epdf-btn-sm{min-width:24px;height:24px;padding:0 3px}
  .epdf-primary{background:var(--epdf-accent);color:#fff}
  .epdf-primary:hover{background:var(--epdf-accent);filter:brightness(1.08)}
  .epdf-danger{color:var(--epdf-danger)}
  .epdf-block{width:100%;margin-top:10px}
  .epdf-icon{flex:none;width:20px;height:20px}
  .epdf-icon-sm{width:14px;height:14px}
  .epdf-icon-xl{width:56px;height:56px;color:var(--epdf-muted)}
  .epdf-sep{width:1px;height:22px;background:var(--epdf-border);margin:0 6px}
  .epdf-muted{color:var(--epdf-muted);font-size:13px}
  .epdf-error{color:var(--epdf-danger)}
  .epdf-warning{background:rgba(217,56,56,.08);color:var(--epdf-danger);padding:8px 10px;border-radius:6px;font-size:13px}

  /* zoom */
  .epdf-zoom{display:flex;align-items:center;gap:0;border:1px solid var(--epdf-border);border-radius:8px;margin-right:6px}
  .epdf-zoom .epdf-btn{height:30px;min-width:30px}
  .epdf-zoom-label{border:0;background:none;color:var(--epdf-text);font:inherit;font-variant-numeric:tabular-nums;width:62px;height:30px;cursor:pointer}

  /* menus */
  .epdf-menu-wrap{position:relative}
  .epdf-menu{position:absolute;top:calc(100% + 6px);left:0;z-index:50;min-width:220px;max-height:70vh;overflow:auto;padding:6px;background:var(--epdf-surface);border:1px solid var(--epdf-border);border-radius:var(--epdf-radius);box-shadow:var(--epdf-shadow)}
  .epdf-menu-right{left:auto;right:0}
  .epdf-menu-center{left:50%;transform:translateX(-50%);min-width:170px}
  .epdf-menu hr{border:0;border-top:1px solid var(--epdf-border);margin:6px 0}
  .epdf-menu-label{font-size:12px;color:var(--epdf-muted);padding:6px 10px 2px;text-transform:uppercase;letter-spacing:.04em}
  .epdf-menu-item{display:flex;align-items:center;gap:10px;width:100%;padding:7px 10px;border:0;border-radius:6px;background:none;color:var(--epdf-text);font:inherit;text-align:left;cursor:pointer;text-decoration:none}
  .epdf-menu-item:hover{background:var(--epdf-surface-2)}
  .epdf-menu-item.is-checked::after{content:"✓";margin-left:auto;color:var(--epdf-accent)}
  .epdf-stamp-menu{display:grid;grid-template-columns:1fr 1fr;gap:4px;min-width:360px}
  .epdf-stamp-chip{display:inline-block;border:2px solid;border-radius:6px;padding:3px 8px;font-weight:800;font-size:12px;letter-spacing:.03em;text-transform:uppercase}

  /* style controls */
  .epdf-style{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  .epdf-swatches{display:flex;gap:5px}
  .epdf-swatch{width:20px;height:20px;border-radius:50%;background:var(--c);box-shadow:inset 0 0 0 1px rgba(0,0,0,.2);cursor:pointer;position:relative}
  .epdf-swatch input{position:absolute;opacity:0;inset:0;margin:0;cursor:pointer}
  .epdf-swatch.is-active{outline:2px solid var(--epdf-accent);outline-offset:2px}
  .epdf-field-inline{display:flex;align-items:center;gap:6px;font-size:13px;color:var(--epdf-muted)}
  .epdf-field-inline input[type=range]{width:90px}
  .epdf select,.epdf input[type=text],.epdf input[type=search],.epdf input[type=number],.epdf input[type=url],.epdf input[type=password],.epdf textarea{font:inherit;color:var(--epdf-text);background:var(--epdf-surface);border:1px solid var(--epdf-border);border-radius:6px;padding:5px 8px}

  /* document tabs */
  .epdf-doctabs{display:flex;align-items:flex-end;gap:2px;padding:4px 8px 0;background:var(--epdf-surface-2);border-bottom:1px solid var(--epdf-border);overflow-x:auto}
  .epdf-doctab{display:flex;align-items:center;max-width:220px;border:1px solid transparent;border-bottom:0;border-radius:8px 8px 0 0}
  .epdf-doctab.is-active{background:var(--epdf-surface);border-color:var(--epdf-border)}
  .epdf-doctab-name{display:flex;align-items:center;gap:6px;border:0;background:none;color:var(--epdf-text);font:inherit;font-size:13px;padding:6px 4px 6px 10px;cursor:pointer;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
  .epdf-doctab-close{border:0;background:none;color:var(--epdf-muted);padding:4px 6px;cursor:pointer;display:flex;border-radius:4px}
  .epdf-doctab-close:hover{background:var(--epdf-border)}

  /* hint */
  .epdf-hint{display:flex;align-items:center;gap:10px;justify-content:center;padding:6px 12px;background:var(--epdf-accent-soft);color:var(--epdf-text);font-size:13px;border-bottom:1px solid var(--epdf-border)}

  /* layout */
  .epdf-body{position:relative;flex:1;display:flex;min-height:0}
  .epdf-main{position:relative;flex:1;min-width:0;display:flex;flex-direction:column}
  .epdf-panel{width:280px;flex:none;display:flex;flex-direction:column;background:var(--epdf-surface);border-right:1px solid var(--epdf-border);min-height:0}
  .epdf-panel-right{border-right:0;border-left:1px solid var(--epdf-border);width:320px}
  .epdf-panel-tabs,.epdf-panel-head{display:flex;align-items:center;gap:4px;padding:6px 8px;border-bottom:1px solid var(--epdf-border)}
  .epdf-panel-head{justify-content:space-between;padding-left:14px}
  .epdf-panel-body{flex:1;overflow:auto;padding:10px}
  .epdf-panel-actions{display:flex;gap:6px;flex-wrap:wrap;margin:6px 0}
  /* compact bars, by the viewer's own width (it may be embedded at any size) */
  .epdf{container-name:epdf;container-type:inline-size}
  .epdf-topbar{flex-wrap:nowrap}
  .epdf-topbar .epdf-tabs{flex:0 1 auto;min-width:0}
  @container epdf (max-width:1180px){.epdf-title{max-width:16ch}.epdf-tab{padding:5px 10px}}
  @container epdf (max-width:1020px){.epdf-title{display:none}.epdf-zoom-label{width:52px}}
  @container epdf (max-width:820px){.epdf-topbar{flex-wrap:wrap}.epdf-tabs{order:3;flex:1 0 100%;margin:0}}
  @media (max-width:720px){.epdf-panel{position:absolute;top:0;bottom:0;z-index:40;box-shadow:var(--epdf-shadow)}.epdf-panel-left{left:0}.epdf-panel-right{right:0;width:min(320px,90vw)}.epdf-title{display:none}}

  /* viewport & pages */
  .epdf-viewport{position:relative;flex:1;overflow:auto;container-name:epdfvp;container-type:size;outline:none;overscroll-behavior:contain}
  .epdf-viewport.epdf-pan{cursor:grab}
  .epdf-probe-w,.epdf-probe-h{position:absolute;top:0;left:0;width:1px;height:1px;opacity:0;pointer-events:none;background-size:1px 1px}
  .epdf-pages{display:flex;flex-direction:column;align-items:center;gap:var(--epdf-gap);padding:var(--epdf-gap);min-width:min-content;min-height:100%}
  .epdf-scroll-horizontal .epdf-pages{flex-direction:row;align-items:center;min-height:100%;width:max-content}
  .epdf-scroll-paged .epdf-pages{justify-content:center}
  .epdf-row{display:flex;gap:var(--epdf-gap);align-items:center}
  .epdf-page{position:relative;flex:none;background:#fff;box-shadow:var(--epdf-shadow);overflow:hidden;overflow:clip;scroll-margin:var(--epdf-gap);user-select:none}
  .epdf-page.is-selected{outline:3px solid var(--epdf-accent);outline-offset:2px}
  .epdf-page-img{position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none}
  .epdf-page-number{position:absolute;bottom:4px;right:6px;font-size:11px;color:#888;background:rgba(255,255,255,.8);padding:0 4px;border-radius:3px;pointer-events:none;opacity:0;transition:opacity .2s}
  .epdf-page:hover .epdf-page-number{opacity:1}

  /* scroll position: a marker's background URL applies only while it crosses the
     middle of the viewport, so the browser fetches it then (scroll-driven animation) */
  .epdf-seen{position:absolute;left:0;width:1px;height:1px;opacity:0;pointer-events:none;background-size:1px 1px;
    animation-name:epdf-seen;animation-duration:auto;animation-timing-function:linear;animation-fill-mode:both;animation-timeline:view()}
  /* seven markers ~14% apart: the page covering the middle band always has one in it */
  .epdf-seen-1{top:7%}.epdf-seen-2{top:21%}.epdf-seen-3{top:36%}.epdf-seen-4{top:50%}.epdf-seen-5{top:64%}.epdf-seen-6{top:79%}.epdf-seen-7{top:93%}
  .epdf-scroll-horizontal .epdf-seen{animation-timeline:view(inline);top:50%}
  .epdf-scroll-horizontal .epdf-seen-1{left:7%}.epdf-scroll-horizontal .epdf-seen-2{left:21%}.epdf-scroll-horizontal .epdf-seen-3{left:36%}.epdf-scroll-horizontal .epdf-seen-4{left:50%}.epdf-scroll-horizontal .epdf-seen-5{left:64%}.epdf-scroll-horizontal .epdf-seen-6{left:79%}.epdf-scroll-horizontal .epdf-seen-7{left:93%}
  .epdf-scroll-paged .epdf-seen{display:none}
  @keyframes epdf-seen{0%,38%{background-image:none}39%,61%{background-image:var(--epdf-seen)}62%,100%{background-image:none}}

  /* text layer */
  .epdf-text-layer{position:absolute;inset:0;overflow:hidden;line-height:1;color:transparent;white-space:pre;user-select:text;-webkit-user-select:text;cursor:text;z-index:1}
  .epdf-tl{position:absolute;transform-origin:0 0;font-family:Helvetica,Arial,sans-serif;white-space:pre}
  .epdf-text-layer br{display:none}
  .epdf-text-layer ::selection{background:var(--epdf-select);color:transparent}
  .epdf-pan .epdf-text-layer{cursor:grab;user-select:none}
  .epdf-tool-highlight .epdf-w,.epdf-tool-underline .epdf-w,.epdf-tool-strikeout .epdf-w,.epdf-tool-squiggly .epdf-w,.epdf-tool-redact_text .epdf-w{cursor:pointer;border-radius:2px}
  .epdf-tool-highlight .epdf-w:hover,.epdf-tool-underline .epdf-w:hover,.epdf-tool-strikeout .epdf-w:hover,.epdf-tool-squiggly .epdf-w:hover,.epdf-tool-redact_text .epdf-w:hover{background:var(--epdf-select)}

  /* overlays */
  .epdf-overlay{position:absolute;inset:0;z-index:2;pointer-events:none}
  .epdf-overlay>*{pointer-events:auto}
  .epdf-hit{position:absolute;background:var(--epdf-hit);mix-blend-mode:multiply;pointer-events:none;border-radius:2px;scroll-margin:30vh}
  .epdf-hit.is-current{background:var(--epdf-hit-current);outline:1px solid rgba(255,120,0,.9)}
  .epdf-anchor{position:absolute;background:var(--epdf-select);pointer-events:none}
  .epdf-annot{position:absolute;padding:0;margin:0;border:0;background:transparent;cursor:pointer;border-radius:2px;scroll-margin:30vh}
  .epdf-annot:hover{outline:1px dashed var(--epdf-accent)}
  .epdf-annot.is-selected{outline:2px solid var(--epdf-accent);outline-offset:1px}
  .epdf-annot-highlight,.epdf-annot-underline,.epdf-annot-strikeout,.epdf-annot-squiggly{pointer-events:none}
  .epdf-tool-pointer .epdf-annot-highlight,.epdf-tool-pointer .epdf-annot-underline,.epdf-tool-pointer .epdf-annot-strikeout,.epdf-tool-pointer .epdf-annot-squiggly{pointer-events:auto}
  .epdf-mode-view .epdf-annot-highlight,.epdf-mode-view .epdf-annot-underline,.epdf-mode-view .epdf-annot-strikeout,.epdf-mode-view .epdf-annot-squiggly{pointer-events:none}
  .epdf-link{position:absolute;display:block;border:0;background:transparent;cursor:pointer;padding:0}
  .epdf-link:hover{background:rgba(59,108,246,.12);outline:1px solid rgba(59,108,246,.35)}
  .epdf-strip{position:absolute;transform:translateY(calc(-100% - 8px));display:flex;gap:2px;padding:3px;background:var(--epdf-surface);border:1px solid var(--epdf-border);border-radius:8px;box-shadow:var(--epdf-shadow);z-index:5;white-space:nowrap}
  .epdf-strip .epdf-btn{height:30px;min-width:30px}
  .epdf-freetext-editor{position:absolute;z-index:6;display:flex;flex-direction:column;gap:4px;min-width:160px;min-height:70px}
  .epdf-freetext-editor textarea{flex:1;width:100%;resize:both;border:2px solid var(--epdf-accent)}
  .epdf-preview{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
  .epdf-preview polyline,.epdf-preview line{fill:none;stroke:var(--epdf-accent);stroke-width:2;vector-effect:non-scaling-stroke;stroke-dasharray:6 4}
  .epdf-preview circle{fill:var(--epdf-accent)}
  .epdf-measure line{stroke:#e44234;stroke-dasharray:none}
  .epdf-measure-label{position:absolute;transform:translate(-50%,-130%);background:#e44234;color:#fff;font-size:12px;padding:2px 6px;border-radius:4px;white-space:nowrap;pointer-events:none}
  .epdf-pointer{position:absolute;inset:0;margin:0;z-index:4}
  .epdf-pointer input[type=image]{display:block;border:0;padding:0;margin:0;cursor:crosshair;opacity:0}
  .epdf-tool-note .epdf-pointer input,.epdf-tool-stamp .epdf-pointer input,.epdf-tool-free_text .epdf-pointer input{cursor:copy}

  /* form fields */
  .epdf-form{position:absolute;inset:0;margin:0}
  .epdf-input{position:absolute;margin:0;padding:0 2px!important;border:1px solid rgba(59,108,246,.45)!important;border-radius:2px!important;background:rgba(214,226,255,.55)!important;color:#000!important;font-size:calc(var(--epdf-scale) * 11px)!important;line-height:1.1}
  .epdf-input:focus{outline:2px solid var(--epdf-accent);background:rgba(255,255,255,.9)!important}
  textarea.epdf-input{resize:none}
  .epdf-check{display:flex;align-items:center;justify-content:center}
  .epdf-check input{margin:0;width:70%;height:70%}

  /* pager */
  .epdf-pager{position:absolute;bottom:14px;left:50%;transform:translateX(-50%);display:flex;align-items:center;gap:2px;padding:4px;background:var(--epdf-surface);border:1px solid var(--epdf-border);border-radius:999px;box-shadow:var(--epdf-shadow);z-index:10}
  .epdf-pager .epdf-btn{border-radius:999px;height:30px;min-width:30px}
  .epdf-page-input{display:flex;align-items:center;gap:6px;margin:0 4px;font-variant-numeric:tabular-nums;color:var(--epdf-muted)}
  .epdf-page-input input{width:46px;text-align:center;padding:3px 4px!important}
  .epdf-page-current{border:0;background:none;font:inherit;cursor:text;padding:0}
  .epdf-page-box{display:inline-block;min-width:46px;text-align:center;padding:3px 4px;border:1px solid var(--epdf-border);border-radius:6px;color:var(--epdf-text);background:var(--epdf-surface)}

  /* panels content */
  .epdf-thumbs{display:flex;flex-direction:column;align-items:center;gap:14px;padding:4px}
  .epdf-thumb{display:flex;flex-direction:column;align-items:center;gap:4px;color:var(--epdf-muted);text-decoration:none;font-size:12px}
  .epdf-thumb img{width:150px;height:auto;background:#fff;box-shadow:var(--epdf-shadow);border:2px solid transparent;border-radius:2px}
  .epdf-thumb.is-current img{border-color:var(--epdf-accent)}
  .epdf-thumb.is-current{color:var(--epdf-accent);font-weight:600}
  .epdf-thumb.is-selected img{outline:3px solid var(--epdf-accent)}
  .epdf-tree{list-style:none;margin:0;padding:0 0 0 14px}
  .epdf-outline>.epdf-tree{padding-left:0}
  .epdf-tree-row{display:flex;align-items:center;gap:2px;border-radius:6px}
  .epdf-tree-row:hover{background:var(--epdf-surface-2)}
  .epdf-tree-toggle{border:0;background:none;color:var(--epdf-muted);width:22px;height:26px;cursor:pointer;display:flex;align-items:center;justify-content:center;padding:0}
  .epdf-tree-spacer{width:22px;flex:none}
  .epdf-tree-link{flex:1;color:var(--epdf-text);text-decoration:none;padding:4px 2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .epdf-tree-link.is-bold{font-weight:700}.epdf-tree-link.is-italic{font-style:italic}
  .epdf-tree-actions{display:none}
  .epdf-tree-row:hover .epdf-tree-actions{display:flex}
  .epdf-inline-form{display:flex;gap:6px;margin-top:8px}
  .epdf-inline-form input{flex:1;min-width:0}
  .epdf-attachment{display:flex;align-items:center;gap:8px;padding:8px;border-radius:6px}
  .epdf-attachment:hover{background:var(--epdf-surface-2)}
  .epdf-attachment-info{flex:1;min-width:0;display:flex;flex-direction:column}
  .epdf-attachment-info strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .epdf-search{display:flex;flex-direction:column;gap:6px}
  .epdf-search-box{display:flex;align-items:center;gap:6px;border:1px solid var(--epdf-border);border-radius:8px;padding:0 8px;background:var(--epdf-surface)}
  .epdf-search-box input{border:0!important;flex:1;min-width:0;outline:none;padding:7px 0!important}
  .epdf-check-label{display:flex;align-items:center;gap:6px;font-size:13px;color:var(--epdf-muted)}
  .epdf-search-nav{display:flex;align-items:center;gap:4px;margin:8px 0;font-size:13px;color:var(--epdf-muted)}
  .epdf-search-nav span{flex:1}
  .epdf-result-page{font-size:12px;font-weight:600;color:var(--epdf-muted);margin:10px 0 4px}
  .epdf-result{display:block;width:100%;text-align:left;border:0;background:none;color:var(--epdf-text);font:inherit;font-size:13px;padding:6px 8px;border-radius:6px;cursor:pointer;line-height:1.35;word-break:break-word}
  .epdf-result:hover{background:var(--epdf-surface-2)}
  .epdf-result.is-current{background:var(--epdf-accent-soft)}
  .epdf-result span{color:var(--epdf-muted)}
  .epdf-result mark{background:var(--epdf-hit);color:inherit;border-radius:2px}
  .epdf-comment{border:1px solid var(--epdf-border);border-radius:8px;padding:8px 10px;margin-bottom:10px}
  .epdf-comment.is-selected{border-color:var(--epdf-accent)}
  .epdf-comment-head{display:flex;align-items:center;gap:8px;width:100%;border:0;background:none;padding:0;color:var(--epdf-text);font:inherit;cursor:pointer;text-align:left}
  .epdf-comment-head .epdf-muted{margin-left:auto}
  .epdf-comment-dot{width:10px;height:10px;border-radius:50%;flex:none}
  .epdf-comment-body{margin:6px 0;white-space:pre-wrap}
  .epdf-reply{border-left:2px solid var(--epdf-border);padding-left:8px;margin:6px 0;font-size:13px}
  .epdf-reply p{margin:2px 0}
  .epdf-props{display:flex;flex-direction:column;gap:12px}
  .epdf-props-type{text-transform:capitalize;font-weight:600}
  .epdf-props-style,.epdf-props-text{display:flex;flex-direction:column;gap:10px}
  .epdf-field{display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--epdf-muted)}
  .epdf-field textarea{resize:vertical}
  .epdf-nudge{display:grid;grid-template-columns:repeat(3,36px);gap:4px;justify-content:center}

  /* empty, dialogs */
  .epdf-empty{flex:1;display:flex;align-items:center;justify-content:center;padding:24px}
  .epdf-empty-card{text-align:center;max-width:420px;padding:32px;border:2px dashed var(--epdf-border);border-radius:16px;background:var(--epdf-surface)}
  .epdf-empty-card h2{margin:8px 0 4px;font-size:20px}
  .epdf-progress{height:4px;background:var(--epdf-border);border-radius:4px;margin-top:12px;overflow:hidden}
  .epdf-progress span{display:block;height:100%;background:var(--epdf-accent)}
  .epdf-backdrop{position:absolute;inset:0;z-index:100;background:rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;padding:16px}
  .epdf-dialog{position:relative;background:var(--epdf-surface);color:var(--epdf-text);border-radius:12px;box-shadow:var(--epdf-shadow);padding:20px 22px;width:min(480px,100%);max-height:90%;overflow:auto}
  .epdf-dialog h3{margin:0 0 12px;font-size:17px}
  .epdf-dialog-close{position:absolute;top:10px;right:10px}
  .epdf-dialog-actions{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
  .epdf-column{display:flex;flex-direction:column;gap:8px;align-items:stretch}
  .epdf-props-form{display:flex;flex-direction:column;gap:10px}
  .epdf-dl{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:13px;margin:8px 0}
  .epdf-dl dt{color:var(--epdf-muted)}
  .epdf-dl dd{margin:0;word-break:break-word}
  .epdf-keys kbd{display:inline-block;min-width:22px;text-align:center;padding:1px 6px;border:1px solid var(--epdf-border);border-bottom-width:2px;border-radius:4px;font:12px ui-monospace,monospace;background:var(--epdf-surface-2)}
  .epdf-drop{border:2px dashed var(--epdf-border);border-radius:12px;padding:24px;text-align:center}
  .epdf-snapshot{display:block;max-width:100%;max-height:50vh;margin:0 auto;background:#fff;box-shadow:var(--epdf-shadow)}

  @media print{.epdf-topbar,.epdf-modebar,.epdf-hint,.epdf-panel,.epdf-pager{display:none!important}.epdf-viewport{overflow:visible}}
  """

  @version @css |> :erlang.md5() |> Base.url_encode64(padding: false) |> binary_part(0, 10)

  @doc "The stylesheet."
  def css, do: @css

  @doc "A hash of the stylesheet, used in its URL so browsers never keep a stale copy."
  def version, do: @version
end
