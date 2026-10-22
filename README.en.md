# Miku Desktop

[繁體中文](README.md) · [日本語](README.ja.md) · **English**

Hatsune Miku, living on your macOS desktop. She walks around animated Tokyo street scenes, reacts to your pointer, and chats with you through an AI running on your own Mac, remembering the time you spend together.

**Website**: [miku.qimake.com](https://miku.qimake.com/) (overview and live background demo)

![The Shibuya scramble crossing at dusk](Wallpaper/assets/scenes/shibuya-scramble-dusk.jpg)

## Features

### Living scenes

- **Seven scenes**: the Shibuya scramble crossing, Ikebukuro, Akihabara (GiGO), Shinjuku, a school hallway, a music room, and Miku's room. Pick one yourself or let them rotate at an interval you choose (her room is left out of the rotation).
- **Time and weather**: Day, dusk, and night follow your local time. Rain, snow, fog, thunderstorms, sunrise, and sunset all show in the scene, and the light on Miku follows the scene and the weather.
- **Street life**: Traffic and JR trains run through the street scenes. At the Shibuya crossing, people wait at the kerbs, stream across in every direction when the lights change, and the pedestrian signals nearby light up to match. Animations can be turned off to save power.

### Interacting with her

- Move the pointer near her, pat her head, poke her cheek, hold her hand (she follows the pointer), drag her, pick her up, and let her drop back down.
- After dragging her, you can pin her in place or let her wander freely again.
- Depending on the scene, weather, season, and events, she carries a clear umbrella, a drink, a leek, a fan, or glowsticks, and wears a hat on holidays. While music plays, she rests a hand on her headset and moves to the beat.

### Chat and memory

- **Three languages**: Traditional Chinese, Japanese, and English. Choose a cheerful, gentle, quiet, or custom personality, and set what she calls you.
- **Sounds like Miku**: Upbeat and direct, and she lights up when the talk turns to music. She never quotes copyrighted lyrics. Replies come with facial expressions, gestures, and lip sync.
- **Understands images**: Select, drag, or paste an image into the chat window (requires a local model with image input).
- **Long-term memory**: Keeps conversations, summaries, preferences, interaction history, affection, and relationship status. Remembered facts can be deleted one at a time. Resetting memory takes two confirmations and keeps one backup you can restore.

### Her daily life

- **Sleep schedule**: By default she sleeps from 1:00 to 7:00 a.m. Say good night to let her turn in early; chatting or interacting wakes her. At bedtime she goes to her room and lies on her side under the covers.
- **Special days**: She remembers her birthday, Miku Day, Christmas, New Year, summer festivals, and the anniversary of the day you met. Magical Mirai and SNOW MIKU dates are checked on the official sites every three days.
- **Notebook and diary**: She writes a diary entry before bed every night, which you can read or delete in Miku's Notebook. No diary is written while memory is off.
- **Mini games**: Rock-paper-scissors, a Vocaloid song quiz, and rhythm tap. Type a game's name in chat or start one from the Mini games menu in the chat window.

### Optional proactive companionship

Each of these can be turned on separately. **All are off by default**, and everything is handled on this Mac only:

| Option | What she does |
| --- | --- |
| Apps & breaks | Notices what you're using and for how long, and suggests a break when it's time |
| Music playing | Reads the song title from Music / Spotify and talks about what you're listening to |
| YouTube / Niconico | Reads the video title |
| Glance at the screen | Now and then shows the screen to the local model (never stored; requires macOS 14 or later) |
| Random little moments | Hums, asks you something, or invites you to play at random times |

### Desktop integration

Separate floating **Chat / Settings** buttons, menu bar controls under **♪**, pointer passthrough on transparent areas, feedback on Force Touch trackpads, and launch at login. Clicking Miku herself only triggers character interactions, never a window.

## Requirements

- An Apple silicon Mac running macOS 13 or later
- Xcode Command Line Tools with Swift 5.10 or later
- A separately running local AI service for chat; the service and model may need a newer system or more memory

## Install and build

```sh
git clone https://github.com/miku2339/miku_desktop.git
cd miku_desktop
./scripts/fetch-model.sh
./scripts/build-app.sh
```

`fetch-model.sh` downloads the character model and verifies its checksums. Please read the model's terms of use before using it.

The build lands in the `outputs/` folder **one level above the project**:

| File | Purpose |
| --- | --- |
| `Miku Desktop.zip` | Unzip it and move the app into Applications |
| `Miku Desktop.app` | A shortcut to the latest local build |

Once it's open, use the **Chat / Settings** buttons on the desktop or **♪** in the menu bar. A local wallpaper server is built in, so Plash isn't needed. Scenes and the character work offline; chat needs the local AI service, and weather needs an internet connection.

### Shareable build

```sh
./scripts/build-app.sh --public
```

This creates `../outputs/Miku Desktop (Public).zip` without the optional Tda model. Every asset remains subject to its own license.

### Optional: Tda classic outfit model

To use the classic outfit model by Tda / 金子卵黄, download `Tda式デフォ服ミク_ver1.1.zip` from the [author's distribution page](https://bowlroll.net/file/16344), read the included terms, then import it with Python 3:

```sh
python3 scripts/import-tda-model.py /path/to/Tda式デフォ服ミク_ver1.1.zip
./scripts/build-app.sh
```

Without it, the Animasa model is used. A build that includes the Tda model is for your own use only; the model and its textures are not distributed with the source code.

## Setting up the local AI

1. Install and start [oMLX](https://github.com/jundot/omlx), and load a local model.
2. Open **Settings → Local AI** and enter the endpoint and the model ID your service actually provides.
3. Click **Test connection**; once it succeeds, you can start chatting.

The default endpoint is `http://127.0.0.1:8000/v1` with the model `Qwen3.5-0.8B-MLX-4bit`; change them to match your local service. The app doesn't ship a language model. Small models are limited in knowledge, language, and staying in character, so a larger model gives better results.

For safety, only loopback (local) endpoints are accepted. When the settings match oMLX, the app reads oMLX's existing API key at run time and never writes it into the project. Image chat and "Glance at the screen" need both the service and the loaded model to support visual input.

## Privacy and network access

- Conversations, memories, diary entries, and chat images are stored in `~/Library/Application Support/MikuDesktop/`. Preferences such as personality and language are stored in macOS user defaults.
- Chat messages and any observations you turn on go only to the local AI. Screen captures are never saved and need Screen Recording permission; the music and video options may need macOS Automation permission.
- Resetting memory clears conversations, summaries, remembered facts, interaction history, and relationship data, but keeps her personality and other settings. You can restore from the backup afterwards or delete it permanently.
- The app only connects to these sites on its own:

| Connects to | Why | How often |
| --- | --- | --- |
| Open-Meteo | Weather for the selected city's coordinates | Periodically |
| magicalmirai.com, snowmiku.com | Reads public pages to confirm Magical Mirai and SNOW MIKU dates | Every three days, cached locally |

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/MikuDesktop/` | The native Swift app: windows, chat, settings, memory, sleep schedule, special days, mini games |
| `Wallpaper/companion/` | The character (three.js / MMD), animated backgrounds, crowds and traffic, interactions |
| `Wallpaper/assets/scenes/` | Scene images and their layout data |
| `Tests/` | JavaScript and Swift tests |
| `scripts/` | Build, model download, and test scripts |
| `website/`, `deploy/website/` | The website's source and deployment settings |

## Development and testing

After making changes, run these checks (the JavaScript tests need Node.js):

```sh
node --test Tests/*.test.mjs
./scripts/test-memory.sh
./scripts/test-relationship.sh
./scripts/test-awareness.sh
./scripts/test-sleep-schedule.sh
./scripts/test-special-days.sh
./scripts/test-mini-games.sh
```

Issues and pull requests are welcome. When reporting a problem, please include your macOS version, steps to reproduce, and relevant screenshots. Before sharing logs, remove private conversations, API keys, and other personal information.

## License and assets

This is an unofficial fan project and is not affiliated with Crypton Future Media, Project SEKAI, OTOIRO, or JR East.

Original project code is available under the [PolyForm Noncommercial License 1.0.0](LICENSE), which permits noncommercial use, modification, and distribution under its terms. Versions previously released under the MIT License remain subject to their original MIT terms. Character assets, MMD models, backgrounds, and third-party libraries remain subject to their respective original terms. Some anime-style backgrounds are restricted to noncommercial use. The Tokyo and school scenes are not original frames from any official music video.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the [scene asset attribution](Wallpaper/assets/scenes/ATTRIBUTION.md) for detailed sources and terms of use.
