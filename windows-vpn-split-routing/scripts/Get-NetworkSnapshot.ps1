#requires -Version 7.2
param([string]$OutputFile)
$ErrorActionPreference = 'Stop'
$adapters = @(Get-NetAdapter -IncludeHidden)
$interfaces = @(Get-NetIPInterface -AddressFamily IPv4)
$routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore)
$addresses = @(Get-NetIPAddress -AddressFamily IPv4)
$rows = @(foreach ($adapter in $adapters) {
    $index = $adapter.ifIndex
    $ipInterface = $interfaces | Where-Object InterfaceIndex -eq $index | Select-Object -First 1
    $publicRoutes = @($routes | Where-Object {
        $_.InterfaceIndex -eq $index -and $_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1')
    })
    $gateway = @($publicRoutes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' })
    [pscustomobject]@{
        alias = $adapter.Name
        index = $index
        description = $adapter.InterfaceDescription
        up = $adapter.Status -eq 'Up'
        physical = [bool]$adapter.HardwareInterface
        has_ipv4 = @($addresses | Where-Object { $_.InterfaceIndex -eq $index -and $_.AddressState -eq 'Preferred' }).Count -gt 0
        has_default_gateway = $gateway.Count -gt 0
        public_route_prefixes = @($publicRoutes | Select-Object -ExpandProperty DestinationPrefix -Unique)
        interface_metric = $ipInterface.InterfaceMetric
    }
})
$physical = @($rows | Where-Object { $_.up -and $_.physical -and $_.has_ipv4 -and $_.has_default_gateway } | Sort-Object interface_metric)
$vpn = @($rows | Where-Object { $_.up -and !$_.physical -and $_.has_ipv4 -and $_.public_route_prefixes.Count -gt 0 })
$effective = @(foreach ($destination in @('1.1.1.1','149.112.112.112')) {
    try {
        $selection = Find-NetRoute -RemoteIPAddress $destination -ErrorAction Stop | Where-Object InterfaceIndex | Select-Object -First 1
        [pscustomobject]@{test_address=$destination;interface_index=$selection.InterfaceIndex}
    } catch {
        [pscustomobject]@{test_address=$destination;interface_index=$null}
    }
})
$proxy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$result = [pscustomobject]@{
    schema_version = 1
    captured_utc = [datetimeoffset]::UtcNow.ToString('o')
    adapters = $rows
    suggested_physical = if ($physical.Count) { $physical[0].alias } else { $null }
    vpn_candidates = @($vpn | Select-Object -ExpandProperty alias)
    effective_public_routes = $effective
    system_proxy_enabled = [bool]$proxy.ProxyEnable
    existing_pac = ![string]::IsNullOrWhiteSpace($proxy.AutoConfigURL)
    occupied_tcp_ports = @(Get-NetTCPConnection -State Listen | Where-Object LocalPort -ge 7897 | Where-Object LocalPort -le 7997 | Select-Object -ExpandProperty LocalPort -Unique)
}
$json = $result | ConvertTo-Json -Depth 8
if ($OutputFile) {
    $destination = [IO.Path]::GetFullPath($OutputFile)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::WriteAllText($destination,$json,[Text.UTF8Encoding]::new($false))
}
$json
