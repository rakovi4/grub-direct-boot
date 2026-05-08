#Requires -RunAsAdministrator
<#
.SYNOPSIS
    GRUB Direct Boot - Boot Linux ISO from hard drive without USB stick.
.DESCRIPTION
    Sets up GRUB bootloader on the EFI partition to boot a Linux ISO
    directly from your hard drive. No USB stick needed. No bloatware.
    Downloads GRUB binaries from official Ubuntu package archive.
    Works on UEFI systems with GPT partition table.
.EXAMPLE
    .\install.ps1 -IsoPath "C:\Users\Me\Downloads\ubuntu-24.04-desktop-amd64.iso"
.EXAMPLE
    .\install.ps1 -IsoPath "D:\ISOs\fedora-40.iso" -MenuTitle "Fedora 40"
.EXAMPLE
    .\install.ps1 -Uninstall
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$IsoPath,

    [Parameter(Mandatory=$false)]
    [string]$MenuTitle = "Linux ISO Installer",

    [Parameter(Mandatory=$false)]
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$EfiDir = "EFI\grub-direct-boot"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $env:ProgramData "grub-direct-boot-state.txt"
$GrubPkgUrl = "http://archive.ubuntu.com/ubuntu/pool/main/g/grub2-unsigned/grub-efi-amd64-bin_2.12-1ubuntu7_amd64.deb"

function Write-Step($msg) { Write-Host "  [*] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  [-] $msg" -ForegroundColor Red }

# --- Download and extract GRUB from Ubuntu package ---
function Get-GrubFiles {
    $tempDir = Join-Path $env:TEMP "grub-direct-boot-dl"
    $debFile = Join-Path $tempDir "grub.deb"
    $extractDir = Join-Path $tempDir "extract"

    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    # Download .deb
    Write-Step "Downloading GRUB from Ubuntu archive (~1.6 MB)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $GrubPkgUrl -OutFile $debFile -UseBasicParsing

    if (-not (Test-Path $debFile)) { throw "Download failed" }
    Write-OK "Downloaded"

    # Parse .deb (ar archive) to extract data.tar
    Write-Step "Extracting GRUB modules..."
    $bytes = [System.IO.File]::ReadAllBytes($debFile)

    # ar format: 8-byte magic "!<arch>\n", then entries with 60-byte headers
    $pos = 8  # skip ar magic
    $dataTarFile = $null

    while ($pos -lt $bytes.Length) {
        # Read 60-byte ar header
        $name = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 16).Trim()
        $sizeStr = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 48, 10).Trim()
        $size = [int64]$sizeStr
        $pos += 60  # skip header

        if ($name -like "data.tar*") {
            $dataFile = Join-Path $tempDir $name
            $stream = [System.IO.File]::Create($dataFile)
            $stream.Write($bytes, $pos, $size)
            $stream.Close()
            $dataTarFile = $dataFile
        }

        $pos += $size
        if ($pos % 2 -ne 0) { $pos++ }  # ar entries are 2-byte aligned
    }

    if (-not $dataTarFile) { throw "Could not find data.tar in .deb package" }

    # Extract data.tar using Windows built-in tar
    & tar -xf $dataTarFile -C $extractDir 2>&1 | Out-Null

    # Find extracted GRUB files
    $modDir = Get-ChildItem -Path $extractDir -Recurse -Directory -Filter "x86_64-efi" | Select-Object -First 1
    if (-not $modDir) { throw "GRUB modules not found in package" }

    $grubRoot = $modDir.Parent.FullName
    Write-OK "Extracted GRUB modules"

    return @{
        ModulesDir = $modDir.FullName
        GrubDir = $grubRoot
        TempDir = $tempDir
    }
}

# --- Build grubx64.efi from modules ---
function Build-GrubEfi($modulesDir, $outputPath) {
    # Instead of building, use the pre-built monolithic image if available,
    # or copy the modular setup (modules loaded via grub.cfg insmod)
    # Ubuntu package includes individual .mod files — we use insmod in grub.cfg
    # We need a minimal grubx64.efi — check if one exists in the package
    $coreImg = Join-Path (Split-Path $modulesDir) "grubx64.efi"
    if (Test-Path $coreImg) {
        Copy-Item $coreImg $outputPath -Force
        return
    }

    # Look for any EFI binary in the package
    $efiFiles = Get-ChildItem -Path (Split-Path $modulesDir) -Filter "*.efi" -Recurse
    if ($efiFiles) {
        Copy-Item $efiFiles[0].FullName $outputPath -Force
        return
    }

    throw "No GRUB EFI binary found in package. The grub-efi-amd64-bin package may have changed structure."
}

# --- Find and mount EFI partition ---
function Mount-EfiPartition {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    $letter = [char[]](90..65) | Where-Object { $used -notcontains [string]$_ } | Select-Object -First 1
    if (-not $letter) { throw "No free drive letters available" }

    Write-Step "Mounting EFI partition as ${letter}:"

    $diskpartScript = @"
list vol
"@
    $diskpartScript | Out-File -FilePath "$env:TEMP\gdb-listvol.txt" -Encoding ASCII
    $output = & diskpart /s "$env:TEMP\gdb-listvol.txt" 2>&1 | Out-String

    $lines = $output -split "`n" | Where-Object { $_ -match "FAT32" -and $_ -match "System" }
    if (-not $lines) {
        # Fallback: try matching by size (100 MB typical EFI)
        $lines = $output -split "`n" | Where-Object { $_ -match "FAT32" -and $_ -match "100 M" }
    }
    if (-not $lines) { throw "Could not find EFI System Partition (FAT32)" }

    $volNum = ($lines[0] -replace '^\D*(\d+).*', '$1').Trim()

    $assignScript = @"
select volume $volNum
assign letter=$letter
"@
    $assignScript | Out-File -FilePath "$env:TEMP\gdb-assign.txt" -Encoding ASCII
    & diskpart /s "$env:TEMP\gdb-assign.txt" | Out-Null

    if (-not (Test-Path "${letter}:\")) {
        throw "Failed to mount EFI partition"
    }

    Write-OK "EFI partition mounted as ${letter}:"
    return "${letter}:"
}

function Remove-EfiLetter($drive) {
    $letter = $drive[0]
    $script = @"
select volume $letter
remove letter=$letter
"@
    try {
        $script | Out-File -FilePath "$env:TEMP\gdb-remove.txt" -Encoding ASCII
        & diskpart /s "$env:TEMP\gdb-remove.txt" 2>&1 | Out-Null
    } catch {}
}

# --- Uninstall ---
if ($Uninstall) {
    Write-Host "`n  GRUB Direct Boot - Uninstall`n" -ForegroundColor Yellow

    if (Test-Path $StateFile) {
        $guid = (Get-Content $StateFile -Raw).Trim()
        Write-Step "Removing BCD entry $guid"
        & bcdedit /delete $guid /f 2>&1 | Out-Null
        Remove-Item $StateFile -Force
        Write-OK "BCD entry removed"
    } else {
        Write-Step "No BCD state file found, skipping"
    }

    $efiDrive = Mount-EfiPartition
    $target = Join-Path $efiDrive $EfiDir
    if (Test-Path $target) {
        Write-Step "Removing $target"
        Remove-Item $target -Recurse -Force
        Write-OK "GRUB files removed from EFI partition"
    }
    Remove-EfiLetter $efiDrive

    Write-Host "`n  Uninstall complete. Reboot to apply.`n" -ForegroundColor Green
    exit 0
}

# --- Install ---
if (-not $IsoPath) {
    Write-Err "Usage: .\install.ps1 -IsoPath 'C:\path\to\linux.iso'"
    Write-Err "       .\install.ps1 -Uninstall"
    exit 1
}

if (-not (Test-Path $IsoPath)) {
    Write-Err "ISO file not found: $IsoPath"
    exit 1
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Yellow
Write-Host "  GRUB Direct Boot - Install" -ForegroundColor Yellow
Write-Host "  ============================================" -ForegroundColor Yellow
Write-Host "  ISO:   $IsoPath"
Write-Host "  Title: $MenuTitle"
Write-Host ""

# Step 1: Download GRUB
$grub = Get-GrubFiles

try {
    # Step 2: Mount EFI partition
    $efiDrive = Mount-EfiPartition

    try {
        # Step 3: Copy GRUB files to EFI partition
        $target = Join-Path $efiDrive $EfiDir
        Write-Step "Copying GRUB files to $target"

        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Directory -Path "$target\x86_64-efi" -Force | Out-Null

        # Copy modules
        Copy-Item "$($grub.ModulesDir)\*" "$target\x86_64-efi\" -Force

        # Copy or locate EFI binary
        Build-GrubEfi $grub.ModulesDir "$target\grubx64.efi"

        # Copy fonts if available
        $fontDir = Join-Path $grub.GrubDir "fonts"
        if (Test-Path $fontDir) {
            New-Item -ItemType Directory -Path "$target\fonts" -Force | Out-Null
            Copy-Item "$fontDir\*" "$target\fonts\" -Force
        }

        Write-OK "GRUB files copied to EFI partition"

        # Step 4: Generate grub.cfg
        Write-Step "Generating grub.cfg"

        $isoRelative = (Split-Path -NoQualifier $IsoPath).Replace('\', '/')

        $grubCfg = @"
set default=0
set timeout=10
set pager=1

insmod part_gpt
insmod ntfs
insmod ext2
insmod fat
insmod loopback
insmod iso9660
insmod linux
insmod search
insmod all_video

menuentry '$MenuTitle' --class linux {
    search --no-floppy --set=root --file $isoRelative
    set isofile="$isoRelative"
    loopback loop `$isofile
    linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=`$isofile quiet splash ---
    initrd (loop)/casper/initrd
}

menuentry 'Windows Boot Manager' --class windows {
    chainloader /efi/Microsoft/Boot/bootmgfw.efi
}

menuentry 'Reboot' --class reboot {
    reboot
}

menuentry 'Shutdown' --class shutdown {
    halt
}
"@
        $grubCfg | Out-File -FilePath "$target\grub.cfg" -Encoding ASCII -NoNewline
        Write-OK "grub.cfg written"

        # Step 5: Create BCD boot entry
        Write-Step "Creating UEFI boot entry"

        $bcdOutput = & bcdedit /copy "{bootmgr}" /d "GRUB Direct Boot - $MenuTitle" 2>&1 | Out-String
        if ($bcdOutput -match '\{[a-f0-9-]+\}') {
            $guid = $Matches[0]
        } else {
            throw "Failed to create BCD entry: $bcdOutput"
        }

        & bcdedit /set $guid path "\$EfiDir\grubx64.efi" | Out-Null
        & bcdedit /set "{fwbootmgr}" displayorder $guid /addfirst | Out-Null

        $guid | Out-File -FilePath $StateFile -Encoding ASCII

        Write-OK "BCD entry created: $guid"
        Write-OK "Set as first in firmware boot order"

    } finally {
        Remove-EfiLetter $efiDrive
    }
} finally {
    # Clean up downloaded files
    if ($grub.TempDir -and (Test-Path $grub.TempDir)) {
        Remove-Item $grub.TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Reboot your computer. GRUB menu will appear"
Write-Host "  with '$MenuTitle' as the default option."
Write-Host ""
Write-Host "  To remove later: .\install.ps1 -Uninstall"
Write-Host ""
