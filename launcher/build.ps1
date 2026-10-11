<#
Builds dist\DotaVsWarcraft\:
    DotaVsWarcraft.exe         PyInstaller one-file build of launcher\dvw_launcher
    StormLib.dll               StormLib 9.40, x64 (MPQ writer)
    vrf\                       Source 2 Viewer CLI 20.0 (asset exporter)
    THIRD_PARTY_NOTICES.txt
    README.txt
    DotaVsWarcraft.w3x         only with -BaseMap

Third-party binaries are downloaded from their official release URLs into
launcher\vendor\ (git-ignored) and checked against pinned SHA256 values before
use. Run from any folder:
    powershell -ExecutionPolicy Bypass -File launcher\build.ps1 [-BaseMap <map.w3x>]
#>
param(
    [string]$Python = "",
    [string]$BaseMap = ""
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Launcher = $PSScriptRoot
$Root = (Resolve-Path (Join-Path $Launcher "..")).Path
if (-not $Python) { $Python = Join-Path $Root ".venv\Scripts\python.exe" }
$Vendor = Join-Path $Launcher "vendor"
$Dist = Join-Path $Root "dist\DotaVsWarcraft"
$Work = Join-Path $Root "build\pyinstaller"

# SHA256 pins. VRF: the GitHub release asset digest. StormLib: the GitHub
# release asset digest of stormlib_dll.zip (the release's own release.sha256
# lists only the per-configuration zips, not stormlib_dll.zip).
$Packages = @(
    @{ Name = "Source 2 Viewer CLI 20.0"; Dir = "vrf"; Zip = "vrf-cli-windows-x64-20.0.zip"
       Url = "https://github.com/ValveResourceFormat/ValveResourceFormat/releases/download/20.0/cli-windows-x64.zip"
       Sha256 = "D32AB327B8BBB42A2528866AFB03BB582BDB779D0005488DA32B90292AFD3FF5" },
    @{ Name = "StormLib 9.40"; Dir = "stormlib"; Zip = "stormlib_dll-9.40.zip"
       Url = "https://github.com/ladislav-zezula/StormLib/releases/download/v9.40/stormlib_dll.zip"
       Sha256 = "B2C9635E7B63EDEE1BD7C82E7DC180D739F3ACCB2B8994804C7774E464CE89AE" }
)

# Native tools log to stderr; in Windows PowerShell 5.1 that becomes error
# records, which "Stop" would turn into failures. Judge them by exit code.
function Invoke-Native([string]$What, [scriptblock]$Command) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $saved }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

function Get-Package($p) {
    New-Item -ItemType Directory -Force $Vendor | Out-Null
    $zip = Join-Path $Vendor $p.Zip
    if ((Test-Path $zip) -and (Get-FileHash $zip -Algorithm SHA256).Hash -ne $p.Sha256) {
        Remove-Item $zip -Force
    }
    if (-not (Test-Path $zip)) {
        $part = "$zip.part"
        for ($try = 1; ; $try++) {
            Write-Host "Downloading $($p.Name) (attempt $try)"
            try {
                Invoke-WebRequest -Uri $p.Url -OutFile $part -UseBasicParsing -TimeoutSec 600
                break
            } catch {
                if ($try -ge 3) { throw "Download of $($p.Name) failed: $_" }
                Start-Sleep -Seconds 5
            }
        }
        $hash = (Get-FileHash $part -Algorithm SHA256).Hash
        if ($hash -ne $p.Sha256) {
            Remove-Item $part -Force
            throw "$($p.Name): SHA256 mismatch, got $hash, expected $($p.Sha256)"
        }
        Move-Item $part $zip -Force
    }
    Write-Host "$($p.Name): SHA256 OK"
    $dir = Join-Path $Vendor $p.Dir
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dir
    return $dir
}

if (-not (Test-Path $Python)) { throw "Python not found: $Python (create the venv first)" }
Invoke-Native "pip install" { & $Python -m pip install --disable-pip-version-check -q -r (Join-Path $Launcher "requirements.txt") }
foreach ($f in @((Join-Path $Launcher "vo_manifest.json"), (Join-Path $Root "src\data\heroes.json"),
                  (Join-Path $Root "src\data\items.json"), (Join-Path $Root "specs\models.json"),
                  (Join-Path $Root "specs\effects.json"))) {
    if (-not (Test-Path $f)) { throw "Missing $f (run tools\select_vo.py first; specs\models.json lists the converted unit models)" }
}
# Optional HUD images (contract at the top of dvw_launcher\assets.py): checked here, bundled when present.
$hudSpec = Join-Path $Root "specs\hud_assets.json"
$optionalData = @()
if (Test-Path $hudSpec) {
    Invoke-Native "hud_assets.json check" { & $Python -I -c "import sys; sys.path.insert(0, sys.argv[2]); from dvw_launcher import assets; print(len(assets.load_hud_specs(sys.argv[1])), 'HUD images')" $hudSpec $Launcher }
    $optionalData += @("--add-data", "$hudSpec;data")
}

$vrfDir = Get-Package $Packages[0]
$stormDir = Get-Package $Packages[1]
$stormDll = Join-Path $stormDir "x64\StormLib.dll"
if (-not (Test-Path (Join-Path $vrfDir "Source2Viewer-CLI.exe"))) { throw "Source2Viewer-CLI.exe missing in the VRF zip" }
if (-not (Test-Path $stormDll)) { throw "x64\StormLib.dll missing in the StormLib zip" }

if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Force $Work | Out-Null
Invoke-Native "PyInstaller" {
    & $Python -m PyInstaller --noconfirm --clean --onefile --windowed --noupx `
        --name DotaVsWarcraft `
        --distpath $Dist --workpath $Work --specpath $Work `
        --paths $Launcher `
        --add-data "$(Join-Path $Root 'src\data\heroes.json');data" `
        --add-data "$(Join-Path $Root 'src\data\items.json');data" `
        --add-data "$(Join-Path $Launcher 'vo_manifest.json');data" `
        --add-data "$(Join-Path $Root 'specs\models.json');data" `
        --add-data "$(Join-Path $Root 'specs\effects.json');data" `
        @optionalData `
        --exclude-module tkinter --exclude-module unittest --exclude-module pydoc `
        --exclude-module doctest --exclude-module numpy `
        (Join-Path $Launcher "DotaVsWarcraft.py")
}

New-Item -ItemType Directory -Force (Join-Path $Dist "vrf") | Out-Null
Copy-Item (Join-Path $vrfDir "*") (Join-Path $Dist "vrf") -Recurse
Copy-Item $stormDll $Dist
Copy-Item (Join-Path $Launcher "README.txt") $Dist
Invoke-Native "make_notices.py" { & $Python (Join-Path $Launcher "make_notices.py") (Join-Path $Dist "THIRD_PARTY_NOTICES.txt") }
if ($BaseMap) { Copy-Item $BaseMap (Join-Path $Dist "DotaVsWarcraft.w3x") }

$files = Get-ChildItem $Dist -Recurse -File
$total = ($files | Measure-Object Length -Sum).Sum
$files | ForEach-Object { "{0,12:N0}  {1}" -f $_.Length, $_.FullName.Substring($Dist.Length + 1) }
"{0,12:N0}  total ({1:N1} MB) in {2}" -f $total, ($total / 1MB), $Dist
