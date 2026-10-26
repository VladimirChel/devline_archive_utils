#requires -Version 5.1
<#
.SYNOPSIS
Burns the date/time from an embedded text subtitle track into MP4 video.
.EXAMPLE
.\Burn-Timestamp.ps1 -Mode GPU
.EXAMPLE
.\Burn-Timestamp.ps1 -Mode CPU -InputPath 'D:\Video' -Threads 4
.EXAMPLE
.\Burn-Timestamp.ps1 -Mode GPU -Stabilize
#>
[CmdletBinding()]
param(
    [ValidateSet('GPU', 'CPU')][string]$Mode = 'GPU',
    [string]$InputPath,
    [string]$OutputDirectory,
    [string]$FFmpegPath,
    [string]$FFprobePath,
    [ValidateRange(0, 32)][int]$SubtitleStream = 0,
    [ValidateRange(0, 51)][int]$Quality = 30,
    [ValidateSet('ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium')]
    [string]$CpuPreset = 'veryfast',
    [ValidateSet('p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7')]
    [string]$GpuPreset = 'p1',
    [ValidateRange(0, 128)][int]$Threads = 0,
    [ValidateRange(0, 100)][double]$PreviewSeconds = 0,
    [switch]$Resize1080p,
    [switch]$Stabilize,
    [ValidateRange(1, 1000)][int]$StabilizationSmoothing = 30,
    [ValidateRange(1, 10)][int]$StabilizationShakiness = 8,
    [ValidateRange(8, 100)][double]$FontSize = 24,
    [string]$FontName = 'Microsoft Sans Serif',
    [ValidateRange(0, 1000)][int]$MarginRight = 0,
    [ValidateRange(0, 1000)][int]$MarginBottom = 0,
    [switch]$ExactSubtitleGaps,
    [switch]$SoftwareDecode
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding($false)

function Resolve-Tool([string]$Explicit, [string]$Name) {
    if ($Explicit) { return (Resolve-Path -LiteralPath $Explicit).ProviderPath }
    foreach ($p in @((Join-Path $PSScriptRoot "bin\$Name.exe"), (Join-Path $PSScriptRoot "$Name.exe"))) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $cmd = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "$Name.exe not found. Put ffmpeg.exe and ffprobe.exe in the bin folder next to this script." }
    return $cmd.Source
}

function Get-Probe([string]$Path) {
    $json = & $script:probe -v error -show_streams -show_format -of json $Path
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed: $Path" }
    return (($json -join "`n") | ConvertFrom-Json)
}

function Invoke-FFmpegProgress([string[]]$Arguments, [double]$Expected, [string]$Stage = 'Progress') {
    $processedSeconds = 0.0
    $progressPercent = 0
    $encodingSpeed = '--'
    Write-Host -NoNewline ("{0}:   0%" -f $Stage)
    # Parse machine-readable stdout; keep stderr visible for diagnostics.
    & $script:ffmpeg @Arguments | ForEach-Object {
        $line = [string]$_
        if ($line -match '^out_time_us=(-?\d+)$') {
            $processedSeconds = [Math]::Max(0.0, [double]::Parse($Matches[1], $inv) / 1000000.0)
            $progressPercent = [Math]::Max($progressPercent,
                [Math]::Min(99, [int][Math]::Floor(100.0 * $processedSeconds / $Expected)))
        } elseif ($line -match '^speed=(.*)$') {
            $encodingSpeed = $Matches[1].Trim()
        } elseif ($line -match '^progress=') {
            Write-Host -NoNewline (("`r{0}: {1,3}% | {2:0.0}/{3:0.0} s | speed {4}        ") -f
                $Stage, $progressPercent, [Math]::Min($processedSeconds, $Expected), $Expected, $encodingSpeed)
        }
    }
    $ffmpegExitCode = $LASTEXITCODE
    Write-Host
    if ($ffmpegExitCode -ne 0) { throw "FFmpeg $Stage failed (exit $ffmpegExitCode)." }
}

function To-Milliseconds([string]$Time) {
    $m = [regex]::Match($Time, '^(\d+):(\d{2}):(\d{2}),(\d{3})$')
    if (-not $m.Success) { throw "Invalid subtitle time: $Time" }
    return ([long]$m.Groups[1].Value * 3600000 + [long]$m.Groups[2].Value * 60000 +
        [long]$m.Groups[3].Value * 1000 + [long]$m.Groups[4].Value)
}

function To-AssTime([long]$Ms) {
    $cs = [long][Math]::Round($Ms / 10.0, 0, [MidpointRounding]::AwayFromZero)
    $h = [long][Math]::Floor($cs / 360000.0)
    $m = [long][Math]::Floor(($cs % 360000) / 6000.0)
    $s = [long][Math]::Floor(($cs % 6000) / 100.0)
    return ('{0}:{1:00}:{2:00}.{3:00}' -f $h, $m, $s, ($cs % 100))
}

function Write-TimestampAss([string]$SrtPath, [string]$AssPath, [int]$Width, [int]$Height) {
    $srt = [IO.File]::ReadAllText($SrtPath, [Text.Encoding]::UTF8)
    $srt = $srt.Replace("`r`n", "`n").Trim([char]0xFEFF).Trim()
    $cues = New-Object 'System.Collections.Generic.List[object]'
    foreach ($block in [regex]::Split($srt, '\n\s*\n')) {
        $match = [regex]::Match($block, '(?s)^\s*\d+\s*\n(\d+:\d{2}:\d{2},\d{3})\s*-->\s*(\d+:\d{2}:\d{2},\d{3})[^\n]*\n(.*)$')
        if (-not $match.Success) { throw 'Unrecognized SRT block. Expected an embedded text subtitle track.' }
        $text = [regex]::Replace($match.Groups[3].Value, '<[^>]*>', '')
        $date = [regex]::Match($text, '(?<!\d)\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?!\d)')
        if (-not $date.Success) { throw "Subtitle has no YYYY-MM-DD HH:mm:ss date/time: $text" }
        $parsed = [datetime]::MinValue
        $stamp = $date.Value.Replace('T', ' ')
        if (-not [datetime]::TryParseExact($stamp, 'yyyy-MM-dd HH:mm:ss', $inv,
                [Globalization.DateTimeStyles]::None, [ref]$parsed)) { throw "Invalid date/time: $stamp" }
        $start = To-Milliseconds $match.Groups[1].Value
        $end = To-Milliseconds $match.Groups[2].Value
        if ($end -le $start) { throw 'A subtitle has an empty or negative interval.' }
        if ($cues.Count -gt 0 -and $start -lt $cues[$cues.Count - 1].End) {
            throw 'Overlapping or unordered date/time subtitles are not supported.'
        }
        $cues.Add([pscustomobject]@{ Start = $start; End = $end; Text = $stamp })
    }
    if ($cues.Count -eq 0) { throw 'No date/time subtitles found.' }
    # Camera exports have 5-65 ms gaps. Hold the previous real subtitle across
    # gaps up to 250 ms to avoid a blinking clock; never invent clock values.
    $filled = 0
    if (-not $ExactSubtitleGaps) {
        for ($i = 0; $i -lt $cues.Count - 1; $i++) {
            $gap = $cues[$i + 1].Start - $cues[$i].End
            if ($gap -gt 0 -and $gap -le 250) { $cues[$i].End = $cues[$i + 1].Start; $filled++ }
        }
    }
    $font = $FontName.Replace(',', '').Replace("`r", '').Replace("`n", '')
    $size = ($FontSize * $Height / 1440.0).ToString('0.###', $inv)
    $right = [int][Math]::Round($MarginRight * $Width / 2560.0)
    $bottom = [int][Math]::Round($MarginBottom * $Height / 1440.0)
    $ass = New-Object Text.StringBuilder
    [void]$ass.AppendLine(@"
[Script Info]
ScriptType: v4.00+
PlayResX: $Width
PlayResY: $Height
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Clock,$font,$size,&H00000000,&H00000000,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,0,0,3,0,$right,$bottom,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"@)
    foreach ($cue in $cues) {
        [void]$ass.AppendLine(('Dialogue: 0,{0},{1},Clock,,0,0,0,,{2}' -f
            (To-AssTime $cue.Start), (To-AssTime $cue.End), $cue.Text))
    }
    [IO.File]::WriteAllText($AssPath, $ass.ToString(), $utf8)
    Write-Host ("Subtitles: {0}; short gaps filled: {1}; first: {2}; last: {3}" -f
        $cues.Count, $filled, $cues[0].Text, $cues[$cues.Count - 1].Text)
}

try {
    $script:ffmpeg = Resolve-Tool $FFmpegPath 'ffmpeg'
    if (-not $FFprobePath) {
        $nearProbe = Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
        if (Test-Path -LiteralPath $nearProbe) { $FFprobePath = $nearProbe }
    }
    $script:probe = Resolve-Tool $FFprobePath 'ffprobe'
    if ($Stabilize) {
        $availableFilters = (& $ffmpeg -hide_banner -filters | Out-String)
        if ($LASTEXITCODE -ne 0 -or
            $availableFilters -notmatch '(?m)^\s*\S+\s+vidstabdetect\s' -or
            $availableFilters -notmatch '(?m)^\s*\S+\s+vidstabtransform\s') {
            throw 'Stabilization requires FFmpeg with vidstabdetect and vidstabtransform (libvidstab). Use the bundled bin\ffmpeg.exe or a build with --enable-libvidstab.'
        }
    }
    if (-not $InputPath) { $InputPath = $PSScriptRoot }
    $item = Get-Item -LiteralPath $InputPath
    if ($item.PSIsContainer) {
        $inputFiles = @(Get-ChildItem -LiteralPath $item.FullName -File |
            Where-Object { $_.Extension -in @('.mp4', '.mkv', '.mov', '.m4v') -and $_.BaseName -notmatch '_timestamp_' } |
            Sort-Object Name)
        $defaultOutput = Join-Path $item.FullName "Timestamp-$Mode"
    } else {
        $inputFiles = @($item)
        $defaultOutput = Join-Path $item.DirectoryName "Timestamp-$Mode"
    }
    if ($inputFiles.Count -eq 0) { throw 'No input videos found.' }
    if (-not $OutputDirectory) { $OutputDirectory = $defaultOutput }
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
    [void][IO.Directory]::CreateDirectory($outputRoot)
    Write-Host "Mode: $Mode | FFmpeg: $ffmpeg"
    if ($Stabilize) {
        Write-Host "Stabilization: ON | smoothing: $StabilizationSmoothing | shakiness: $StabilizationShakiness | analyze, then encode"
    }
    $failed = 0
    foreach ($file in $inputFiles) {
        $work = $null
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $suffix = if ($PreviewSeconds -gt 0) { '_preview' } else { '' }
            if ($Resize1080p) { $suffix = '_1080p' + $suffix }
            if ($Stabilize) { $suffix = '_stabilized' + $suffix }
            $out = Join-Path $outputRoot ($file.BaseName + '_timestamp_' + $Mode.ToLowerInvariant() + $suffix + '.mp4')
            if (Test-Path -LiteralPath $out) { throw "Output already exists (not overwritten): $out" }
            Write-Host "`nInput: $($file.FullName)"
            $info = Get-Probe $file.FullName
            $video = @($info.streams | Where-Object { $_.codec_type -eq 'video' })[0]
            if (-not $video) { throw 'No video stream.' }
            $sourceDurationText = [string]$info.format.duration
            if ($video.PSObject.Properties['duration']) { $sourceDurationText = [string]$video.duration }
            $sourceDuration = [double]::Parse($sourceDurationText, $inv)
            if ($sourceDuration -le 0 -or [double]::IsNaN($sourceDuration) -or [double]::IsInfinity($sourceDuration)) {
                throw 'Cannot calculate progress: video duration must be positive.'
            }
            $expected = $sourceDuration
            if ($PreviewSeconds -gt 0) { $expected = [Math]::Min($expected, $PreviewSeconds) }
            $subs = @($info.streams | Where-Object { $_.codec_type -eq 'subtitle' })
            if ($subs.Count -le $SubtitleStream) { throw "Subtitle stream s:$SubtitleStream not found." }
            $work = Join-Path $outputRoot ('.timestamp-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($work)
            $srtPath = Join-Path $work 'clock.srt'
            & $ffmpeg -hide_banner -loglevel error -nostdin -n -i $file.FullName -map "0:s:$SubtitleStream" -c:s srt $srtPath
            if ($LASTEXITCODE -ne 0) { throw 'Cannot extract text subtitles.' }
            $outputWidth = [int]$video.width
            $outputHeight = [int]$video.height
            $overlayFilter = 'ass=clock.ass'
            if ($Resize1080p) {
                $outputWidth = 1920
                $outputHeight = 1080
                # Resize before drawing text so the clock remains sharp. Preserve
                # picture proportions; pad other aspect ratios to an exact 1080p frame.
                $overlayFilter = 'scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bilinear,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,ass=clock.ass'
            }
            Write-TimestampAss $srtPath (Join-Path $work 'clock.ass') $outputWidth $outputHeight
            $decoder = @('-threads', "$Threads")
            $downloadFilter = ''
            $filter = $overlayFilter
            $encoder = @('-c:v', 'libx264', '-preset', $CpuPreset, '-crf', "$Quality", '-threads', "$Threads", '-pix_fmt', 'yuv420p')
            if ($Mode -eq 'GPU') {
                if (-not $SoftwareDecode) {
                    $decoder = @('-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda')
                    $downloadFilter = 'hwdownload,format=nv12,'
                    $filter = $downloadFilter + $overlayFilter
                    if ($video.pix_fmt -ne 'yuv420p' -and $video.pix_fmt -ne 'nv12') {
                        throw 'GPU decode expects 8-bit 4:2:0 input. Use -SoftwareDecode for other pixel formats.'
                    }
                }
                $encoder = @('-c:v', 'h264_nvenc', '-preset', $GpuPreset, '-rc', 'vbr', '-cq', "$Quality",
                    '-b:v', '0', '-multipass', 'disabled', '-rc-lookahead', '0', '-pix_fmt', 'nv12')
            }
            Push-Location -LiteralPath $work
            try {
                # Open decoder, filter and encoder on real input before starting a long run.
                if ($Mode -eq 'GPU') {
                    & $ffmpeg -hide_banner -loglevel error -nostdin @decoder -noautorotate -i $file.FullName -map 0:v:0 -vf $filter @encoder -frames:v 3 -an -sn -f null -
                    if ($LASTEXITCODE -ne 0) {
                        throw 'GPU preflight failed. Check the NVIDIA driver/FFmpeg compatibility; try -SoftwareDecode if only hardware decoding fails. Use -Mode CPU for software encoding.'
                    }
                }
                $limit = @()
                if ($PreviewSeconds -gt 0) { $limit = @('-t', $PreviewSeconds.ToString('0.###', $inv)) }
                $progressStage = 'Progress'
                if ($Stabilize) {
                    # Analyze untouched source frames at the same resolution and
                    # timestamps used by the transform pass. No intermediate encode.
                    $analysisFilter = $downloadFilter + "vidstabdetect=shakiness=${StabilizationShakiness}:accuracy=15:result=stabilization.trf"
                    $analysisArguments = @('-hide_banner', '-loglevel', 'warning', '-nostats',
                        '-progress', 'pipe:1', '-stats_period', '0.5', '-nostdin', '-n', '-filter_threads', '1') +
                        $decoder + @('-noautorotate', '-i', $file.FullName, '-map', '0:v:0', '-vf', $analysisFilter,
                        '-an', '-sn', '-dn', '-fps_mode', 'passthrough') + $limit + @('-f', 'null', '-')
                    Invoke-FFmpegProgress -Arguments $analysisArguments -Expected $expected -Stage 'Analysis'
                    $motionPath = Join-Path $work 'stabilization.trf'
                    if (-not (Test-Path -LiteralPath $motionPath -PathType Leaf) -or
                        (Get-Item -LiteralPath $motionPath).Length -eq 0) {
                        throw 'Stabilization analysis produced no motion data.'
                    }
                    Write-Host 'Analysis: 100%'
                    # Transform before resize/padding and before drawing the clock.
                    # Static automatic zoom avoids black borders and zoom pumping.
                    $filter = $downloadFilter + "vidstabtransform=input=stabilization.trf:smoothing=${StabilizationSmoothing}:optzoom=1:interpol=bicubic," + $overlayFilter
                    $progressStage = 'Encoding'
                }
                $audio = @('-an')
                if (@($info.streams | Where-Object { $_.codec_type -eq 'audio' }).Count -gt 0) {
                    $audio = @('-map', '0:a?', '-c:a', 'aac', '-b:a', '128k')
                }
                $arguments = @('-hide_banner', '-loglevel', 'warning', '-nostats', '-progress', 'pipe:1',
                    '-stats_period', '0.5', '-nostdin', '-n', '-filter_threads', '1') +
                    $decoder + @('-noautorotate', '-i', $file.FullName, '-map', '0:v:0',
                    '-vf', $filter) + $encoder + $audio + @('-sn', '-dn',
                    '-map_metadata', '0', '-map_chapters', '-1', '-fps_mode', 'passthrough', '-enc_time_base:v', 'demux', '-movflags', '+faststart') +
                    $limit + @('encoded.mp4')
                Invoke-FFmpegProgress -Arguments $arguments -Expected $expected -Stage $progressStage
                Write-Host 'Verifying output...'
                $result = Get-Probe (Join-Path $work 'encoded.mp4')
                $resultVideo = @($result.streams | Where-Object { $_.codec_type -eq 'video' })[0]
                if (-not $resultVideo -or $resultVideo.codec_name -ne 'h264' -or
                    $resultVideo.width -ne $outputWidth -or $resultVideo.height -ne $outputHeight) {
                    throw 'Output verification failed: wrong codec or dimensions.'
                }
                $actual = [double]::Parse([string]$resultVideo.duration, $inv)
                if ([Math]::Abs($expected - $actual) -gt 0.5) { throw "Output duration mismatch: expected $expected; got $actual." }
                # File.Move refuses to overwrite an existing file, including a race.
                [IO.File]::Move((Join-Path $work 'encoded.mp4'), $out)
                $timer.Stop()
                Write-Host ("{0}: 100%" -f $progressStage)
                Write-Host ("OK: {0}`nElapsed: {1:0.00} s; video: {2:0.00} s; total speed: {3:0.00}x" -f
                    $out, $timer.Elapsed.TotalSeconds, $actual, ($actual / [Math]::Max(0.01, $timer.Elapsed.TotalSeconds)))
                # Clean only the known files in this invocation's unique directory.
                foreach ($name in @('clock.srt', 'clock.ass', 'stabilization.trf')) { [IO.File]::Delete((Join-Path $work $name)) }
            } finally { Pop-Location }
            [IO.Directory]::Delete($work, $false)
        } catch {
            $failed++
            Write-Warning ("FAILED: {0}: {1}" -f $file.Name, $_.Exception.Message)
            if ($work -and (Test-Path -LiteralPath $work)) { Write-Warning "Diagnostics / incomplete output retained: $work" }
        }
    }
    if ($failed -gt 0) { throw "$failed file(s) failed. Originals were not modified." }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit 0
