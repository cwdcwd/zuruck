/**
 * The single-page shell: HTML skeleton + CSS (theme tokens ported from
 * scripts/status.sh:271-314 so the recovery UI matches the dashboards). The
 * browser bundle (app/web/app.ts) and a small runtime config are injected here;
 * app.ts fills the mount points. Everything is inline → the page is fully
 * self-contained (the same property that lets status.sh's HTML work anywhere).
 */

export interface PageConfig {
  token: string;
  repo: string;
  bundle: string;
}

const STYLE = `
:root{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--muted:#5c636e;--line:#e3e6ea;
  --ok:#1a7f37;--bad:#cf222e;--warn:#9a6700;--accent:#0969da;--accent-soft:#0969da22;--sel:#0969da14}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--muted:#9198a1;--line:#30363d;
  --ok:#3fb950;--bad:#f85149;--warn:#d29922;--accent:#58a6ff;--accent-soft:#58a6ff22;--sel:#58a6ff1f}}
:root[data-theme=dark]{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--muted:#9198a1;--line:#30363d;
  --ok:#3fb950;--bad:#f85149;--warn:#d29922;--accent:#58a6ff;--accent-soft:#58a6ff22;--sel:#58a6ff1f}
:root[data-theme=light]{--bg:#f6f7f9;--card:#fff;--fg:#1a1d21;--muted:#5c636e;--line:#e3e6ea;
  --ok:#1a7f37;--bad:#cf222e;--warn:#9a6700;--accent:#0969da;--accent-soft:#0969da22;--sel:#0969da14}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
header{display:flex;align-items:center;gap:14px;padding:14px 20px;border-bottom:1px solid var(--line);
  position:sticky;top:0;background:var(--bg);z-index:5}
header h1{font-size:16px;margin:0;font-weight:650}
header .repo{color:var(--muted);font-size:12px;word-break:break-all;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
select,input[type=text],button{font:inherit;color:var(--fg);background:var(--card);
  border:1px solid var(--line);border-radius:8px;padding:7px 10px}
button{cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
button:disabled{opacity:.5;cursor:not-allowed}
.layout{display:grid;grid-template-columns:minmax(320px,1.3fr) 1fr;gap:0;height:calc(100vh - 59px)}
.pane{overflow:auto;padding:16px 18px}
.pane.left{border-right:1px solid var(--line)}
.toolbar{display:flex;gap:10px;align-items:center;margin-bottom:12px;flex-wrap:wrap}
.toolbar input[type=text]{flex:1;min-width:140px}
.hint{color:var(--muted);font-size:13px}
ul.tree{list-style:none;margin:0;padding:0;font-size:14px}
ul.tree ul{list-style:none;margin:0;padding-left:18px}
.row{display:flex;align-items:center;gap:8px;padding:3px 6px;border-radius:6px;cursor:default;white-space:nowrap}
.row:hover{background:var(--sel)}
.row .tw{width:14px;text-align:center;color:var(--muted);cursor:pointer;user-select:none}
.row .nm{cursor:pointer;overflow:hidden;text-overflow:ellipsis}
.row .nm.dir{font-weight:550}
.row .sz{color:var(--muted);font-size:12px;margin-left:auto;font-variant-numeric:tabular-nums}
.row input[type=checkbox]{accent-color:var(--accent)}
.icon{width:16px;display:inline-block;text-align:center}
.preview{white-space:pre-wrap;word-break:break-word;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  font-size:12.5px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;
  max-height:52vh;overflow:auto}
.preview img{max-width:100%;height:auto;border-radius:6px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:14px}
.card h2{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:0 0 10px}
.sel-list{list-style:none;margin:0 0 10px;padding:0;font-size:13px;max-height:160px;overflow:auto}
.sel-list li{display:flex;gap:8px;align-items:center;padding:2px 0;color:var(--muted)}
.sel-list li .p{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.sel-list li button{padding:0 6px;border:none;background:none;color:var(--bad)}
.field{display:flex;gap:8px;align-items:center;margin-bottom:10px}
.field label{color:var(--muted);font-size:13px;min-width:52px}
.field input{flex:1}
.log{white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
  background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px;max-height:200px;overflow:auto;margin-top:10px}
.badge{display:inline-block;font-size:11px;padding:2px 8px;border-radius:999px;background:var(--accent-soft);color:var(--accent)}
.err{color:var(--bad)}
a.dl{color:var(--accent);text-decoration:none;font-size:13px}
`;

export function renderPage(cfg: PageConfig): string {
  // Escape `<` (and U+2028/2029) so no value can break out of the <script> tag,
  // even though token/repo are trusted local values today.
  const config = JSON.stringify({ token: cfg.token, repo: cfg.repo })
    .replace(/</g, '\\u003c')
    .replace(/\\u2028/g, '\\u2028')
    .replace(/\\u2029/g, '\\u2029');
  return `<!doctype html>
<html lang=en>
<head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Zuruck — Recover files</title>
<style>${STYLE}</style>
</head>
<body>
<header>
  <h1>Zuruck · Recover files</h1>
  <span class=repo>${escapeHtml(cfg.repo)}</span>
</header>
<div class=layout>
  <div class="pane left">
    <div class=toolbar>
      <select id=snap-picker aria-label="Snapshot"></select>
      <input id=search type=text placeholder="Search filenames…">
      <button id=search-btn>Search</button>
    </div>
    <div id=tree><div class=hint>Loading snapshots…</div></div>
  </div>
  <div class="pane right">
    <div class=card>
      <h2>Preview</h2>
      <div id=preview class=hint>Select a file to preview it.</div>
    </div>
    <div class=card>
      <h2>Restore selected <span id=sel-count class=badge>0</span></h2>
      <ul id=sel-list class=sel-list></ul>
      <div class=field><label for=target>To</label><input id=target type=text></div>
      <div class=toolbar>
        <button id=restore-btn class=primary disabled>Restore</button>
        <span id=restore-hint class=hint>Files restore into a fresh folder — never over your live files.</span>
      </div>
      <div id=restore-log class=log style="display:none"></div>
    </div>
  </div>
</div>
<script>window.__ZURUCK__=${config};</script>
<script>${cfg.bundle}</script>
</body>
</html>`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] as string));
}
