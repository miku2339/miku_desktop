param($request)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$p=$request.payload
function Await-WinRT($operation,[Type]$type) {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'} | Select-Object -First 1
  if(!$method){throw 'Windows Runtime task adapter is unavailable'}
  $task=$method.MakeGenericMethod($type).Invoke($null,@($operation))
  if(!$task.Wait(10000)){throw 'Windows Runtime request timed out'}
  return $task.GetAwaiter().GetResult()
}
function Get-MediaManager {
  $null=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
  $null=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime]
  return (Await-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]))
}
function Get-Media {
  $manager=Get-MediaManager
  $session=$manager.GetCurrentSession()
  if(!$session){return @{available=$true;session=$null}}
  $media=Await-WinRT ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
  $playback=$session.GetPlaybackInfo()
  return @{available=$true;session=@{app=$session.SourceAppUserModelId;title=$media.Title;artist=$media.Artist;album=$media.AlbumTitle;status=$playback.PlaybackStatus.ToString()};outboundSharing=$false}
}
function Control-Media([bool]$resume) {
  if($p.userInitiated -ne $true){throw 'Media control requires an explicit user call action'}
  $manager=Get-MediaManager
  $session=$manager.GetCurrentSession()
  if(!$session){return @{paused=$false;resumed=$false;reason='no-session'}}
  $media=Await-WinRT ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
  $identity=@{app=[string]$session.SourceAppUserModelId;title=[string]$media.Title;artist=[string]$media.Artist;album=[string]$media.AlbumTitle}
  $playback=$session.GetPlaybackInfo()
  if($resume) {
    foreach($key in @('app','title','artist','album')) {
      if([string]$identity[$key] -cne [string]$p.resume.$key){return @{resumed=$false;reason='session-changed'}}
    }
    if($playback.PlaybackStatus.ToString() -ne 'Paused'){return @{resumed=$false;reason='not-paused'}}
    if(!$playback.Controls.IsPlayEnabled){return @{resumed=$false;reason='play-unavailable'}}
    $changed=Await-WinRT ($session.TryPlayAsync()) ([bool])
    return @{resumed=[bool]$changed;reason=$(if($changed){'resumed'}else{'play-rejected'})}
  }
  if($playback.PlaybackStatus.ToString() -ne 'Playing'){return @{paused=$false;reason='not-playing'}}
  if(!$playback.Controls.IsPauseEnabled){return @{paused=$false;reason='pause-unavailable'}}
  $changed=Await-WinRT ($session.TryPauseAsync()) ([bool])
  return @{paused=[bool]$changed;resume=$(if($changed){$identity}else{$null});reason=$(if($changed){'paused'}else{'pause-rejected'})}
}
function Fetch-Json([string]$url) {
  $query=[Net.HttpWebRequest]::Create($url)
  $query.AllowAutoRedirect=$false;$query.Timeout=15000;$query.ReadWriteTimeout=15000
  $query.UserAgent='MikuDesktop-Windows/1.0';$query.Accept='application/json'
  $response=$null;$stream=$null;$buffer=$null
  try {
    $response=$query.GetResponse()
    if([int]$response.StatusCode -ne 200){throw 'Service returned an unexpected HTTP status'}
    $stream=$response.GetResponseStream();$buffer=[IO.MemoryStream]::new();$bytes=New-Object byte[] 8192
    while(($count=$stream.Read($bytes,0,$bytes.Length)) -gt 0){
      if($buffer.Length+$count -gt 1048576){throw 'Service response exceeded its size limit'}
      $buffer.Write($bytes,0,$count)
    }
    return ([Text.Encoding]::UTF8.GetString($buffer.ToArray()) | ConvertFrom-Json)
  } finally {if($stream){$stream.Dispose()};if($buffer){$buffer.Dispose()};if($response){$response.Dispose()}}
}
function Get-Voices {
  Add-Type -AssemblyName System.Speech
  $synth=[System.Speech.Synthesis.SpeechSynthesizer]::new()
  try {
    $voices=@($synth.GetInstalledVoices() | ForEach-Object {@{id=$_.VoiceInfo.Name;name=$_.VoiceInfo.Name;language=$_.VoiceInfo.Culture.Name;gender=$_.VoiceInfo.Gender.ToString();enabled=$_.Enabled}})
    $recognizers=@([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | ForEach-Object {@{id=$_.Id;name=$_.Name;language=$_.Culture.Name}})
    return @{voices=$voices;recognizers=$recognizers;ttsAvailable=(@($voices | Where-Object {$_.enabled}).Count -gt 0);sttAvailable=($recognizers.Count -gt 0);engine='System.Speech'}
  } finally {$synth.Dispose()}
}
function Get-AudioDevices {
  $null=[Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
  $null=[Windows.Devices.Enumeration.DeviceInformationCollection,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
  $null=[Windows.Media.Devices.MediaDevice,Windows.Media.Devices,ContentType=WindowsRuntime]
  $result=@{}
  foreach($kind in @('capture','render')) {
    if($kind -eq 'capture'){$selector=[Windows.Media.Devices.MediaDevice]::GetAudioCaptureSelector()}else{$selector=[Windows.Media.Devices.MediaDevice]::GetAudioRenderSelector()}
    $devices=Await-WinRT ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    $result[$kind]=@($devices | ForEach-Object {@{id=$_.Id;name=$_.Name;enabled=$_.IsEnabled}})
  }
  return $result
}
function Speak-Text {
  Add-Type -AssemblyName System.Speech
  Add-Type -ReferencedAssemblies @([System.Speech.Synthesis.SpeechSynthesizer].Assembly.Location) -TypeDefinition @'
using System;
using System.Speech.Synthesis;
public static class MikuSpeechHost {
 public static void Run(string text,string voice,string language,int rate) {
  using(var synth=new SpeechSynthesizer()) {
   if(!String.IsNullOrEmpty(voice)) synth.SelectVoice(voice);
   else if(!String.IsNullOrEmpty(language)) {
    var requested=new System.Globalization.CultureInfo(language);
    bool found=false;
    foreach(var installed in synth.GetInstalledVoices()) {
     if(installed.Enabled && installed.VoiceInfo.Culture.Name.Equals(language,StringComparison.OrdinalIgnoreCase)) {
      synth.SelectVoice(installed.VoiceInfo.Name);found=true;break;
     }
    }
    if(!found && !language.Equals("zh-HK",StringComparison.OrdinalIgnoreCase) && !language.StartsWith("yue",StringComparison.OrdinalIgnoreCase)) {
     foreach(var installed in synth.GetInstalledVoices()) {
      var culture=installed.VoiceInfo.Culture;
      if(requested.TwoLetterISOLanguageName.Equals("zh",StringComparison.OrdinalIgnoreCase) && !culture.Name.Equals("zh-TW",StringComparison.OrdinalIgnoreCase) && !culture.Name.Equals("zh-CN",StringComparison.OrdinalIgnoreCase)) continue;
      if(installed.Enabled && !culture.Name.Equals("zh-HK",StringComparison.OrdinalIgnoreCase) && culture.TwoLetterISOLanguageName.Equals(requested.TwoLetterISOLanguageName,StringComparison.OrdinalIgnoreCase)) {
       synth.SelectVoice(installed.VoiceInfo.Name);found=true;break;
      }
     }
    }
    if(!found) throw new InvalidOperationException("No installed voice supports the selected language");
   }
   synth.Rate=rate;
   synth.SpeakStarted += delegate { Console.WriteLine("{\"event\":\"voice-start\"}");Console.Out.Flush(); };
   synth.SpeakCompleted += delegate { Console.WriteLine("{\"event\":\"voice-end\"}");Console.Out.Flush(); };
   synth.Speak(text);
  }
 }
}
'@
  [MikuSpeechHost]::Run([string]$p.text,[string]$p.voice,[string]$p.language,[int]$p.rate)
  return @{completed=$true}
}
function Listen-Once {
  if($p.userInitiated -ne $true){throw 'Start speech input with the microphone button first'}
  Add-Type -AssemblyName System.Speech
  $installed=@([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers())
  if(!$installed.Count){throw 'No Windows speech recognizer is installed'}
  $language=[string]$p.language
  if([string]::IsNullOrEmpty($language)) {
    $recognizer=$installed | Where-Object {$_.Culture.Name -eq [Globalization.CultureInfo]::CurrentUICulture.Name} | Select-Object -First 1
    if(!$recognizer){$recognizer=$installed[0]}
  } else {
    $recognizer=$installed | Where-Object {$_.Culture.Name -eq $language} | Select-Object -First 1
    if(!$recognizer -and $language -ne 'zh-HK' -and !$language.StartsWith('yue',[StringComparison]::OrdinalIgnoreCase)) {
      $base=[Globalization.CultureInfo]::GetCultureInfo($language).TwoLetterISOLanguageName
      $recognizer=$installed | Where-Object {$_.Culture.Name -ne 'zh-HK' -and $_.Culture.TwoLetterISOLanguageName -eq $base -and ($base -ne 'zh' -or $_.Culture.Name -in @('zh-TW','zh-CN'))} | Select-Object -First 1
    }
  }
  if(!$recognizer){throw 'No installed speech recognizer supports the selected language'}
  $engine=[System.Speech.Recognition.SpeechRecognitionEngine]::new($recognizer)
  try {
    $engine.LoadGrammar([System.Speech.Recognition.DictationGrammar]::new())
    $engine.InitialSilenceTimeout=[TimeSpan]::FromSeconds([double]$p.seconds)
    $engine.BabbleTimeout=[TimeSpan]::FromSeconds([double]$p.seconds)
    $engine.EndSilenceTimeout=[TimeSpan]::FromMilliseconds(700)
    $engine.SetInputToDefaultAudioDevice()
    $result=$engine.Recognize([TimeSpan]::FromSeconds([double]$p.seconds))
    if(!$result){return @{text='';confidence=0;noSpeech=$true;language=$recognizer.Culture.Name}}
    return @{text=$result.Text;confidence=$result.Confidence;noSpeech=$false;language=$recognizer.Culture.Name}
  } finally {$engine.SetInputToNull();$engine.Dispose()}
}
function Get-Weather {
  $latitude=([double]$p.latitude).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
  $longitude=([double]$p.longitude).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
  $timezone=[uri]::EscapeDataString([string]$p.timezone)
  $data=Fetch-Json "https://api.open-meteo.com/v1/forecast?latitude=$latitude&longitude=$longitude&current=weather_code,cloud_cover,wind_speed_10m,wind_direction_10m,temperature_2m&daily=sunrise,sunset&timezone=$timezone&forecast_days=1"
  if(!$data.current){throw 'Weather service returned no current weather'}
  $code=[int]$data.current.weather_code;$kind='cloudy';$intensity=0.5
  switch($code) {
    {$_ -in @(0,1)} {$kind='clear';$intensity=0;break}
    2 {$kind='cloudy';$intensity=0.4;break}
    3 {$kind='cloudy';$intensity=0.8;break}
    {$_ -in @(45,48)} {$kind='fog';$intensity=0.75;break}
    {$_ -in @(51,53,55,56,57)} {$kind='rain';$intensity=0.3;break}
    {$_ -in @(61,80)} {$kind='rain';$intensity=0.45;break}
    {$_ -in @(63,81,66)} {$kind='rain';$intensity=0.65;break}
    {$_ -in @(65,82,67)} {$kind='rain';$intensity=0.9;break}
    {$_ -in @(71,77,85)} {$kind='snow';$intensity=0.4;break}
    73 {$kind='snow';$intensity=0.65;break}
    {$_ -in @(75,86)} {$kind='snow';$intensity=0.9;break}
    {$_ -in @(95,96,99)} {$kind='storm';$intensity=0.9;break}
  }
  $speed=8.0;if($null -ne $data.current.wind_speed_10m){$speed=[double]$data.current.wind_speed_10m}
  $direction=270.0;if($null -ne $data.current.wind_direction_10m){$direction=[double]$data.current.wind_direction_10m}
  $wind=-[Math]::Sin($direction*[Math]::PI/180)*[Math]::Min(1,$speed/35)
  $cloud=0.3;if($null -ne $data.current.cloud_cover){$cloud=[double]$data.current.cloud_cover/100}
  $sun=@{sunrise=$null;sunset=$null}
  foreach($event in @('sunrise','sunset')) {
    if($data.daily.$event.Count -gt 0){
      $time=[DateTime]::ParseExact([string]$data.daily.$event[0],"yyyy-MM-dd'T'HH:mm",[Globalization.CultureInfo]::InvariantCulture)
      $local=[DateTimeOffset]::new([DateTime]::SpecifyKind($time,[DateTimeKind]::Unspecified),[TimeSpan]::FromSeconds([int]$data.utc_offset_seconds)).ToLocalTime()
      $sun[$event]=$local.Hour+$local.Minute/60.0
    }
  }
  return @{kind=$kind;intensity=$intensity;wind=$wind;cloud=$cloud;temperature=$data.current.temperature_2m;sunrise=$sun.sunrise;sunset=$sun.sunset;isLive=$true;source='Open-Meteo';latitude=$p.latitude;longitude=$p.longitude}
}
function Check-Update {
  try {$release=Fetch-Json 'https://api.github.com/repos/miku2339/miku_desktop/releases/latest'}
  catch {if($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404){return @{status='noRelease'}};throw}
  if($release.draft -or $release.prerelease){return @{status='noRelease'}}
  $tag=[string]$release.tag_name
  if($tag -notmatch '^v?\d+\.\d+\.\d+(\.\d+)?$'){throw 'Release version is invalid'}
  $page=[uri]$release.html_url
  if($page.Scheme -ne 'https' -or $page.Host -ne 'github.com' -or !$page.IsDefaultPort -or $page.UserInfo -or $page.Query -or $page.Fragment -or $page.AbsolutePath -ne "/miku2339/miku_desktop/releases/tag/$tag"){throw 'Release page is outside the project repository'}
  $assets=@($release.assets | Where-Object {
    $_.state -eq 'uploaded' -and $_.size -gt 0 -and $_.name -match '(?i)^miku[ ._-]?desktop.*(windows.*\.(zip|exe|msi)|(x64|x86_64|arm64|aarch64).*\.(exe|msi))$' -and
    ([uri]$_.browser_download_url).Scheme -eq 'https' -and ([uri]$_.browser_download_url).Host -eq 'github.com' -and
    ([uri]$_.browser_download_url).AbsolutePath.StartsWith("/miku2339/miku_desktop/releases/download/$tag/",[StringComparison]::Ordinal)
  })
  if(!$assets.Count){return @{status='noRelease'}}
  $version=$tag.TrimStart('v')
  if([version]$version -le [version]$p.currentVersion){return @{status='upToDate';version=$version}}
  return @{status='available';version=$version;pageURL=$page.AbsoluteUri}
}
function Import-Tda {
  Add-Type -AssemblyName System.IO.Compression
  $source=[IO.FileInfo]::new([string]$p.path)
  if(!$source.Exists -or $source.Length -le 0 -or $source.Length -gt 12582912 -or (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne '79baabda41248efe06a3e401ae137f34ce8a20b73db6f76c9039ff9c6b673f92'){throw 'Select the author-original Tda v1.1 ZIP from https://bowlroll.net/file/16344'}
  $hashes=@{
    'body00_s.bmp'='ec4d2ba9b86638e91268fec13f7472934ce493748d2b810ca4602222b80d6ce7'
    'body01_s.bmp'='428847cb0a5038c576dbd754402973de3ba1e95a94c8c988dde78883d025db7a'
    'body02_MikuAp.tga'='5e397b2c3b46805e49f6d8c5a440aee9fafda9a83c08c53cee552dac35ecc80f'
    'hair_MikuAp.png'='1d215253ddc25ae9d6d1309bf3b6ea2a9f9a9b79d10c76a49bba14ccac25d37d'
    'hair_s.bmp'='84b32daa627d6835b50f81c6279d84a89f398fa645fc5f7b711435c935dcc95b'
    'k_Asi2.png'='ea24137369a45963c052f94c0ba6f983e98cebbec286806fe344dde970cd5c33'
    'k_face_MikuAp.tga'='3da7bf0d5a62606f2e28344bab9bc69d64c05e90558fcdb487ff879e115308df'
    'k_Hada.png'='45b45a939c17f98cf6dc4eebb1ea128c1b336e2428d0f9906a91eaba2dc3ea2b'
    'k_hika.png'='00893ed908c3a132829fc95fdc437f3a165b3953334c0a08ee63525aeea6a619'
    'k_huku1.png'='640e14bb2935cc814f403aa2271e9f7342df5ec55ce75672f9181a858e74454f'
    'k_huku2.png'='440c6f705d33c92edba20539a8ff922efd5e737e934eb47ac06d4b61ec6f4797'
    'ReadMe_Tda.txt'='5b732de972eb58d258bd5294c2a2c9927d26931961b414130131ab248ddf9fb6'
    'ReadMe_Tda_English.txt'='62ccff079e89a2e8e1ec073aefcc3c57da37012742495021ccc79abd490dbf20'
    'ReadMe_金子卵黄.txt'='12594f475d34935cd4a40f4061dbab05783b19a5dbb03f4e3aab4b9e47616d3d'
    'skin_s.bmp'='009219d37c409d1b496e94897343e85af8ff03162bcdb0ee90b859a5708a3ab1'
    'miku.pmx'='7ef24d4d43eba55b2125f62c69edb674bab61e835df7c0f2cd03b94572498966'
    'toon_defo.bmp'='5df98b15c19816f9f8701a4e1cb8c568879285a6a6340fee84a4fb8b87e4f6ea'
    'toon_hair.bmp'='61297ea34a2b7f4a0239506ed801a58ea7747d31800316278491c14f04749dd6'
    'toon_skin.bmp'='48b04e38f6a559f0ebdb748ea65addeafd529a988b0b9b3cddcdcdf7d7e8000f'
  }
  $parent=Join-Path $request.dataDir 'CharacterModels';$destination=Join-Path $parent 'tda'
  $null=[IO.Directory]::CreateDirectory($parent)
  foreach($folder in @($parent,$destination)) {if((Test-Path -LiteralPath $folder) -and ((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The Tda model destination must not be a link'}}
  $stage=Join-Path $parent ('.tda-import-'+[Guid]::NewGuid().ToString('N'))
  $previous=$stage+'-previous';$replacing=Test-Path -LiteralPath $destination
  $null=[IO.Directory]::CreateDirectory($stage)
  $file=$null;$zip=$null
  try {
    $file=[IO.File]::OpenRead($source.FullName)
    $zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Read,$false,[Text.Encoding]::GetEncoding(932))
    $seen=@{}
    foreach($entry in $zip.Entries) {
      if($entry.FullName.EndsWith('/')){continue}
      $parts=$entry.FullName.Split('/')
      if($parts.Count -ne 2 -or $parts[0] -cne 'Tda式デフォ服ミク_ver1.1'){throw 'Unexpected author archive layout'}
      $name=$parts[1];if([IO.Path]::GetExtension($name).ToLowerInvariant() -eq '.pmx'){$name='miku.pmx'}
      if(!$hashes.ContainsKey($name) -or $seen.ContainsKey($name) -or $entry.Length -gt 67108864){throw 'Unexpected or duplicate model archive entry'}
      $seen[$name]=$true;$inputStream=$entry.Open();$output=[IO.File]::Create((Join-Path $stage $name))
      try{$inputStream.CopyTo($output)}finally{$inputStream.Dispose();$output.Dispose()}
      if((Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[$name]){throw 'Model asset checksum mismatch'}
    }
    if($seen.Count -ne $hashes.Count){throw 'Author archive is missing model assets or terms'}
    $zip.Dispose();$zip=$null;$file.Dispose();$file=$null
    if($replacing){[IO.Directory]::Move($destination,$previous)}
    try{[IO.Directory]::Move($stage,$destination)}catch{if($replacing){[IO.Directory]::Move($previous,$destination)};throw}
    if(Test-Path -LiteralPath $previous){[IO.Directory]::Delete($previous,$true)}
    return @{imported=$true;path=$destination;files=$hashes.Count;model='Tda式デフォ服ミク';private=$true}
  } finally {if($zip){$zip.Dispose()};if($file){$file.Dispose()};if(Test-Path -LiteralPath $stage){[IO.Directory]::Delete($stage,$true)}}
}
try {
  $result=switch([string]$request.action) {
    'voices' {Get-Voices;break}
    'audio_devices' {Get-AudioDevices;break}
    'system_info' {@{osVersion=[Environment]::OSVersion.Version.ToString();timeZone=[TimeZoneInfo]::Local.Id;localTime=[DateTimeOffset]::Now.ToString('o');language=[Globalization.CultureInfo]::CurrentUICulture.Name;microphoneRead=$false};break}
    'media' {Get-Media;break}
    'media_pause' {Control-Media $false;break}
    'media_resume' {Control-Media $true;break}
    'speak' {Speak-Text;break}
    'play_audio' {
      Add-Type -AssemblyName System
      $player=[Media.SoundPlayer]::new([string]$p.path)
      try{$player.Load();[Console]::WriteLine('{"event":"voice-start"}');[Console]::Out.Flush();$player.PlaySync();[Console]::WriteLine('{"event":"voice-end"}');[Console]::Out.Flush();@{completed=$true}}finally{$player.Dispose()}
      break
    }
    'listen_once' {Listen-Once;break}
    'weather' {Get-Weather;break}
    'update_check' {Check-Update;break}
    'pick_tda' {
      Add-Type -AssemblyName System.Windows.Forms
      $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Filter='ZIP archives (*.zip)|*.zip';$dialog.CheckFileExists=$true;$dialog.Multiselect=$false
      try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){@{path=$dialog.FileName}}else{@{path=$null}}}finally{$dialog.Dispose()}
      break
    }
    'pick_file' {
      Add-Type -AssemblyName System.Windows.Forms
      $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.CheckFileExists=$true;$dialog.Multiselect=$false
      switch([string]$p.kind){
        'image' {$dialog.Filter='Images (*.png;*.jpg;*.jpeg;*.webp)|*.png;*.jpg;*.jpeg;*.webp'}
        'audio' {$dialog.Filter='WAV audio (*.wav)|*.wav'}
        'json' {$dialog.Filter='JSON document (*.json)|*.json'}
        'zip' {$dialog.Filter='ZIP archive (*.zip)|*.zip'}
        default {$dialog.Filter='Documents (*.json;*.txt)|*.json;*.txt'}
      }
      try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){@{path=$dialog.FileName}}else{@{path=$null}}}finally{$dialog.Dispose()}
      break
    }
    'autostart' {
      $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
      try {
        if($null -ne $p.enabled){if($p.enabled){$key.SetValue('MikuDesktop',('"'+[string]$p.executable+'"'))}else{$key.DeleteValue('MikuDesktop',$false)}}
        @{enabled=($null -ne $key.GetValue('MikuDesktop'))}
      } finally {$key.Dispose()}
      break
    }
    'open_url' {
      $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[string]$p.url;$start.UseShellExecute=$true
      $null=[Diagnostics.Process]::Start($start);@{opened=$true};break
    }
    'open_data' {
      $null=[IO.Directory]::CreateDirectory([string]$request.dataDir)
      $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[string]$request.dataDir;$start.UseShellExecute=$true
      $null=[Diagnostics.Process]::Start($start);@{opened=$true};break
    }
    'export_file' {
      Add-Type -AssemblyName System.Windows.Forms
      $extension=[IO.Path]::GetExtension([string]$p.sourcePath)
      $dialog=[Windows.Forms.SaveFileDialog]::new();$dialog.Filter=('Album image (*'+$extension+')|*'+$extension);$dialog.DefaultExt=$extension.TrimStart('.');$dialog.AddExtension=$true;$dialog.OverwritePrompt=$true;$dialog.FileName=[string]$p.suggestedName
      try {
        if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){@{path=$null;cancelled=$true}}
        else {
          if([IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant() -ne $extension.ToLowerInvariant()){throw 'Keep the original image file extension'}
          [IO.File]::Copy([string]$p.sourcePath,$dialog.FileName,$true);@{path=$dialog.FileName;cancelled=$false}
        }
      } finally {$dialog.Dispose()}
      break
    }
    'export_json' {
      Add-Type -AssemblyName System.Windows.Forms
      $dialog=[Windows.Forms.SaveFileDialog]::new();$dialog.Filter='JSON document (*.json)|*.json';$dialog.DefaultExt='json';$dialog.AddExtension=$true;$dialog.OverwritePrompt=$true;$dialog.FileName=[string]$p.suggestedName
      try {
        if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){@{path=$null;cancelled=$true}}
        else {
          if([IO.Path]::GetExtension($dialog.FileName).ToLowerInvariant() -ne '.json'){throw 'Use a JSON file extension'}
          [IO.File]::WriteAllText($dialog.FileName,[string]$p.document,[Text.UTF8Encoding]::new($false));@{path=$dialog.FileName;cancelled=$false}
        }
      } finally {$dialog.Dispose()}
      break
    }
    'capture_screen' {
      if($p.userInitiated -ne $true -and $p.screenAwarenessEnabled -ne $true){throw 'Screen capture requires an explicit user action or enabled screen awareness'}
      Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
      $bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds
      $bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
      $small=$null;$canvas=$null;$stream=$null
      try {
        $graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size)
        $width=[Math]::Min(1024,$bounds.Width);$height=[int]($bounds.Height*$width/$bounds.Width)
        $small=[Drawing.Bitmap]::new($width,$height);$canvas=[Drawing.Graphics]::FromImage($small);$canvas.DrawImage($bitmap,0,0,$width,$height)
        $stream=[IO.MemoryStream]::new();$small.Save($stream,[Drawing.Imaging.ImageFormat]::Jpeg)
        @{dataURL=('data:image/jpeg;base64,'+[Convert]::ToBase64String($stream.ToArray()));width=$width;height=$height;stored=$false}
      } finally {if($stream){$stream.Dispose()};if($canvas){$canvas.Dispose()};if($small){$small.Dispose()};$graphics.Dispose();$bitmap.Dispose()}
      break
    }
    default {throw 'Unknown Windows platform helper action'}
  }
  [Console]::WriteLine((@{ok=$true;value=$result}|ConvertTo-Json -Depth 12 -Compress))
} catch {
  [Console]::WriteLine((@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Depth 4 -Compress))
  exit 1
}
