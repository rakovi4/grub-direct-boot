# GRUB Direct Boot

Boot Linux ISO directly from your hard drive. No USB stick needed.

## Why?

Sometimes you need to install Linux and:
- It's 3 AM and you don't have a USB stick
- Ventoy doesn't support internal drives on Windows
- Grub2Win geo-blocks your country
- You just want something that works

This tool downloads GRUB EFI bootloader from official Ubuntu repositories, copies it to your EFI partition, and creates a boot menu entry. One command. Done.

## Requirements

- Windows 10/11 with UEFI boot (GPT partition table)
- Secure Boot **disabled** in BIOS
- A Linux ISO file on your hard drive
- Internet connection (downloads ~1.6 MB of GRUB files)
- Administrator privileges

## Quick Start

1. Download/clone this repo
2. Open PowerShell **as Administrator**
3. Run:

```powershell
.\install.ps1 -IsoPath "C:\Users\You\Downloads\ubuntu-24.04-desktop-amd64.iso"
```

4. Reboot. GRUB menu appears. Select your Linux installer. Done.

## Usage

### Install

```powershell
# Basic - uses default menu title
.\install.ps1 -IsoPath "C:\path\to\linux.iso"

# Custom menu title
.\install.ps1 -IsoPath "C:\ISOs\fedora-40.iso" -MenuTitle "Fedora 40"
```

### Uninstall

```powershell
.\install.ps1 -Uninstall
```

Removes GRUB files from EFI partition and deletes the boot entry. Your Windows boot is untouched.

## What it does

1. Downloads GRUB EFI bootloader from Ubuntu's official package archive
2. Mounts your EFI System Partition
3. Copies GRUB EFI binary + modules to `\EFI\grub-direct-boot\`
4. Generates `grub.cfg` pointing to your ISO
5. Adds a UEFI firmware boot entry via `bcdedit`
6. Sets GRUB as first in boot order
7. Cleans up downloaded files

On reboot, GRUB menu shows your Linux installer + Windows fallback.

## What it does NOT do

- Touch your Windows bootloader
- Modify your disk partitions
- Ship any third-party binaries (downloads from official source at install time)
- Phone home or check your locale/country/timezone
- Ask for donations with passive-aggressive popups

## Tested with

- Ubuntu 24.04 LTS
- Windows 10 Pro (UEFI/GPT)
- Lenovo IdeaPad (82K2)

Should work with any UEFI system and any Linux ISO that uses the standard Casper live boot layout (`/casper/vmlinuz` + `/casper/initrd`).

## Non-Ubuntu ISOs

The default `grub.cfg` template uses Ubuntu's Casper boot layout. For other distros, you may need to edit the generated `grub.cfg` on the EFI partition after install. Common alternatives:

| Distro | Kernel path | Initrd path | Boot param |
|--------|------------|-------------|------------|
| Ubuntu/Mint | `/casper/vmlinuz` | `/casper/initrd` | `boot=casper` |
| Fedora | `/images/pxeboot/vmlinuz` | `/images/pxeboot/initrd.img` | `root=live:CDLABEL=...` |
| Arch | `/arch/boot/x86_64/vmlinuz-linux` | `/arch/boot/x86_64/initramfs-linux.img` | `archisobasedir=arch` |

Multi-distro template support is planned.

## GRUB source

GRUB binaries are downloaded at install time from Ubuntu's official package archive (`archive.ubuntu.com`). GRUB is free software under the [GNU General Public License v3](https://www.gnu.org/licenses/gpl-3.0.html). Source code is available at [https://ftp.gnu.org/gnu/grub/](https://ftp.gnu.org/gnu/grub/).

## Origin story

Built at 3 AM when every other option failed. Ventoy only works on USB drives. Grub2Win geo-blocks Russian users via IP + Windows locale checks. The official installer self-deletes and reboots if it doesn't like your country. So we said: why do we need the GUI at all? GRUB is just files on the EFI partition + a boot entry. One PowerShell script does the whole job.

## License

MIT
