# Shibuya background photograph

JR Shibuya Station Hachiko Gates.jpg — Mister0124, 18 September 2019.

Source: https://commons.wikimedia.org/wiki/File:JR_Shibuya_Station_Hachiko_Gates.jpg
License: CC BY-SA 4.0 — https://creativecommons.org/licenses/by-sa/4.0/

shibuya-hachiko.png is an anime-style adaptation of the source photograph: stylised with AnimeGANv2 (Shinkai style) and a colour, cel-shading, line-art and glow finishing pass (`scripts/anime-backgrounds.py`). The app crops it to fit the screen and applies CSS colour grading for dusk and night. The photograph and this adaptation remain under CC BY-SA 4.0. The photographer does not endorse this app. Photographed signage belongs to its respective owners.

# Other scenes

The Ikebukuro, Akihabara, Shinjuku, school hallway and music room backgrounds were converted to an anime style with the same pipeline.

# GiGO Akihabara background set

`gigo-day.jpg`, `gigo-dusk.jpg` and `gigo-night.jpg` were painted with OpenAI image generation using the user's own photographs of GiGO Akihabara Building 1 as references. The three lighting variants share one composition. Native outputs were 1586×992; the delivered 2560×1600 images are Lanczos upscales approved by the user. Signage and advertising shown in the scene belong to their respective owners. Composition coordinates and output details are in `gigo-layout.json`.

`gigo-occluders-*.png` and `gigo-viaduct-occluders-*.png` are cut-outs of the same three images (corner bollards, lamp posts, railings, shrubs and the viaduct's catenary poles), drawn over the animated traffic and trains so they pass behind them. The set is included in public builds.

# Miku's room

`room-day.jpg`, `room-dusk.jpg` and `room-night.jpg` are original OpenAI-generated anime bedroom backgrounds. The existing music-room image was used as a style reference. Dusk and night edit the same daytime composition; outputs were registered to the day image and resized from 1586×992 to 2560×1600 with Lanczos resampling. The prompt specifies an empty music bedroom, turquoise bedding, an unobstructed left foreground, and daylight, sunset or moonlight with a bedside lamp. Asset hashes, measured coordinates and registration results are in `room-layout.json`. `room-blanket-*.png` are cut-outs of the blanket from the same three images (one polygon traced on the day image and applied to all three), drawn over Miku while she sleeps so she lies under the covers.

# Shibuya scramble crossing

`shibuya-scramble-day.jpg`, `shibuya-scramble-dusk.jpg` and `shibuya-scramble-night.jpg` were painted with OpenAI image generation using the user's own photographs, primarily `IMG_6817.HEIC` and `IMG_6818.HEIC`, as architectural references. The daytime composition was reframed as a level street view with an empty crossing and foreground pavement; identifiable signs were replaced with abstract artwork. Dusk and night are lighting edits of the same final daytime image. Native 1586×992 outputs were resized to 2560×1600 using the user-approved Lanczos upscale workflow. No registration warp was needed: SIFT correspondence displacement P95 is 1.530 px for dusk and 1.653 px for night at delivery size. Asset hashes, prompt summaries and approximate composition coordinates are recorded in `shibuya-scramble-layout.json`. The original user photographs and video are not included in these assets.
