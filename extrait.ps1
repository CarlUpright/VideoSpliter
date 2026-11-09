# Interactive video clip tool. Run: powershell -ExecutionPolicy Bypass -File extrait.ps1
$configFile = Join-Path $PSScriptRoot "config.json"   # saved paths (ffmpeg, output folder), not committed
$font       = "C\:/Windows/Fonts/arial.ttf"
$inv        = [Globalization.CultureInfo]::InvariantCulture
$utf8       = New-Object System.Text.UTF8Encoding($false)

function Clean([string]$s) { return $s.Trim().Trim('"').Trim("'") }

function Ask($q, $default) {
  $a = Read-Host $q
  if ([string]::IsNullOrWhiteSpace($a)) { return $default }
  return $a.Trim()
}

$config = @{}
if (Test-Path -LiteralPath $configFile) {
  try { (Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $config[$_.Name] = $_.Value } } catch {}
}
function Save-Config { $config | ConvertTo-Json | Set-Content -LiteralPath $configFile -Encoding UTF8 }

# Asks for a path. With a saved (or detected) value, Enter keeps it; typing a path replaces it.
# $isValid receives the cleaned input and returns the final path, or $null if invalid.
function Ask-Path([string]$label, [string]$suggested, [scriptblock]$isValid) {
  while ($true) {
    $prompt = if ($suggested) { "$label [$suggested] (Enter = keep, or type a new path)" } else { $label }
    $in = Clean (Read-Host $prompt)
    if ($in -eq "") { $in = $suggested }
    if ($in -ne "") {
      $r = & $isValid $in
      if ($r) { return $r }
    }
    Write-Host "Invalid or not found, try again." -ForegroundColor Yellow
  }
}

# Accepts the exe path or the folder containing it.
function Resolve-Exe([string]$p, [string]$exe) {
  if (Test-Path -LiteralPath $p -PathType Container) { $p = Join-Path $p $exe }
  if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
  return $null
}

function ToSeconds([string]$t) {
  $s = 0.0
  foreach ($p in ($t -replace '\s','').Split(':')) { $s = $s * 60 + [double]::Parse($p, $inv) }
  return $s
}
function Fmt([double]$s) { return [TimeSpan]::FromSeconds($s).ToString('hh\:mm\:ss') }
function Num([double]$n) { return $n.ToString('0.###', $inv) }

# Settings: saved value (or ffmpeg found in PATH) is offered as the default
$sugg = if ($config.ffmpeg) { $config.ffmpeg } else { (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source }
$ffmpeg = Ask-Path "Path to ffmpeg.exe (or its folder)" $sugg { param($p) Resolve-Exe $p "ffmpeg.exe" }

$ffprobe = Join-Path (Split-Path $ffmpeg) "ffprobe.exe"
if (-not (Test-Path -LiteralPath $ffprobe)) {
  $ffprobe = Ask-Path "Path to ffprobe.exe (or its folder)" (Get-Command ffprobe.exe -ErrorAction SilentlyContinue).Source { param($p) Resolve-Exe $p "ffprobe.exe" }
}

$outDir = Ask-Path "Output folder for the clips" $config.outDir {
  param($p)
  try { New-Item -ItemType Directory -Force -Path $p -ErrorAction Stop | Out-Null; return $p } catch { return $null }
}

$config.ffmpeg = $ffmpeg
$config.outDir = $outDir
Save-Config

function Invoke-Part($src, $p) {
  $reenc = ($p.Title -ne "") -or $p.Fade
  Write-Host ""
  if (-not $reenc) {
    Write-Host "Cutting without re-encoding (start may be a few seconds off, at the nearest keyframe)." -ForegroundColor Cyan
    & $ffmpeg -hide_banner -loglevel warning -stats -y `
      -ss (Num $p.Start) -i $src -t (Num ($p.End - $p.Start)) `
      -c copy -avoid_negative_ts make_zero $p.Dest
  } else {
    # With a title we start 1 s earlier so the title sits on the fade-in from black.
    $pre   = if ($p.Title -ne "") { [Math]::Min(1.0, $p.Start) } else { 0.0 }
    $from  = $p.Start - $pre
    $total = $p.End - $from
    $fo    = $total - 1
    $vf = @("fade=t=in:st=0:d=1")
    # aformat forces a named layout; AAC refuses unnamed ones such as "6 channels"
    $layouts = @{ 1 = @("mono","128k"); 2 = @("stereo","192k"); 6 = @("5.1","384k"); 8 = @("7.1","512k") }
    $lay = if ($layouts.ContainsKey($audioCh)) { $layouts[$audioCh] } else { @("stereo","192k") }
    $af = @("aformat=channel_layouts=$($lay[0])", "afade=t=in:st=0:d=1")
    if ($p.Title -ne "") {
      $txt = Join-Path $env:TEMP "titre_clip.txt"
      [IO.File]::WriteAllText($txt, $p.Title, $utf8)
      $txtFF = $txt.Replace('\','/').Replace(':','\:')
      $vf += "drawtext=fontfile='$font':textfile='$txtFF':fontcolor=white:fontsize=h/20:x=(w-text_w)/2:y=(h-text_h)/2:enable='lt(t,1)'"
    }
    if ($p.Fade) {
      $vf += "fade=t=out:st=$(Num $fo):d=1"
      $af += "afade=t=out:st=$(Num $fo):d=1"
    }
    $vf += "format=yuv420p"
    if ($audioCh -eq 0) { $audioNote = "no audio track"; $aargs = @("-an") }
    else {
      $audioNote = "audio kept as $($lay[0])"
      if (-not $layouts.ContainsKey($audioCh)) { $audioNote = "unusual $audioCh-channel audio converted to stereo" }
      $aargs = @("-af", ($af -join ","), "-c:a", "aac", "-b:a", $lay[1])
    }
    Write-Host "Re-encoding ($(Fmt $total) to process). Note: $audioNote." -ForegroundColor Cyan
    & $ffmpeg -hide_banner -loglevel warning -stats -y `
      -ss (Num $from) -i $src -t (Num $total) `
      -vf ($vf -join ",") @aargs `
      -c:v libx264 -crf 18 -preset fast $p.Dest
    if ($p.Title -ne "") { Remove-Item $txt -ErrorAction SilentlyContinue }
  }
  if ($LASTEXITCODE -eq 0) { Write-Host "Done -> $($p.Dest)" -ForegroundColor Green }
  else { Write-Host "ffmpeg reported an error." -ForegroundColor Red }
}

do {
  Write-Host ""
  Write-Host "=== New video ===" -ForegroundColor Cyan

  # Source file (quotes optional)
  do {
    $src = Clean (Read-Host "Video file (drag it here or paste the path)")
    $ok = Test-Path -LiteralPath $src -PathType Leaf
    if (-not $ok) { Write-Host "File not found." -ForegroundColor Yellow }
  } until ($ok)

  $dur = [double]::Parse((& $ffprobe -v error -show_entries format=duration -of csv=p=0 $src), $inv)
  $chOut = & $ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 $src
  $audioCh = if ($chOut) { [int]($chOut | Select-Object -First 1) } else { 0 }
  Write-Host "Video length: $(Fmt $dur), audio channels: $audioCh"
  $base = [IO.Path]::GetFileNameWithoutExtension($src)
  $hms  = '^(\d+):(\d+):(\d+)$'

  # Collect all the parts first, then process them
  $parts = @()
  do {
    Write-Host ""
    Write-Host "--- Part $($parts.Count + 1) ---" -ForegroundColor Cyan
    do {
      try {
        $start = ToSeconds (Read-Host "Start time (e.g. 1:36:06)")
        $endIn = Ask "End time (empty = end of video)" ""
        $end   = if ($endIn -eq "") { $dur } else { ToSeconds $endIn }
        $ok = ($start -ge 0) -and ($end -gt $start) -and ($end -le $dur + 0.5)
        if (-not $ok) { Write-Host "Invalid times (end must be after start and within the video)." -ForegroundColor Yellow }
      } catch { $ok = $false; Write-Host "Could not read that time." -ForegroundColor Yellow }
    } until ($ok)
    if ($end -gt $dur) { $end = $dur }

    $title = Ask "Title (empty = none)" ""
    $fade  = (Ask "Fade in/out? (Y/n)" "y") -match '^[yYoO]'

    $reenc   = ($title -ne "") -or $fade
    $ext     = if ($reenc) { ".mp4" } else { [IO.Path]::GetExtension($src) }
    $defName = "$base ($((Fmt $start) -replace $hms,'$1h$2m$3s')-$((Fmt $end) -replace $hms,'$1h$2m$3s'))"
    $name    = (Ask "Output name without extension (empty = '$defName')" $defName) -replace '[\\/:*?"<>|]','-'

    $parts += [pscustomobject]@{
      Start = $start; End = $end; Title = $title; Fade = $fade
      Dest  = Join-Path $outDir "$name$ext"
    }
    $more = (Ask "Add another part from this video? (y/N)" "n") -match '^[yYoO]'
  } while ($more)

  $i = 0
  foreach ($p in $parts) {
    $i++
    Write-Host ""
    Write-Host "=== [$i/$($parts.Count)] $([IO.Path]::GetFileName($p.Dest)) ===" -ForegroundColor Cyan
    Invoke-Part $src $p
  }

  Write-Host ""
  $again = (Ask "Another video? (Y/n)" "y") -match '^[yYoO]'
} while ($again)
