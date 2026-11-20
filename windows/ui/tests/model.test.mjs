import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSnapshot, buildSettingsPatch, imageSource, audioSource, safeSourceURL, mayAutoSpeak, songDescription, songPage, MAX_IMAGE_BYTES, imageFileError, imageFromTransfer, imageDimensions } from '../model.mjs';
import { resolveLanguage, setLanguage, t } from '../i18n.mjs';

test('snapshot accepts wrapped collections without losing companion metadata', () => {
  const value = normalizeSnapshot({ notes: { entries: [{ id: 'one' }] }, songs: { items: [{ id: 'song.one' }] }, sleep: { asleep: true } });
  assert.equal(value.notes[0].id, 'one');
  assert.equal(value.songs[0].id, 'song.one');
  assert.deepEqual(value.messages, []);
  assert.equal(value.sleep.asleep, true);
});

test('settings preserve saved keys when secret input is blank', () => {
  const form = { elements: [
    { name: 'cloudApiKey', type: 'password', value: '  ' },
    { name: 'aimcpApiKey', type: 'password', value: ' new-key ' },
    { name: 'clearCloudApiKey', type: 'checkbox', checked: true },
    { name: 'cloudEndpoint', type: 'url', value: ' https://example.test/v1 ' },
    { name: 'latitude', type: 'number', value: '' },
    { name: 'model', type: 'text', value: 'hidden-model', disabled: true },
  ] };
  assert.deepEqual(buildSettingsPatch(form), { aimcpApiKey: 'new-key', clearCloudApiKey: true, cloudEndpoint: 'https://example.test/v1', latitude: null });
});

test('image and audio sources reject remote or executable media', () => {
  assert.equal(imageSource({ image: 'data:image/jpeg;base64,YQ==' }), 'data:image/jpeg;base64,YQ==');
  assert.equal(imageSource({ base64: 'YQ==', mime: 'image/png' }), 'data:image/png;base64,YQ==');
  assert.equal(imageSource('https://example.test/track.png'), null);
  assert.equal(imageSource('data:image/svg+xml;base64,YQ=='), null);
  assert.equal(audioSource({ audio: 'YQ==', mimeType: 'audio/wav' }), 'data:audio/wav;base64,YQ==');
  assert.equal(audioSource({ audio: 'https://example.test/audio.wav' }), null);
  assert.equal(audioSource({ audio: '<script>', mimeType: 'audio/wav' }), null);
});

test('source URLs allow HTTPS and reject embedded credentials', () => {
  assert.equal(safeSourceURL('https://vocadb.net/S/39'), 'https://vocadb.net/S/39');
  for (const value of ['javascript:alert(1)', 'file:///etc/passwd', 'https://name:key@example.test/', 'http://example.test/']) assert.equal(safeSourceURL(value), null);
});

test('quiet hours include midnight and exclude their ending minute', () => {
  const settings = { speechEnabled: true, quietStart: '23:00', quietEnd: '07:00' };
  const at = (hour, minute = 0) => new Date(2026, 10, 10, hour, minute);
  assert.equal(mayAutoSpeak(settings, at(23)), false);
  assert.equal(mayAutoSpeak(settings, at(6, 59)), false);
  assert.equal(mayAutoSpeak(settings, at(7)), true);
  assert.equal(mayAutoSpeak({ ...settings, speechQuietEnabled: false }, at(1)), true);
  assert.equal(mayAutoSpeak({ ...settings, speechMuted: true }, at(12)), false);
  assert.equal(mayAutoSpeak({ ...settings, speechEnabled: false }, at(12)), false);
});

test('same-day quiet period and equal boundaries remain well defined', () => {
  const settings = { speechEnabled: true, quietStart: '12:00', quietEnd: '13:00' };
  assert.equal(mayAutoSpeak(settings, new Date(2026, 10, 10, 12, 30)), false);
  assert.equal(mayAutoSpeak(settings, new Date(2026, 10, 10, 13)), true);
  assert.equal(mayAutoSpeak({ ...settings, quietEnd: '12:00' }, new Date(2026, 10, 10, 12)), true);
});

test('UI locale resolves Chinese variants and translations retain script', () => {
  assert.equal(resolveLanguage('auto', 'zh-CN'), 'zh-Hans');
  assert.equal(resolveLanguage('auto', 'zh-HK'), 'zh-Hant');
  assert.equal(resolveLanguage('auto', 'ja-JP'), 'ja');
  setLanguage('zh-Hans'); assert.equal(t('settings'), '设置');
  setLanguage('zh-Hant'); assert.equal(t('settings'), '設定');
  assert.equal(songDescription({ content: { 'zh-Hant': '內容', en: 'Text' } }, 'zh-Hans'), '內容');
});


test('large song catalog searches the whole library before applying its 200-card limit', () => {
  const songs = Array.from({ length: 50_000 }, (_, index) => ({ id: `song.${index}`, aliases: [`Song ${index}`], creators: ['Producer'], content: { en: index === 49_999 ? 'Hidden final song' : 'Description' } }));
  const first = songPage(songs);
  assert.equal(first.items.length, 200);
  assert.equal(first.total, 50_000);
  assert.equal(first.pages, 250);
  assert.equal(songPage(songs, '', 249).items[199].id, 'song.49999');
  const found = songPage(songs, 'hidden final');
  assert.equal(found.total, 1);
  assert.equal(found.items[0].id, 'song.49999');
  assert.equal(songs.length, 50_000);
});

test('song pagination clamps oversized requests and pages after filtering', () => {
  const songs = Array.from({ length: 401 }, (_, index) => ({ id: String(index), aliases: [`Title ${index}`], creators: [index === 400 ? 'Last producer' : 'Other'], content: { ja: index === 400 ? 'ミクの楽曲' : '' } }));
  assert.equal(songPage(songs, '', 0, 50_000).items.length, 200);
  assert.equal(songPage(songs, '', 99).page, 2);
  assert.equal(songPage(songs, '', 2).items.length, 1);
  assert.equal(songPage(songs, 'last producer', 99).page, 0);
  assert.equal(songPage(songs, 'ミクの楽曲').items[0].id, '400');
  assert.equal(songPage(songs, 'Ｔｉｔｌｅ ４００').total, 1);
  assert.equal(songPage(songs, 'missing').items.length, 0);
  assert.equal(songPage(songs, 'missing').pages, 1);
});


test('light snapshots retain the full song cache and explicit full snapshots replace it', () => {
  const previous = { songs: [{ id: 'song.cached' }] };
  const light = normalizeSnapshot({ songs: [], songsOmitted: true, messages: [{ id: 'new' }] }, previous);
  assert.equal(light.songs, previous.songs);
  assert.equal(light.messages[0].id, 'new');
  assert.deepEqual(normalizeSnapshot({ songs: [], songsOmitted: false }, previous).songs, []);
  assert.deepEqual(normalizeSnapshot({ songsOmitted: true }).songs, []);
});


test('image paste preserves text and never fetches HTML or URI image references', () => {
  const png = { type: 'image/png', size: 1024, name: 'clipboard.png' };
  assert.equal(imageFromTransfer({ files: [png], getData: () => '' }), png);
  assert.equal(imageFromTransfer({ files: [png], getData: () => 'Copied page text' }), null);
  assert.equal(imageFromTransfer({ files: [], getData: () => 'https://example.test/image.png' }), null);
  assert.equal(imageFromTransfer({ items: [{ kind: 'file', getAsFile: () => png }], getData: () => '' }), png);
  assert.equal(imageFromTransfer({ files: [png], getData: () => 'A filename' }, false), png);
});

test('picked, pasted and dropped images share format, size and dimension bounds', () => {
  assert.equal(imageFileError({ type: 'image/jpeg', size: MAX_IMAGE_BYTES }), null);
  assert.equal(imageFileError({ type: 'image/png', size: MAX_IMAGE_BYTES + 1 }), 'imageTooLarge');
  assert.equal(imageFileError({ type: 'image/svg+xml', size: 20 }), 'imageInvalid');
  assert.equal(imageFileError({ type: 'image/png', size: 0 }), 'imageInvalid');
  assert.deepEqual(imageDimensions(3840, 2160), { width: 1280, height: 720 });
  assert.deepEqual(imageDimensions(200, 100), { width: 200, height: 100 });
  assert.throws(() => imageDimensions(0, 20), /imageInvalid/);
  assert.throws(() => imageDimensions(10000, 10000), /imageInvalid/);
});
