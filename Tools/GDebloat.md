# GDebloat — Micro 11 Barebones renamed and edited

This is now the **actual uploaded Micro script**, edited in place, rather than the previous rewritten GDebloat pipeline. The original ownership, bulk deletion, package removal, WinSxS whitelist/copy/delete, hive-helper definitions, WIM rebuild, ESD compression and ISO mastering code remains wherever it does not conflict with the exclusions below.

The source was `TrimKit/Micro 11 Barebones.ps1`, SHA-256 `46254253E4B18470221DFF828C7F1F5BBB0B4339C3369571AD7F4BBA9D22F20B`. Its original install/boot deletion arrays and package-pattern list remain; exceptions are applied after those lists. Install file targets include 7,777 literal entries and one computed Help path. No new per-file reparse, hardlink, driver-inventory or image-health gates are added to the build.

## Changes to Micro

- Renamed its branding and staging folder to **GDebloat**.
- Embedded **oscdimg.exe**. It extracts into a unique temporary executable and verifies SHA-256 `F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD`; it does not download the tool. `-OscdimgPath` can select an existing executable.
- Excluded Ethernet/Wi-Fi driver packages and driver/INF paths from the main deletion lists. Intel/Realtek Ethernet drivers already present in the source are retained. Micro's separate install-image printer/scanner/smartcard/tape-driver pruning remains.
- Added keep prefixes for Store, Xbox/Gaming, shared AppX runtimes and media codecs. Added audio, installer, .NET, core shell and sign-in exceptions to the file lists. AppX residual-folder removal uses only successfully removed packages.
- Retained **Micro's WinSxS copy/delete method**, expanded with driver/audio/Store/Xbox/runtime/installer keep patterns. Manifests/catalogs and root metadata files are retained. This is still an aggressive whitelist, not a verified dependency closure.
- Restored **Micro's original boot flow**: delete boot index 1, mount the remaining Setup image as index 1, run its original file and WinSxS trimming, commit, and export index 1 with maximum compression. Driver paths/payloads and registry files/profile hives are excluded from removal; the registry tweak/cleanup stages are omitted. Setup-media trimming follows Micro's list with driver/registry exclusions. The custom multi-index rebuild and broad runtime whitelist have been removed.
- Removed execution-policy changes, install policy/tweak stages, and offline registry mutation/cleanup/compaction stages. Boot hives are not loaded, edited, compacted or cleaned. Unused original registry helper definitions remain. No fake WSUS, UAC, pagefile, CPU-mitigation, or other policy tweaks are applied. Micro's update-file removal remains; automatic updates are not separately disabled by a new policy.
- Removed the empty WinRE placeholder. Edge, WebView2 and recovery removals remain.
- Restored Micro's original drive-root workspace: `C:\scratchdir` and `C:\GDebloat` by default. `-WorkDirectory` can select another drive root, such as `D:\`. An existing scratch/media directory stops startup rather than being overwritten. Added optional source-drive/index/output parameters and removed the completion prompt. Existing output files are not overwritten.

## Run

Use elevated **64-bit Windows PowerShell** on Windows. The source parameter follows Micro's original workflow: **mounted media drive**, not an ISO-file path. Mount the ISO first. Supply an image index that exists in that media, or omit it to use Micro's selection menu.

```powershell
.\GDebloat.ps1 -SourceIso 'F:\' -ImageIndex 1 `
  -OutputIso 'E:\Test\GDebloat.iso' -WorkDirectory 'C:\'
```

Running `.\GDebloat.ps1` prompts for the drive and edition. The old `SizeProfile` option is not part of this literal Micro adaptation. Driver and GSecurity inclusion are automatic as described below. The output defaults to `GDebloat.iso` beside the script. Transcripts are saved beside the script with unique names. The original short scratch path and original WinSxS deletion/rename sequence are restored: `WinSxS_edit` is prepared, the original `WinSxS` is deleted, and the prepared folder is renamed. The custom backup-folder swap, native RD fallback and extended-path helpers have been removed.

Use the source media or the auto-detected `Drivers` folder for the hardware drivers you need. Preserving drivers does not add Intel VMD/RST, RAID or Ethernet drivers absent from the source. Boot and install the original media on the same hardware when diagnosing a media-driver message.

## Automatic additions — no extra prompts

Only Micro's source-drive and edition-selection questions are shown. These additions run automatically:

- **Drivers:** when `Drivers` exists beside `GDebloat.ps1`, recursively add its signed INF packages to the installation image and the retained boot Setup image. Use extracted driver packages, not installer EXEs. `-DriverDirectory` overrides the location; `-SkipAutoDrivers` disables injection. DISM signature enforcement remains enabled.
- **GSecurity:** when `GSecurity` exists beside the script, use `GSecurity\Iso` if present, otherwise the folder itself as an overlay. Its root payload/answer-file content and `sources\$OEM$` content are copied into the final media; boot/EFI trees and source setup images/providers cannot be replaced. Copying files does not independently execute GSecurity scripts; its OEM/answer-file payload determines installed behavior. `-GSecurityDirectory` overrides the location; `-SkipGSecurity` disables inclusion.
- **.NET Framework 3.5 and DirectPlay:** enabled before Micro's removal stages and included in the keep exceptions. NetFx3 sources are discovered on the mounted media under `sources\sxs`, then beside the script under `NetFx3` or `sources\sxs`. `-NetFx3Source` can select another matching CAB directory. If NetFx3 is already enabled, source CABs are unnecessary. Otherwise, missing or mismatched CABs stop the build with a clear error, without asking another question. DirectPlay uses the source image's payload.

Enabling Windows features and injecting drivers naturally updates their offline registrations through DISM. This is separate from the removed Micro registry policy/cleanup stages. Feature/driver injection failures stop the build; the script does not silently omit requested features.

## Size and later browser installation

Micro's final output uses a single-edition, recovery-compressed **install.esd**. Its intermediate WIM is temporary. One GB remains a target, not a verified result. Protecting required dependencies increases the image compared with unmodified Micro.

For later browser installation, use Microsoft's full x64 [Edge installer](https://www.microsoft.com/edge/business/download) and [WebView2 Evergreen Standalone Runtime](https://developer.microsoft.com/microsoft-edge/webview2/). Shared runtimes, installer files and related metadata have keep exceptions. Actual reinstallation, Store downloads, Xbox sign-in/game launch and audio have **not** been validated on a completed image. Aggressive Micro stripping can still break dependencies and servicing; preservation patterns do not guarantee restoration.

Use Rufus to create the USB. If the final ESD exceeds FAT32's single-file limit, use NTFS/UEFI:NTFS.

## Checks

```powershell
pwsh -NoProfile -File .\tests\GDebloat.Tests.ps1
```

These checks parse the script and exercise its protection filters, original-list counts, protected AppX prefixes, original boot-index deletion/export sequence, absence of policy stages, and embedded executable checksum. Command doubles also exercise feature enabling, missing NetFx3 sources, driver injection/failures, and a disposable GSecurity overlay. They do not execute Micro's Windows build or prove a bootable/functioning result.
