# =============================================================================
# run.ps1  -  Lanzador interactivo del Benchmark Convolucion 2D
# =============================================================================
#
# USO:
#   .\run.ps1
#
# PREREQUISITO:
#   La carpeta de binarios (ver $BIN_DIR_NAME) debe existir en el directorio
#   raiz del proyecto y contener exactamente los tres ejecutables definidos
#   en $VERSION_LABELS.
#
#   Los binarios forman parte del repositorio (producto final pre-compilado).
#   Si necesitas recompilarlos, usa el Makefile desde MSYS2 MinGW32.
#   Consulta COMPILACION.md para instrucciones detalladas.
#
# POLITICA DE EJECUCION:
#   Si el sistema bloquea scripts sin firmar, ejecutar una vez:
#     Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Configuracion de carpetas  <-- cambiar aqui si se renombran los directorios
# --------------------------------------------------------------------------
$BIN_DIR_NAME     = "bin"
$RESULTS_DIR_NAME = "results"

# --------------------------------------------------------------------------
# Diccionario de versiones: stem del ejecutable -> etiqueta a mostrar
#
# RESPONSABILIDAD DEL PROGRAMADOR: actualizar esta tabla si el Makefile
# cambia el nombre de algun binario. El stem es el nombre del .exe sin
# extension (ej. conv2d_x87 para conv2d_x87.exe).
# --------------------------------------------------------------------------
$VERSION_LABELS = [ordered]@{
    "conv2d_c"    = "C"
    "conv2d_x87"  = "x87 FPU"
    "conv2d_simd" = "SSE packed"
}

# --------------------------------------------------------------------------
# Rutas derivadas (no modificar)
# --------------------------------------------------------------------------
$SCRIPT_DIR  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BIN_DIR     = Join-Path $SCRIPT_DIR $BIN_DIR_NAME
$RESULTS_DIR = Join-Path $SCRIPT_DIR $RESULTS_DIR_NAME

# --------------------------------------------------------------------------
# Helpers de formato
# --------------------------------------------------------------------------
function Write-Header {
    param([string]$Text)
    $line = "=" * 56
    Write-Host ""
    Write-Host $line     -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line     -ForegroundColor DarkCyan
}

function Write-Section {
    param([string]$Text)
    $pad = "-" * [Math]::Max(2, 42 - $Text.Length)
    Write-Host ""
    Write-Host "--- $Text $pad" -ForegroundColor Yellow
}

function Format-Bytes {
    param([long]$Bytes)
    switch ($Bytes) {
        { $_ -ge 1GB } { return "{0:F1} GB" -f ($_ / 1GB) }
        { $_ -ge 1MB } { return "{0:F0} MB" -f ($_ / 1MB) }
        { $_ -ge 1KB } { return "{0:F0} KB" -f ($_ / 1KB) }
        default        { return "$_ B" }
    }
}

# --------------------------------------------------------------------------
# Verificar que $BIN_DIR existe y que contiene todos los binarios declarados
# en $VERSION_LABELS. Ademas avisa si hay binarios conv2d_*.exe en la carpeta
# que no tienen entrada en el diccionario (el programador olvido actualizarlo).
# --------------------------------------------------------------------------
function Assert-Binaries {
    if (-not (Test-Path $BIN_DIR)) {
        Write-Host ""
        Write-Host ("  ERROR: '$BIN_DIR_NAME' folder not found.") -ForegroundColor Red
        Write-Host ""
        Write-Host "  Pre-compiled binaries must be located at:" -ForegroundColor Yellow
        Write-Host "    $BIN_DIR"                                -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To build from source, see COMPILACION.md"         -ForegroundColor Yellow
        Write-Host "  and run 'make' from the MSYS2 MinGW32 shell."      -ForegroundColor Yellow
        exit 1
    }

    # Comprobar que existen los binarios declarados en el diccionario
    $missing = @()
    foreach ($stem in $VERSION_LABELS.Keys) {
        if (-not (Test-Path (Join-Path $BIN_DIR "$stem.exe"))) {
            $missing += "$stem.exe"
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "  ERROR: Missing executables in '$BIN_DIR_NAME':" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  See COMPILACION.md to recompile." -ForegroundColor Yellow
        exit 1
    }

    # Avisar si hay binarios conv2d_*.exe en la carpeta sin clave en el diccionario
    $unlabeled = @(
        Get-ChildItem -Path $BIN_DIR -Filter "conv2d_*.exe" |
        Where-Object { -not $VERSION_LABELS.Contains($_.BaseName) } |
        ForEach-Object { $_.Name }
    )
    if ($unlabeled.Count -gt 0) {
        Write-Host ""
        Write-Host "  WARNING: Binaries found in '$BIN_DIR_NAME' with no entry in `$VERSION_LABELS`:" `
            -ForegroundColor Yellow
        $unlabeled | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host "  They will be ignored. Update `$VERSION_LABELS` in run.ps1 to include them." `
            -ForegroundColor Yellow
        Write-Host ""
    }
}

# --------------------------------------------------------------------------
# Device information
# --------------------------------------------------------------------------
function Show-DeviceInfo {
    Write-Header "Device information"

    Write-Section "Processor"
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $archMap = @{ 0='x86'; 5='ARM'; 6='ia64'; 9='x64'; 12='ARM64' }
        $archStr = if ($archMap.ContainsKey([int]$cpu.Architecture)) {
                       $archMap[[int]$cpu.Architecture]
                   } else { "Unknown ($($cpu.Architecture))" }

        Write-Host ("  Model          : {0}" -f $cpu.Name.Trim())
        Write-Host ("  Manufacturer   : {0}" -f $cpu.Manufacturer)
        Write-Host ("  Architecture   : {0}-bit ({1})" -f $cpu.AddressWidth, $archStr)
        Write-Host ("  Physical cores : {0}" -f $cpu.NumberOfCores)
        Write-Host ("  Logical cores  : {0}" -f $cpu.NumberOfLogicalProcessors)
        Write-Host ("  Max frequency  : {0} MHz" -f $cpu.MaxClockSpeed)
        Write-Host ("  Base frequency : {0} MHz" -f $cpu.CurrentClockSpeed)
        if ($cpu.L2CacheSize -gt 0) {
            Write-Host ("  L2 cache       : {0}" -f (Format-Bytes ($cpu.L2CacheSize * 1KB)))
        }
        if ($cpu.L3CacheSize -gt 0) {
            Write-Host ("  L3 cache       : {0}" -f (Format-Bytes ($cpu.L3CacheSize * 1KB)))
        }
    } catch {
        Write-Host "  [Could not retrieve CPU information]" -ForegroundColor Red
    }

    Write-Section "RAM"
    try {
        $os    = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs    = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
        $total = [long]$cs.TotalPhysicalMemory
        $avail = [long]$os.FreePhysicalMemory * 1KB
        $used  = $total - $avail
        $pct   = [Math]::Round(($used / $total) * 100, 1)

        Write-Host ("  Total          : {0}" -f (Format-Bytes $total))
        Write-Host ("  Available      : {0}" -f (Format-Bytes $avail))
        Write-Host ("  In use         : {0} ({1}%)" -f (Format-Bytes $used), $pct)
    } catch {
        Write-Host "  [Could not retrieve RAM information]" -ForegroundColor Red
    }

    Write-Section "Operating System"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Host ("  Name           : {0}" -f $os.Caption)
        Write-Host ("  Version        : {0} (Build {1})" -f $os.Version, $os.BuildNumber)
        Write-Host ("  Architecture   : {0}" -f $os.OSArchitecture)
    } catch {
        Write-Host "  [Could not retrieve OS information]" -ForegroundColor Red
    }

    Write-Section "Benchmark note"
    Write-Host "  PE32 binaries (x86, 32-bit), compiled with MSVC + NASM."
    Write-Host "  Flags: /Od /arch:IA32 (no optimization, no auto-vectorization)."
    Write-Host ""
}

# --------------------------------------------------------------------------
# Run a binary (it writes the .txt and prints the path)
# --------------------------------------------------------------------------
function Invoke-Version {
    param([string]$Stem, [string]$Label)

    $line = "=" * 56
    Write-Host ""
    Write-Host $line -ForegroundColor DarkGreen
    Write-Host ("  Running: {0}" -f $Label) -ForegroundColor Green
    Write-Host $line -ForegroundColor DarkGreen
    Write-Host ""

    & (Join-Path $BIN_DIR "$Stem.exe")
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  [WARNING] Process exited with code $LASTEXITCODE") -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Muestra los resultados del fichero result_*.txt mas reciente para un stem
# --------------------------------------------------------------------------
function Show-Results {
    param([string]$Stem)

    if (-not (Test-Path $RESULTS_DIR)) { return }

    $latest = Get-ChildItem -Path $RESULTS_DIR -Filter "result_*_$Stem*.txt" |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1
    if ($null -eq $latest) { return }

    $d    = Read-ResultFile -Path $latest.FullName
    $line = "=" * 56

    Write-Host ""
    Write-Host $line                                              -ForegroundColor DarkCyan
    Write-Host ("  Results -- {0}" -f $d['VERSION'])             -ForegroundColor Cyan
    Write-Host $line                                              -ForegroundColor DarkCyan

    Write-Host ""
    Write-Host "--- Information ---------------------------" -ForegroundColor Yellow
    Write-Host ("  Image         : {0} x {1} floats" -f $d['IMG_WIDTH'], $d['IMG_HEIGHT'])
    Write-Host ("  Kernel        : {0} x {0} (Gaussian blur)" -f $d['KERNEL_SIZE'])
    Write-Host ("  Repetitions   : {0}" -f $d['REPETITIONS'])

    Write-Host ""
    Write-Host "--- Timing --------------------------------" -ForegroundColor Yellow
    Write-Host ("  Total         : {0,10} s"   -f $d['TIME_TOTAL_S'])
    Write-Host ("  Mean  /rep    : {0,10} ms"  -f $d['TIME_MEAN_MS'])
    Write-Host ("  Min   /rep    : {0,10} ms"  -f $d['TIME_MIN_MS'])
    Write-Host ("  Max   /rep    : {0,10} ms"  -f $d['TIME_MAX_MS'])
    Write-Host ("  Std deviation : {0,10} ms  (+-{1}%)" -f $d['TIME_STDDEV_MS'], $d['TIME_STDDEV_PCT'])

    Write-Host ""
    Write-Host "--- Performance ---------------------------" -ForegroundColor Yellow
    Write-Host ("  Throughput    : {0,10} MB/s" -f $d['THROUGHPUT_MBS'])
    Write-Host ("  GFLOPS        : {0,10}"      -f $d['GFLOPS'])

    Write-Host ""
    Write-Host "--- Effective iterations ------------------" -ForegroundColor Yellow
    Write-Host ("  Valid rows    : {0,10}"  -f $d['VALID_ROWS'])
    Write-Host ("  Valid cols    : {0,10}"  -f $d['VALID_COLS'])
    Write-Host ("  Pixels/rep    : {0,10}"  -f $d['TOTAL_PIXELS'])

    Write-Host ""
    Write-Host "--- SSE packed breakdown (SIMD=4) ---------" -ForegroundColor Yellow
    $packed = [int]$d['PACKED_PER_ROW']
    Write-Host ("  Packed iter   : {0,10}  /row  ({1} pixels)" -f $packed, ($packed * 4))
    Write-Host ("  Scalar iter   : {0,10}  /row  (tail)"       -f $d['SCALAR_PER_ROW'])

    Write-Host ""
    Write-Host "--- Verification --------------------------" -ForegroundColor Yellow
    Write-Host ("  Checksum      : {0}" -f $d['CHECKSUM'])
    Write-Host ""
}

# --------------------------------------------------------------------------
# Lee un fichero result_*.txt y devuelve un hashtable KEY->valor
# --------------------------------------------------------------------------
function Read-ResultFile {
    param([string]$Path)

    $data = @{}
    foreach ($line in (Get-Content $Path)) {
        $idx = $line.IndexOf(':')
        if ($idx -gt 0) {
            $key   = $line.Substring(0, $idx)
            $value = $line.Substring($idx + 1)
            $data[$key] = $value
        }
    }
    return $data
}

# --------------------------------------------------------------------------
# Tabla comparativa leida desde los ficheros result_*.txt mas recientes
# --------------------------------------------------------------------------
function Show-ComparisonTable {
    if (-not (Test-Path $RESULTS_DIR)) {
        Write-Host "  No results directory found." -ForegroundColor Yellow
        return
    }

    $datasets = @()
    foreach ($stem in $VERSION_LABELS.Keys) {
        $pattern = "result_*_$stem*.txt"
        $latest  = Get-ChildItem -Path $RESULTS_DIR -Filter $pattern |
                   Sort-Object LastWriteTime -Descending |
                   Select-Object -First 1
        if ($null -eq $latest) {
            Write-Host ("  [WARNING] No result found for $stem") -ForegroundColor Yellow
            continue
        }
        $d = Read-ResultFile -Path $latest.FullName
        $datasets += $d
    }

    if ($datasets.Count -lt 2) {
        Write-Host "  Not enough results to compare." -ForegroundColor Yellow
        return
    }

    $base = $datasets[0]
    $line = "=" * 64

    Write-Host ""
    Write-Host $line                              -ForegroundColor DarkCyan
    Write-Host "  Performance comparison table"   -ForegroundColor Cyan
    Write-Host $line                              -ForegroundColor DarkCyan

    # ---- Absolute values ----
    Write-Host ""
    Write-Host ("  {0,-26} {1,10} {2,11} {3,9}" -f `
        "Version", "Mean(ms)", "MB/s", "GFLOPS") -ForegroundColor White
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray
    foreach ($d in $datasets) {
        $short = $d['VERSION']
        if ($short.Length -gt 26) { $short = $short.Substring(0,23) + "..." }
        Write-Host ("  {0,-26} {1,10} {2,11} {3,9}" -f `
            $short, $d['TIME_MEAN_MS'], $d['THROUGHPUT_MBS'], $d['GFLOPS'])
    }

    # ---- Speedup vs primera version (C puro) ----
    Write-Host ""
    Write-Host "  Speedup vs pure C (lower is better):" -ForegroundColor Yellow
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray
    Write-Host ("  {0,-26} {1,12} {2,10}" -f "Version", "Diff(ms)", "Speedup") -ForegroundColor White
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray
    $baseMean = [double]$base['TIME_MEAN_MS']
    foreach ($d in $datasets) {
        $mean    = [double]$d['TIME_MEAN_MS']
        $diff    = $mean - $baseMean
        $speedup = if ($mean -gt 0) { $baseMean / $mean } else { 0 }
        $color   = if ($speedup -ge 1.0) { "Green" } else { "Red" }
        $short   = $d['VERSION']
        if ($short.Length -gt 26) { $short = $short.Substring(0,23) + "..." }
        $diffStr = if ($diff -ge 0) { "+{0:F3}" -f $diff } else { "{0:F3}" -f $diff }
        Write-Host ("  {0,-26} {1,12} {2,9:F2}x" -f $short, $diffStr, $speedup) `
            -ForegroundColor $color
    }

    # ---- Throughput vs primera version ----
    Write-Host ""
    Write-Host "  Throughput vs pure C (higher is better):" -ForegroundColor Yellow
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray
    Write-Host ("  {0,-26} {1,14} {2,10}" -f "Version", "Diff(MB/s)", "Ratio") -ForegroundColor White
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray
    $baseTp = [double]$base['THROUGHPUT_MBS']
    foreach ($d in $datasets) {
        $tp    = [double]$d['THROUGHPUT_MBS']
        $diff  = $tp - $baseTp
        $ratio = if ($baseTp -gt 0) { $tp / $baseTp } else { 0 }
        $color = if ($ratio -ge 1.0) { "Green" } else { "Red" }
        $short = $d['VERSION']
        if ($short.Length -gt 26) { $short = $short.Substring(0,23) + "..." }
        $diffStr = if ($diff -ge 0) { "+{0:F2}" -f $diff } else { "{0:F2}" -f $diff }
        Write-Host ("  {0,-26} {1,14} {2,9:F2}x" -f $short, $diffStr, $ratio) `
            -ForegroundColor $color
    }

    # ---- Checksum verification ----
    Write-Host ""
    Write-Host "  Checksum verification:" -ForegroundColor Yellow
    Write-Host ("  " + "-" * 58) -ForegroundColor DarkGray
    $baseCs = $base['CHECKSUM']
    foreach ($d in $datasets) {
        $cs    = $d['CHECKSUM']
        $ok    = ($cs -eq $baseCs)
        $color = if ($ok) { "Green" } else { "Red" }
        $mark  = if ($ok) { "OK" } else { "MISMATCH" }
        $short = $d['VERSION']
        if ($short.Length -gt 26) { $short = $short.Substring(0,23) + "..." }
        Write-Host ("  {0,-26}  {1}  [{2}]" -f $short, $cs, $mark) -ForegroundColor $color
    }

    Write-Host ""
}

# --------------------------------------------------------------------------
# Menu
# --------------------------------------------------------------------------
function Show-Menu {
    Write-Header "2D Convolution Benchmark - Menu"
    Write-Host ""
    $i = 1
    foreach ($stem in $VERSION_LABELS.Keys) {
        Write-Host ("  [{0}]  {1}" -f $i, $VERSION_LABELS[$stem]) -ForegroundColor White
        $i++
    }
    Write-Host ("  [{0}]  Run ALL versions" -f $i) -ForegroundColor Magenta
    Write-Host "  [0]  Exit"                        -ForegroundColor DarkGray
    Write-Host ""
}

# --------------------------------------------------------------------------
# Punto de entrada
# --------------------------------------------------------------------------
Assert-Binaries
Show-DeviceInfo
Show-Menu

$numVersions = $VERSION_LABELS.Count
$valid  = $false
$choice = 0
while (-not $valid) {
    $raw = Read-Host "  Select an option"
    if ([int]::TryParse($raw.Trim(), [ref]$choice)) {
        if ($choice -ge 0 -and $choice -le ($numVersions + 1)) {
            $valid = $true
        }
    }
    if (-not $valid) {
        Write-Host ("  Invalid option. Enter a number between 0 and {0}." `
            -f ($numVersions + 1)) -ForegroundColor Red
    }
}

if ($choice -eq 0) {
    Write-Host "  Exiting." -ForegroundColor DarkGray
    exit 0
}

$stems = @($VERSION_LABELS.Keys)

if ($choice -le $numVersions) {
    $stem  = $stems[$choice - 1]
    $label = $VERSION_LABELS[$stem]
    Invoke-Version -Stem $stem -Label $label
    Show-Results   -Stem $stem
} else {
    foreach ($stem in $stems) {
        Invoke-Version -Stem $stem -Label $VERSION_LABELS[$stem]
        Show-Results   -Stem $stem
    }
    Show-ComparisonTable
}

Write-Host "  Benchmark complete." -ForegroundColor Cyan
Write-Host ""