# Miku Desktop

[繁體中文](README.md) · [日本語](README.ja.md) · **English**

A Hatsune Miku desktop companion for macOS, featuring dynamic scenes, an interactive 3D character, and local AI-powered chat and memory.

## Features

- **Scenes and lighting**: Shibuya, Ikebukuro, Akihabara, Shinjuku, a school hallway, a music room, and Miku's room. Day, sunset, and night transition gradually with local time, while character lighting follows the scene and weather. Choose a background, enable automatic rotation, and set the rotation interval. Miku's room is excluded from automatic rotation.
- **Dynamic backgrounds**: Rain, snow, fog, thunderstorms, sunrise, sunset, and indoor lighting. Traffic and JR trains appear in applicable street scenes. Dynamic effects can be disabled to save power.
- **Character interaction**: Move the pointer near Miku, pat her head, poke her cheek, hold her hand, drag her, pick her up, and let her land. Chat responses can include facial expressions, actions, and lip sync. After dragging her, you can pin her in place or let her walk freely again.
- **Trilingual chat and personality**: Traditional Chinese, Japanese, and English. Choose a cheerful, gentle, quiet, or custom personality, and set how Miku addresses you. Responses receive the local date and time, along with relevant Hatsune Miku and song information.
- **Image understanding**: Select, drag, or paste an image into the chat window. This requires a local model that supports image input.
- **Long-term memory**: Persists conversations, summaries, preferences, interaction history, affection, and relationship status. Individual memories can be deleted. Resetting memory requires two confirmations and keeps a recoverable backup of the previous state.
- **Sleep schedule and wake-up**: Miku sleeps from 1:00 a.m. to 7:00 a.m. by default. Saying good night lets her rest early, while chatting or interacting can wake her. **Bed mode is not enabled yet because the lying pose and duvet occlusion still need calibration, so she currently dozes while standing.**
- **Optional proactive companionship**: Independently enable awareness of active apps and routines, Music/Spotify, YouTube/Niconico video titles, and periodic screen understanding. All four are disabled by default.
- **Desktop controls**: Separate floating **Chat / Settings** buttons, menu bar controls, pointer passthrough for transparent areas, feedback on compatible Force Touch trackpads, and launch at login. Clicking Miku only triggers character interactions.

![Miku's room at night](Wallpaper/assets/scenes/room-night.jpg)

## Build and run

Requires an Apple silicon Mac, macOS 13 or later, and Xcode Command Line Tools with Swift 5.10 or later. The local AI service and model may have higher system or memory requirements.

```sh
git clone https://github.com/miku2339/miku_desktop.git
cd miku_desktop
./scripts/fetch-model.sh
./scripts/build-app.sh
```

`fetch-model.sh` downloads the character model and verifies its checksum. Read the terms included with the model before use.

Release builds are placed in the `outputs/` directory **one level above the project**:

| File | Purpose |
| --- | --- |
| `Miku Desktop.zip` | Unzip it, then move the app to Applications and run it |
| `Miku Desktop.app` | A shortcut to the latest local build |

After opening the app, use the desktop **Chat / Settings** buttons or the **♪** menu bar item. The app includes a local wallpaper server, so Plash is not required. Scenes and the character work offline; chat requires a separately running local AI service, while weather data requires an internet connection.

### Public package and optional model

```sh
./scripts/build-app.sh --public
```

The public build creates `../outputs/Miku Desktop (Public).zip` and excludes the optional Tda model and the complete GiGO Akihabara image set. When the GiGO images are unavailable, that Akihabara scene is skipped. Each asset remains subject to its own license.

For the classic Tda / 金子卵黄 outfit model, download `Tda式デフォ服ミク_ver1.1.zip` from the [author's distribution page](https://bowlroll.net/file/16344), read the included terms, then import it with Python 3:

```sh
python3 scripts/import-tda-model.py /path/to/Tda式デフォ服ミク_ver1.1.zip
./scripts/build-app.sh
```

The Animasa model is used when Tda has not been imported. Local packages that include Tda are for personal use only; the model and textures are not distributed with the source code.

## Local AI

1. Install and start [oMLX](https://github.com/jundot/omlx), then load a local model.
2. In **Settings → Local AI**, enter the endpoint and the actual model ID exposed by the service.
3. Select **Test connection**, then open chat.

The initial endpoint is `http://127.0.0.1:8000/v1`, and the model name is `Qwen3.5-0.8B-MLX-4bit`. Both can be changed to match your local service. The app does not include language model weights. Small models have limited knowledge and may follow language and personality instructions less reliably.

Only loopback endpoints are accepted. When the settings match oMLX, the app reads the existing API key at runtime and does not write it into the project. Image chat and periodic screen understanding require both the service and the loaded model's converted build to support visual input; text-only models cannot use these features.

## Data and permissions

- Conversations, memories, and chat images are stored in `~/Library/Application Support/MikuDesktop/`. Preferences such as personality and language are stored in macOS user defaults.
- Resetting clears conversations, summaries, remembered facts, interaction history, and relationship data while retaining personality and other settings. Restoring replaces any new post-reset memories with the backup created before the reset. You can also permanently delete the backup.
- Chat content and any enabled observation data are passed to the local AI. Periodic screen captures are not saved; this feature requires macOS 14 or later and Screen Recording permission. Music and video features may require macOS Automation permission.
- The weather service connects to Open-Meteo to request weather using the selected city's coordinates. Screen awareness and weather are separate features.

## Development and contributions

The native Swift interface is in `Sources/MikuDesktop/`. Character, background, and interaction scripts are in `Wallpaper/companion/`, while scene images are in `Wallpaper/assets/scenes/`.

After changing related features, run the following checks as appropriate. The JavaScript tests require Node.js:

```sh
node --test Tests/*.test.mjs
./scripts/test-memory.sh
./scripts/test-relationship.sh
./scripts/test-awareness.sh
./scripts/test-sleep-schedule.sh
```

Issues and pull requests are welcome. When reporting a problem, include your macOS version, reproduction steps, and relevant screenshots. Remove private conversations, API keys, and other personal data before sharing logs.

## Assets and licenses

This is an unofficial fan project and is not affiliated with Crypton Future Media, Project SEKAI, OTOIRO, or JR East.

The source code is available under the [MIT License](LICENSE). Character assets, MMD models, backgrounds, and third-party libraries remain subject to their respective licenses. Some anime-style backgrounds are restricted to non-commercial use. The Tokyo and school scenes are not original frames from any official music video.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the [scene asset attribution](Wallpaper/assets/scenes/ATTRIBUTION.md) for detailed sources and terms of use.
