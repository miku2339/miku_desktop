# Windows counterpart of scripts/fetch-model.sh: downloads the default (Animasa) model that
# three.js ships as an example into Wallpaper/assets/companion-model and checks its hashes.
# The Tda model is never downloaded here; users import it themselves (AGENTS.md).
$ErrorActionPreference = 'Stop'

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$modelDir = Join-Path $projectRoot 'Wallpaper\assets\companion-model'
$sourceUrl = 'https://raw.githubusercontent.com/mrdoob/three.js/r171/examples/models/mmd/miku'
New-Item -ItemType Directory -Force -Path $modelDir | Out-Null

$assets = [ordered]@{
  'miku_v2.pmd'        = '45a5a2fb897266a1b371b30cf53ed9435d375ddea9fce7f095bba2739b9bdae5'
  'eyeM2.bmp'          = 'a318f2d5bd22e3ac3a5b8cab4021fd68e25042e7730e8c04720cee68e3548565'
  'readme.txt'         = '702a3f62567fc9c8becbdb47a73058683086ba75e236612a3e8e8d5486cd0a9e'
  'readme_miku_v2.txt' = '6732866be1a712d7af142fcbf59f7e3bab8691ea472f86bb674020b13d51355a'
}

foreach ($name in $assets.Keys) {
  $target = Join-Path $modelDir $name
  $expected = $assets[$name]
  if ((Test-Path $target) -and ((Get-FileHash -Algorithm SHA256 $target).Hash.ToLower() -eq $expected)) {
    continue
  }
  $temporary = "$target.download"
  Invoke-WebRequest -UseBasicParsing -Uri "$sourceUrl/$name" -OutFile $temporary
  if ((Get-FileHash -Algorithm SHA256 $temporary).Hash.ToLower() -ne $expected) {
    Remove-Item -Force $temporary
    throw "Checksum mismatch: $name"
  }
  Move-Item -Force $temporary $target
}

Write-Host 'Model ready. Read Wallpaper/assets/companion-model/readme_miku_v2.txt before use.'
