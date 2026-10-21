const DEFAULT_COORDINATES = Object.freeze({
  bedHeadX: 0.93,
  bedSurfaceY: 0.79,
  windowBounds: [0.06, 0.1, 0.3, 0.36],
  wallFloorBoundaryY: 0.62,
  clearForeground: [0.04, 0.7, 0.44, 0.3],
  suggestedFootY: 0.915,
  rectFormat: 'x,y,width,height'
});

export const DEFAULT_ROOM_LAYOUT = Object.freeze({
  sleepReady: false,
  imageSize: [2560, 1600],
  coordinates: DEFAULT_COORDINATES
});

const unit = (value, fallback) => {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 && number <= 1 ? number : fallback;
};

function normalizedRect(value, fallback) {
  if (!Array.isArray(value) || value.length !== 4) return [...fallback];
  const [x, y, width, height] = value.map(Number);
  if (![x, y, width, height].every(Number.isFinite)
      || x < 0 || y < 0 || width < 0 || height < 0
      || x + width > 1 || y + height > 1) return [...fallback];
  return [x, y, width, height];
}

function imageSize(layout) {
  const day = layout?.files?.day;
  const width = Number(day?.width ?? layout?.imageSize?.[0]);
  const height = Number(day?.height ?? layout?.imageSize?.[1]);
  return Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0
    ? [width, height]
    : [...DEFAULT_ROOM_LAYOUT.imageSize];
}

export function normalizeRoomLayout(layout) {
  const source = layout && typeof layout === 'object' ? layout : {};
  const coordinates = source.coordinates && typeof source.coordinates === 'object'
    ? source.coordinates
    : {};
  const bed = coordinates.bed && typeof coordinates.bed === 'object' ? coordinates.bed : {};

  return {
    sleepReady: source.sleepReady === true,
    imageSize: imageSize(source),
    coordinates: {
      bedHeadX: unit(coordinates.bedHeadX ?? bed.headX, DEFAULT_COORDINATES.bedHeadX),
      bedSurfaceY: unit(coordinates.bedSurfaceY ?? bed.surfaceY, DEFAULT_COORDINATES.bedSurfaceY),
      windowBounds: normalizedRect(coordinates.windowBounds, DEFAULT_COORDINATES.windowBounds),
      wallFloorBoundaryY: unit(coordinates.wallFloorBoundaryY, DEFAULT_COORDINATES.wallFloorBoundaryY),
      clearForeground: normalizedRect(coordinates.clearForeground, DEFAULT_COORDINATES.clearForeground),
      suggestedFootY: unit(coordinates.suggestedFootY, DEFAULT_COORDINATES.suggestedFootY),
      rectFormat: DEFAULT_COORDINATES.rectFormat
    }
  };
}

export async function loadRoomLayout(url, fetchImpl = globalThis.fetch) {
  if (typeof fetchImpl !== 'function') return normalizeRoomLayout(null);
  try {
    const response = await fetchImpl(url);
    if (!response.ok) return normalizeRoomLayout(null);
    return normalizeRoomLayout(await response.json());
  } catch {
    return normalizeRoomLayout(null);
  }
}

/** Map image-normalized coordinates through the same centered `cover` fit as the room image. */
export function roomViewportGeometry(layout, viewportWidth, viewportHeight) {
  const room = normalizeRoomLayout(layout);
  const [imageWidth, imageHeight] = room.imageSize;
  const width = Math.max(1, Number(viewportWidth) || 1);
  const height = Math.max(1, Number(viewportHeight) || 1);
  const scale = Math.max(width / imageWidth, height / imageHeight);
  const drawnWidth = imageWidth * scale / width;
  const drawnHeight = imageHeight * scale / height;
  const offsetX = (1 - drawnWidth) / 2;
  const offsetY = (1 - drawnHeight) / 2;
  const pointX = x => offsetX + x * drawnWidth;
  const pointY = y => offsetY + y * drawnHeight;
  const [clearX, clearY, clearWidth, clearHeight] = room.coordinates.clearForeground;

  return {
    bedHeadX: pointX(room.coordinates.bedHeadX),
    bedSurfaceY: pointY(room.coordinates.bedSurfaceY),
    suggestedFootY: pointY(room.coordinates.suggestedFootY),
    clearForeground: [
      pointX(clearX),
      pointY(clearY),
      clearWidth * drawnWidth,
      clearHeight * drawnHeight
    ]
  };
}

export function roomAmbientFeatures(layout) {
  const room = normalizeRoomLayout(layout);
  const [x, y, width, height] = room.coordinates.windowBounds;
  return {
    size: [...room.imageSize],
    windows: [[x, y, x + width, y + height]],
    floor: room.coordinates.wallFloorBoundaryY
  };
}

export function canUseRoomBed(layout, roomLoaded) {
  return Boolean(roomLoaded && layout?.sleepReady === true);
}
