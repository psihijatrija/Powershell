# GDebloat image builder

Run in elevated, 64-bit Windows PowerShell on Windows, using intact x64 Windows installation media. Use an NTFS staging volume with at least 20 GB free (more can be needed for large images). Work takes place in a unique child folder; existing work-folder contents are preserved.

```powershell
.\GDebloat.ps1 -SourceIso 'F:\' -ImageIndex 1 -SizeProfile Minimal `
  -OutputIso 'C:\Downloads\Windows-Minimal.iso' -WorkDirectory 'C:\ISO_Build'
```

`Minimal` is now the default. It removes the explicit optional application list, including Photos, Calculator, Notepad, Terminal, Widgets, and promotional apps. It also removes Edge/WebView2 browser directories, selected optional capabilities, and selected disabled feature payloads. Audio drivers, codecs, Store/Xbox packages, shared AppX frameworks, and core servicing are retained. **Removing WebView2 can break Xbox or Microsoft sign-in screens and other applications.** Package preservation does not establish that those applications work.

The Micro-derived pass additionally removes installed/staged optional FOD package families through DISM (ISE, WMIC, Notepad/WordPad, legacy Media Player, Steps Recorder, Telnet/TFTP, OpenSSH, XPS, AD LDS, Work Folders, Simple TCP/IP, Projected File System, and the removable Edge WebView FOD where present). It uses exact package identities discovered in the target image. Non-removable/missing-assembly package errors are reported as retained; unexpected errors stop the build. It removes Help, wallpapers, system sound files, troubleshooting scripts, OneDrive setup executables, and regenerable .NET native-image caches. The .NET runtime and assemblies remain.

The uploaded Micro script explicitly targets Intel E2f68/E1i68x64 and Realtek Rtcx21x64 Ethernet FOD packages and contains thousands of raw install/boot file deletions. GDebloat excludes those driver cuts and the raw deletion of .NET runtimes, core shell apps, component manifests/catalogs, and boot/setup providers. These are concrete differences from Micro, so it does not promise Micro's image size.

WinRE is removed unless `-KeepWinRE` is supplied. Automatic Windows OS updates are disabled by policy unless `-AllowAutomaticUpdates` is supplied. The servicing and update backend remains installed for Store/Xbox dependencies; the builder does not remove Windows Update's component packages or guarantee that all manually initiated updates are blocked.

Use `-SizeProfile Balanced` to retain the additional Minimal targets and browsers. Balanced also attempts to enable .NET 3.5 and DirectPlay. With Minimal, those additions require `-EnableLegacyGamingFeatures`; .NET 3.5 requires matching source payloads, optionally supplied with `-NetFx3Source`.

## Reinstalling Edge and WebView2 later

The build does not set policies blocking browser installation or remove Windows Installer, core servicing, or AppX frameworks. It includes `%SystemRoot%\Setup\Scripts\GDebloat-RestoreBrowsers.txt` in the installed OS.

Download Microsoft's full x64 [Edge Enterprise installer](https://www.microsoft.com/edge/business/download) and [WebView2 Evergreen Standalone Runtime installer](https://developer.microsoft.com/microsoft-edge/webview2/). Install both as Administrator, reboot, then test Xbox sign-in. Edge and WebView2 are separate products; installing only Edge does not establish that the required WebView2 runtime is available. These installations do not require enabling automatic OS updates. Reinstallation and Xbox functionality have not been verified on a completed image in this Linux environment.

## Image size and WinSxS

The large `install_working.wim` in the staging folder is temporary. The final ISO uses **one edition in `sources\install.esd`, compressed with DISM `/Compress:recovery`**. It must not contain an additional install WIM/SWM. The build reports the final ESD's size and SHA-256 separately from the ISO's size and hash. A 1 GB installation image is a target, not a promised result; no size has been measured until an actual Windows build completes.

DISM removes selected optional feature payloads and runs `/StartComponentCleanup /ResetBase` using Windows servicing metadata. It can remove superseded components but is not a dependency-based garbage collector for every manually removed app. Provisioned apps are removed through AppX servicing; Edge/WebView2 directories are removed explicitly. Core WinSxS manifests, catalogs, identity components, drivers, and shared payloads are retained. Disabling automatic updates does not make those files unnecessary for installed applications or setup.

When pending servicing blocks cleanup with `0x800f0806`, the build records the skipped cleanup and retains pending operations. It does not delete `pending.xml` or revert pending setup changes. It supplies this helper **inside the installed Windows image**:

```powershell
# After installation finishes and Windows has rebooted, run elevated:
& "$env:SystemRoot\Setup\Scripts\GDebloat-ComponentCleanup.ps1"
```

This finishes installed-system cleanup when servicing permits it. It does **not** shrink the already-created ISO. `/ResetBase` makes superseded updates non-uninstallable. If the ISO itself needs further reduction after pending actions, a separately validated install/reboot/recapture workflow is needed; the builder does not claim to implement or test that workflow.

## USB setup compatibility

Every boot.wim index and its driver/component payload is retained. Driver inventories are compared before and after servicing; losing a source driver stops the build. The report lists Intel/Realtek Net-class packages (which can include Wi-Fi as well as Ethernet). Drivers absent from the original image must be supplied separately; an inventory match does not prove a particular network adapter works. Setup files and boot sectors are preserved. The copied boot WIM's read-only attribute is cleared before write mounting; the source media is untouched. Overlays cannot replace files under `boot`, `efi`, or `sources`, except `sources\$OEM$` payloads. An overlay cannot supply another installation image.

For hardware that needs Intel VMD/RST, AMD RAID, or another OEM storage driver, supply extracted **signed INF packages appropriate for that hardware**:

```powershell
.\GDebloat.ps1 -SourceIso 'F:\' -ImageIndex 1 `
  -DriverDirectory 'E:\Drivers\Storage'
```

Drivers are added to both the installed OS image and every source boot image. Signature enforcement is not bypassed. Preserving source drivers cannot guarantee that every storage controller is supported.

Use Rufus to create the USB and check its completion status. If `install.esd` is 4 GiB or larger, use NTFS/UEFI:NTFS; copying it directly to FAT32 cannot work. Before deployment, boot the result on the target hardware and test disk visibility, installation, audio output, Store installation, and Xbox sign-in/game launch. Test the original source ISO on the same hardware if a media-driver message occurs.

## Validation

```powershell
pwsh -NoProfile -File .\tests\GDebloat.Tests.ps1
```

These checks exercise parsing, overlay rejection before copying, clearing read-only without changing bytes, native error propagation, cleanup/health handling, profile protections, browser-removal isolation, and boot driver routing. Command doubles cover DISM flow; these tests do not perform a Windows image build or establish hardware, Store, Xbox, or audio functionality. Actual builds must report `Healthy` from the DISM image health scan before export.
