# Windows helper: resolve the peer host address for an SSH forward.
#
# Order:
#   1) explicit -Peer
#   2) `ssh -G <SshHost>` -> HostName; verify the ssh port before trusting it
#   3) the connected WLAN adapter's default gateway (the peer is the hotspot host)
#
# Output: the IPv4 address on stdout; exit 0 on success, 1 when nothing answers.
[CmdletBinding()]
param(
  [string]$SshHost = '',
  [string]$Peer = '',
  [int]$SshPort = 22,
  [int]$ProbeTimeoutMs = 900
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-TcpPort {
  param([string]$Address, [int]$Port, [int]$TimeoutMs)
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync($Address, $Port)
    if (-not $task.Wait($TimeoutMs)) { return $false }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

# A TCP handshake is not proof (hotspot/carrier middleboxes accept any SYN).
# Only a real sshd answers with an "SSH-2.0-..." banner line.
function Test-SshBanner {
  param([string]$Address, [int]$Port, [int]$TimeoutMs)
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync($Address, $Port)
    if (-not $task.Wait($TimeoutMs)) { return $false }
    if (-not $client.Connected) { return $false }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $TimeoutMs
    $buffer = New-Object byte[] 64
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { return $false }
    $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    return $text.StartsWith('SSH-')
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Test-IPv4([string]$value) {
  return $value -match '^\d{1,3}(\.\d{1,3}){3}$'
}

$candidates = New-Object System.Collections.Generic.List[object]

if ($Peer) { $candidates.Add([pscustomobject]@{ Ip = $Peer; Source = 'explicit' }) }

if ($SshHost -and (Get-Command ssh -ErrorAction SilentlyContinue)) {
  $hostName = (ssh -G $SshHost 2>$null | Where-Object { $_ -match '^hostname ' } | Select-Object -First 1) -replace '^hostname\s+', ''
  if ($hostName -and $hostName -ne '%h') {
    if (Test-IPv4 $hostName) {
      $candidates.Add([pscustomobject]@{ Ip = $hostName; Source = 'ssh-config' })
    } else {
      $resolved = [System.Net.Dns]::GetHostAddresses($hostName) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString }
      foreach ($ip in $resolved) { $candidates.Add([pscustomobject]@{ Ip = $ip; Source = 'dns' }) }
    }
  }
}

$cfg = Get-NetIPConfiguration | Where-Object {
  if (-not $_.IPv4DefaultGateway) { return $false }
  if ($_.NetAdapter.Status -ne 'Up') { return $false }
  return $_.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN|802\.11'
} | Select-Object -First 1
if ($cfg) {
  foreach ($nextHop in $cfg.IPv4DefaultGateway.NextHop) {
    $candidates.Add([pscustomobject]@{ Ip = $nextHop; Source = 'wlan-gateway' })
  }
}

foreach ($candidate in $candidates) {
  if (Test-SshBanner -Address $candidate.Ip -Port $SshPort -TimeoutMs $ProbeTimeoutMs) {
    if ($env:PEER_IP_VERBOSE) {
      [Console]::Error.WriteLine("peer-ip: $($candidate.Ip) via $($candidate.Source)")
    }
    Write-Output $candidate.Ip
    exit 0
  }
}

exit 1
