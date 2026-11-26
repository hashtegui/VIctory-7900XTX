# Official RX 6700 XT measurement harness.
# Launches play-rx6700xt.ps1, records title-derived FPS/frame time/draws,
# process memory, GPU engines, dedicated/shared VRAM and device-loss events.
param(
    [Parameter(Mandatory)][string]$Exe,
    [string]$Label = 'run',
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [int]$DurationSeconds = 300,
    [int]$WarmupSeconds = 0,
    [string[]]$PlayArgs = @(),
    [string]$OutputRoot = '',
    [switch]$BuildFirst,
    [switch]$RestartOnDeviceLoss,
    [int]$MaxRestarts = 1,
    [switch]$Capture = $true,
    [ValidateRange(1, 10000)][int]$CaptureEvery = 64
)

$ErrorActionPreference = 'Stop'
if ($DurationSeconds -lt 1) { throw 'DurationSeconds must be positive.' }
if ($WarmupSeconds -lt 0) { throw 'WarmupSeconds cannot be negative.' }
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $OutputRoot) { $OutputRoot = Join-Path $repo '_measurements' }
$OutputRoot = (New-Item -ItemType Directory -Path $OutputRoot -Force).FullName
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '_')
$runDir = Join-Path $OutputRoot "$stamp-$safeLabel"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$launcher = Join-Path $PSScriptRoot 'play-rx6700xt.ps1'
$gameExe = (Resolve-Path -LiteralPath $Exe).Path

function Get-RegistryValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -LiteralPath $Path -ErrorAction Stop).$Name } catch { $null }
}

function Get-EventSnapshot([datetime]$Since) {
    $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $Since } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'Application Error|Windows Error Reporting' -and $_.Message -match 'victory|game_scarlett' } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message)
    $sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $Since } -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in @('Error', 'Critical') -or $_.ProviderName -match 'Display|amd|driver|Resource-Exhaustion' } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message)
    [pscustomobject]@{ application = $app; system = $sys }
}

function Read-Title([string]$Title) {
    $m = [regex]::Match($Title, '(?<fps>\d+(?:\.\d+)?) fps\s+(?<ms>\d+(?:\.\d+)?) ms/frame\s+(?<draws>\d+) draws/frame')
    if ($m.Success) {
        [pscustomobject]@{ fps = [double]$m.Groups['fps'].Value; frameMs = [double]$m.Groups['ms'].Value; draws = [int]$m.Groups['draws'].Value }
    } else { $null }
}

function Percentile([double[]]$Values, [double]$Fraction) {
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Min($sorted.Count - 1, [Math]::Max(0, [Math]::Ceiling($sorted.Count * $Fraction) - 1))
    [double]$sorted[$index]
}

function ToNumber([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    [double]::Parse(([string]$Value).Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
}

function Median([double[]]$Values) { Percentile $Values 0.5 }

function Read-Gpu([int]$GamePid) {
    $result = [ordered]@{ compute = $null; draw3d = $null; copy = $null; dedicatedMiB = $null; sharedMiB = $null }
    try {
        $engine = Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        foreach ($sample in @($engine.CounterSamples | Where-Object { $_.InstanceName -like "pid_${GamePid}_*" })) {
            if ($sample.InstanceName -match 'engtype_compute') { $result.compute = [Math]::Max([double]$result.compute, [Math]::Round($sample.CookedValue, 1)) }
            elseif ($sample.InstanceName -match 'engtype_3d') { $result.draw3d = [Math]::Max([double]$result.draw3d, [Math]::Round($sample.CookedValue, 1)) }
            elseif ($sample.InstanceName -match 'engtype_copy') { $result.copy = [Math]::Max([double]$result.copy, [Math]::Round($sample.CookedValue, 1)) }
        }
    } catch {}
    try {
        $memory = Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage', '\GPU Adapter Memory(*)\Shared Usage' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        foreach ($counter in $memory.CounterSamples) {
            $mib = $counter.CookedValue / 1MB
            if ($mib -le 0) { continue }
            if ($counter.Path -match 'Dedicated Usage') { $result.dedicatedMiB = [Math]::Round($mib, 1) }
            elseif ($counter.Path -match 'Shared Usage') { $result.sharedMiB = [Math]::Round($mib, 1) }
        }
    } catch {}
    [pscustomobject]$result
}

function Read-ProcessCpu([int]$GamePid) {
    try {
        $row = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop | Where-Object { $_.IDProcess -eq $GamePid } | Select-Object -First 1
        if ($row) { [double]$row.PercentProcessorTime } else { $null }
    } catch { $null }
}

$meta = [ordered]@{
    startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    label = $Label
    repo = $repo
    branch = (& git -C $repo branch --show-current)
    sha = (& git -C $repo rev-parse HEAD)
    dirty = [bool](& git -C $repo status --porcelain)
    build = $Build
    durationSeconds = $DurationSeconds
    warmupSeconds = $WarmupSeconds
    playArgs = @($PlayArgs)
    capture = [bool]$Capture
    captureEvery = $CaptureEvery
    gameExecutableB3 = 'b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93'
    gpu = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*Radeon RX 6700 XT*' } | Select-Object -First 1 Name, DriverVersion, DriverDate, PNPDeviceID)
    adrenalin = Get-RegistryValue 'HKLM:\SOFTWARE\AMD\CN' 'CNVersion'
    windows = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture)
    cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors)
    memoryBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
}
$meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'meta.json') -Encoding utf8NoBOM

if ($BuildFirst) {
    if ($Build -eq 'diag') { & cargo build --locked --profile diag -p victory --features diagnostics }
    else { & cargo build --locked --profile release -p victory }
    if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }
}

$allAttempts = @()
for ($attempt = 1; $attempt -le ($MaxRestarts + 1); $attempt++) {
    $attemptDir = Join-Path $runDir ("attempt-$attempt")
    New-Item -ItemType Directory -Path $attemptDir -Force | Out-Null
    $stdout = Join-Path $attemptDir 'stdout.log'
    $stderr = Join-Path $attemptDir 'stderr.log'
    $frames = Join-Path $attemptDir 'samples.csv'
    $captureDir = Join-Path $attemptDir 'captures'
    $beforeIds = @(Get-Process victory -ErrorAction SilentlyContinue | ForEach-Object Id)
    $startUtc = (Get-Date).ToUniversalTime()
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, '-Exe', $gameExe, '-Build', $Build) + @($PlayArgs)
    if ($Build -eq 'diag') { $args += @('-FrameLog', '-GpuTiming') }
    if ($Capture -and $Build -eq 'diag') { $args += @('-CaptureDir', $captureDir, '-CaptureWorld', '-CaptureEvery', "$CaptureEvery") }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

    $game = $null
    for ($i = 0; $i -lt 120 -and -not $game; $i++) {
        Start-Sleep -Milliseconds 500
        $game = Get-Process victory -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $beforeIds } | Sort-Object StartTime -Descending | Select-Object -First 1
        if ($process.HasExited -and -not $game) { break }
    }
    if (-not $game) {
        Write-Output "ATTEMPT $attempt exited before a victory process appeared"
        $allAttempts += [pscustomobject]@{ attempt = $attempt; end = 'launch_failed'; gamePid = $null; deviceLoss = $false; tdr = $false }
        break
    }

    Write-Output "ATTEMPT $attempt game_pid=$($game.Id) waiting_for_world"
    $measureStart = $null
    $lastTitle = ''
    $lastTitleChange = Get-Date
    $lastGpu = [pscustomobject]@{ compute = $null; draw3d = $null; copy = $null; dedicatedMiB = $null; sharedMiB = $null }
    $lastCpu = $null
    $tick = 0
    $stalls = 0
    while ($p = Get-Process -Id $game.Id -ErrorAction SilentlyContinue) {
        $now = Get-Date
        $title = $p.MainWindowTitle
        $parsed = Read-Title $title
        if ($parsed -and $parsed.draws -ge 500 -and -not $measureStart) {
            $measureStart = $now
            Write-Output "ATTEMPT $attempt world_ready title=$title"
        }
        if ($measureStart -and $now -lt $measureStart.AddSeconds($WarmupSeconds)) {
            Start-Sleep -Seconds 1
            continue
        }
        if ($measureStart -and ((($now - $measureStart).TotalSeconds - $WarmupSeconds) -ge $DurationSeconds)) {
            Write-Output "ATTEMPT $attempt duration_complete"
            $p.CloseMainWindow() | Out-Null
            if (-not $p.WaitForExit(5000)) { Stop-Process -Id $p.Id -Force; $p.WaitForExit(5000) | Out-Null }
            break
        }
        if ($title -ne $lastTitle) { $lastTitle = $title; $lastTitleChange = $now }
        $stalled = if ($measureStart -and ($now - $lastTitleChange).TotalSeconds -gt 2) { 1 } else { 0 }
        if ($stalled) { $stalls++ }
        if (($tick % 5) -eq 0) {
            $lastGpu = Read-Gpu $game.Id
            $lastCpu = Read-ProcessCpu $game.Id
        }
        $row = [pscustomobject]@{
            timestampUtc = $now.ToUniversalTime().ToString('o')
            attempt = $attempt
            elapsedSeconds = if ($measureStart) { [Math]::Round((($now - $measureStart).TotalSeconds - $WarmupSeconds), 1) } else { $null }
            title = $title
            fps = if ($parsed) { $parsed.fps } else { $null }
            frameMs = if ($parsed) { $parsed.frameMs } else { $null }
            draws = if ($parsed) { $parsed.draws } else { $null }
            privateMiB = [Math]::Round($p.PrivateMemorySize64 / 1MB, 1)
            workingSetMiB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
            cpuPercent = $lastCpu
            gpuComputePercent = $lastGpu.compute
            gpu3dPercent = $lastGpu.draw3d
            gpuCopyPercent = $lastGpu.copy
            dedicatedVramMiB = $lastGpu.dedicatedMiB
            sharedVramMiB = $lastGpu.sharedMiB
            stalledOver2s = $stalled
        }
        $row | Export-Csv -LiteralPath $frames -Append -NoTypeInformation -Encoding utf8
        $tick++
        Start-Sleep -Seconds 1
    }

    if (-not (Test-Path -LiteralPath $frames)) { @() | Export-Csv -LiteralPath $frames -NoTypeInformation -Encoding utf8 }
    $text = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
    $deviceLoss = $text -match '(?i)device removed|DXGI_ERROR_DEVICE_REMOVED|0x887A000[457]'
    $events = Get-EventSnapshot $startUtc
    $eventText = ($events.application + $events.system | ConvertTo-Json -Depth 5 -Compress)
    $tdr = [bool]($eventText -match '(?i)Display|amdkmdap|TDR|device removed')
    $events | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $attemptDir 'events.json') -Encoding utf8NoBOM
    $attemptResult = [pscustomobject]@{ attempt = $attempt; gamePid = $game.Id; deviceLoss = [bool]$deviceLoss; tdr = $tdr; stalls = $stalls; attemptDir = $attemptDir }
    $allAttempts += $attemptResult
    $attemptResult | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $attemptDir 'result.json') -Encoding utf8NoBOM
    if (-not ($RestartOnDeviceLoss -and ($deviceLoss -or $tdr) -and $attempt -le $MaxRestarts)) { break }
    Write-Output "ATTEMPT $attempt device_loss=$deviceLoss tdr=$tdr; restarting"
}

$rows = @()
foreach ($csv in @(Get-ChildItem -Path (Join-Path $runDir 'attempt-*') -Filter 'samples.csv' -File -ErrorAction SilentlyContinue)) {
    $rows += @(Import-Csv -LiteralPath $csv.FullName)
}
$world = @($rows | Where-Object { $null -ne (ToNumber $_.fps) -and (ToNumber $_.draws) -ge 500 })
$fpsValues = @($world | ForEach-Object { ToNumber $_.fps })
$msValues = @($world | ForEach-Object { ToNumber $_.frameMs })
$drawValues = @($world | ForEach-Object { ToNumber $_.draws })
$privateValues = @($rows | ForEach-Object { ToNumber $_.privateMiB } | Where-Object { $null -ne $_ })
$dedicatedValues = @($rows | ForEach-Object { ToNumber $_.dedicatedVramMiB } | Where-Object { $null -ne $_ })
$sharedValues = @($rows | ForEach-Object { ToNumber $_.sharedVramMiB } | Where-Object { $null -ne $_ })
$summary = [ordered]@{
    runDir = $runDir
    samples = $rows.Count
    worldSamples = $world.Count
    fpsMedian = Median $fpsValues
    frameMsMedian = Median $msValues
    frameMsP95 = Percentile $msValues 0.95
    drawsMedian = Median $drawValues
    privateMaxMiB = if ($privateValues.Count) { ($privateValues | Measure-Object -Maximum).Maximum } else { $null }
    dedicatedVramMaxMiB = if ($dedicatedValues.Count) { ($dedicatedValues | Measure-Object -Maximum).Maximum } else { $null }
    sharedVramMaxMiB = if ($sharedValues.Count) { ($sharedValues | Measure-Object -Maximum).Maximum } else { $null }
    stalledSamples = @($rows | Where-Object { $_.stalledOver2s -eq '1' }).Count
    deviceLoss = [bool](@($allAttempts | Where-Object deviceLoss).Count)
    tdr = [bool](@($allAttempts | Where-Object tdr).Count)
    attempts = $allAttempts
    gc = 'n/a: native Rust/title runtime has no .NET GC'
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'summary.json') -Encoding utf8NoBOM
$md = @"
# Measurement: $Label

- Run: $($meta.startedAtUtc)
- SHA: $($meta.sha)
- Branch: $($meta.branch)
- Build: $Build
- GPU: AMD Radeon RX 6700 XT 12 GB
- Driver: 32.0.21045.5002 / Adrenalin $($meta.adrenalin)
- Windows: 10.0.26200
- Switches: $($PlayArgs -join ' ')

| Metric | Value |
|---|---:|
| World samples | $($summary.worldSamples) |
| Median FPS | $($summary.fpsMedian) |
| Median frame time | $($summary.frameMsMedian) ms |
| P95 frame time | $($summary.frameMsP95) ms |
| Median draws | $($summary.drawsMedian) |
| Private RAM max | $($summary.privateMaxMiB) MiB |
| Dedicated VRAM max | $($summary.dedicatedVramMaxMiB) MiB |
| Shared VRAM max | $($summary.sharedVramMaxMiB) MiB |
| Samples stalled >2 s | $($summary.stalledSamples) |
| Device loss | $($summary.deviceLoss) |
| TDR/display event | $($summary.tdr) |
| GC | $($summary.gc) |

Raw samples: ``samples.csv``. Logs: ``stdout.log`` and ``stderr.log``.
Captures: ``captures``. Events: ``events.json``.
"@
Set-Content -LiteralPath (Join-Path $runDir 'summary.md') -Value $md -Encoding utf8NoBOM
Write-Output "MEASUREMENT_COMPLETE $runDir"
Get-Content -LiteralPath (Join-Path $runDir 'summary.md')