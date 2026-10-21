# Shibuya background photograph

JR Shibuya Station Hachiko Gates.jpg — Mister0124, 18 September 2019.

Source: https://commons.wikimedia.org/wiki/File:JR_Shibuya_Station_Hachiko_Gates.jpg
License: CC BY-SA 4.0 — https://creativecommons.org/licenses/by-sa/4.0/

shibuya-hachiko.png is an anime-style adaptation of the source photograph: stylised with AnimeGANv2 (Shinkai style) and a colour, cel-shading, line-art and glow finishing pass (`scripts/anime-backgrounds.py`). The app crops it to fit the screen and applies CSS colour grading for dusk and night. The photograph and this adaptation remain under CC BY-SA 4.0. The photographer does not endorse this app. Photographed signage belongs to its respective owners.

# Other scenes

The Ikebukuro, Akihabara, Shinjuku, school hallway and music room backgrounds were converted to an anime style with the same pipeline.

# GiGO Akihabara background set

`gigo-day.jpg`, `gigo-dusk.jpg` and `gigo-night.jpg` were painted with OpenAI image generation using the user's own photographs of GiGO Akihabara Building 1 as references. The three lighting variants share one composition. Native outputs were 1586×992; the delivered 2560×1600 images are Lanczos upscales approved by the user. Signage and advertising shown in the scene belong to their respective owners. Composition coordinates and output details are in `gigo-layout.json`.

`gigo-occluders-*.png` and `gigo-viaduct-occluders-*.png` are cut-outs of the same three images (corner bollards, lamp posts, railings, shrubs and the viaduct's catenary poles), drawn over the animated traffic and trains so they pass behind them. `scripts/build-app.sh --public` leaves this whole set out of shared builds.
