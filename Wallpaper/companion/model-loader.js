import * as THREE from 'three';
import { MMDLoader } from './vendor/loaders/MMDLoader.js';
import { MMDParser } from './vendor/libs/mmdparser.module.js';
import { applyFaceMaterials } from './face-materials.js';
import { applyFaceStyle } from './face-style.js';

const TDA_MODEL_URL = '../assets/companion-model/tda/miku.pmx';
const TDA_V4X_MODEL_URL = '../assets/companion-model/tda-v4x/miku.pmx';
const CUSTOM_MODEL_URL = '../assets/companion-model/custom/miku.pmx';
const DEFAULT_MODEL_URL = '../assets/companion-model/miku_v2.pmd';

async function modelURL() {
  const selection = new URLSearchParams(window.location.search).get('character');
  if (selection === 'animasa') return DEFAULT_MODEL_URL;
  const preferred = selection === 'tda-v4x' ? TDA_V4X_MODEL_URL : selection === 'custom' ? CUSTOM_MODEL_URL : TDA_MODEL_URL;
  for (const url of new Set([preferred, TDA_MODEL_URL])) {
    const available = await fetch(url, { method: 'HEAD' }).catch(() => null);
    if (available?.ok) return url;
  }
  return DEFAULT_MODEL_URL;
}

function prepareV4X(data) {
  data.textures = data.textures.map(path => path.replaceAll('\\', '/'));
  // The author calls for this additive material morph at full weight without AutoLuminous.
  // MMDLoader does not apply PMX material morphs, so apply these offsets before building.
  const noAutoLuminous = data.morphs.find(morph => morph.name === 'AL未使用' && morph.type === 8);
  for (const element of noAutoLuminous?.elements ?? []) {
    const material = data.materials[element.index];
    if (!material || element.type !== 1) continue;
    material.diffuse = material.diffuse.map((value, index) => value + element.diffuse[index]);
    material.ambient = material.ambient.map((value, index) => value + element.ambient[index]);
  }
}

function prepareCustomModel(data) {
  data.textures = data.textures.map(path => {
    const parts = path.replaceAll('\\', '/').split('/');
    if (parts.length > 8 || parts.some(part => !part || part.startsWith('.') || part.includes(':') || part.includes('\0'))
        || !/\.(bmp|gif|jpe?g|png|spa|sph|tga|webp)$/i.test(parts.at(-1))) {
      throw new Error('Unsupported custom model texture path');
    }
    return parts.map(encodeURIComponent).join('/');
  });
}

export async function loadCompanionModel() {
  const preferred = await modelURL();
  try {
    return await loadModel(preferred);
  } catch (error) {
    if (preferred !== CUSTOM_MODEL_URL) throw error;
    console.warn('Could not load the custom PMX model');
    return loadModel(DEFAULT_MODEL_URL);
  }
}

async function loadModel(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Model could not be loaded: HTTP ${response.status}`);

  const buffer = await response.arrayBuffer();
  const parser = new MMDParser.Parser();
  const data = url === DEFAULT_MODEL_URL ? parser.parsePmd(buffer, true) : parser.parsePmx(buffer, true);
  if (url === TDA_V4X_MODEL_URL) prepareV4X(data);
  if (url === CUSTOM_MODEL_URL) prepareCustomModel(data);

  const manager = new THREE.LoadingManager();
  const texturesReady = new Promise((resolve, reject) => {
    manager.onLoad = resolve;
    manager.onError = asset => reject(new Error(`Model texture could not be loaded: ${asset}`));
  });
  const loader = new MMDLoader(manager);
  const resourcePath = url.slice(0, url.lastIndexOf('/') + 1);
  manager.itemStart(url);
  const model = loader.meshBuilder.build(data, resourcePath);
  manager.itemEnd(url);
  await texturesReady;
  if (url === TDA_V4X_MODEL_URL) applyFaceStyle(model, { lowerFaceLift: 0.6 });
  if (url === TDA_MODEL_URL) {
    applyFaceStyle(model);
    applyFaceMaterials(model);
  }
  return { model, url, name: data.metadata.modelName || 'Animasa Miku' };
}
