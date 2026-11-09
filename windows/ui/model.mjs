export function asList(value) {
  if (Array.isArray(value)) return value;
  return Array.isArray(value?.entries) ? value.entries : Array.isArray(value?.items) ? value.items : [];
}
export function normalizeSnapshot(value = {}, previous = {}) {
  return {
    ...value,
    settings: value.settings || {},
    profile: value.profile || {},
    messages: asList(value.messages ?? value.conversation),
    diary: asList(value.diary),
    notes: asList(value.notes),
    album: asList(value.album),
    songs: value.songsOmitted ? asList(previous.songs) : asList(value.songs),
    games: value.games || null,
    capabilities: value.capabilities || {},
  };
}
export function listText(value) { return Array.isArray(value) ? value.map(item => typeof item === 'string' ? item : item.text || item.value || '').filter(Boolean).join('\n') : String(value ?? ''); }
export function splitLines(value) { return String(value || '').split(/\r?\n/).map(line => line.trim()).filter(Boolean); }
export function itemId(item, index = 0) { return String(item.id ?? item.uuid ?? index); }
export function messageText(item) { return String(item.text ?? item.content ?? item.message ?? ''); }
export function songTitle(song) { return song.title || song.name || song.displayTitle || song.aliases?.[0] || song.id || ''; }
export function songDescription(song, language = 'zh-Hant') {
  if (typeof song.content === 'string') return song.content;
  return song.content?.[language] || song.content?.[language === 'zh-Hans' ? 'zh-Hant' : language] || song.content?.zhHant || song.content?.en || song.description || '';
}
export function songPage(songs, query = '', page = 0, pageSize = 200) {
  const size = Math.max(1, Math.min(200, Math.floor(Number(pageSize)) || 200));
  const normalize = value => String(value || '').normalize('NFKC').toLocaleLowerCase();
  const search = normalize(query.trim());
  const matches = search ? songs.filter(song => {
    const content = typeof song.content === 'object' && song.content ? Object.values(song.content) : song.content;
    return normalize([songTitle(song), listText(song.aliases), listText(song.creators || song.artist || song.producer), listText(content), song.description || ''].join(' ')).includes(search);
  }) : songs;
  const total = matches.length;
  const pages = Math.max(1, Math.ceil(total / size));
  const current = Math.max(0, Math.min(pages - 1, Math.floor(Number(page)) || 0));
  const start = current * size;
  return { items: matches.slice(start, start + size), total, pages, page: current, start, end: Math.min(start + size, total) };
}
export function safeSourceURL(candidate) {
  try {
    const url = new URL(candidate);
    return url.protocol === 'https:' && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}
export const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
export function imageFileError(file) {
  if (!file || !['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || !Number.isFinite(file.size) || file.size <= 0) return 'imageInvalid';
  return file.size > MAX_IMAGE_BYTES ? 'imageTooLarge' : null;
}
export function transferFiles(transfer) {
  const files = Array.from(transfer?.files || []);
  if (files.length) return files;
  return Array.from(transfer?.items || []).filter(item => item.kind === 'file').map(item => item.getAsFile?.()).filter(Boolean);
}
export function imageFromTransfer(transfer, preferText = true) {
  if (preferText && transfer?.getData?.('text/plain')?.trim()) return null;
  return transferFiles(transfer).find(file => ['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) || null;
}
export function imageDimensions(width, height, maximum = 1280) {
  if (![width, height].every(value => Number.isFinite(value) && value >= 1) || width * height > 64_000_000) throw new Error('imageInvalid');
  const scale = Math.min(1, maximum / Math.max(width, height));
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}
export function imageSource(value) {
  if (typeof value === 'string') return /^data:image\/(png|jpeg|webp);base64,[a-z\d+/=\s]+$/i.test(value) ? value : null;
  const data = value?.base64 ?? value?.data ?? value?.image ?? value?.dataURL ?? value?.dataUrl;
  if (typeof data === 'string' && data.startsWith('data:')) return imageSource(data);
  const mime = value?.mimeType ?? value?.mime ?? 'image/png';
  return typeof data === 'string' && /^image\/(png|jpeg|webp)$/.test(mime) && /^[a-z\d+/=\s]+$/i.test(data) ? `data:${mime};base64,${data}` : null;
}
export function audioSource(value) {
  const source = value?.audio ?? value?.base64 ?? value?.data;
  const mime = value?.mimeType ?? value?.mime ?? 'audio/wav';
  if (typeof source !== 'string') return null;
  if (/^data:audio\/[a-z\d.+-]+;base64,[a-z\d+/=\s]+$/i.test(source)) return source;
  return /^audio\/[a-z\d.+-]+$/i.test(mime) && /^[a-z\d+/=\s]+$/i.test(source) ? `data:${mime};base64,${source}` : null;
}
export function isSnapshot(value) { return Boolean(value && typeof value === 'object' && value.settings && (value.messages || value.profile || value.notes)); }
export function buildSettingsPatch(form) {
  const patch = {};
  for (const field of form.elements) {
    if (!field.name || field.disabled || ['button', 'submit', 'file'].includes(field.type)) continue;
    if (field.type === 'checkbox') patch[field.name] = field.checked;
    else if (field.type === 'number') patch[field.name] = field.value === '' ? null : Number(field.value);
    else if (field.name === 'cloudApiKey' || field.name === 'aimcpApiKey') {
      if (field.value.trim()) patch[field.name] = field.value.trim();
    } else patch[field.name] = field.value.trim();
  }
  return patch;
}
export function dateText(value, language) {
  if (value === null || value === undefined || value === '') return '';
  const number = typeof value === 'number' ? value : null;
  const date = new Date(number === null ? value : number < 1e11 ? number * 1000 : number);
  return Number.isNaN(date.valueOf()) ? String(value) : date.toLocaleString(language, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export function mayAutoSpeak(settings, now = new Date()) {
  if (!settings.speechEnabled || settings.muted || settings.speechMuted) return false;
  if (settings.speechQuietEnabled === false) return true;
  const minutes = value => {
    const match = /^(\d{1,2}):(\d{2})$/.exec(value || '');
    if (!match || Number(match[1]) > 23 || Number(match[2]) > 59) return null;
    return Number(match[1]) * 60 + Number(match[2]);
  };
  const start = minutes(settings.quietStart || '01:00');
  const end = minutes(settings.quietEnd || '07:00');
  if (start === null || end === null || start === end) return true;
  const current = now.getHours() * 60 + now.getMinutes();
  return !(start < end ? current >= start && current < end : current >= start || current < end);
}
