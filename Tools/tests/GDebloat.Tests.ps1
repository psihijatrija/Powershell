# Parse and exercise the literal Micro exceptions without running its build body.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = (Resolve-Path (Join-Path $PSScriptRoot '../GDebloat.ps1')).Path
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
# Default paths must not evaluate PSScriptRoot or environment variables in param().
foreach ($parameter in $ast.ParamBlock.Parameters) {
 if ($parameter.Name.VariablePath.UserPath -in @('OutputIso', 'WorkDirectory')) {
  Assert ($null -eq $parameter.DefaultValue) 'Path still initialized during parameter binding'
 }
}
$sourceText = [IO.File]::ReadAllText($path)
$start = $sourceText.IndexOf('# Initialize runtime paths after parameter binding')
$end = $sourceText.IndexOf('# End runtime path initialization.', $start)
$savedSystemRoot = $env:SystemRoot
if (-not $env:SystemRoot) { $env:SystemRoot = [IO.Path]::GetTempPath() }
$pathFixture = Join-Path ([IO.Path]::GetTempPath()) ('gdebloat-path-' + [guid]::NewGuid().ToString('N') + '.ps1')
$fixtureText = 'param([string]$OutputIso, [string]$WorkDirectory)' + "`n" +
 $sourceText.Substring($start, $end - $start) + "`n" +
 '[pscustomobject]@{ Output = $OutputIso; Work = $WorkDirectory; Root = $PSScriptRoot }'
[IO.File]::WriteAllText($pathFixture, $fixtureText)
try {
 $defaults = & $pathFixture
 Assert ($defaults.Output -eq (Join-Path $defaults.Root 'GDebloat.iso')) 'Default output path incorrect'
 Assert (-not [string]::IsNullOrWhiteSpace($defaults.Work)) 'Default work path missing'
 $explicit = & $pathFixture -OutputIso 'chosen.iso' -WorkDirectory 'chosen-work'
 Assert ($explicit.Output -eq 'chosen.iso' -and $explicit.Work -eq 'chosen-work') 'Explicit paths overridden'
} finally { Remove-Item -LiteralPath $pathFixture -Force; $env:SystemRoot = $savedSystemRoot }
$nodes = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
$filter = $nodes | Where-Object Name -eq 'Test-Micro11CleanupPathForArchitecture'
. ([scriptblock]::Create($filter.Extent.Text))
$isAmd64 = $true; $isArm64 = $false; $isX86 = $false; $gDebloatBootPhase = $false
foreach ($file in @('C:\work\scratchdir\Windows\System32\drivers\e2f.sys',
    'C:\work\scratchdir\Windows\System32\DriverStore\FileRepository\rt640x64.inf_amd64\device.dll',
    'C:\work\scratchdir\Windows\INF\rt640x64.inf', 'C:\work\scratchdir\Windows\System32\config\SYSTEM',
    'C:\work\scratchdir\Users\Default\NTUSER.DAT', 'C:\work\scratchdir\Windows\System32\audiosrv.dll',
    'C:\work\scratchdir\Windows\System32\mmdevapi.dll', 'C:\work\scratchdir\Windows\System32\msiexec.exe',
    'C:\work\scratchdir\Windows\Microsoft.NET\Framework64\v4\mscorlib.dll')) {
    Assert (-not (Test-Micro11CleanupPathForArchitecture $file)) "Protected file selected: $file"
}
Assert (Test-Micro11CleanupPathForArchitecture 'C:\work\scratchdir\Windows\System32\Recovery\winre.wim') 'WinRE removal blocked'
$gDebloatBootPhase = $true
foreach ($file in @('Windows\System32\drivers', 'Windows\System32\DriverStore',
 'Windows\INF', 'Windows\System32\config', 'Windows\SysWOW64', 'Users', 'ProgramData', 'sources\winsetupboot.hiv',
 'sources\winsetupboot.sys', 'Windows\System32\GroupPolicy')) {
 Assert (-not (Test-Micro11CleanupPathForArchitecture ('C:\scratchdir\' + $file))) "Boot driver/registry protection missing: $file"
}
foreach ($file in @('sources\dismapi.dll', 'Windows\Fonts', 'Windows\Help')) {
 Assert (Test-Micro11CleanupPathForArchitecture ('C:\scratchdir\' + $file)) "Original Micro boot removal blocked: $file"
}
$assignments = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true)
$initialInstall = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$installArchitectureAwareRemovalPaths' })[0]
$initialBoot = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$bootArchitectureAwareRemovalPaths' })[0]
$initialPackages = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$packagePatterns' })[0]
$keepApps = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$keepPrefixes' })[0]
$scratchDir = 'C:\work\scratchdir'
$winDir = [IO.Path]::GetTempPath()
$languageCode = 'en-us'
. ([scriptblock]::Create($initialInstall.Extent.Text))
. ([scriptblock]::Create($initialBoot.Extent.Text))
. ([scriptblock]::Create($initialPackages.Extent.Text))
. ([scriptblock]::Create($keepApps.Extent.Text))
Assert ($installArchitectureAwareRemovalPaths.Count -eq 7778) 'Original Micro install list changed'
Assert ($bootArchitectureAwareRemovalPaths.Count -eq 1852) 'Original Micro boot list changed'
Assert ($packagePatterns.Count -eq 72) 'Original Micro package list changed'
foreach ($name in @('Microsoft.WindowsStore_1', 'Microsoft.GamingApp_1', 'Microsoft.XboxIdentityProvider_1',
    'Microsoft.VCLibs.140_1', 'Microsoft.NET.Native.Runtime_1', 'Microsoft.UI.Xaml_1')) {
    Assert (@($keepPrefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) "Protected app missing: $name"
}
$text = [IO.File]::ReadAllText($path)
Assert ($text -match "'/Delete-Image'.*'/Index:1'") 'Original Micro boot index deletion missing'
Assert ($text -notmatch 'Set-ExecutionPolicy|reg.exe add|reg.exe delete|reg load') 'Registry/policy modification remains'
Assert ($text -notmatch 'gDebloatBootImages') 'Custom multi-index boot rebuild remains'
Assert ($text -match '"/SourceImageFile:\$bootWim" ''/SourceIndex:1''') 'Original Micro boot export missing'
$bootSectionStart = $text.IndexOf('Write-Host "BOOT.WIM - MOUNT AND PREPARATION"')
$bootSectionEnd = $text.IndexOf('Write-Host "BOOT.WIM - COMMIT AND PHYSICAL WIM REBUILD"', $bootSectionStart)
$bootSection = $text.Substring($bootSectionStart, $bootSectionEnd - $bootSectionStart)
Assert ($bootSection -match 'WinSxS_edit') 'Original Micro boot WinSxS trimming missing'
Assert ($text -notmatch 'MicroFileLinks|Unsupported reparse tag|Repair-WindowsImage|Assert-DriversPreserved') 'Old rewritten pipeline remains'
$embedded = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$script:EmbeddedOscdimgBase64' })[0]
. ([scriptblock]::Create($embedded.Extent.Text))
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash([Convert]::FromBase64String($script:EmbeddedOscdimgBase64))).Replace('-', '') }
finally { $sha.Dispose() }
Assert ($hash -eq 'F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD') 'Embedded oscdimg changed'
Assert ($text -notmatch 'Replace-GDebloatWinSxS|WinSxS_remove_|Convert-GDebloatNativePath|GB.*Substring') 'Custom WinSxS/work-path mechanics remain'
Assert ($text -match '\$mainOSDrive = \$WorkDirectory.TrimEnd') 'Micro drive-root workspace not restored'
$originalSwap = ' Remove-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS -Recurse -Force' + "`n`n" +
 'Rename-Item -Path "$mainOSDrive\scratchdir\Windows\WinSxS_edit" -NewName "WinSxS" -ErrorAction Stop'
Assert (($text.Split(@($originalSwap), [StringSplitOptions]::None).Count - 1) -eq 2) 'Original Micro install/boot WinSxS sequences changed'
# Exercise only the added automation helpers, using command doubles and temporary files.
foreach ($name in @('Add-GDebloatDrivers', 'Enable-GDebloatLegacyFeatures', 'Copy-GDebloatGSecurityOverlay')) {
 . ([scriptblock]::Create(($nodes | Where-Object Name -eq $name).Extent.Text))
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gdebloat-automation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
 $script:NativeCalls = @(); $script:NativeCode = 0; $script:NetFxState = 'Disabled'
 function dism.exe { $script:NativeCalls += ,@($args); $global:LASTEXITCODE = $script:NativeCode }
 function Get-WindowsOptionalFeature { param($Path, $FeatureName, $ErrorAction) [pscustomobject]@{ State = $script:NetFxState } }
 Enable-GDebloatLegacyFeatures -MountPath $temp -SourcePath $temp
 Assert ($script:NativeCalls.Count -eq 2) 'NetFx3/DirectPlay did not both execute'
 Assert ($script:NativeCalls[0] -contains '/FeatureName:NetFx3') 'NetFx3 not enabled'
 Assert ($script:NativeCalls[1] -contains '/FeatureName:DirectPlay') 'DirectPlay not enabled'
 $script:NativeCalls = @(); $caught = $null
 try { Enable-GDebloatLegacyFeatures -MountPath $temp -SourcePath (Join-Path $temp 'missing') } catch { $caught = $_ }
 Assert ($null -ne $caught -and $script:NativeCalls.Count -eq 0) 'Missing NetFx3 source silently accepted'
 $script:NetFxState = 'Enabled'
 Enable-GDebloatLegacyFeatures -MountPath $temp -SourcePath $null
 Assert ($script:NativeCalls.Count -eq 1) 'Already-enabled NetFx3 required a source'
 $DriverDirectory = $temp
 $script:NativeCalls = @()
 Add-GDebloatDrivers $temp
 Assert ($script:NativeCalls.Count -eq 1 -and $script:NativeCalls[0] -contains '/Add-Driver') 'Driver injection not executed'
 Assert (-not ($script:NativeCalls[0] -contains '/ForceUnsigned')) 'Unsigned-driver enforcement bypassed'
 $script:NativeCode = 5; $caught = $null
 try { Add-GDebloatDrivers $temp } catch { $caught = $_ }
 Assert ($null -ne $caught) 'Driver injection failure ignored'
 $overlay = Join-Path $temp 'overlay'; $media = Join-Path $temp 'media'
 New-Item -ItemType Directory -Path (Join-Path $overlay 'sources/$OEM$'), (Join-Path $media 'sources'), (Join-Path $overlay 'boot') -Force | Out-Null
 [IO.File]::WriteAllText((Join-Path $overlay 'autounattend.xml'), 'answer')
 [IO.File]::WriteAllText((Join-Path $overlay 'sources/boot.wim'), 'do not copy')
 [IO.File]::WriteAllText((Join-Path $overlay 'sources/$OEM$/payload.ps1'), 'payload')
 Copy-GDebloatGSecurityOverlay $overlay $media
 Assert (Test-Path (Join-Path $media 'autounattend.xml')) 'Answer file overlay missing'
 Assert (Test-Path (Join-Path $media 'sources/$OEM$/payload.ps1')) 'OEM overlay missing'
 Assert (-not (Test-Path (Join-Path $media 'sources/boot.wim'))) 'Overlay replaced setup image'
 Assert (-not (Test-Path (Join-Path $media 'boot'))) 'Overlay replaced boot files'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
'PASS: Micro parse/lists, preservation exceptions, boot indexes, no policy stages, embedded oscdimg checksum; NetFx3/DirectPlay flow, missing source, driver injection/errors, and GSecurity overlay.'
