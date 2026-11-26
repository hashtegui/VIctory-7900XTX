# RX 6700 XT profile for VIctory-7900XTX.
# Defaults to the measured Redline profile. Use -Stable for relay 0 compatibility or -Safe for a minimal path.
#   scripts\play-rx6700xt.ps1 -Exe <executable> [-Stable|-Safe] [-FastLoad] [-RayTracing] [-ExperimentalFast]
# Redline uses relay 1, 1080p output and a 0.5 internal render scale. It was stable
# on this RX 6700 XT and roughly doubled frame rate over relay 0. -ExperimentalFast keeps the older 7900 XTX settings.
param(
    [Parameter(Mandatory)][string]$Exe,
    [switch]$Safe,
    [switch]$Stable,
    [switch]$RayTracing,
    [switch]$ExperimentalFast,
    [switch]$FastLoad,
    [switch]$LowCopy,
    [switch]$LeanThreads,
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [hashtable]$More = @{}
)

$processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$physicalCores = if ($processor) { [int]$processor.NumberOfCores } else { 6 }
$logicalCpus = [Environment]::ProcessorCount
if ($physicalCores -lt 1) { $physicalCores = [Math]::Max(1, [Math]::Floor($logicalCpus / 2)) }
$translateThreads = [Math]::Max(2, [Math]::Min(6, $physicalCores))
$joinParts = [Math]::Max(2, [Math]::Min(6, $physicalCores))
$mappingThreads = [Math]::Max(1, [Math]::Min(4, $physicalCores - 1))
$leanTranslateThreads = [Math]::Max(2, [Math]::Min(4, $physicalCores - 2))
$leanJoinParts = [Math]::Max(2, [Math]::Min(4, $physicalCores - 2))
$leanMappingThreads = [Math]::Max(1, [Math]::Min(2, $physicalCores - 2))

$settings = @{
    # RX 6700 XT is RDNA 2. Reports in the fork's issues #11, #46 and #51 find
    # relay stages 1/2, texture no-wait and the two-submission burial lag able
    # to remove the device. Stability comes first; ExperimentalFast opts in.
    VICTORY_RELAY = '0'; VICTORY_TEXTURE_NO_WAIT = '0'; VICTORY_CARD_STEPS = '0'; VICTORY_BURY_LAG = '0'
    VICTORY_WIDE_BACK = '1'; VICTORY_CARD_REHASH_RUNS = '1'
    VICTORY_JOIN_COPIES = '1'; VICTORY_INDIRECT_WINDOW = '1'; VICTORY_RELAY_COPY = '1'
    VICTORY_INDIRECT_BATCH = '2'; VICTORY_TITLE_PRIORITIES = '0'; VICTORY_CARD_AWAKE = '1'
    VICTORY_SHOW_AFTER = '1'; VICTORY_AMBIENT = '0.8'; VICTORY_D3D12_DRED = 'light'
    # The RX 6700 XT has 12 GB. Keep 2 GiB for shadow-side buffers and let the
    # runtime's 97% VRAM ceiling cover the rest of the card.
    VICTORY_MEMORY_CARD_MB = '2048'
    VICTORY_MEMORY_MAP = '0'
    VICTORY_THIN_THREADS = "$translateThreads"
}
if ($Safe -and $Stable) { throw '-Safe and -Stable cannot be combined.' }
if ($Safe) {
    $settings.VICTORY_UNDER_WIDE = '0'; $settings.VICTORY_LAND_ECHO = '0'; $settings.VICTORY_MAP_THREADS = '1'
    $profile = 'safe'
} elseif ($Stable) {
    $settings.VICTORY_THIN = '1'; $settings.VICTORY_JOIN_PARTS = "$joinParts"
    $settings.VICTORY_UPLOAD_AHEAD = '0'; $settings.VICTORY_MAP_THREADS = "$mappingThreads"
    $profile = 'stable'
} else {
    # Measured Redline profile on the RX 6700 XT: relay 1 with retirement lag
    # zero stayed up, while 1080p output and a 0.5 internal scale removed most
    # of the pixel cost without frame generation.
    $settings.VICTORY_RELAY = '1'
    $settings.VICTORY_OUTPUT = '1920x1080'; $settings.VICTORY_RENDER_SCALE = '0.5'; $settings.VICTORY_UPSCALER = '6'
    $settings.VICTORY_THIN = '1'; $settings.VICTORY_JOIN_PARTS = "$leanJoinParts"
    $settings.VICTORY_THIN_THREADS = "$leanTranslateThreads"
    $settings.VICTORY_UPLOAD_AHEAD = '0'; $settings.VICTORY_MAP_THREADS = "$leanMappingThreads"
    $profile = 'redline'
}
if ($ExperimentalFast) {
    if ($Safe -or $Stable) { throw '-ExperimentalFast cannot be combined with -Safe or -Stable.' }
    $settings.VICTORY_RELAY = '2'; $settings.VICTORY_TEXTURE_NO_WAIT = '1'
    $settings.VICTORY_CARD_STEPS = '2'; $settings.VICTORY_BURY_LAG = '64'
    $settings.VICTORY_UPLOAD_AHEAD = '1'
    $profile = 'experimental-fast'
}
if ($FastLoad) { $settings.VICTORY_DSTORAGE_STAGING_MB = '256' }
if ($LowCopy) {
    # Try moving buffers down to 64 KiB onto the card before the 512 MiB cap;
    # candidate only until the reduced PCIe traffic is measured.
    $settings.VICTORY_CARD_BUFFERS_MIN_KB = '64'
    $settings.VICTORY_CARD_BUFFERS_MB = '512'
}
if ($LeanThreads) {
    $settings.VICTORY_THIN_THREADS = '4'
    $settings.VICTORY_JOIN_PARTS = '4'
    $settings.VICTORY_MAP_THREADS = '2'
}
if ($RayTracing) { $settings.VICTORY_BVH_BUILDER = '1' }
foreach ($key in $More.Keys) { $settings[$key] = [string]$More[$key] }

$victory = Join-Path $PSScriptRoot "..\target\$Build\victory.exe"
if (-not (Test-Path -LiteralPath $victory)) { throw "No $victory. Build it first (README.md)." }
if (-not (Test-Path -LiteralPath $Exe)) { throw "No $Exe." }

$paths = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR'
Get-ChildItem Env:VICTORY_* | Where-Object { $_.Name -notin $paths } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($key in $settings.Keys) { Set-Item "Env:$key" $settings[$key] }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
Write-Host "RX 6700 XT profile=$profile physicalCores=$physicalCores logicalCpus=$logicalCpus translateThreads=$($settings['VICTORY_THIN_THREADS']) joinParts=$($settings['VICTORY_JOIN_PARTS']) mappingThreads=$($settings['VICTORY_MAP_THREADS'])"
Push-Location (Join-Path $PSScriptRoot '..')
try { & $victory run $Exe --execute } finally { Pop-Location }