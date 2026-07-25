/**
 * Zuruck Recovery UI — browser SPA.
 *
 * Vanilla TypeScript, no framework. Talks to the local server (app/server) over
 * same-origin fetch, presenting the per-session token on every call. DOM is built
 * with createElement + textContent (never innerHTML from data), so a filename can
 * never inject markup. Bundled to an IIFE by app/zuruck-ui.mjs and inlined into
 * the page shell (app/server/page.ts).
 */

interface Snapshot {
  id: string;
  short_id: string;
  time: string;
  hostname: string;
  paths: string[];
  tags?: string[];
}
interface DirEntry {
  name: string;
  type: string;
  path: string;
  size?: number;
}

const CFG = (window as unknown as { __ZURUCK__: { token: string; repo: string } }).__ZURUCK__;

// ── API helpers ────────────────────────────────────────────────────────────
async function api<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { 'x-zuruck-token': CFG.token } });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `HTTP ${res.status}`);
  return res.json() as Promise<T>;
}
function dumpUrl(snap: string, path: string, opts?: { download?: boolean; max?: number }): string {
  const p = new URLSearchParams({ snap, path, t: CFG.token });
  if (opts?.download) p.set('download', '1');
  if (opts?.max) p.set('max', String(opts.max));
  return `/api/dump?${p.toString()}`;
}

// ── Formatting (mirrors app/core/format.ts) ────────────────────────────────
function human(bytes?: number): string {
  if (bytes == null) return '';
  const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let b = bytes;
  let i = 0;
  while (b >= 1024 && i < u.length - 1) {
    b /= 1024;
    i++;
  }
  return i === 0 ? `${Math.round(b)} ${u[i]}` : `${b.toFixed(1)} ${u[i]}`;
}

// ── State ──────────────────────────────────────────────────────────────────
let current: Snapshot | null = null;
const selected = new Map<string, DirEntry>();

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const treeEl = $('tree');
const selListEl = $('sel-list');
const selCountEl = $('sel-count');
const restoreBtn = $<HTMLButtonElement>('restore-btn');
const previewEl = $('preview');

// ── Selection ──────────────────────────────────────────────────────────────
function toggleSelect(entry: DirEntry, on: boolean): void {
  if (on) selected.set(entry.path, entry);
  else selected.delete(entry.path);
  renderSelection();
}
function renderSelection(): void {
  selCountEl.textContent = String(selected.size);
  restoreBtn.disabled = selected.size === 0;
  selListEl.replaceChildren();
  for (const e of selected.values()) {
    const li = document.createElement('li');
    const icon = document.createElement('span');
    icon.className = 'icon';
    icon.textContent = e.type === 'dir' ? '📁' : '📄';
    const p = document.createElement('span');
    p.className = 'p';
    p.textContent = e.path;
    p.title = e.path;
    const rm = document.createElement('button');
    rm.textContent = '✕';
    rm.title = 'Remove';
    rm.onclick = () => {
      toggleSelect(e, false);
      const cb = document.querySelector<HTMLInputElement>(`input[data-path="${cssEscape(e.path)}"]`);
      if (cb) cb.checked = false;
    };
    li.append(icon, p, rm);
    selListEl.append(li);
  }
}
function cssEscape(s: string): string {
  return s.replace(/["\\]/g, '\\$&');
}

// ── Tree rendering ─────────────────────────────────────────────────────────
function makeRow(entry: DirEntry, isDir: boolean): { row: HTMLElement; childHost: HTMLElement } {
  const li = document.createElement('li');
  const row = document.createElement('div');
  row.className = 'row';

  const tw = document.createElement('span');
  tw.className = 'tw';
  tw.textContent = isDir ? '▸' : '';

  const cb = document.createElement('input');
  cb.type = 'checkbox';
  cb.dataset.path = entry.path;
  cb.checked = selected.has(entry.path);
  cb.onchange = () => toggleSelect(entry, cb.checked);

  const icon = document.createElement('span');
  icon.className = 'icon';
  icon.textContent = isDir ? '📁' : '📄';

  const nm = document.createElement('span');
  nm.className = 'nm' + (isDir ? ' dir' : '');
  nm.textContent = entry.name;
  nm.title = entry.path;

  const sz = document.createElement('span');
  sz.className = 'sz';
  sz.textContent = isDir ? '' : human(entry.size);

  row.append(tw, cb, icon, nm, sz);
  const childHost = document.createElement('ul');
  childHost.style.display = 'none';
  li.append(row, childHost);

  if (isDir) {
    let loaded = false;
    const toggle = async () => {
      const openNow = childHost.style.display === 'none';
      childHost.style.display = openNow ? 'block' : 'none';
      tw.textContent = openNow ? '▾' : '▸';
      if (openNow && !loaded) {
        loaded = true;
        childHost.append(hint('Loading…'));
        try {
          const kids = await api<DirEntry[]>(
            `/api/ls?snap=${encodeURIComponent(current!.short_id)}&path=${encodeURIComponent(entry.path)}`,
          );
          childHost.replaceChildren();
          if (kids.length === 0) childHost.append(hint('(empty)'));
          for (const k of kids) childHost.append(makeRow(k, k.type === 'dir').row.parentElement!);
        } catch (err) {
          childHost.replaceChildren(hint('Error: ' + (err as Error).message, true));
          loaded = false;
        }
      }
    };
    tw.onclick = toggle;
    nm.onclick = toggle;
  } else {
    nm.onclick = () => preview(entry);
  }
  return { row, childHost };
}

function renderRoots(snap: Snapshot): void {
  const ul = document.createElement('ul');
  ul.className = 'tree';
  for (const rootPath of snap.paths) {
    const entry: DirEntry = { name: rootPath, type: 'dir', path: rootPath };
    ul.append(makeRow(entry, true).row.parentElement!);
  }
  treeEl.replaceChildren(ul);
}

function hint(text: string, err = false): HTMLElement {
  const d = document.createElement('div');
  d.className = 'hint' + (err ? ' err' : '');
  d.textContent = text;
  return d;
}

// ── Preview ────────────────────────────────────────────────────────────────
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|bmp|ico)$/i;
const TEXT_EXT = /\.(txt|md|log|json|js|ts|tsx|jsx|css|html?|xml|csv|ya?ml|sh|conf|ini|toml|py|rb|go|rs|c|h|cpp|java|sql|env|gitignore)$/i;

async function preview(entry: DirEntry): Promise<void> {
  previewEl.className = '';
  previewEl.replaceChildren();
  const header = document.createElement('div');
  header.style.marginBottom = '8px';
  const name = document.createElement('span');
  name.textContent = entry.name + '  ';
  const dl = document.createElement('a');
  dl.className = 'dl';
  dl.textContent = '⬇ Download';
  dl.href = dumpUrl(current!.short_id, entry.path, { download: true });
  header.append(name, dl);

  if (IMAGE_EXT.test(entry.name)) {
    const img = document.createElement('img');
    img.src = dumpUrl(current!.short_id, entry.path);
    const box = document.createElement('div');
    box.className = 'preview';
    box.append(img);
    previewEl.append(header, box);
  } else if (TEXT_EXT.test(entry.name)) {
    const pre = document.createElement('pre');
    pre.className = 'preview';
    pre.textContent = 'Loading…';
    previewEl.append(header, pre);
    try {
      const res = await fetch(dumpUrl(current!.short_id, entry.path, { max: 262144 }), {
        headers: { 'x-zuruck-token': CFG.token },
      });
      pre.textContent = await res.text();
    } catch (err) {
      pre.textContent = 'Error: ' + (err as Error).message;
    }
  } else {
    const box = document.createElement('div');
    box.className = 'hint';
    box.textContent = 'No inline preview for this file type — use Download.';
    previewEl.append(header, box);
  }
}

// ── Search ─────────────────────────────────────────────────────────────────
async function runSearch(): Promise<void> {
  const q = $<HTMLInputElement>('search').value.trim();
  if (!q) {
    renderRoots(current!);
    return;
  }
  treeEl.replaceChildren(hint('Searching…'));
  try {
    const hits = await api<DirEntry[]>(
      `/api/find?snap=${encodeURIComponent(current!.short_id)}&q=${encodeURIComponent(q)}`,
    );
    const ul = document.createElement('ul');
    ul.className = 'tree';
    if (hits.length === 0) ul.append(hint('No matches.'));
    for (const h of hits) ul.append(makeRow(h, h.type === 'dir').row.parentElement!);
    const back = document.createElement('button');
    back.textContent = '← Back to tree';
    back.style.marginBottom = '10px';
    back.onclick = () => renderRoots(current!);
    treeEl.replaceChildren(back, ul);
  } catch (err) {
    treeEl.replaceChildren(hint('Error: ' + (err as Error).message, true));
  }
}

// ── Restore ────────────────────────────────────────────────────────────────
function defaultTarget(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  const stamp = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  return `~/zuruck-restore-${stamp}`;
}

async function runRestore(): Promise<void> {
  if (selected.size === 0) return;
  const target = $<HTMLInputElement>('target').value.trim() || defaultTarget();
  const log = $('restore-log');
  log.style.display = 'block';
  log.textContent = '';
  restoreBtn.disabled = true;
  try {
    const res = await fetch('/api/restore', {
      method: 'POST',
      headers: { 'x-zuruck-token': CFG.token, 'content-type': 'application/json' },
      body: JSON.stringify({ snap: current!.short_id, includes: [...selected.keys()], target }),
    });
    const reader = res.body!.getReader();
    const dec = new TextDecoder();
    let all = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      all += dec.decode(value, { stream: true });
      log.textContent = all;
      log.scrollTop = log.scrollHeight;
    }
    const m = all.match(/__DONE__ (\d+) (.+)\s*$/);
    if (m && (m[1] === '0' || m[1] === '3')) {
      const doneTarget = m[2].trim();
      const reveal = document.createElement('button');
      reveal.textContent = '📂 Reveal in Finder';
      reveal.className = 'primary';
      reveal.style.marginTop = '10px';
      reveal.onclick = () =>
        fetch('/api/reveal', {
          method: 'POST',
          headers: { 'x-zuruck-token': CFG.token, 'content-type': 'application/json' },
          body: JSON.stringify({ path: doneTarget }),
        });
      log.after(reveal);
    }
  } catch (err) {
    log.textContent += '\nError: ' + (err as Error).message;
  } finally {
    restoreBtn.disabled = selected.size === 0;
  }
}

// ── Boot ───────────────────────────────────────────────────────────────────
async function boot(): Promise<void> {
  $<HTMLInputElement>('target').value = defaultTarget();
  restoreBtn.onclick = runRestore;
  $('search-btn').onclick = runSearch;
  $<HTMLInputElement>('search').addEventListener('keydown', (e) => {
    if ((e as KeyboardEvent).key === 'Enter') runSearch();
  });

  const picker = $<HTMLSelectElement>('snap-picker');
  try {
    const snaps = await api<Snapshot[]>('/api/snapshots');
    if (snaps.length === 0) {
      treeEl.replaceChildren(hint('No snapshots in this repository yet.'));
      return;
    }
    snaps.reverse(); // newest first
    picker.replaceChildren();
    for (const s of snaps) {
      const opt = document.createElement('option');
      opt.value = s.short_id;
      const when = s.time.replace('T', ' ').slice(0, 19);
      opt.textContent = `${when}  ·  ${s.short_id}${s.tags?.length ? '  ·  ' + s.tags.join(',') : ''}`;
      picker.append(opt);
    }
    const select = (shortId: string) => {
      current = snaps.find((s) => s.short_id === shortId) || snaps[0];
      selected.clear();
      renderSelection();
      renderRoots(current);
    };
    picker.onchange = () => select(picker.value);
    select(snaps[0].short_id);
  } catch (err) {
    treeEl.replaceChildren(hint('Error loading snapshots: ' + (err as Error).message, true));
  }
}

boot();
