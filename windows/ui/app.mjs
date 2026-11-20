import { t, setLanguage, getLanguage, languages, spokenLanguages } from './i18n.mjs';
import { normalizeSnapshot, asList, listText, splitLines, itemId, messageText, songTitle, songDescription, songPage, safeSourceURL, imageSource, isSnapshot, buildSettingsPatch, dateText, mayAutoSpeak, MAX_IMAGE_BYTES, imageFileError, transferFiles, imageFromTransfer, imageDimensions } from './model.mjs';
import { VoiceController } from './audio.mjs';

const app = document.querySelector('#app');
const notice = document.querySelector('#notice');
const state = { snapshot: normalizeSnapshot(), view: '', tab: 'diary', pending: false, attachment: null, attachmentPreparing: false, voiceState: 'idle', voiceList: [], search: '', songPage: 0, songsLoaded: false, onlineSongs: null, selectedSong: null, selectedPhoto: null, game: null, noticeTimer: null };
let page;
let header;
let messagesNode;
let composer;
let composerInput;
let voiceStatus;
let refreshPromise;
let songsPromise;
const chatImages = new Map();
let lastMessageSignature = '';
let attachmentGeneration = 0;
const today = new Date();
state.calendarMonth = new Date(today.getFullYear(), today.getMonth(), 1);
state.calendarDay = dayKey(today);
const views = ['chat', 'notebook', 'album', 'songs', 'settings', 'controls'];
const navViews = ['chat', 'notebook', 'album', 'songs', 'settings'];

function element(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(props)) {
    if (value === null || value === undefined) continue;
    if (name === 'text') node.textContent = String(value);
    else if (name === 'class') node.className = value;
    else if (name.startsWith('on') && typeof value === 'function') node.addEventListener(name.slice(2).toLowerCase(), value);
    else if (name in node && !name.startsWith('aria') && !name.startsWith('data')) node[name] = value;
    else node.setAttribute(name, String(value));
  }
  for (const child of [children].flat()) if (child !== null && child !== undefined) node.append(typeof child === 'string' ? document.createTextNode(child) : child);
  return node;
}
function button(label, handler, className = '', props = {}) {
  return element('button', { type: 'button', text: label, class: className, onclick: handler, ...props });
}
function localizedButton(key, handler, className = '', props = {}) { return button(t(key), handler, className, props); }
function field(label, input, hint) { return element('label', { class: 'field' }, [element('span', { text: label }), input, hint ? element('small', { text: hint, class: 'hint' }) : null]); }
function input(name, value, type = 'text', props = {}) { return element('input', { name, value: value ?? '', type, ...props }); }
function textarea(name, value, props = {}) { return element('textarea', { name, value: value ?? '', ...props }); }
function select(name, value, options, props = {}) {
  const node = element('select', { name, ...props }, options.map(([id, title]) => element('option', { value: id, text: title })));
  node.value = value ?? options[0]?.[0] ?? '';
  return node;
}
function check(name, value, label, hint) {
  return element('label', { class: 'check' }, [input(name, '', 'checkbox', { checked: Boolean(value) }), element('span', {}, [document.createTextNode(label), hint ? element('small', { class: 'hint', text: hint, style: 'display:block' }) : null])]);
}
function section(title, children, hint) { return element('section', { class: 'section' }, [element('h2', { text: title }), hint ? element('p', { text: hint, class: 'hint' }) : null, ...children]); }
function empty(text = t('empty')) { return element('div', { class: 'empty', text }); }
function formatDate(value) { return dateText(value, getLanguage()); }
function showNotice(text, error = false) {
  clearTimeout(state.noticeTimer);
  notice.textContent = String(text).slice(0, 600);
  notice.classList.toggle('error', error);
  notice.setAttribute('role', error ? 'alert' : 'status');
  notice.hidden = false;
  state.noticeTimer = setTimeout(() => { notice.hidden = true; }, error ? 10000 : 4500);
}
function errorText(error) {
  const raw = typeof error === 'string' ? error : error?.message || '';
  if (raw === 'voice-not-configured') return t('speechPrivacy');
  if (/voice-audio-missing|voice-playback-failed|voice-stream-invalid/.test(raw)) return t('operationFailed');
  return raw.slice(0, 600) || t('operationFailed');
}
function report(error) { showNotice(errorText(error), true); }
async function invoke(command, args = {}) {
  const bridge = window.__TAURI_INTERNALS__;
  if (!bridge?.invoke) throw new Error(t('connectionRequired'));
  return bridge.invoke(command, args);
}
async function action(name, payload = {}) {
  const result = await invoke('desktop_action', { action: name, payload });
  if (isSnapshot(result)) acceptSnapshot(result);
  return result;
}
async function platform(name, payload = {}) { return invoke('desktop_platform', { action: name, payload }); }
async function runButton(target, task, { refresh = true, refreshSongs = false, success = null } = {}) {
  if (target) target.disabled = true;
  try {
    const result = await task();
    if (refresh) { await loadSnapshot({ includeSongs: refreshSongs }); renderView(); }
    if (success) showNotice(success);
    return result;
  } catch (error) { report(error); return null; }
  finally { if (target?.isConnected) target.disabled = false; }
}
function acceptSnapshot(value) {
  state.snapshot = normalizeSnapshot(value, state.snapshot);
  if (value.games) state.game = gameResult(value.games);
  if (!value.songsOmitted) state.songsLoaded = true;
  if (!value.songsOmitted && state.onlineSongs) {
    const ids = new Set(state.onlineSongs.map(song => song.id));
    const favorites = new Map(state.snapshot.songs.filter(song => ids.has(song.id)).map(song => [song.id, Boolean(song.favorite)]));
    for (const song of state.onlineSongs) if (favorites.has(song.id)) song.favorite = favorites.get(song.id);
  }
  const images = new Set(state.snapshot.messages.filter(message => message.imageName).map(chatImageKey));
  for (const key of chatImages.keys()) if (!images.has(key)) chatImages.delete(key);
  const language = setLanguage(state.snapshot.settings.interfaceLanguage || 'auto');
  document.documentElement.lang = language;
}
async function loadSnapshot({ includeSongs = false } = {}) {
  if (includeSongs && songsPromise) return songsPromise;
  if (!includeSongs && refreshPromise) return refreshPromise;
  const request = invoke('desktop_snapshot', { includeSongs }).then(acceptSnapshot);
  if (includeSongs) {
    songsPromise = request.finally(() => { songsPromise = null; });
    return songsPromise;
  }
  refreshPromise = request.finally(() => { refreshPromise = null; });
  return refreshPromise;
}
async function confirmAction(title, detail = '', word = '', confirmLabel = 'delete') {
  const dialog = document.querySelector('#confirm-dialog');
  dialog.returnValue = 'cancel';
  document.querySelector('#confirm-title').textContent = title;
  document.querySelector('#confirm-detail').textContent = detail;
  document.querySelector('#confirm-cancel').textContent = t('cancel');
  document.querySelector('#confirm-ok').textContent = word ? t('resetMemory') : t(confirmLabel);
  const label = document.querySelector('#confirm-label');
  const wordInput = document.querySelector('#confirm-word');
  label.hidden = !word;
  wordInput.value = '';
  document.querySelector('#confirm-prompt').textContent = t('confirmReset');
  const ok = document.querySelector('#confirm-ok');
  ok.disabled = Boolean(word);
  wordInput.oninput = () => { ok.disabled = wordInput.value === '' || wordInput.value !== word; };
  return new Promise(resolve => {
    dialog.addEventListener('close', () => resolve(dialog.returnValue === 'ok' && (!word || wordInput.value === word)), { once: true });
    dialog.showModal();
    (word ? wordInput : document.querySelector('#confirm-cancel')).focus();
  });
}
function setRoute(view) { if (view === state.view) return; location.hash = view; }
function route() {
  const requested = location.hash.slice(1).split('/')[0] || new URLSearchParams(location.search).get('view') || 'chat';
  const next = views.includes(requested) ? requested : 'chat';
  if (!['chat', 'notebook'].includes(next)) stopRhythm();
  if (next !== 'chat' && (voice.calling || voice.listening)) void voice.stop();
  state.view = next;
  buildShell();
  renderView();
  if (next === 'songs' && !state.songsLoaded) void loadSnapshot({ includeSongs: true }).then(() => { if (state.view === 'songs') renderView(); }).catch(report);
}
function buildShell() {
  document.body.classList.toggle('controls-body', state.view === 'controls');
  document.documentElement.classList.toggle('controls-page', state.view === 'controls');
  app.replaceChildren();
  document.title = state.view === 'controls' ? 'Miku Desktop' : `${t(state.view)} · Miku Desktop`;
  if (state.view === 'controls') { renderControls(); return; }
  const nav = element('nav', { class: 'nav', 'aria-label': 'Miku Desktop' }, navViews.map(view => localizedButton(view, () => setRoute(view), '', { 'aria-current': view === state.view ? 'page' : 'false' })));
  const sidebar = element('aside', { class: 'sidebar' }, [element('div', { class: 'brand', text: 'MIKU ♪' }, [element('small', { text: 'DESKTOP COMPANION' })]), nav, element('div', { class: 'footer', text: 'Miku Desktop' })]);
  header = element('header', { class: 'page-header' }, [element('h1', { text: t(state.view) }), element('div', { class: 'actions' }, [localizedButton('refresh', event => void runButton(event.currentTarget, () => loadSnapshot({ includeSongs: state.view === 'songs' }), { refresh: false }).then(() => renderView()), 'small')])]);
  page = element('main', { class: `page ${state.view === 'chat' ? 'chat-page' : ''}`, id: 'main-content', tabIndex: -1 });
  app.append(element('div', { class: 'shell' }, [sidebar, element('div', { class: 'main' }, [header, page])]));
}
function renderView() {
  if (state.view === 'controls') return;
  if (!page) return;
  page.replaceChildren();
  messagesNode = null;
  const renderer = { chat: renderChat, settings: renderSettings, notebook: renderNotebook, album: renderAlbum, songs: renderSongs }[state.view];
  renderer?.();
}
const voice = new VoiceController({
  invoke, action, settings: () => state.snapshot.settings,
  onState: phase => { state.voiceState = phase; updateVoiceStatus(); },
  onText: (text, fromCall) => { if (fromCall) return; if (composerInput) { composerInput.value = [composerInput.value.trim(), text].filter(Boolean).join('\n'); composerInput.focus(); } },
  onReply: reply => { acceptGameReply(reply); void loadSnapshot().then(renderMessages).catch(report); },
  onError: report,
});

function renderChat() {
  voiceStatus = element('div', { class: 'call-status', hidden: state.voiceState === 'idle' });
  messagesNode = element('div', { class: 'messages', role: 'log', 'aria-live': 'polite', 'aria-relevant': 'additions', 'aria-label': t('chat') });
  composerInput = textarea('message', '', { placeholder: t('message'), 'aria-label': t('message'), rows: 2, maxLength: 12000 });
  composerInput.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) { event.preventDefault(); void sendChat(); }
  });
  composerInput.addEventListener('paste', event => {
    const file = imageFromTransfer(event.clipboardData);
    if (!file) return;
    event.preventDefault();
    void attachFile(file);
  });
  page.ondragover = event => {
    if (!Array.from(event.dataTransfer?.types || []).includes('Files')) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
    page.classList.add('drop-active');
  };
  page.ondragleave = event => { if (!page.contains(event.relatedTarget)) page.classList.remove('drop-active'); };
  page.ondrop = event => {
    page.classList.remove('drop-active');
    const files = transferFiles(event.dataTransfer);
    if (!files.length) return;
    event.preventDefault();
    void attachFile(imageFromTransfer(event.dataTransfer, false) || files[0]);
  };
  composer = element('form', { class: 'composer', onsubmit: event => { event.preventDefault(); void sendChat(); } });
  const attachInput = input('attachment', '', 'file', { accept: 'image/png,image/jpeg,image/webp', hidden: true });
  attachInput.addEventListener('change', () => { const file = attachInput.files?.[0]; attachInput.value = ''; void attachFile(file); });
  const attachPreview = element('div', { class: 'attachment', id: 'attachment-preview', hidden: !state.attachment });
  const voiceInput = localizedButton('listen', () => void voice.listenOnce(), 'small', { title: t('micHint'), 'aria-pressed': voice.listening });
  const callButton = localizedButton('call', () => {
    if (voice.calling) void voice.stop();
    else void voice.startCall();
  }, 'small', { title: t('micHint'), 'aria-pressed': voice.calling });
  const send = element('button', { type: 'submit', class: 'primary', text: t(state.pending ? 'sending' : 'send'), disabled: state.pending, id: 'send-message' });
  composer.append(attachPreview, composerInput, attachInput, element('div', { class: 'actions' }, [element('div', { class: 'left-actions' }, [localizedButton('attach', () => attachInput.click(), 'small'), voiceInput, callButton, localizedButton('stop', () => { void voice.stop(); if (state.pending) void action('chat_cancel').catch(report); }, 'small')]), send]), element('div', { class: 'hint', text: t('sendHint') }));
  page.append(voiceStatus, messagesNode, composer);
  renderMessages();
  renderAttachment();
  updateVoiceStatus();
}
function renderMessages() {
  if (!messagesNode || state.view !== 'chat') return;
  const messages = state.snapshot.messages;
  const signature = `${state.pending}:${JSON.stringify(state.snapshot.games?.current || null)}:` + messages.map(item => `${item.id || ''}:${item.role}:${messageText(item)}`).join('|');
  if (signature === lastMessageSignature && messagesNode.childElementCount) return;
  const stickToBottom = messagesNode.scrollHeight - messagesNode.scrollTop - messagesNode.clientHeight < 100;
  lastMessageSignature = signature;
  messagesNode.replaceChildren();
  if (!messages.length) messagesNode.append(element('div', { class: 'greeting' }, [element('div', { class: 'note', text: '♪', 'aria-hidden': 'true' }), element('h2', { text: t('greeting') }), element('p', { class: 'hint', text: t('greetingHint') })]));
  for (const message of messages) {
    const role = message.role === 'user' ? 'user' : 'assistant';
    const text = messageText(message);
    const bubble = element('div', { class: 'bubble', text });
    const image = imageSource(message.image || message.imageData);
    if (image) bubble.append(element('img', { src: image, alt: t('attach') }));
    else if (message.imageName) {
      const thumbnail = element('img', { alt: t('attach'), loading: 'lazy' });
      bubble.append(thumbnail);
      loadChatImage(message, thumbnail);
    }
    const actions = element('div', { class: 'message-actions' }, [localizedButton('copy', async () => {
      try { await navigator.clipboard.writeText(text); showNotice(t('copied')); } catch (error) { report(error); }
    }, 'small')]);
    if (role === 'assistant') actions.append(localizedButton('speak', event => void runButton(event.currentTarget, () => voice.speak(text, message.language), { refresh: false }), 'small'));
    messagesNode.append(element('article', { class: `message ${role}` }, [element('div', { class: 'sender', text: role === 'user' ? t('you') : 'Miku' }), bubble, actions]));
  }
  const game = state.game || gameResult(state.snapshot.games);
  if (game?.kind && !game.isOver) renderGames(messagesNode, false);
  if (state.pending) messagesNode.append(element('div', { class: 'hint', text: t('sending'), role: 'status' }));
  if (stickToBottom || messages.length <= 2) messagesNode.scrollTop = messagesNode.scrollHeight;
}
function chatImageKey(message) { return `${message.id}:${message.imageName}`; }
function imageThumbnail(source) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      try {
        const scale = Math.min(1, 440 / Math.max(image.naturalWidth, image.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        const context = canvas.getContext('2d');
        if (!context) throw new Error(t('unavailable'));
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        resolve(canvas.toDataURL('image/png'));
      } catch (error) { reject(error); }
    };
    image.onerror = () => reject(new Error(t('unavailable')));
    image.src = source;
  });
}
function loadChatImage(message, image) {
  const key = chatImageKey(message);
  let cached = chatImages.get(key);
  if (!cached) {
    cached = { source: null, failed: false, pending: null };
    chatImages.set(key, cached);
    cached.pending = action('chat_image', { id: message.id }).then(result => {
      const source = imageSource(result);
      if (!source) throw new Error(t('unavailable'));
      return imageThumbnail(source);
    }).then(source => { if (chatImages.get(key) === cached) cached.source = source; return source; }).catch(() => { cached.failed = true; return null; }).finally(() => { cached.pending = null; });
  }
  const show = source => { if (!image.isConnected) return; if (source) image.src = source; else image.alt = t('unavailable'); };
  if (cached.source) image.src = cached.source;
  else if (cached.failed) image.alt = t('unavailable');
  else void cached.pending.then(show);
}
async function sendChat() {
  const text = composerInput?.value.trim() || '';
  if (state.attachmentPreparing) { showNotice(t('loading')); return; }
  if ((!text && !state.attachment) || state.pending) return;
  state.pending = true;
  const image = state.attachment?.data || null;
  const draft = composerInput.value;
  composerInput.value = '';
  const submit = document.querySelector('#send-message');
  submit.disabled = true;
  submit.textContent = t('sending');
  try {
    if (voice.calling || voice.listening) await voice.stop();
    const reply = await invoke('desktop_send_message', { text, image });
    acceptGameReply(reply);
    state.attachment = null;
    renderAttachment();
    await loadSnapshot();
    renderMessages();
    if (reply.voiced === true && mayAutoSpeak(state.snapshot.settings)) void voice.speak(reply.text || reply.content || '', reply.language).catch(report);
    else await action('voice_ended', {}).catch(() => {});
  } catch (error) { composerInput.value = draft; report(error); }
  finally { state.pending = false; submit.disabled = false; submit.textContent = t('send'); renderMessages(); }
}
async function attachFile(file) {
  if (!file) return;
  const generation = ++attachmentGeneration;
  state.attachmentPreparing = false;
  const invalid = imageFileError(file);
  if (invalid) { report(t(invalid)); return; }
  state.attachmentPreparing = true;
  try {
    const source = await new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = () => reject(new Error(t('imageInvalid'))); reader.readAsDataURL(file); });
    if (!imageSource(source)) throw new Error(t('imageInvalid'));
    const data = await new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => {
        try {
          const dimensions = imageDimensions(image.naturalWidth, image.naturalHeight);
          const canvas = document.createElement('canvas');
          canvas.width = dimensions.width; canvas.height = dimensions.height;
          const context = canvas.getContext('2d');
          if (!context) throw new Error('imageInvalid');
          context.fillStyle = '#ffffff'; context.fillRect(0, 0, canvas.width, canvas.height);
          context.drawImage(image, 0, 0, canvas.width, canvas.height);
          resolve(canvas.toDataURL('image/jpeg', 0.82));
        } catch { reject(new Error(t('imageInvalid'))); }
      };
      image.onerror = () => reject(new Error(t('imageInvalid')));
      image.src = source;
    });
    if (!imageSource(data) || data.length * 3 / 4 > MAX_IMAGE_BYTES) throw new Error(t('imageTooLarge'));
    if (generation !== attachmentGeneration) return;
    state.attachment = { data, name: file.name || t('attach') };
    renderAttachment();
  } catch (error) { if (generation === attachmentGeneration) report(error); }
  finally { if (generation === attachmentGeneration) state.attachmentPreparing = false; }
}
function renderAttachment() {
  const preview = document.querySelector('#attachment-preview');
  if (!preview) return;
  preview.replaceChildren();
  preview.hidden = !state.attachment;
  if (state.attachment) preview.append(element('img', { src: state.attachment.data, alt: state.attachment.name }), element('span', { class: 'hint', text: state.attachment.name }), localizedButton('removeImage', () => { attachmentGeneration += 1; state.attachmentPreparing = false; state.attachment = null; renderAttachment(); }, 'small'));
}
function updateVoiceStatus() {
  if (!voiceStatus?.isConnected) return;
  const phase = state.voiceState;
  voiceStatus.hidden = phase === 'idle';
  voiceStatus.replaceChildren(element('span', { class: 'call-dot', 'aria-hidden': 'true' }), element('span', { text: t({ listening: 'listening', speaking: 'callSpeaking', thinking: 'callThinking' }[phase] || 'call') }), ...(voice.calling && ['thinking', 'speaking'].includes(phase) ? [localizedButton('interruptAndListen', () => void voice.interruptAndListen().catch(report), 'small')] : []), localizedButton(voice.calling ? 'callStop' : 'stop', () => void voice.stop(), 'small'));
}

function settingsForm(title, children, onSave) {
  const form = element('form', { onsubmit: event => { event.preventDefault(); const submit = event.currentTarget.querySelector('[type=submit]'); void runButton(submit, async () => { await onSave(settingsValues(form)); }, { success: t('saved') }); } }, [...children, element('div', { class: 'actions end' }, [element('button', { type: 'submit', class: 'primary', text: t('save') })])]);
  return section(title, [form]);
}
function settingsValues(form) { const patch = buildSettingsPatch(form); form.querySelectorAll('[type=password]').forEach(input => { input.value = ''; }); return patch; }
async function saveSettings(patch) { const snapshot = await invoke('desktop_update_settings', { patch }); if (isSnapshot(snapshot)) acceptSnapshot(snapshot); }
function renderSettings() {
  const s = state.snapshot.settings;
  const provider = select('aiProvider', s.aiProvider || 'local', [['local', t('local')], ['cloud', t('cloud')]]);
  const localFields = element('div', {}, [field(`Ollama ${t('endpoint')}`, input('endpoint', s.endpoint || 'http://127.0.0.1:11434/v1', 'url', { placeholder: 'http://127.0.0.1:11434/v1', required: true })), field(t('model'), input('model', s.model, 'text', { placeholder: 'qwen3.5:4b' }))]);
  const cloudFields = element('div', {}, [field(t('endpoint'), input('cloudEndpoint', s.cloudEndpoint, 'url', { placeholder: 'https://…/v1' })), field(t('model'), input('cloudModel', s.cloudModel)), field(t('apiKey'), input('cloudApiKey', '', 'password', { autocomplete: 'new-password', placeholder: t('keepKey'), maxLength: 4096 }), s.cloudApiKeyPresent ? t('keySaved') : t('keepKey')), s.cloudApiKeyPresent ? check('clearCloudApiKey', false, t('clearKey')) : null, element('p', { class: 'hint', text: t('cloudPrivacy') })]);
  const connectionStatus = element('div', { class: 'status', role: 'status' });
  const aiFields = [field(t('aiProvider'), provider), localFields, cloudFields, element('div', { class: 'actions' }, [localizedButton('connect', event => void runButton(event.currentTarget, async () => { await saveSettings(settingsValues(provider.form)); const result = await action('ai_models'); connectionStatus.textContent = result?.message || t('connected'); }, { refresh: false })), localizedButton('models', event => void runButton(event.currentTarget, async () => { await saveSettings(settingsValues(provider.form)); const result = await action('ai_models'); const models = asList(result?.models || result?.data || result); connectionStatus.textContent = models.map(model => typeof model === 'string' ? model : model.id || model.name).join('\n') || t('empty'); }, { refresh: false }))]), connectionStatus];
  function updateProvider() { localFields.hidden = provider.value === 'cloud'; cloudFields.hidden = provider.value !== 'cloud'; localFields.querySelectorAll('input').forEach(node => { node.disabled = localFields.hidden; }); cloudFields.querySelectorAll('input').forEach(node => { node.disabled = cloudFields.hidden; }); }
  provider.addEventListener('change', updateProvider);
  page.append(settingsForm(t('ai'), aiFields, saveSettings));
  updateProvider();
  page.append(settingsForm(t('songs'), [check('vocadb.lookupEnabled', s['vocadb.lookupEnabled'], t('onlineLookup')), check('songPreferenceMemory', s.songPreferenceMemory, t('rememberSongs')), field(`AIMCP ${t('apiKey')}`, input('aimcpApiKey', '', 'password', { autocomplete: 'new-password', placeholder: t('keepKey'), maxLength: 4096 }), s.aimcpApiKeyPresent ? t('keySaved') : t('keepKey')), s.aimcpApiKeyPresent ? check('clearAimcpApiKey', false, t('clearKey')) : null], saveSettings));
  page.append(settingsForm(t('language'), [field(t('uiLanguage'), select('interfaceLanguage', s.interfaceLanguage || 'auto', languages)), field(t('replyLanguage'), select('replyLanguage', s.replyLanguage || 'auto', spokenLanguages))], async patch => { await saveSettings(patch); buildShell(); }));
  const persona = select('personalityPreset', s.personalityPreset || 'lively', ['lively', 'gentle', 'quiet', 'custom'].map(key => [key, t(key)]));
  const custom = field(t('customPersona'), textarea('customPersonality', s.customPersonality, { maxLength: 1600 }));
  persona.addEventListener('change', () => { custom.hidden = persona.value !== 'custom'; });
  custom.hidden = persona.value !== 'custom';
  page.append(settingsForm(t('persona'), [field(t('nickname'), input('nickname', s.nickname, 'text', { maxLength: 80 })), field(t('persona'), persona), custom, check('memoryEnabled', s.memoryEnabled !== false, t('memoryEnabled'))], saveSettings));
  const tts = select('speechProvider', s.speechProvider || (s.ttsProvider === 'local' ? 'local' : 'system'), [['system', t('windowsVoice')], ['local', t('localTTS')]]);
  const nativeVoices = [['', t('auto')], ...state.voiceList.map(voice => [voice.id, `${voice.name} · ${voice.language || ''}`])];
  if (s.speechVoice && !nativeVoices.some(([id]) => id === s.speechVoice)) nativeVoices.push([s.speechVoice, s.speechVoice]);
  const native = field(t('voice'), select('speechVoice', s.speechVoice || '', nativeVoices));
  const localTTS = element('div', {}, [field(t('endpoint'), input('ttsEndpoint', s.ttsEndpoint || '', 'url', { placeholder: 'http://127.0.0.1:…/v1' })), field(t('voiceModel'), input('ttsModel', s.ttsModel || '')), field(t('voice'), input('ttsVoice', s.ttsVoice || ''))]);
  const voiceFields = [check('speechEnabled', s.speechEnabled, t('speechEnabled')), check('speechRepliesOnly', s.speechRepliesOnly !== false, t('speechRepliesOnly')), field(t('speechProvider'), tts), field(t('recognitionLanguage'), select('speechRecognitionLanguage', s.speechRecognitionLanguage || 'auto', spokenLanguages)), native, localTTS, element('p', { class: 'hint', text: t('speechPrivacy') }), check('speechQuietEnabled', s.speechQuietEnabled !== false, t('quietEnabled')), element('div', { class: 'columns' }, [field(t('quietStart'), input('quietStart', s.quietStart || '23:00', 'time')), field(t('quietEnd'), input('quietEnd', s.quietEnd || '08:00', 'time'))]), localizedButton('refresh', event => void runButton(event.currentTarget, async () => { const result = await platform('voices'); state.voiceList = asList(result?.voices); }, { refresh: true }), 'small')];
  function updateVoice() { native.hidden = tts.value !== 'system'; localTTS.hidden = tts.value !== 'local'; localTTS.querySelectorAll('input').forEach(node => { node.disabled = localTTS.hidden; }); native.querySelector('select').disabled = native.hidden; }
  tts.addEventListener('change', updateVoice);
  page.append(settingsForm(t('speech'), voiceFields, saveSettings));
  updateVoice();
  page.append(settingsForm(t('awareness'), [check('awarenessActivity', s.awarenessActivity, t('awarenessActivity')), check('awarenessMedia', s.awarenessMedia, t('awarenessMedia')), check('awarenessScreen', s.awarenessScreen, t('awarenessScreen')), check('awarenessRandom', s.awarenessRandom, t('awarenessRandom')), check('cloudSharesAwareness', s.cloudSharesAwareness, t('shareAwareness')), element('p', { class: 'hint', text: t('awarenessPrivacy') })], saveSettings));
  page.append(settingsForm(t('sleep'), [check('sleepEnabled', s.sleepEnabled !== false, t('sleepEnabled')), element('div', { class: 'columns' }, [field(t('bedtime'), input('sleepStartHour', clockValue(s.sleepStartHour, s.quietStart || '01:00'), 'time')), field(t('wakeTime'), input('sleepEndHour', clockValue(s.sleepEndHour, s.quietEnd || '07:00'), 'time'))])], saveSettings));
  const weatherStatus = element('div', { class: 'status', role: 'status' });
  page.append(settingsForm(t('weather'), [element('p', { class: 'hint', text: t('weatherHint') }), element('div', { class: 'columns' }, [field(t('latitude'), input('latitude', s.latitude ?? '', 'number', { min: -90, max: 90, step: 'any' })), field(t('longitude'), input('longitude', s.longitude ?? '', 'number', { min: -180, max: 180, step: 'any' }))]), weatherStatus], async patch => { await saveSettings(patch); const result = await platform('weather', patch); weatherStatus.textContent = `${result.temperature ?? '—'} °C · ${result.kind || ''}`; }));
  page.append(settingsForm(t('desktop'), [check('interactiveMode', s.interactiveMode !== false, t('interactive')), check('fullMotion', s.fullMotion, t('fullMotion'), t('restartHint')), field(t('scene'), select('selectedScene', s.selectedScene || 'auto', [['auto', t('auto')], ...['shibuya', 'ikebukuro', 'akihabara', 'shinjuku', 'hallway', 'room', 'musicroom'].map(id => [id, t(id)])])), check('ambientEnabled', s.ambientEnabled !== false, t('ambient')), field(t('rotation'), input('sceneRotationSeconds', s.sceneRotationSeconds || 180, 'number', { min: 30, max: 3600, step: 10 })), element('div', { class: 'actions' }, [localizedButton('resetPosition', event => void runButton(event.currentTarget, () => action('reset_position'), { refresh: false }), 'small'), localizedButton('reload', event => void runButton(event.currentTarget, () => action('reload'), { refresh: false }), 'small'), localizedButton('restart', event => void runButton(event.currentTarget, () => action('restart'), { refresh: false }), 'small'), localizedButton('comeOver', event => void runButton(event.currentTarget, () => action('come_over'), { refresh: false }), 'small')])], saveSettings));
  const tdaStatus = element('div', { class: 'status', role: 'status' });
  page.append(section(t('character'), [element('p', { class: 'hint', text: t('tdaHint') }), element('div', { class: 'actions' }, [localizedButton('importTda', event => void runButton(event.currentTarget, async () => { const selected = await platform('pick_tda'); const path = typeof selected === 'string' ? selected : selected?.path; if (!path) return; const result = await platform('import_tda', { path }); tdaStatus.textContent = result?.imported ? t('saved') : result?.message || t('operationFailed'); }, { refresh: false })), localizedButton('authorPage', () => void openURL('https://bowlroll.net/file/16344'), 'small')]), tdaStatus]));
  const general = element('form', {}, [check('launchAtLogin', s.launchAtLogin, t('launchAtLogin'))]);
  general.querySelector('input').addEventListener('change', event => {
    const target = event.target;
    void runButton(target, async () => {
      try { await saveSettings({ launchAtLogin: target.checked }); }
      catch (error) { target.checked = !target.checked; throw error; }
    }, { refresh: false });
  });
  const updateStatus = element('div', { class: 'status', role: 'status' });
  page.append(section(t('general'), [general, element('div', { class: 'actions' }, [localizedButton('updates', event => void runButton(event.currentTarget, async () => { const result = await platform('update_check'); const url = safeSourceURL(result.url || result.htmlUrl || result.releaseURL); updateStatus.replaceChildren(document.createTextNode(result.message || result.version || t('noRelease'))); if (url) updateStatus.append(document.createTextNode(' '), localizedButton('source', () => void openURL(url), 'small')); }, { refresh: false })), localizedButton('openData', event => void runButton(event.currentTarget, () => platform('open_data'), { refresh: false }))]), updateStatus]));
}

function renderNotebook() {
  const tabs = ['diary', 'notes', 'profile', 'memory', 'specialDays', 'games'];
  page.append(element('div', { class: 'tabs', role: 'tablist' }, tabs.map(tab => localizedButton(tab, () => { state.tab = tab; renderView(); }, '', { role: 'tab', 'aria-selected': state.tab === tab }))));
  ({ diary: renderDiary, notes: renderNotes, profile: renderProfile, memory: renderMemory, specialDays: renderSpecialDays, games: renderGames }[state.tab] || renderDiary)();
}
function renderDiary() {
  page.append(element('div', { class: 'toolbar' }, [localizedButton('generateDiary', event => void runButton(event.currentTarget, () => action('diary_generate')), 'primary')]), element('p', { class: 'hint', text: t('diaryHint') }));
  if (!state.snapshot.diary.length) { page.append(empty()); return; }
  const list = element('div', { class: 'list' });
  for (const [index, entry] of state.snapshot.diary.entries()) {
    list.append(element('article', { class: 'card' }, [element('h3', { text: entry.title || entry.day || entry.day || entry.date || formatDate(entry.createdAt) }), element('p', { class: 'metadata', text: entry.day || entry.date || formatDate(entry.createdAt || entry.written || entry.timestamp) }), element('p', { text: entry.text || entry.content || entry.body || '' }), element('div', { class: 'actions' }, [localizedButton('delete', async event => { if (await confirmAction(t('deleteConfirm'))) void runButton(event.currentTarget, () => action('diary_delete', { id: itemId(entry, index) })); }, 'small danger')])]));
  }
  page.append(list);
}
function renderNotes() {
  const title = input('title', '', 'text', { placeholder: t('noteTitle'), maxLength: 120 });
  const body = textarea('text', '', { placeholder: t('noteText'), required: true, maxLength: 20000 });
  let selectedId = null;
  const form = element('form', { onsubmit: event => { event.preventDefault(); void runButton(form.querySelector('[type=submit]'), () => action('notes_save', { id: selectedId, title: title.value.trim(), text: body.value.trim() }), { success: t('saved') }); } }, [field(t('title'), title), field(t('content'), body), element('div', { class: 'actions' }, [element('button', { type: 'submit', class: 'primary', text: t('save') }), localizedButton('cancel', () => { selectedId = null; form.reset(); })])]);
  const list = element('div', { class: 'list' });
  for (const [index, note] of state.snapshot.notes.entries()) {
    list.append(element('article', { class: 'card' }, [element('h3', { text: note.title || t('notes') }), element('p', { text: note.text || note.content || '' }), element('p', { class: 'metadata', text: formatDate(note.updatedAt || note.updated || note.createdAt || note.created || note.date) }), element('div', { class: 'actions' }, [localizedButton('edit', () => { selectedId = itemId(note, index); title.value = note.title || ''; body.value = note.text || note.content || ''; title.focus(); }, 'small'), localizedButton('delete', async event => { if (await confirmAction(t('deleteConfirm'))) void runButton(event.currentTarget, () => action('notes_delete', { id: itemId(note, index) })); }, 'small danger')])]));
  }
  if (!state.snapshot.notes.length) list.append(empty());
  page.append(element('div', { class: 'split' }, [section(t('notes'), [form]), list]));
}
function renderProfile() {
  const p = state.snapshot.profile;
  const form = element('form', { onsubmit: event => { event.preventDefault(); const data = buildSettingsPatch(form); data.facts = splitLines(data.facts); void runButton(form.querySelector('[type=submit]'), () => action('profile_save', data), { success: t('saved') }); } }, [field(t('name'), input('name', p.name || state.snapshot.settings.nickname || '', 'text', { maxLength: 80 })), field(t('birthday'), input('birthday', p.birthday || '', 'date')), element('div', { class: 'columns' }, [field(t('likes'), textarea('likes', listText(p.likes)), t('lineHint')), field(t('dislikes'), textarea('dislikes', listText(p.dislikes)), t('lineHint'))]), field(t('facts'), textarea('facts', listText(p.facts)), t('lineHint')), element('div', { class: 'actions end' }, [element('button', { type: 'submit', class: 'primary', text: t('save') })])]);
  page.append(section(t('profile'), [form], t('localData')));
}
function renderMemory() {
  const profile = state.snapshot.profile;
  const friendship = Number(profile.friendship ?? profile.affection ?? 0);
  const facts = asList(profile.facts || state.snapshot.facts || state.snapshot.memory?.facts);
  const list = element('div', { class: 'list' });
  for (const [index, fact] of facts.entries()) {
    const text = typeof fact === 'string' ? fact : fact.text || fact.value || fact.content || '';
    list.append(element('div', { class: 'fact' }, [element('span', { text }), localizedButton('forget', async event => { if (await confirmAction(t('forget'), text)) void runButton(event.currentTarget, () => action('memory_forget', { id: typeof fact === 'string' ? String(index) : itemId(fact, index) })); }, 'small danger')]));
  }
  if (!facts.length) list.append(empty());
  page.append(section(t('memory'), [element('div', { class: 'toolbar' }, [element('span', { class: 'badge', text: t(profile.status === 'dating' ? 'dating' : 'friends') }), element('span', { text: `${t('friendship')} ${Math.max(0, Math.min(100, friendship))}/100` })]), element('progress', { max: 100, value: Math.max(0, Math.min(100, friendship)), 'aria-label': t('friendship') }), profile.offended ? element('p', { class: 'hint', text: t('offended') }) : null, list, element('div', { class: 'actions' }, [localizedButton('clearChat', async event => { if (await confirmAction(t('clearChat'), t('clearChatDetail'), '', 'clearChat')) void runButton(event.currentTarget, () => action('memory_clear_chat')); }, 'danger'), localizedButton('resetMemory', async event => { if (await confirmAction(t('resetMemory'), t('resetDetail'), 'RESET')) void runButton(event.currentTarget, () => action('memory_reset', { confirmation: 'RESET' })); }, 'danger'), localizedButton('restoreMemory', async event => { if (await confirmAction(t('restoreMemory'), t('restoreDetail'), '', 'restoreMemory')) void runButton(event.currentTarget, () => action('memory_restore')); })])], t('localData')));
}
function gameResult(value) {
  if (!value) return null;
  if (typeof value.game === 'string') return { ...value.state, ...value, kind: value.game };
  const current = value.games?.current || value.current || value.game || value;
  const last = value.games?.lastLine || value.lastLine || {};
  return { ...current, ...last, kind: current.kind || current.type, choices: last.choices || current.choices || current.question?.options?.map((title, index) => ({ id: String(index), title })) || [] };
}
function acceptGameReply(reply) {
  if (typeof reply?.game !== 'string') return;
  state.game = gameResult(reply);
  if (state.game.kind === 'rhythm' && !state.game.isOver) { prepareRhythm(); startRhythm(); }
}
function renderGames(target = page, showPicker = true) {
  const current = state.game || gameResult(state.snapshot.games);
  if (!current?.kind && !current?.text && !current?.choices?.length) {
    if (showPicker) renderGamePicker();
    return;
  }
  const card = section(t(current.kind || 'games'), [element('div', { class: 'game-result', text: current.text || current.message || '' }), current.score !== undefined ? element('p', { class: 'game-score', text: `${t('score')} ${current.score}` }) : null]);
  const choices = asList(current.choices);
  const choiceRow = element('div', { class: 'game-choices' });
  for (const [index, choice] of choices.entries()) {
    const id = typeof choice === 'string' ? choice : choice.value ?? choice.id ?? index;
    const title = typeof choice === 'string' ? choice : choice.title || choice.text || choice.label || String(id);
    choiceRow.append(button(title, event => void runButton(event.currentTarget, async () => { state.game = gameResult(await action('games_play', { choice: String(id) })); }), 'primary'));
  }
  if (!choices.length && current.kind === 'rps' && !current.isOver) {
    for (const choice of ['rock', 'scissors', 'paper']) choiceRow.append(localizedButton(choice, event => void runButton(event.currentTarget, async () => { state.game = gameResult(await action('games_play', { choice })); }), 'primary'));
  }
  if (current.kind === 'rhythm' && !current.isOver) {
    card.append(element('div', { class: 'game-score', id: 'rhythm-count', role: 'status', text: '♪' }));
    const grade = element('span', { class: 'game-score', role: 'status', 'aria-live': 'polite', text: current.lastGrade ? t(current.lastGrade) : '' });
    const pad = localizedButton('tap', event => void runButton(event.currentTarget, async () => {
      state.game = gameResult(await action('games_play', { elapsedSeconds: (performance.now() - state.rhythmStart) / 1000 }));
      grade.textContent = state.game?.lastGrade ? t(state.game.lastGrade) : '';
    }, { refresh: false }), 'primary');
    pad.addEventListener('keydown', event => { if (event.code === 'Space') { event.preventDefault(); if (!event.repeat) pad.click(); } });
    choiceRow.append(pad, grade);
    requestAnimationFrame(() => { if (pad.isConnected) pad.focus({ preventScroll: true }); });
  }
  card.append(choiceRow, element('div', { class: 'actions' }, [localizedButton('endGame', event => void runButton(event.currentTarget, async () => { stopRhythm(); await action('games_stop'); state.game = null; }), 'small')]));
  target.append(card);
  if (current.isOver && showPicker) renderGamePicker();
}


function clockValue(value, fallback) { return typeof value === 'number' ? `${String(value).padStart(2, '0')}:00` : value || fallback; }
function dayKey(date) { return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`; }
function renderSpecialDays() {
  const dates = state.snapshot.specialDays || {};
  const seen = new Set();
  const entries = [...asList(dates.all), ...asList(dates.today), ...asList(dates.upcoming), ...asList(dates.known)].filter(entry => {
    const key = `${entry.key || entry.kind}:${entry.start || entry.date}:${entry.end || ''}:${entry.city || ''}:${entry.venue || ''}`;
    if (seen.has(key)) return false;
    seen.add(key); return true;
  });
  const month = state.calendarMonth;
  const title = month.toLocaleDateString(getLanguage(), { year: 'numeric', month: 'long' });
  const moveMonth = offset => { state.calendarMonth = new Date(month.getFullYear(), month.getMonth() + offset, 1); state.calendarDay = dayKey(state.calendarMonth); renderView(); };
  page.append(element('div', { class: 'toolbar' }, [localizedButton('previousMonth', () => moveMonth(-1), 'small'), element('strong', { text: title }), localizedButton('nextMonth', () => moveMonth(1), 'small'), localizedButton('today', () => { const now = new Date(); state.calendarMonth = new Date(now.getFullYear(), now.getMonth(), 1); state.calendarDay = dayKey(now); renderView(); }, 'small'), localizedButton('updateEvents', event => void runButton(event.currentTarget, () => action('events_refresh')), 'small')]));
  const week = element('tr');
  for (let day = 0; day < 7; day++) week.append(element('th', { scope: 'col', text: new Date(2026, 10, 1 + day).toLocaleDateString(getLanguage(), { weekday: 'short' }) }));
  const body = element('tbody');
  const first = new Date(month.getFullYear(), month.getMonth(), 1 - month.getDay());
  for (let row = 0; row < 6; row++) {
    const tr = element('tr');
    for (let col = 0; col < 7; col++) {
      const date = new Date(first.getFullYear(), first.getMonth(), first.getDate() + row * 7 + col);
      const key = dayKey(date);
      const events = entries.filter(entry => (entry.start || entry.date) <= key && (entry.end || entry.start || entry.date) >= key);
      const label = [date.toLocaleDateString(getLanguage(), { month: 'long', day: 'numeric', weekday: 'long' }), ...events.map(entry => t(entry.key === 'birthday' ? 'mikuBirthday' : entry.key || entry.kind || 'specialDays'))].join(' · ');
      tr.append(element('td', {}, [button(String(date.getDate()) + (events.length ? ' ♪' : ''), () => { state.calendarDay = key; state.calendarMonth = new Date(date.getFullYear(), date.getMonth(), 1); renderView(); }, date.getMonth() === month.getMonth() ? '' : 'outside-month', { 'aria-label': label, 'aria-pressed': state.calendarDay === key, 'aria-current': key === dayKey(new Date()) ? 'date' : null })]));
    }
    body.append(tr);
  }
  page.append(element('table', { class: 'calendar' }, [element('caption', { class: 'sr-only', text: title }), element('thead', {}, [week]), body]));
  page.append(element('h2', { class: 'calendar-selection', text: state.calendarDay }));
  const selected = entries.filter(entry => (entry.start || entry.date) <= state.calendarDay && (entry.end || entry.start || entry.date) >= state.calendarDay);
  if (!selected.length) page.append(empty(t('noEvents')));
  for (const entry of selected) {
    const label = entry.title || t(entry.key === 'birthday' ? 'mikuBirthday' : entry.key || entry.kind || 'specialDays');
    page.append(element('article', { class: 'card' }, [element('h3', { text: label }), element('p', { class: 'metadata', text: [entry.start || entry.date, entry.end && entry.end !== entry.start ? entry.end : '', entry.city, entry.venue].filter(Boolean).join(' · ') }), entry.source ? localizedButton('source', () => void openURL(entry.source), 'small') : null]));
  }
}
function renderGamePicker() {
  for (const kind of ['rps', 'quiz', 'rhythm']) {
    page.append(section(t(kind), [localizedButton('startGame', event => void runButton(event.currentTarget, async () => {
      if (kind === 'rhythm') prepareRhythm(); else stopRhythm();
      let result;
      try { result = await action('games_start', { kind }); }
      catch (error) { stopRhythm(); throw error; }
      state.game = gameResult(result);
      if (kind === 'rhythm') startRhythm();
    }), 'primary')]));
  }
}
function prepareRhythm() {
  stopRhythm();
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (AudioContext) { state.rhythmAudio = new AudioContext(); void state.rhythmAudio.resume().catch(() => {}); }
}
function startRhythm() {
  state.rhythmStart = performance.now() + 400;
  const interval = 60 / 104;
  const context = state.rhythmAudio;
  if (context) {
    const start = context.currentTime + 0.4;
    for (let beat = 0; beat < 20; beat++) {
      const tone = context.createOscillator();
      const gain = context.createGain();
      tone.frequency.value = beat < 4 || beat % 4 === 0 ? 1000 : 700;
      gain.gain.setValueAtTime(0.1, start + beat * interval);
      gain.gain.exponentialRampToValueAtTime(0.001, start + beat * interval + 0.065);
      tone.connect(gain); gain.connect(context.destination);
      tone.start(start + beat * interval); tone.stop(start + beat * interval + 0.07);
    }
  }
  state.rhythmTimer = setInterval(() => {
    const elapsed = (performance.now() - state.rhythmStart) / 1000;
    const beat = Math.floor(elapsed / interval);
    const count = document.querySelector('#rhythm-count');
    if (count) count.textContent = beat < 0 ? '♪' : beat < 4 ? String(4 - beat) : `${Math.min(16, beat - 3)} / 16`;
    if (elapsed >= 20 * interval) {
      clearInterval(state.rhythmTimer); state.rhythmTimer = null;
      void action('games_play', { finish: true }).then(result => { state.game = gameResult(result); void loadSnapshot().then(renderView); }).catch(report).finally(stopRhythm);
    }
  }, 60);
}
function stopRhythm() {
  clearInterval(state.rhythmTimer); state.rhythmTimer = null;
  if (state.rhythmAudio) { void state.rhythmAudio.close().catch(() => {}); state.rhythmAudio = null; }
}

function renderAlbum() {
  page.append(element('div', { class: 'toolbar' }, [localizedButton('takePhoto', event => void runButton(event.currentTarget, () => action('album_capture')), 'primary')]));
  if (state.selectedPhoto) { renderPhotoDetail(state.selectedPhoto); return; }
  if (!state.snapshot.album.length) { page.append(empty()); return; }
  const grid = element('div', { class: 'album-grid' });
  for (const [index, photo] of state.snapshot.album.entries()) {
    const id = itemId(photo, index);
    const image = element('img', { alt: photo.title || t('album'), loading: 'lazy' });
    const preview = imageSource(photo.thumbnail || photo.image || photo.dataURL);
    if (preview) image.src = preview;
    else void action('album_image', { id }).then(result => { const src = imageSource(result); if (src && image.isConnected) image.src = src; }).catch(() => { image.alt = t('unavailable'); });
    const open = () => { state.selectedPhoto = photo; renderView(); };
    const card = element('article', { class: 'card photo-card' }, [image, element('div', { class: 'photo-info' }, [element('h3', { text: photo.title || t('together') }), element('p', { class: 'metadata', text: formatDate(photo.capturedAt || photo.createdAt || photo.created || photo.timestamp || photo.date) }), element('p', { text: photo.note || '' }), button(t('edit'), open, 'small')])]);
    grid.append(card);
  }
  page.append(grid);
}
function renderPhotoDetail(photo) {
  const id = itemId(photo);
  const image = element('img', { alt: photo.title || t('album'), style: 'max-width:100%;max-height:45vh;object-fit:contain;border-radius:10px' });
  void action('album_image', { id }).then(result => { const src = imageSource(result); if (src && image.isConnected) image.src = src; }).catch(report);
  const title = input('title', photo.title || '', 'text', { maxLength: 120 });
  const note = textarea('note', photo.note || '', { maxLength: 2000 });
  const category = select('category', photo.category || 'everyday', ['everyday', 'firstMeeting', 'birthday', 'achievement'].map(key => [key, t(key)]));
  const form = element('form', { onsubmit: event => { event.preventDefault(); void runButton(form.querySelector('[type=submit]'), async () => { await action('album_save', { id, title: title.value.trim(), note: note.value.trim(), category: category.value }); state.selectedPhoto = null; }, { success: t('saved') }); } }, [image, field(t('photoTitle'), title), field(t('photoNote'), note), field(t('category'), category), element('div', { class: 'actions' }, [element('button', { type: 'submit', class: 'primary', text: t('save') }), localizedButton('export', event => void runButton(event.currentTarget, async () => { const result = await action('album_export', { id }); if (result?.saved || result?.path && !result.cancelled) showNotice(t('saved')); }, { refresh: false })), localizedButton('delete', async event => { if (await confirmAction(t('deleteConfirm'))) void runButton(event.currentTarget, async () => { await action('album_delete', { id }); state.selectedPhoto = null; }); }, 'danger'), localizedButton('cancel', () => { state.selectedPhoto = null; renderView(); })])]);
  page.append(section(t('album'), [form]));
}
async function openURL(candidate) {
  const url = safeSourceURL(candidate);
  if (!url) { report(t('invalidURL')); return; }
  try { await platform('open_url', { url }); } catch (error) { report(error); }
}

function renderSongs() {
  const search = input('query', state.search, 'search', { placeholder: t('search'), 'aria-label': t('search'), maxLength: 200 });
  let list = element('div', { class: 'list' });
  const inputFile = input('song-import', '', 'file', { accept: '.json,application/json', hidden: true });
  inputFile.addEventListener('change', async () => {
    const file = inputFile.files?.[0];
    if (!file) return;
    if (file.size > 1024 * 1024) { report(t('importInvalid')); return; }
    try { const document = JSON.parse(await file.text()); await action('songs_import', { document }); await loadSnapshot({ includeSongs: true }); state.onlineSongs = null; state.songPage = 0; renderView(); showNotice(t('saved')); } catch (error) { report(error); }
  });
  const toolbar = element('form', { class: 'toolbar', onsubmit: event => { event.preventDefault(); void runButton(toolbar.querySelector('[type=submit]'), async () => { const result = await action('songs_vocadb', { query: search.value.trim() }); state.onlineSongs = asList(result?.songs || result?.entries || result?.items || result); state.search = search.value.trim(); state.songPage = 0; }, { refresh: true }); } }, [search, element('button', { type: 'submit', text: t('onlineSearch') }), localizedButton('add', () => { state.selectedSong = {}; renderSongEditor(); }), localizedButton('updateCatalog', event => void runButton(event.currentTarget, () => action('songs_update'), { refreshSongs: true, success: t('saved') }), 'small'), inputFile, localizedButton('import', () => inputFile.click(), 'small'), localizedButton('export', event => void runButton(event.currentTarget, async () => { const result = await action('songs_export'); if (result?.saved || result?.path && !result.cancelled) showNotice(t('saved')); }, { refresh: false }), 'small')]);
  const pagination = element('nav', { class: 'toolbar song-pagination', 'aria-label': t('pagination') });
  const renderList = () => {
    list.replaceChildren();
    pagination.replaceChildren();
    const query = state.search;
    const result = songPage(state.onlineSongs || state.snapshot.songs, state.onlineSongs ? '' : query, state.songPage);
    state.songPage = result.page;
    const changePage = offset => { state.songPage += offset; renderList(); page.scrollTop = 0; };
    pagination.append(localizedButton('previousPage', () => changePage(-1), 'small', { disabled: result.page === 0 }), element('span', { class: 'metadata', role: 'status', 'aria-live': 'polite', text: `${result.total ? result.start + 1 : 0}–${result.end} / ${result.total} · ${t('page')} ${result.page + 1}/${result.pages}` }), localizedButton('nextPage', () => changePage(1), 'small', { disabled: result.page + 1 >= result.pages }));
    for (const [index, song] of result.items.entries()) {
      const id = itemId(song, result.start + index);
      const card = element('article', { class: 'card song-result', tabIndex: 0 }, [element('h3', { text: songTitle(song) }), element('p', { class: 'metadata', text: listText(song.creators || song.artist || song.producer).replaceAll('\n', ' · ') }), element('p', { text: songDescription(song, getLanguage()) }), element('div', { class: 'actions' }, [localizedButton('edit', () => { state.selectedSong = song; renderSongEditor(); }, 'small'), song.kind === 'song' && song.sourceStatus !== 'online' ? localizedButton('favorite', event => void runButton(event.currentTarget, () => action('songs_favorite', { id, favorite: !song.favorite }), { refreshSongs: true, success: t('saved') }), 'small', { 'aria-pressed': Boolean(song.favorite) }) : null, song.sourceURL || song.url ? localizedButton('source', () => void openURL(song.sourceURL || song.url), 'small') : null])]);
      list.append(card);
    }
    if (!result.total) list.append(empty(query ? t('noResults') : t('empty')));
  };
  let searchTimer;
  search.addEventListener('input', () => {
    state.search = search.value; state.onlineSongs = null; state.songPage = 0;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { if (list.isConnected) renderList(); }, 120);
  });
  page.append(toolbar, element('p', { class: 'hint', text: t('lyricsHint') }), pagination, list);
  renderList();
  if (state.selectedSong) renderSongEditor();
}
function renderSongEditor() {
  const old = document.querySelector('#song-editor');
  old?.remove();
  const song = state.selectedSong || {};
  const title = input('title', songTitle(song), 'text', { required: true, maxLength: 200 });
  const creators = textarea('creators', listText(song.creators || song.producer), { maxLength: 1500 });
  const aliases = textarea('aliases', listText(song.aliases), { maxLength: 1500 });
  const content = textarea('content', songDescription(song, getLanguage()), { maxLength: 10000 });
  const source = input('sourceURL', song.sourceURL || song.url || '', 'url', { required: true });
  const kind = select('kind', song.kind || 'song', [['song', t('song')], ['performance', t('performance')], ['character', t('character')]]);
  const form = element('form', { id: 'song-editor', class: 'section', onsubmit: event => {
    event.preventDefault();
    const sourceURL = safeSourceURL(source.value.trim());
    if (!sourceURL) { report(t('invalidURL')); source.focus(); return; }
    const aliasesValue = [...new Set([title.value.trim(), ...splitLines(aliases.value)])];
    const updated = { ...song, title: title.value.trim(), aliases: aliasesValue, creators: splitLines(creators.value), sourceURL, kind: kind.value, content: typeof song.content === 'object' ? { ...song.content, [getLanguage()]: content.value.trim() } : { [getLanguage()]: content.value.trim() } };
    void runButton(form.querySelector('[type=submit]'), async () => { await action('songs_save', { song: updated }); state.selectedSong = null; state.onlineSongs = null; }, { refreshSongs: true, success: t('saved') });
  } }, [element('h2', { text: t(song.id ? 'edit' : 'add') }), field(t('title'), title), element('div', { class: 'columns' }, [field(t('creators'), creators, t('lineHint')), field(t('aliases'), aliases, t('lineHint'))]), field(t('songKind'), kind), field(t('songContent'), content, t('lyricsHint')), field(t('sourceURL'), source), element('div', { class: 'actions' }, [element('button', { type: 'submit', class: 'primary', text: t('save') }), song.id && song.sourceStatus === 'manual' ? localizedButton('delete', async event => { if (await confirmAction(t('deleteConfirm'))) void runButton(event.currentTarget, async () => { await action('songs_delete', { id: song.id }); state.selectedSong = null; }, { refreshSongs: true }); }, 'danger') : null, localizedButton('cancel', () => { state.selectedSong = null; form.remove(); })])]);
  page.prepend(form);
  title.focus();
}

function renderControls() {
  const controlBar = element('div', { class: 'control-bar' }, [element('span', { class: 'grip', text: '♪', 'aria-hidden': 'true', onmousedown: event => { if (event.button === 0) void action('drag_window').catch(report); } }), localizedButton('chat', () => void invoke('desktop_open', { view: 'chat' }).catch(report), 'primary'), localizedButton('notebook', () => void invoke('desktop_open', { view: 'notebook' }).catch(report)), localizedButton('settings', () => void invoke('desktop_open', { view: 'settings' }).catch(report), 'icon')]);
  app.append(controlBar);
}

window.addEventListener('miku-voice-segment', event => voice.enqueueSegment(event.detail));
window.addEventListener('hashchange', route);
window.addEventListener('focus', () => {
  if (state.view === 'chat') void loadSnapshot().then(renderMessages).catch(report);
});
document.addEventListener('visibilitychange', () => { if (document.hidden && (voice.calling || voice.listening)) void voice.stop(); });
window.addEventListener('beforeunload', () => { stopRhythm(); if (voice.calling || voice.listening || voice.speaking) void voice.stop(); });
setInterval(() => {
  if (state.view === 'chat' && !document.hidden && !state.pending) void loadSnapshot().then(renderMessages).catch(() => {});
}, 4000);

try {
  await loadSnapshot();
  route();
  void platform('voices').then(result => { state.voiceList = asList(result?.voices || result); }).catch(() => {});
} catch (error) {
  setLanguage('auto');
  state.view = 'chat';
  buildShell();
  page.append(section('Miku Desktop', [element('p', { class: 'error', text: errorText(error), role: 'alert' }), localizedButton('retry', () => location.reload(), 'primary')]));
}
