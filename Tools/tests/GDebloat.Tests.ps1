# Non-destructive regression checks. Run: pwsh -NoProfile -File ./Tools/tests/GDebloat.Tests.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '../GDebloat.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $path).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$functions = $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)
foreach ($name in @('Test-AllowedOverlayPath', 'Set-StagedImageWritable', 'Invoke-Native', 'Invoke-Dism', 'Copy-IsoOverlayInternal', 'Write-Utf8', 'Write-Step', 'Test-KeptApp', 'Remove-OfflineBrowserPayload', 'Get-OfflineDriverInventory', 'Assert-DriversPreserved', 'Get-OfflineReparseTag', 'Prepare-OfflineRemovalTree')) {
    $definition = $functions | Where-Object Name -eq $name
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
foreach ($name in @('sources/boot.wim', 'sources/install.wim', 'sources/install.esd',
    'sources/install2.swm', 'sources/setup.exe', 'sources/dismapi.dll',
    'efi/microsoft/boot/efisys.bin', 'boot/etfsboot.com', 'bootmgr', 'setup.exe',
    'SOURCES\INSTALL.WIM')) {
    Assert (-not (Test-AllowedOverlayPath $name)) "Unsafe overlay accepted: $name"
}
foreach ($name in @('autounattend.xml', 'sources/$OEM$/$$/Setup/Scripts/SetupComplete.cmd', 'payloads/install.ps1')) {
    Assert (Test-AllowedOverlayPath $name) "Allowed overlay rejected: $name"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gdebloat-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $image = Join-Path $temp 'boot.wim'
    [IO.File]::WriteAllText($image, 'source image placeholder')
    $hash = (Get-FileHash $image).Hash
    [IO.File]::SetAttributes($image, [IO.FileAttributes]::ReadOnly)
    Set-StagedImageWritable $image
    Assert (-not ((Get-Item $image).Attributes -band [IO.FileAttributes]::ReadOnly)) 'Staged image remains read-only'
    Assert ((Get-FileHash $image).Hash -eq $hash) 'Clearing read-only changed image bytes'

    $overlay = Join-Path $temp 'overlay'
    $media = Join-Path $temp 'media'
    New-Item -ItemType Directory -Path (Join-Path $overlay 'sources'), $media | Out-Null
    [IO.File]::WriteAllText((Join-Path $overlay 'autounattend.xml'), 'answer')
    [IO.File]::WriteAllText((Join-Path $overlay 'sources/install.wim'), 'bad')
    $blocked = $false
    try { Copy-IsoOverlayInternal $overlay $media | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Unsafe overlay was not blocked'
    Assert (@(Get-ChildItem $media -Recurse -File).Count -eq 0) 'Overlay partially copied before rejection'

    # Execute a real child process to verify native exit-code propagation.
    $caught = $null
    try { Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-Command', 'exit 7') }
    catch { $caught = $_ }
    Assert ($null -ne $caught) 'Native failure was ignored'
    Assert ($caught.Exception.Data['ExitCode'] -eq 7) 'Native exit code was lost'

    # Exercise the actual cleanup catch block without mounting or servicing an image.
    $scriptText = [IO.File]::ReadAllText((Resolve-Path $path))
    $start = $scriptText.IndexOf('    $componentCleanupCompleted = $false')
    $end = $scriptText.IndexOf('    $winrePresent =', $start)
    $cleanup = [scriptblock]::Create($scriptText.Substring($start, $end - $start))
    function Invoke-Dism { param($Arguments)
        if ($script:SimulatedExitCode) {
            $errorObject = [InvalidOperationException]::new('simulated servicing error')
            $errorObject.Data['ExitCode'] = $script:SimulatedExitCode
            throw $errorObject
        }
    }
    function Repair-WindowsImage { param($Path, [switch]$ScanHealth, $ErrorAction)
        [pscustomobject]@{ ImageHealthState = $script:SimulatedHealth }
    }
    $mount = $temp
    $script:SimulatedHealth = 'Healthy'
    $script:SimulatedExitCode = -2146498554
    . $cleanup
    Assert (-not $componentCleanupCompleted) 'Pending cleanup was reported as completed'
    Assert ($componentCleanupSkipReason -match '0x800f0806') 'Pending reason was lost'
    $script:SimulatedExitCode = 5
    $caught = $null
    try { . $cleanup } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Unexpected cleanup failure was ignored'
    $script:SimulatedExitCode = 0
    . $cleanup
    Assert $componentCleanupCompleted 'Successful cleanup was not recorded'
    $script:SimulatedHealth = 'Repairable'
    $caught = $null
    try { . $cleanup } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Unhealthy image was accepted'
    # Verify Minimal extends the explicit removal list without touching protected packages.
    $configStart = $scriptText.IndexOf('$ProfileData = @{')
    $configEnd = $scriptText.IndexOf('# HELPER FUNCTIONS', $configStart)
    $config = [scriptblock]::Create($scriptText.Substring($configStart, $configEnd - $configStart))
    $SizeProfile = 'Balanced'
    . $config
    $balancedCount = $ProfileData.RemoveApps.Count
    $SizeProfile = 'Minimal'
    . $config
    Assert ($ProfileData.RemoveApps.Count -gt $balancedCount) 'Minimal did not expand removals'
    foreach ($app in $ProfileData.RemoveApps) {
        Assert (-not (Test-KeptApp $app)) "Protected app selected for removal: $app"
    }

    # Exercise browser removal on a disposable offline-image-shaped fixture.
    $fixture = Join-Path $temp 'offline'
    foreach ($relative in @('Windows/System32/config', 'Windows/WinSxS',
        'Windows/System32/DriverStore', 'Program Files/WindowsApps/Microsoft.WindowsStore',
        'Program Files (x86)/Microsoft/Edge', 'Program Files (x86)/Microsoft/EdgeWebView')) {
        $directory = Join-Path $fixture $relative
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory 'sentinel'), 'keep')
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'Windows/System32/config/SYSTEM'), 'hive placeholder')
    $removed = @(Remove-OfflineBrowserPayload $fixture)
    Assert ($removed.Count -eq 2) 'Browser fixture removal count incorrect'
    Assert (-not (Test-Path (Join-Path $fixture 'Program Files (x86)/Microsoft/EdgeWebView'))) 'WebView2 payload retained'
    foreach ($relative in @('Windows/WinSxS/sentinel', 'Windows/System32/DriverStore/sentinel',
        'Program Files/WindowsApps/Microsoft.WindowsStore/sentinel')) {
        Assert (Test-Path (Join-Path $fixture $relative)) "Browser removal damaged protected path: $relative"
    }

    # Real filesystem links must be removed without touching external targets.
    $outside = Join-Path $temp 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'outside sentinel')
    $linkedBrowser = Join-Path $fixture 'Program Files (x86)/Microsoft/Edge'
    New-Item -ItemType Directory -Path $linkedBrowser -Force | Out-Null
    $linkedPath = Join-Path $linkedBrowser 'external-link'
    New-Item -ItemType SymbolicLink -Path $linkedPath -Target $outside | Out-Null
    # fsutil is Windows-only; return the real symlink tag for this fixture.
    function Get-OfflineReparseTag { param($Path) '0xa000000c' }
    Remove-OfflineBrowserPayload $fixture | Out-Null
    Assert (Test-Path (Join-Path $outside 'keep.txt')) 'Browser cleanup followed an external link'
    Assert (-not (Test-Path $linkedBrowser)) 'Browser tree containing a link was not removed'

    # Simulate a WOF-compressed file through the entry predicate, without fsutil.
    $wofFile = [pscustomobject]@{ FullName = 'WOF-fixture'; Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $false }
    function Get-Item { param($LiteralPath, [switch]$Force, $ErrorAction) $wofFile }
    function Get-OfflineReparseTag { param($Path) '0x80000017' }
    Prepare-OfflineRemovalTree 'WOF-fixture'
    Remove-Item Function:Get-Item
    function Get-OfflineReparseTag { param($Path) '0x8000ffff' }
    function Get-Item { param($LiteralPath, [switch]$Force, $ErrorAction) $wofFile }
    $caught = $null
    try { Prepare-OfflineRemovalTree 'unknown-fixture' } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Unknown reparse tag was accepted'
    Remove-Item Function:Get-Item
    # Restore the actual implementation for subsequent test sections.
    . ([scriptblock]::Create(($functions | Where-Object Name -eq 'Get-OfflineReparseTag').Extent.Text))

    # Exercise the Micro package selection against optional, Ethernet, and core packages.
    foreach ($relative in @('Windows/Help', 'Windows/Web', 'Windows/Media', 'Windows/diagnostics', 'Windows/assembly/NativeImages_test')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $relative) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Join-Path $fixture $relative) 'sentinel'), 'remove')
    }
    function Get-WindowsPackage { param($Path, $ErrorAction)
        foreach ($name in @('Microsoft-Windows-StepsRecorder-Package~amd64~1.0',
            'Microsoft-Edge-WebView-FOD-Package~amd64~1.0',
            'Microsoft-Windows-Ethernet-Client-Intel-E2f68-FOD-Package~amd64~1.0',
            'Microsoft-Windows-Ethernet-Client-Realtek-Rtcx21x64-FOD-Package~amd64~1.0',
            'Microsoft-Windows-Core-Package~amd64~1.0')) {
            [pscustomobject]@{ PackageName = $name; PackageState = 'Installed' }
        }
    }
    function Invoke-Dism { param($Arguments)
        $script:PackageCalls += ,@($Arguments)
        if ($Arguments -match 'WebView') {
            $errorObject = [InvalidOperationException]::new('non-removable package')
            $errorObject.Data['ExitCode'] = -2146498523
            throw $errorObject
        }
    }
    $microStart = $scriptText.IndexOf("    if (`$SizeProfile -eq 'Minimal') {", $scriptText.IndexOf('    $features = @('))
    $microEnd = $scriptText.IndexOf('    # WINRE REMOVAL', $microStart)
    $microBlock = [scriptblock]::Create($scriptText.Substring($microStart, $microEnd - $microStart))
    $script:PackageCalls = @()
    $microPackageResults = @()
    $mount = $fixture
    . $microBlock
    Assert ($script:PackageCalls.Count -eq 2) 'Micro selection touched Ethernet or core packages'
    Assert (@($microPackageResults | Where-Object Outcome -eq 'Removed').Count -eq 1) 'Micro removal result incorrect'
    Assert (@($microPackageResults | Where-Object Outcome -eq 'Retained').Count -eq 1) 'Non-removable package was falsely counted'
    Assert (-not (Test-Path (Join-Path $fixture 'Windows/Help'))) 'Micro optional data was not removed'
    Assert (Test-Path (Join-Path $fixture 'Windows/WinSxS/sentinel')) 'Micro data cleanup touched WinSxS'

    # Run the real boot servicing block against command doubles: both indexes must
    # receive supplied drivers, with no unsigned-driver bypass or payload deletion.
    function Write-Header { param($Title) }
    function Get-WindowsImage { param($ImagePath)
        [pscustomobject]@{ ImageIndex = 1; ImageName = 'WinPE' }
        [pscustomobject]@{ ImageIndex = 2; ImageName = 'Setup' }
    }
    function Invoke-Dism { param($Arguments)
        $script:BootCalls += ,@($Arguments)
    }
    $media = Join-Path $temp 'boot-media'
    New-Item -ItemType Directory -Path (Join-Path $media 'sources') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $media 'sources/boot.wim'), 'boot placeholder')
    $bootMount = Join-Path $temp 'bootmount'
    New-Item -ItemType Directory -Path $bootMount | Out-Null
    $bootStart = $scriptText.IndexOf('    $bootWimPath =')
    $bootEnd = $scriptText.IndexOf('    # ISO MASTERING', $bootStart)
    $bootBlock = [scriptblock]::Create($scriptText.Substring($bootStart, $bootEnd - $bootStart))
    function Get-WindowsDriver { param($Path, [switch]$All, $ErrorAction)
        [pscustomobject]@{ Driver = 'rt640x64.inf'; OriginalFileName = 'rt640x64.inf'; Version = '1.0'; ClassName = 'Net'; ProviderName = 'Realtek' }
        [pscustomobject]@{ Driver = 'e2f.inf'; OriginalFileName = 'e2f.inf'; Version = '2.0'; ClassName = 'Net'; ProviderName = 'Intel' }
    }
    $driverFixture = @(Get-OfflineDriverInventory $bootMount)
    Assert ($driverFixture.Count -eq 2) 'Network driver inventory incomplete'
    Assert-DriversPreserved $driverFixture $driverFixture 'Fixture'
    $caught = $null
    try { Assert-DriversPreserved $driverFixture @($driverFixture[0]) 'Fixture' } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Loss of Intel Ethernet driver was accepted'
    $DriverDirectory = 'signed OEM drivers'
    $script:BootCalls = @()
    . $bootBlock
    Assert ($script:BootCalls.Count -eq 6) 'Not all boot indexes were serviced'
    Assert (@($script:BootCalls | Where-Object { $_ -contains '/Add-Driver' }).Count -eq 2) 'Driver injection missed a boot index'
    Assert (-not ($script:BootCalls | Where-Object { $_ -contains '/ForceUnsigned' })) 'Unsigned drivers allowed'
    Assert (-not $mountedBootImage) 'Boot mount flag not cleared'
    $DriverDirectory = $null
    $script:BootCalls = @()
    . $bootBlock
    Assert ($script:BootCalls.Count -eq 2) 'Default boot servicing changed extra indexes'
    Assert ($script:BootCalls[0] -contains '/Index:2') 'Default servicing selected the wrong boot index'
    'PASS: parse, WOF handling, external-link isolation, overlays, read-only attributes, exit codes, cleanup, health gate, profiles, browser isolation, Micro removals, Ethernet driver preservation, boot driver routing.'

} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
