#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$PhysicalInterface,
    [Parameter(Mandatory)][string]$VpnInterface,
    [Parameter(Mandatory)][string]$CoreExe,
    [Parameter(Mandatory)][string]$DestinationDirectory,
    [ValidateRange(1024,65535)][int]$Port = 7897,
    [string]$PolicyFile = (Join-Path (Split-Path $PSScriptRoot) 'assets\routing-policy.json'),
    [switch]$WithoutProviders
)
$ErrorActionPreference = 'Stop'
$core = (Resolve-Path -LiteralPath $CoreExe).Path
$root = [IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\')
if ($PhysicalInterface -eq $VpnInterface) { throw 'Physical and VPN adapters must be different' }
foreach ($name in @($PhysicalInterface,$VpnInterface)) {
    if (!(Get-NetAdapter -IncludeHidden | Where-Object Name -eq $name)) {
        throw "Adapter was not found: $name"
    }
}
if ([IO.Path]::GetExtension($core) -ne '.exe') { throw 'Expected a Windows Mihomo executable' }
$configFile = Join-Path $root 'config.yaml'
$settingsFile = Join-Path $root 'routing-settings.json'
if ((Test-Path -LiteralPath $configFile) -or (Test-Path -LiteralPath $settingsFile)) { throw 'Use a fresh destination directory or back up the existing configuration first' }
$policy = Get-Content -LiteralPath $PolicyFile -Raw | ConvertFrom-Json
if ($policy.schema_version -ne 1 -or $policy.foreign_default -ne 'VPN') { throw 'Unexpected routing policy schema' }
$idn = [Globalization.IdnMapping]::new()
function Convert-Domain([string]$value) {
    $domain = $idn.GetAscii($value.Trim().TrimStart('.')).ToLowerInvariant()
    if ($domain -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$' -or $domain.Length -gt 253) {
        throw 'A policy entry is not a plain DNS suffix'
    }
    return $domain
}
$rules = [Collections.Generic.List[string]]::new()
$rules.AddRange([string[]]@('DOMAIN-SUFFIX,localhost,DIRECT','DOMAIN-SUFFIX,local,DIRECT',
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve','IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve','IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
    'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve'))
foreach ($domain in @($policy.vpn_domain_suffixes)) { $rules.Add('DOMAIN-SUFFIX,'+(Convert-Domain $domain)+',VPN') }
foreach ($domain in @($policy.direct_domain_suffixes)+@($policy.direct_country_suffixes)) { $rules.Add('DOMAIN-SUFFIX,'+(Convert-Domain $domain)+',ISP_DIRECT') }
$providers = [ordered]@{}
if (!$WithoutProviders -and $policy.use_russian_domain_provider) {
    $providers.russian_domains = [ordered]@{type='http';behavior='domain';format='mrs';url='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ru.mrs';path='./rules/category-ru.mrs';interval=86400;proxy='VPN'}
    $rules.Add('RULE-SET,russian_domains,ISP_DIRECT')
}
if (!$WithoutProviders -and $policy.use_russian_ip_provider) {
    $providers.russian_networks = [ordered]@{type='http';behavior='ipcidr';format='mrs';url='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/ru.mrs';path='./rules/ru-ip.mrs';interval=86400;proxy='VPN'}
    $rules.Add('RULE-SET,russian_networks,ISP_DIRECT')
}
$rules.Add('MATCH,VPN')
$config = [ordered]@{
    'mixed-port'=$Port; 'allow-lan'=$false; 'bind-address'='127.0.0.1'; mode='rule'; 'log-level'='info'
    ipv6=$false; 'find-process-mode'='off'; tun=@{enable=$false}
    proxies=@(
        [ordered]@{name='ISP_DIRECT';type='direct';'interface-name'=$PhysicalInterface;'ip-version'='ipv4'},
        [ordered]@{name='VPN';type='direct';'interface-name'=$VpnInterface;'ip-version'='ipv4'}
    )
    dns=[ordered]@{enable=$true;ipv6=$false;'enhanced-mode'='redir-host';'default-nameserver'=@('1.1.1.1');
        nameserver=@('https://1.1.1.1/dns-query#VPN','https://1.0.0.1/dns-query#VPN');
        'direct-nameserver'=@('https://1.1.1.1/dns-query#ISP_DIRECT')}
    'rule-providers'=$providers; rules=$rules.ToArray()
}
$settings = [ordered]@{schema_version=1;core_executable=$core;data_directory=$root;config_file=$configFile;
    physical_interface=$PhysicalInterface;vpn_interface=$VpnInterface;proxy_port=$Port}
[IO.Directory]::CreateDirectory($root) | Out-Null
# JSON is a valid YAML document. This keeps quotes and Unicode adapter names reliable.
[IO.File]::WriteAllText($configFile,($config | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($settingsFile,($settings | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{generated=$true;port=$Port;providers_enabled=$providers.Count -gt 0;settings_file=$settingsFile} | ConvertTo-Json -Compress
