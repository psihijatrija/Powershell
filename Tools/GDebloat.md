# GDebloat: adapted Micro 11 Barebones

This version replaces the previous GDebloat removal pipeline with the **complete install-image file and package lists from the uploaded `TrimKit/Micro 11 Barebones.ps1`**: 7,777 file targets and 72 package patterns. It uses Micro's bulk `takeown`/`icacls` ownership pass and direct file deletion, with explicit exceptions for drivers, audio, Store/Xbox packages, shared runtimes, and installation infrastructure. The former per-file reparse-tag blocker is gone, so ordinary WIM/SIS-backed files are not rejected as unknown links.

The uploaded Micro source SHA-256 is `46254253E4B18470221DFF828C7F1F5BBB0B4339C3369571AD7F4BBA9D22F20B`. This is an adapted builder, not a byte-for-byte copy: its destructive boot/setup and blind registry-deletion stages are intentionally excluded. No claim is made that Windows functionality has been verified or that it reaches Micro's original size.

## Run

Use elevated **64-bit Windows PowerShell**, intact x64 Windows installation media, and an NTFS staging volume with at least 20 GB free. The script prompts for the source and edition if omitted. It uses a fresh work subdirectory and never clears the supplied parent directory.

```powershell
.\GDebloat.ps1 -SourceIso 'F:\' -ImageIndex 1 `
  -OutputIso 'E:\Test\GDebloat-Micro.iso' -WorkDirectory 'C:\ISO_Build'
```

`SourceIso` also accepts a mounted media folder or ISO path. Choose an edition present in your source. An existing output ISO is never overwritten; choose another filename or remove the old output yourself. `-SizeProfile Minimal` is accepted for compatibility. The old Balanced profile, GSecurity overlays, and legacy feature-injection options are not part of this replacement.

**Oscdimg is embedded** in the single script. It extracts into the isolated work directory and verifies SHA-256 `F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD` before use. An explicit `-OscdimgPath`, local executable, or installed ADK executable can still be selected. No runtime download is required.

## What differs from Micro

- **Boot/setup:** Micro's boot-index deletion, boot driver/file removal, boot WinSxS pruning, and setup-media file cleanup are omitted. The source `boot.wim` is copied and checked for byte equality. Without optional driver injection it remains unchanged. This preserves source compatibility; it cannot supply drivers absent from the source.
- **Drivers:** install-image DriverStore, INF files, and driver binaries are protected. Intel/Realtek Ethernet and Wi-Fi FOD packages are excluded from Micro's package-removal patterns. Source driver inventories are compared before and after removals; loss of a source driver stops export. The report lists detected Intel/Realtek Net-class packages, including Ethernet and potentially Wi-Fi. That list is not a hardware compatibility test.
- **Audio/Store/Xbox:** audio services/binaries, Store/Xbox provisioned packages, codecs, shared AppX frameworks, .NET runtimes, installer files, and core shell/identity dependencies have protected exceptions. All other provisioned applications are candidates for removal, as in Micro. Broad registry garbage-collection and service-registration deletion are excluded. Preservation is intended to support these features but does not establish that they work.
- **WinSxS:** direct payload trimming replaces Micro's near-empty component-store whitelist. Component directories are retained if they contain files with multiple hardlinks, match protected runtime/device families, or have unknown link state. Other component payload directories can be deleted. Metadata directories and root files, including pending operations, remain. This ties trimming to what remains installed but is **not a complete dependency-graph analysis**. It can still leave CBS servicing inconsistent. Native link counts are queried in-process rather than launching `fsutil` for every file.
- **Updates:** automatic OS updates are disabled by policy; the servicing/delivery backend is retained for Store/Xbox. Micro's fake WSUS server and disabling of `wuauserv` are omitted. Manual OS updates are not guaranteed to be blocked.
- **Edge/WebView2/WinRE:** removed. No empty recovery-WIM placeholder is created. Browser restoration instructions are included at `%SystemRoot%\Setup\Scripts\GDebloat-RestoreBrowsers.txt`. Windows Installer/framework files are protected so later installation can be attempted with Microsoft's full Edge installer and WebView2 Evergreen Standalone Runtime. Restoration and Xbox sign-in still require testing on the finished image.
- **Failures:** optional app/package/file removals are reported as retained or partial instead of falsely counted as successes. Mounting, image export, driver loss, protected AppX loss, and ISO creation remain fatal. Failed builds retain the transcript and work directory.

The script does not inherit unrelated Micro changes that disable UAC, the pagefile, or CPU security mitigations. It does not guarantee Windows Update/servicing support after manual component stripping, or that missing dependencies can be restored without original media/rebuilding.

## OEM drivers and USB

If the source lacks your hardware's driver, supply the extracted **signed INF packages**:

```powershell
.\GDebloat.ps1 -SourceIso 'F:\' -ImageIndex 1 `
  -OutputIso 'E:\Test\GDebloat-Micro.iso' -DriverDirectory 'E:\Drivers'
```

This adds the supplied drivers to the installed OS image and every original boot image, preserving original driver inventories. Unsigned-driver enforcement is not bypassed. Drivers must match the target hardware; random driver bundles are unnecessary.

Use Rufus to create the USB and check its completion status. An `install.esd` at or above 4 GiB cannot be copied directly to FAT32; use NTFS/UEFI:NTFS. Test disk detection and installation on the target hardware. If a media-driver error appears, compare with the original ISO on the same USB and hardware.

## Size and validation

The large working WIM is temporary. Final media contains **one recovery-compressed `sources\install.esd`**, not that working WIM. The report records final ESD/ISO sizes and SHA-256 values, the number of eligible Micro targets, component removals, and individual removal outcomes. **One GB is a target, not a verified or guaranteed result.** Retained drivers, active components, runtimes, and installer metadata impose a size cost.

```powershell
pwsh -NoProfile -File .\tests\GDebloat.Tests.ps1
```

Checks cover parsing, the complete Micro target lists, protection filters, metadata-helper compilation, simulated live/retired component trimming, disposable-file removal, driver-loss detection, native errors, and the embedded executable checksum. Native hardlink queries and image servicing require Windows and are not validated by these Linux checks. Boot the finished USB and test installation, audio, Store downloads, Xbox sign-in/game launch, and later Edge/WebView2 installation before relying on the image.
