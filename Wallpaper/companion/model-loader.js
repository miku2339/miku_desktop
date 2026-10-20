import * as THREE from 'three';
import { MMDLoader } from './vendor/loaders/MMDLoader.js';
import { MMDParser } from './vendor/libs/mmdparser.module.js';

const TDA_MODEL_URL = '../assets/companion-model/tda/miku.pmx';
const DEFAULT_MODEL_URL = '../assets/companion-model/miku_v2.pmd';

export async function loadCompanionModel() {
  const available = await fetch(TDA_MODEL_URL, { method: 'HEAD' }).catch(() => null);
  const url = available?.ok ? TDA_MODEL_URL : DEFAULT_MODEL_URL;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Model could not be loaded: HTTP ${response.status}`);

  const buffer = await response.arrayBuffer();
  const parser = new MMDParser.Parser();
  const data = url === TDA_MODEL_URL ? parser.parsePmx(buffer, true) : parser.parsePmd(buffer, true);

  const manager = new THREE.LoadingManager();
  const texturesReady = new Promise((resolve, reject) => {
    manager.onLoad = resolve;
    manager.onError = asset => reject(new Error(`Model texture could not be loaded: ${asset}`));
  });
  const loader = new MMDLoader(manager);
  const resourcePath = url.slice(0, url.lastIndexOf('/') + 1);
  const model = loader.meshBuilder.build(data, resourcePath);
  await texturesReady;
  return { model, url, name: data.metadata.modelName || 'Animasa Miku' };
}
