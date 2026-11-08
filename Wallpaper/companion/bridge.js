// The app around the page: a WKWebView in the macOS app, a WebView2 (Tauri) window on
// Windows (docs/windows-port.md). The page sends messages through here; the app talks
// back by calling window.mikuCompanion.* on either platform.

/** Tauri command the Windows shell registers for messages from the page. */
export const TAURI_COMMAND = 'miku_message';

function macHandler(win) {
  const handler = win?.webkit?.messageHandlers?.miku;
  return typeof handler?.postMessage === 'function' ? handler : null;
}

function tauriInvoke(win) {
  const invoke = win?.__TAURI__?.core?.invoke ?? win?.__TAURI_INTERNALS__?.invoke;
  return typeof invoke === 'function' ? invoke : null;
}

/**
 * Which app the page is running in, looked up on every call: the app may set up its side
 * after the page script has started.
 */
export function createNativeBridge(win = globalThis.window, { onError = () => {} } = {}) {
  function platform() {
    if (macHandler(win)) return 'mac';
    if (tauriInvoke(win)) return 'windows';
    return null;
  }

  /** Sends a message to the app; false when the page is open on its own (a browser). */
  function post(message) {
    const handler = macHandler(win);
    if (handler) {
      handler.postMessage(message);
      return true;
    }
    const invoke = tauriInvoke(win);
    if (invoke) {
      Promise.resolve()
        .then(() => invoke(TAURI_COMMAND, { message }))
        .catch(onError);
      return true;
    }
    return false;
  }

  return { available: () => platform() !== null, platform, post };
}
