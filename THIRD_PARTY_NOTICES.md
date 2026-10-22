# Third-party notices

Project-owned source code is licensed separately under the [PolyForm Noncommercial License 1.0.0](LICENSE). The notices below continue to apply to their respective third-party code and assets.

## three.js and MMD runtime

Vendored from [three.js r171](https://github.com/mrdoob/three.js/tree/r171), including its MMD loader, shader, parser, TGA loader and OutlineEffect. See `Wallpaper/companion/vendor/THREE-LICENSE.txt` and the individual file headers for attribution and license terms.

## Hatsune Miku model

Animasa Hatsune Miku v2.3, originally bundled with MikuMikuDance. The model and eye texture are fetched separately from the [three.js r171 Miku example](https://github.com/mrdoob/three.js/tree/r171/examples/models/mmd/miku). See `Wallpaper/assets/companion-model/readme_miku_v2.txt`, `readme.txt` and `ASSET-NOTICE.txt`. These assets are not covered by the three.js MIT license or the project’s PolyForm Noncommercial license.

Hatsune Miku is a character of Crypton Future Media, Inc. Consult [Piapro character licensing](https://piapro.jp/license/character_guideline) for character use. The repository does not include model weights or character model binaries. A local build may contain the separately downloaded character model; the build does not grant redistribution rights.

The optional detailed classic-outfit model is **Tda式初音ミク デフォ服ver v1.1**, edited by **金子卵黄** from **Tda**'s model. Obtain it from the [author's original distribution](https://bowlroll.net/file/16344). Keep `ReadMe_Tda.txt`, `ReadMe_Tda_English.txt` and `ReadMe_金子卵黄.txt` with the locally imported assets. Both authors prohibit redistribution of the unmodified original data. The optional model and its textures are excluded from this repository and must not be included in public binary releases.

## Background photograph and generated artwork

The Shibuya background is **JR Shibuya Station Hachiko Gates.jpg** by **Mister0124**, obtained from the [original Wikimedia Commons file page](https://commons.wikimedia.org/wiki/File:JR_Shibuya_Station_Hachiko_Gates.jpg) under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The background at `Wallpaper/assets/scenes/shibuya-hachiko.png` is a semi-anime adaptation produced with image editing, based on the photograph. The station perspective, ticket gates and original sign placement are retained; textures and lighting are stylized. All three time-of-day views use this adapted image, with responsive display cropping and CSS color grading for dusk and night. The photograph and this visual adaptation remain under CC BY-SA 4.0; the project code is licensed separately. Photographed signage remains the property of its respective owners. Attribution is also bundled in `Wallpaper/assets/scenes/ATTRIBUTION.md`.

The other Tokyo and school backgrounds are generated recreations inspired by real locations and the atmosphere of the official [セカイ music video](https://www.youtube.com/watch?v=9vyIPWBeRes). They are not official music-video frames. Generated fallback character artwork remains subject to the character owner's rights.

## AI backend and model

[oMLX](https://github.com/jundot/omlx) and [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) are separate components and are not bundled. The default MLX conversion is [mlx-community/Qwen3.5-0.8B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-4bit). Their respective licenses apply.

## Anime background conversion

The scene backgrounds were converted with [AnimeGANv2](https://github.com/TachibanaYoshino/AnimeGANv2) (Shinkai style, by Xin Chen), followed by this project's finishing pass in `scripts/anime-backgrounds.py`. AnimeGANv2 is available for non-commercial use only; the model itself is not included in this repository. Do not use the converted backgrounds commercially without the AnimeGANv2 author's permission.

## Weather data

Live weather and sunrise / sunset times come from [Open-Meteo](https://open-meteo.com/) (CC BY 4.0). Only the chosen city's coordinates are sent; no other data leaves the Mac.
