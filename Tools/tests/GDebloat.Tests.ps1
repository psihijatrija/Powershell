# Non-destructive checks of the Micro-derived builder; no Windows image is mounted.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = (Resolve-Path (Join-Path $PSScriptRoot '../GDebloat.ps1')).Path
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
$functions = $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
# Load only reviewed literal configuration assignments, never the build entry point.
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -in @('$ProtectedAppPatterns', '$MicroRemovalPaths', '$MicroPackagePatterns', '$script:EmbeddedOscdimgBase64')) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
Assert ($MicroRemovalPaths.Count -eq 7777) 'Micro file-removal baseline incomplete'
Assert ($MicroPackagePatterns.Count -eq 72) 'Micro package-removal baseline incomplete'
foreach ($relative in $MicroRemovalPaths) {
    Assert ($relative -notmatch '(^[\\/]|^[A-Za-z]:|(^|[\\/])\.\.([\\/]|$))') "Unsafe relative path in Micro data: $relative"
}
foreach ($name in @('Microsoft.WindowsStore', 'Microsoft.GamingApp', 'Microsoft.XboxIdentityProvider',
    'Microsoft.VCLibs.140.00', 'Microsoft.NET.Native.Runtime.2.2', 'Microsoft.UI.Xaml.2.8', 'Microsoft.WindowsAppRuntime.1.6')) {
    Assert (Test-MicroProtectedApp $name) "Protected app would be removed: $name"
}
Assert (-not (Test-MicroProtectedApp 'Microsoft.BingNews')) 'Micro app removal was accidentally narrowed'
foreach ($name in @('Microsoft-Windows-Ethernet-Client-Intel-E2f68-FOD-Package~amd64~1.0',
    'Microsoft-Windows-Ethernet-Client-Intel-E1i68x64-FOD-Package~amd64~1.0',
    'Microsoft-Windows-Ethernet-Client-Realtek-Rtcx21x64-FOD-Package~amd64~1.0',
    'Microsoft-Windows-NetFx-Package~amd64~1.0')) {
    Assert (Test-MicroProtectedPackage $name) "Required package would be removed: $name"
}
Assert (-not (Test-MicroProtectedPackage 'Microsoft-Edge-WebView-FOD-Package~amd64~1.0')) 'WebView removal blocked'
foreach ($relative in @('Windows/System32/DriverStore/FileRepository/rt640x64.inf_amd64/device.sys',
    'Windows/System32/drivers/e2f.sys', 'Windows/INF/rt640x64.inf', 'Windows/System32/audiosrv.dll',
    'Windows/System32/mmdevapi.dll', 'Windows/System32/msiexec.exe', 'Windows/Microsoft.NET/Framework/v4.0.30319/mscorlib.dll',
    'Windows/servicing/Packages/required.mum', 'Windows/SystemApps/MicrosoftWindows.Client.CBS_cw5n1h2txyewy/file.dll')) {
    Assert (Test-MicroProtectedPath $relative) "Protected path selected for removal: $relative"
}
foreach ($relative in @('Windows/System32/Recovery/winre.wim', 'Program Files (x86)/Microsoft/Edge',
    'Windows/assembly/NativeImages_v4.0.30319_64', 'Windows/Help/old.chm')) {
    Assert (-not (Test-MicroProtectedPath $relative)) "Requested Micro removal blocked: $relative"
}
$eligible = @($MicroRemovalPaths | Where-Object { -not (Test-MicroProtectedPath $_) })
Assert ($eligible.Count -gt 1000) 'Micro file-removal pass unexpectedly empty/narrow'
# Compile the real Windows metadata query without invoking kernel32 on this host.
Initialize-MicroLinkQuery
Assert ($null -ne ('GDebloat.MicroFileLinks' -as [type])) 'Hardlink metadata helper failed to compile'
function Get-MicroLinkCount([string]$Path) {
    if ($Path -match 'unknown') { throw 'metadata unavailable' }
    if ($Path -match 'live') { return 2 }
    return 1
}
Assert (Test-MicroKeepComponent 'amd64_runtime' @([pscustomobject]@{ FullName = 'live.dll' })) 'Live component discarded'
Assert (Test-MicroKeepComponent 'amd64_runtime' @([pscustomobject]@{ FullName = 'unknown.dll' })) 'Unknown component state discarded'
Assert (Test-MicroKeepComponent 'amd64_microsoft-windows-audio' @()) 'Audio component discarded'
Assert (Test-MicroKeepComponent 'Manifests' @()) 'Installer metadata discarded'
Assert (-not (Test-MicroKeepComponent 'amd64_obsolete' @([pscustomobject]@{ FullName = 'retired.dll' }))) 'Retired component not selected'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('micro-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    foreach ($relative in @('Windows/Help', 'Windows/System32/DriverStore',
        'Windows/WinSxS/amd64_obsolete', 'Windows/WinSxS/amd64_live', 'Windows/WinSxS/Manifests')) {
        $directory = Join-Path $temp $relative
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory 'sentinel'), 'fixture')
    }
    $results = @(Remove-MicroTargets $temp @('Windows/Help', 'Windows/System32/DriverStore'))
    Assert ($results.Count -eq 1 -and $results[0].Outcome -eq 'Removed') 'Micro removal result incorrect'
    Assert (Test-Path (Join-Path $temp 'Windows/System32/DriverStore/sentinel')) 'DriverStore was deleted'
    $count = Invoke-MicroWinSxSTrim $temp
    Assert ($count -eq 1) 'Incorrect component trim count'
    Assert (Test-Path (Join-Path $temp 'Windows/WinSxS/amd64_live/sentinel')) 'Live component removed'
    Assert (Test-Path (Join-Path $temp 'Windows/WinSxS/Manifests/sentinel')) 'Manifests removed'
    $before = @([pscustomobject]@{ Key = 'intel'; Inf = 'e2f.inf' }, [pscustomobject]@{ Key = 'realtek'; Inf = 'rt640x64.inf' })
    Assert-DriversPreserved $before $before 'Fixture'
    $caught = $null
    try { Assert-DriversPreserved $before @($before[0]) 'Fixture' } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Loss of Realtek Ethernet driver accepted'
    $caught = $null
    try { Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-Command', 'exit 7') } catch { $caught = $_ }
    Assert ($null -ne $caught -and $caught.Exception.Data['ExitCode'] -eq 7) 'Native error lost'
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = [BitConverter]::ToString($hash.ComputeHash([Convert]::FromBase64String($script:EmbeddedOscdimgBase64))).Replace('-', '') }
    finally { $hash.Dispose() }
    Assert ($actualHash -eq 'F5129F313ED7EB46F2677CF522E64264A225F226307ED0DDB52BB14C46E7CFDD') 'Embedded tool changed'
    # Boot media must have no destructive servicing in the real build body.
    $text = [IO.File]::ReadAllText($path)
    Assert ($text -notmatch '/Delete-Image') 'Boot index deletion reintroduced'
    Assert ($text -notmatch 'Unsupported reparse tag|fsutil.exe.*reparsepoint') 'Old per-file reparse blocker retained'
    "PASS: parse, complete Micro baseline ($($MicroRemovalPaths.Count) targets, $($eligible.Count) eligible), protection filters, metadata helper compilation, component trimming, file removal, driver loss, native errors, executable checksum."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
