#requires -Version 7.2
param([Parameter(Mandatory)][string]$SettingsFile,[switch]$CheckOnly,[switch]$Once)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
if ($cfg.schema_version -ne 1) { throw 'Unsupported settings schema' }
$root = [IO.Path]::GetFullPath($cfg.data_directory).TrimEnd('\')
$configPath = [IO.Path]::GetFullPath($cfg.config_file)
$corePath = (Resolve-Path -LiteralPath $cfg.core_executable).Path
if ($configPath -ne (Join-Path $root 'config.yaml') -or !(Test-Path -LiteralPath $configPath)) { throw 'Unexpected configuration path' }
if ($cfg.proxy_port -lt 1024 -or $cfg.proxy_port -gt 65535) { throw 'Invalid proxy port' }
$directoryArg = '(?:^|\s)-d\s+(?:"'+[regex]::Escape($root)+'"|'+[regex]::Escape($root)+'(?=\s|$))'
$configArg = '(?:^|\s)-f\s+(?:"'+[regex]::Escape($configPath)+'"|'+[regex]::Escape($configPath)+'(?=\s|$))'
$lastMessage = ''
function Get-OwnedCore {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -eq $corePath -and $_.CommandLine -and
        $_.CommandLine -match $directoryArg -and $_.CommandLine -match $configArg
    })
}
function Read-Health {
    $owners = @(Get-OwnedCore)
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $cfg.proxy_port -ErrorAction SilentlyContinue)
    $ready = $owners.Count -eq 1 -and $listeners.Count -gt 0 -and
        @($listeners | Where-Object { $_.OwningProcess -ne $owners[0].ProcessId -or $_.LocalAddress -notin @('127.0.0.1','::1') }).Count -eq 0
    $adapters = @(Get-NetAdapter -IncludeHidden)
    $physical = @($adapters | Where-Object { $_.Name -eq $cfg.physical_interface -and $_.Status -eq 'Up' })
    $vpn = @($adapters | Where-Object { $_.Name -eq $cfg.vpn_interface -and $_.Status -eq 'Up' })
    [pscustomobject]@{listener_ready=[bool]$ready;owned_processes=$owners.Count;port=$cfg.proxy_port;physical_up=$physical.Count -eq 1;vpn_up=$vpn.Count -eq 1;port_occupied=$listeners.Count -gt 0}
}
if ($CheckOnly) { Read-Health | ConvertTo-Json -Compress; exit 0 }
$settingsHash = (Get-FileHash -LiteralPath $SettingsFile -Algorithm SHA256).Hash.Substring(0,16)
$mutex = [Threading.Mutex]::new($false,('Local\VpnSplitRouting-'+$settingsHash))
$ownsLock = $false
try {
    try { $ownsLock=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsLock=$true }
    if (!$ownsLock) { exit 0 }
    do {
        try {
            $health = Read-Health
            $message = 'WAITING_FOR_NETWORK'
            if ($health.owned_processes -gt 1) { throw 'Multiple owned core processes' }
            if ($health.listener_ready) { $message = if ($health.vpn_up) { 'READY' } else { 'READY_VPN_DOWN' } }
            elseif ($health.owned_processes -eq 1) { $message = 'CORE_STARTING_OR_UNHEALTHY' }
            elseif ($health.port_occupied) { $message = 'PORT_BELONGS_TO_ANOTHER_PROCESS' }
            elseif ($health.physical_up -and $health.vpn_up) {
                $argsForCore = @('-d',('"'+$root+'"'),'-f',('"'+$configPath+'"'))
                Start-Process -FilePath $corePath -ArgumentList $argsForCore -WorkingDirectory $root -WindowStyle Hidden `
                    -RedirectStandardOutput (Join-Path $root 'core.stdout.log') -RedirectStandardError (Join-Path $root 'core.stderr.log') | Out-Null
                $message = 'CORE_STARTED'
            }
        } catch { $message = 'ERROR_'+$_.Exception.GetType().Name }
        if ($message -ne $lastMessage) {
            Add-Content -LiteralPath (Join-Path $root 'supervisor.log') -Value ([datetimeoffset]::UtcNow.ToString('o')+' '+$message) -Encoding utf8
            $lastMessage=$message
        }
        if (!$Once) { Start-Sleep -Seconds 10 }
    } while (!$Once)
} finally {
    if ($ownsLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
