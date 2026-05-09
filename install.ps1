#Requires -RunAsAdministrator
<#
.SYNOPSIS
    GRUB Direct Boot - Boot Linux ISO from hard drive without USB stick.
.DESCRIPTION
    Sets up GRUB bootloader on the EFI partition to boot a Linux ISO
    directly from your hard drive. No USB stick needed. No bloatware.
    Downloads GRUB binaries from GitHub release (GNU GRUB 2.12, GPL v3).
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
$GrubZipUrl = "https://github.com/rakovi4/grub-direct-boot/releases/download/v1.0.0/grub-efi-x64.zip"

function Write-Step($msg) { Write-Host "  [*] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  [-] $msg" -ForegroundColor Red }

# --- Download and extract GRUB binaries ---
function Get-GrubFiles {
    $tempDir = Join-Path $env:TEMP "grub-direct-boot-dl"
    $zipFile = Join-Path $tempDir "grub-efi-x64.zip"

    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # Download .zip from GitHub release
    Write-Step "Downloading GRUB binaries (~4.2 MB)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $GrubZipUrl -OutFile $zipFile -UseBasicParsing

    if (-not (Test-Path $zipFile)) { throw "Download failed" }
    Write-OK "Downloaded"

    # Extract using built-in PowerShell
    Write-Step "Extracting GRUB files..."
    Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

    $grubDir = Join-Path $tempDir "grub"
    if (-not (Test-Path $grubDir)) { throw "GRUB files not found in archive" }

    Write-OK "Extracted GRUB files"

    return @{
        GrubDir = $grubDir
        TempDir = $tempDir
    }
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

    # Match FAT32 + ~100 MB EFI partition (locale-independent: just match FAT32 + 100)
    $lines = @($output -split "`n" | Where-Object { $_ -match "FAT32" -and $_ -match "\b100\b" })
    if (-not $lines) {
        # Broader fallback: any FAT32 volume (EFI is typically the only one)
        $lines = @($output -split "`n" | Where-Object { $_ -match "FAT32" })
    }
    if (-not $lines) { throw "Could not find EFI System Partition (FAT32)" }

    $volNum = ($lines[0] -replace '^\D*(\d+).*', '$1').Trim()

    $assignScript = @"
select volume $volNum
assign letter=$letter
"@
    $assignScript | Out-File -FilePath "$env:TEMP\gdb-assign.txt" -Encoding ASCII
    & diskpart /s "$env:TEMP\gdb-assign.txt" 2>&1 | Out-Null

    Start-Sleep -Seconds 2

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

        # Copy entire GRUB directory (grubx64.efi + x86_64-efi/ + fonts/)
        Copy-Item "$($grub.GrubDir)\*" "$target\" -Recurse -Force

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
