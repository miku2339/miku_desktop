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
- **Connected daily activities**: She randomly chooses scene-, weather-, and music-aware walks, drinks, or listening breaks without repeating the same plan in a row. Say “come here” or use the ♪ menu: she puts her prop away, approaches and stays for a moment, then walks back to resume her activity. Chat and touch pause the routine.
- Depending on the scene, weather, season, and events, she carries a clear umbrella, a drink, a leek, a fan, or glowsticks, and wears a hat on holidays. While music plays, she rests a hand on her headset and moves to the beat.

### Chat and memory

- **Multilingual interface and replies**: The interface and desktop interaction lines support Traditional Chinese, Japanese, English, and Korean. Under “Miku speaks” in Settings you can have her reply in Mandarin, Cantonese, Japanese, English, or Korean, or choose Automatic to follow the language you write in. The voice is selected from the text, using common words to distinguish Mandarin and Cantonese; ambiguous short phrases follow the selected language. Choose a cheerful, gentle, quiet, or custom personality, and set what she calls you.
- **Sounds like Miku**: Upbeat and direct, and she lights up when the talk turns to music. She never quotes copyrighted lyrics. Replies come with facial expressions and gestures.
- **Voice calls**: Press the phone button in chat for on-device recognition in Mandarin, Cantonese, Japanese, English, or Korean. Switch in the call card or under “⋯ → Conversation language.” An offline language download may be needed on first use; speech input and TTS voice support are separate. On supported audio devices, listening continues while Miku thinks or speaks, so you can interrupt by talking; “My turn” remains available for manual interruption. Replies are generated and played sentence by sentence, preparing the next sentence during playback. Includes live captions, microphone mute, and end-call controls. Microphone input pauses before opening requested music. Enable and configure your own local TTS first.
- **Local speech and lip sync**: Connect your own local TTS service and voice model; the app does not provide or download the owner's private Miku voice. Korean speech requires your own Korean-capable local model; the owner's existing private four-language model does not support Korean. Her mouth starts when audio playback starts and follows its actual duration. A temporary service or connection failure is retried once. Speech diagnostics record only the error category, language, character count, timing, and attempt count—not the text being spoken.
- **Humming clips**: In Settings → Speech, click “Open Humming Folder” and add original hums you made yourself (wav, m4a, aiff…, up to 10 seconds each). When she hums in a reply, one plays at random after she finishes speaking, and her mouth follows the audio; nothing plays while muted, on a call or in full screen. These private original clips stay on your Mac and are not distributed with the app; with the folder empty, humming stays as text. Do not add existing songs.
- **Understands images**: Select, drag, or paste an image into the chat window (requires a local model with image input).
- **Updatable song knowledge**: Open Song Knowledge in the notebook or from Companion tools in chat to search songs, creators, characters, and events, view sources, mark favorite songs, and export, edit, or import JSON. With memory enabled, clearly saying that you like a recognized song also adds it to favorites. It includes 200 verified Hatsune Miku songs (creators, years, and original uploads from VocaDB); for songs it doesn't have, she says she isn't sure instead of pretending. You can also enable the optional “Look up songs on VocaDB” under Local AI in Settings (off by default) to make an additional creator and official-video lookup with VocaDB attribution.
- **MikuWiki and AIMCP**: [MikuWiki](https://mikuwiki.qimake.com/) provides the online song catalog. In Song Knowledge → AIMCP Settings, enter a key you generate for yourself on the [MikuWiki AIMCP account page](https://mikuwiki.qimake.com/knowledge?lang=en). The app uses the fixed `https://mikuwiki.qimake.com/api/v1/song-knowledge` endpoint for catalog updates and `/api/v1/knowledge` for song lookup, storing the key only in this Mac's Keychain. With a key configured, an unknown song in chat or an Enter search in Song Knowledge sends the identified title or entered search text, never the full conversation. A manual update prefers AIMCP when a key is present and tries GitHub only after a connection failure, server error, missing endpoint, or failed data validation. Key, permission, and quota errors are reported directly instead of silently falling back; existing data is kept if GitHub also cannot be reached. AIMCP and GitHub use separate caches; imported JSON still fully overrides an entry with the same ID, while favorites are stored separately and remain available offline.
- **Our memory album**: Open the notebook’s Memory Album, or choose “Take a Memory Photo” from the ♪ menu, to manually photograph Miku and her scene, add a title and note, and choose everyday, first meeting, birthday, or achievement. Export photos or delete them individually.
- **Long-term memory**: Keeps conversations, summaries, preferences, interaction history, affection, and relationship status. Remembered facts can be deleted one at a time. Resetting memory takes two confirmations and keeps one backup you can restore.

### Her daily life

- **Sleep schedule**: By default she sleeps from 1:00 to 7:00 a.m. Say good night to let her turn in early; chatting or interacting wakes her. At bedtime she goes to her room and lies on her side under the covers.
- **Special days**: She remembers her birthday, Miku Day, Christmas, New Year, summer festivals, and the anniversary of the day you met. Magical Mirai, Miku With You, MIKU EXPO and SNOW MIKU dates are checked through official sources every three days.
- **Event lookup**: On the notebook’s diary page, enter an event name or year (such as “MIKU EXPO 2026”) and search for official dates, cities, venues and source links. Chat answers use cached official records and do not guess unconfirmed dates.
- **Notebook and diary**: Miku’s Notebook has sidebar pages for Settings, Memory Album, Song Knowledge and Diary, with shortcuts to settings sections. She writes a diary entry before bed every night, which you can read or delete. No diary is written while memory is off.
- **Mini games**: Rock-paper-scissors, a Vocaloid song quiz, and rhythm tap. Type a game's name in chat or start one from the Mini games menu in the chat window.
- **Plays songs for you**: Say “play Tell Your World on Spotify” in chat, or answer with a song name when she asks what you'd like to hear. She opens it once she has replied and finished speaking. YouTube plays an official video from Song Knowledge or the optional VocaDB lookup, otherwise opening search results; Spotify opens an app or web search for you to press Play; Apple Music first tries your local library and opens Apple Music search if it finds no match. Without a service named, she uses the one you named last, YouTube by default.

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

Separate floating **Chat / Notebook** buttons, menu bar controls under **♪**, pointer passthrough on transparent areas, feedback on Force Touch trackpads, and launch at login. Clicking Miku herself only triggers character interactions, never a window.

## Requirements

- An Apple silicon Mac running macOS 13 or later
- Building from source requires Xcode 26 or corresponding Command Line Tools, including the macOS 26 SDK or later
- A separately running local AI service for chat; the service and model may need a newer system or more memory

## Install and build

```sh
git clone https://github.com/miku2339/miku_desktop.git
cd miku_desktop
./scripts/install-app.sh
```

`install-app.sh` obtains the original Tda v1.1 ZIP from the [author's distribution page](https://bowlroll.net/file/16344), verifies its checksum, imports the model, then builds, installs and opens the app. It installs into `/Applications` when writable, otherwise `~/Applications`. Read the authors' terms before using the model.

If the author's site requires login or verification, or the download is unavailable, installation stops. Obtain the original ZIP yourself, then continue:

```sh
./scripts/install-app.sh --tda-archive "/path/to/Tda式デフォ服ミク_ver1.1.zip"
```

Use `--app-dir DIR` to choose the installation folder or `--no-open` to install without opening the app. Use `--skip-tda` only when you want to skip obtaining and importing Tda. Any previously imported model is retained.

Installation also produces these files in `outputs/`, **one level above the project**:

| File | Purpose |
| --- | --- |
| `Miku Desktop (Public).zip` | Shareable package; each user obtains the Tda model themselves |
| `Miku Desktop.app` | A shortcut to the latest local build |

Once it's open, use the **Chat / Notebook** buttons on the desktop or **♪** in the menu bar. A local wallpaper server is built in, so Plash isn't needed. Scenes and the character work offline; chat needs the local AI service, and weather needs an internet connection.

### Shareable build

```sh
./scripts/build-app.sh --public
```

This creates `../outputs/Miku Desktop (Public).zip` without the optional Tda model. Every asset remains subject to its own license.

### Tda classic outfit model

The installer stores the classic outfit model by Tda / 金子卵黄 and its authors' terms in `~/Library/Application Support/MikuDesktop/CharacterModels/tda/`, where they survive app updates. Users who already downloaded the public app can also import it manually:

1. Download `Tda式デフォ服ミク_ver1.1.zip` from the [author's distribution page](https://bowlroll.net/file/16344), read the included terms, and keep the original ZIP intact.
2. Open **Notebook → Settings → Character**, click **Import Tda ZIP…**, and select the archive.
3. The desktop character switches to Tda immediately. The model and its authors' terms are stored on this Mac and retained when you update the app.

The bundled Animasa model is used before import. Public packages do not include the Tda model or its textures.

When building from source, you can also import with Python 3 before building:

```sh
python3 scripts/import-tda-model.py /path/to/Tda式デフォ服ミク_ver1.1.zip
./scripts/build-app.sh
```

A local build that includes the Tda model is for your own use only. The model and its textures are not distributed with the source code.

## Setting up the local AI

1. Install and start [oMLX](https://github.com/jundot/omlx), and load a local model.
2. Open **Settings → Local AI** and enter the endpoint and the model ID your service actually provides.
3. Click **Test connection**; once it succeeds, you can start chatting.

The default endpoint is `http://127.0.0.1:8000/v1` with the model `Qwen3.5-0.8B-MLX-4bit`; change them to match your local service. The app doesn't ship a language model. Small models are limited in knowledge, language, and staying in character, so a larger model gives better results.

For safety, only loopback (local) endpoints are accepted. When the settings match oMLX, the app reads oMLX's existing API key at run time and never writes it into the project. Image chat and "Glance at the screen" need both the service and the loaded model to support visual input.

## Privacy and network access

- Conversations, memories, diary entries, and chat images are stored in `~/Library/Application Support/MikuDesktop/`. Preferences such as personality and language are stored in macOS user defaults.
- Chat messages and any observations you turn on go to the local AI. With an AIMCP key configured, song queries missing from the offline catalog also send the identified title to MikuWiki, never the full conversation. Screen captures for proactive observations are never saved and need Screen Recording permission; the music and video options may need macOS Automation permission.
- Voice calls request microphone and speech-recognition permission only after you press the phone button. Recognition audio is neither saved nor sent to a recognition server. If on-device recognition for the selected language is unavailable, the app tells you instead of using cloud recognition. Recognized text follows the same memory settings as typed chat.
- When reading aloud is enabled, text goes only to the configured local TTS endpoint. Supply your own voice model; the app package contains no voice weights or reference audio. To keep her quiet for a while, click the speaker button in the chat window, or choose Mute for 1 Hour or Mute Until Turned Back On under Miku’s Voice in the ♪ menu. Nothing is generated while muted, and what she says on her own while asleep is never read aloud. Reading aloud also pauses on its own while you are on a call or recording (another app is using the microphone) or something is full screen in front; replays you ask for still play.
- To keep her quiet during a Focus: macOS doesn’t let apps read Focus directly, so use a Shortcuts automation instead (macOS 26 or later). Run `open -g "miku-desktop://quiet/on"` when the Focus turns on and `open -g "miku-desktop://quiet/off"` when it turns off; step-by-step instructions are under Miku’s Voice → Follow Focus… in the ♪ menu. A Focus ending only lifts its own quiet, never a mute you set yourself. `miku-desktop://` links accept only these voice commands.
- Resetting memory clears conversations, summaries, remembered facts, interaction history, and relationship data, but keeps her personality and other settings. You can restore from the backup afterwards or delete it permanently.
- Manually saved photos and song favorites are kept separately and managed on their notebook pages; conversation-memory resets leave them intact. Photos contain only Miku and her scene and are resized into `album/`; knowledge and favorites live in `Knowledge/`.
- The app makes the following network connections:

| Connects to | Why | How often |
| --- | --- | --- |
| Open-Meteo | Weather for the selected city's coordinates | Periodically |
| magicalmirai.com, snowmiku.com, mikuexpo.com, www.scla.com.cn | Reads official public event dates, cities and venues; no chat content is sent | Every three days or on manual search, cached locally |
| mikuwiki.qimake.com | Updates the catalog through `/api/v1/song-knowledge` and looks up songs through `/api/v1/knowledge`; sends only song titles or catalog search text, using your key stored in Keychain | With a key configured: manual updates, Enter searches in Song Knowledge, or chat about songs missing from the offline catalog |
| raw.githubusercontent.com | Downloads this repository's song knowledge when no AIMCP key is configured, or after an AIMCP connection, server, endpoint, or data-validation error; key, permission, and quota errors do not fall back | Only when you click Check for Updates |
| YouTube, Spotify, Apple Music | Opens the song or search you asked for; the title goes to the service you chose | Only when you ask her to play something |
| vocadb.net | Looks up the creator and official video of songs not in the knowledge base; only the title is sent and lyrics are never fetched; results are cached locally and cleared when turned off | Off by default; when on, only for songs not in the knowledge base, at most 30 a day |

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/MikuDesktop/` | The native Swift app: windows, chat, settings, memory, sleep schedule, special days, mini games |
| `Wallpaper/companion/` | The character (three.js / MMD), animated backgrounds, crowds and traffic, interactions |
| `Wallpaper/assets/scenes/` | Scene images and their layout data |
| `Tests/` | JavaScript, Swift, and installer tests |
| `scripts/` | Build, model download, and test scripts |
| `website/`, `deploy/website/` | The website's source and deployment settings |

## Development and testing

After making changes, run these checks (the JavaScript tests need Node.js):

```sh
node --test Tests/*.test.mjs
python3 -m unittest discover -s Tests -p 'test_tda_setup.py'
./scripts/test-memory.sh
./scripts/test-relationship.sh
./scripts/test-awareness.sh
./scripts/test-sleep-schedule.sh
./scripts/test-special-days.sh
./scripts/test-mini-games.sh
./scripts/test-companion-requests.sh
./scripts/test-song-knowledge.sh
./scripts/test-character-model.sh
./scripts/test-memory-album.sh
```

Issues and pull requests are welcome. When reporting a problem, please include your macOS version, steps to reproduce, and relevant screenshots. Before sharing logs, remove private conversations, API keys, and other personal information.

## License and assets

This is an unofficial fan project and is not affiliated with Crypton Future Media, Project SEKAI, OTOIRO, or JR East.

Original project code is available under the [PolyForm Noncommercial License 1.0.0](LICENSE), which permits noncommercial use, modification, and distribution under its terms. Versions previously released under the MIT License remain subject to their original MIT terms. Character assets, MMD models, backgrounds, and third-party libraries remain subject to their respective original terms. Some anime-style backgrounds are restricted to noncommercial use. The Tokyo and school scenes are not original frames from any official music video.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the [scene asset attribution](Wallpaper/assets/scenes/ATTRIBUTION.md) for detailed sources and terms of use.
