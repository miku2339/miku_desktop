# Third-party notices

## three.js and MMD runtime

Vendored from [three.js r171](https://github.com/mrdoob/three.js/tree/r171), including its MMD loader, shader, parser and TGA loader. See `Wallpaper/companion/vendor/THREE-LICENSE.txt` and the individual file headers for attribution and license terms.

## Hatsune Miku model

Animasa Hatsune Miku v2.3, originally bundled with MikuMikuDance. The model and eye texture are fetched separately from the [three.js r171 Miku example](https://github.com/mrdoob/three.js/tree/r171/examples/models/mmd/miku). See `Wallpaper/assets/companion-model/readme_miku_v2.txt`, `readme.txt` and `ASSET-NOTICE.txt`. These assets are not covered by the three.js or project MIT license.

Hatsune Miku is a character of Crypton Future Media, Inc. Consult [Piapro character licensing](https://piapro.jp/license/character_guideline) for character use. The repository does not include model weights or character model binaries. A local build may contain the separately downloaded character model; the build does not grant redistribution rights.

## Backgrounds and marks

The generated Tokyo and school backgrounds are recreations inspired by real locations and the atmosphere of the official [セカイ music video](https://www.youtube.com/watch?v=9vyIPWBeRes). They are not official music-video frames. Generated fallback character artwork remains subject to the character owner's rights.

The JR East mark is reproduced without distortion from the [JR East logo SVG](https://commons.wikimedia.org/wiki/File:JR_East_logo.svg), whose original source is JR East. It remains a mark of its owner and is not licensed under this project's MIT license.

## AI backend and model

[oMLX](https://github.com/jundot/omlx) and [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) are separate components and are not bundled. The default MLX conversion is [mlx-community/Qwen3.5-0.8B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-4bit). Their respective licenses apply.
