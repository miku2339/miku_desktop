#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT') {
    throw 'Miku Desktop for Windows requires Windows 10 or 11.'
}

$repo = 'miku2339/miku_desktop'
$installerName = 'MikuDesktop-Windows-x64-setup.exe'

function Find-WindowsInstaller {
    $page = 1
    do {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=100&page=$page" -Headers @{ Accept = 'application/vnd.github+json' } -UserAgent 'MikuDesktop-Installer'
        foreach ($release in $releases) {
            if ($release.draft -or $release.prerelease) { continue }
            foreach ($asset in $release.assets) {
                if ($asset.name -cne $installerName -or $asset.state -ne 'uploaded') { continue }
                if ($asset.digest -notmatch '^sha256:([0-9a-f]{64})$') {
                    throw 'GitHub did not provide a SHA-256 digest for the Windows installer.'
                }
                $tag = [Uri]::EscapeDataString($release.tag_name)
                return @{
                    Url = "https://github.com/$repo/releases/download/$tag/$installerName"
                    Hash = $asset.digest.Substring(7)
                    Version = $release.tag_name
                }
            }
        }
        $page++
    } while ($releases.Count -eq 100)
    throw "No Windows x64 installer has been published at https://github.com/$repo/releases."
}

$previousTls = [Net.ServicePointManager]::SecurityProtocol
$tempDir = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    $installer = Find-WindowsInstaller
    $tempDir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ("MikuDesktop-" + [Guid]::NewGuid()))
    $file = Join-Path $tempDir.FullName $installerName
    Write-Host "Downloading Miku Desktop $($installer.Version)..."
    Invoke-WebRequest -UseBasicParsing -Uri $installer.Url -OutFile $file
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $installer.Hash) {
        throw 'The downloaded installer failed SHA-256 verification.'
    }
    $setup = Start-Process -FilePath $file -ArgumentList '/S' -Wait -PassThru
    if ($setup.ExitCode -ne 0) {
        throw "Miku Desktop setup exited with code $($setup.ExitCode)."
    }
    Write-Host "Miku Desktop $($installer.Version) installed. Open it from the Start menu."
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousTls
    if ($tempDir) { Remove-Item -LiteralPath $tempDir.FullName -Recurse -Force }
}
