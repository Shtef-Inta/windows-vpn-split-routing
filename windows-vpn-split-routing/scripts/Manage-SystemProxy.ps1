#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][ValidateSet('Apply','Restore')][string]$Action,[Parameter(Mandatory)][string]$SettingsFile)
$ErrorActionPreference='Stop'
$cfg=Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
if ($cfg.schema_version -ne 1 -or $cfg.proxy_port -lt 1024 -or $cfg.proxy_port -gt 65535) { throw 'Unexpected routing settings' }
$root=[IO.Path]::GetFullPath($cfg.data_directory)
$snapshot=Join-Path $root 'system-proxy-before.json'
$registryPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$managedProxy='127.0.0.1:'+$cfg.proxy_port
$values=Get-ItemProperty -LiteralPath $registryPath
function Read-ProxyValues {
    $key=Get-Item -LiteralPath $registryPath
    @(foreach ($name in @('ProxyEnable','ProxyServer','ProxyOverride')) {
        $exists=$name -in $key.GetValueNames()
        [pscustomobject]@{name=$name;exists=$exists;value=if($exists){$key.GetValue($name)};kind=if($exists){$key.GetValueKind($name).ToString()}}
    })
}
function Write-ProxyValues($items) {
    foreach ($item in $items) {
        if ($item.exists) { New-ItemProperty -LiteralPath $registryPath -Name $item.name -PropertyType $item.kind -Value $item.value -Force | Out-Null }
        else { Remove-ItemProperty -LiteralPath $registryPath -Name $item.name -ErrorAction SilentlyContinue }
    }
}
if ($Action -eq 'Apply') {
    if ($values.AutoConfigURL) { throw 'An existing PAC configuration needs an explicit migration before this script can apply the proxy' }
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $cfg.proxy_port -ErrorAction SilentlyContinue)
    if (!$listeners.Count -or @($listeners|Where-Object LocalAddress -notin @('127.0.0.1','::1')).Count) { throw 'The loopback proxy listener is not ready' }
    $corePath=(Resolve-Path -LiteralPath $cfg.core_executable).Path
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $listeners[0].OwningProcess)
    if (!$owner -or $owner.ExecutablePath -ne $corePath -or !$owner.CommandLine.Contains($cfg.config_file,[StringComparison]::OrdinalIgnoreCase)) { throw 'The listener is not owned by the selected Mihomo configuration' }
    if ($listeners.OwningProcess | Where-Object {$_ -ne $owner.ProcessId}) { throw 'The port has multiple owners' }
    if ((Test-Path -LiteralPath $snapshot) -and $values.ProxyServer -ne $managedProxy) {
        throw 'A previous baseline exists and the active proxy differs; reconcile that snapshot before replacing another proxy'
    }
    if (!$PSCmdlet.ShouldProcess('Current Windows user','Back up and apply local split-routing proxy')) { return }
    $before=Read-ProxyValues
    if (!(Test-Path -LiteralPath $snapshot)) {
        [pscustomobject]@{schema_version=1;values=$before} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshot -Encoding utf8
    }
    try {
        New-ItemProperty -LiteralPath $registryPath -Name ProxyServer -PropertyType String -Value $managedProxy -Force | Out-Null
        New-ItemProperty -LiteralPath $registryPath -Name ProxyOverride -PropertyType String -Value 'localhost;127.*;[::1];<local>' -Force | Out-Null
        New-ItemProperty -LiteralPath $registryPath -Name ProxyEnable -PropertyType DWord -Value 1 -Force | Out-Null
    } catch {
        Write-ProxyValues $before
        throw
    }
} else {
    $saved=Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    if ($saved.schema_version -ne 1 -or @($saved.values).Count -ne 3 -or @($saved.values|Where-Object name -notin @('ProxyEnable','ProxyServer','ProxyOverride')).Count) { throw 'Unexpected baseline snapshot' }
    if ($values.ProxyServer -ne $managedProxy) { throw 'Another application changed the proxy; review before restoring the previous baseline' }
    if (!$PSCmdlet.ShouldProcess('Current Windows user','Restore proxy baseline')) { return }
    $before=Read-ProxyValues
    try {
        Write-ProxyValues $saved.values
    } catch {
        Write-ProxyValues $before
        throw
    }
}
if (!('VpnSplitWinInet' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VpnSplitWinInet {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);
}
'@
}
[void][VpnSplitWinInet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
[void][VpnSplitWinInet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
[pscustomobject]@{action=$Action;applied=$true;proxy_port=$cfg.proxy_port} | ConvertTo-Json -Compress
