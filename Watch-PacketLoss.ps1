[CmdletBinding(DefaultParameterSetName='Watch')]
param(
    [Parameter(ParameterSetName='Watch')][ipaddress]$Gateway,
    [Parameter(ParameterSetName='Watch')][ipaddress]$InternetA = '1.1.1.1',
    [Parameter(ParameterSetName='Watch')][ipaddress]$InternetB = '8.8.8.8',
    [Parameter(ParameterSetName='Watch')][ValidateRange(1,300)][int]$IntervalSeconds = 2,
    [Parameter(ParameterSetName='Watch')][ValidateRange(100,30000)][int]$TimeoutMs = 1000,
    [Parameter(ParameterSetName='Watch')][string]$OutputDirectory = '.',
    [Parameter(ParameterSetName='Watch')][ValidateRange(0,2147483647)][int]$Rounds = 0,
    [Parameter(Mandatory,ParameterSetName='Report')][string]$Report
)

$ErrorActionPreference = 'Stop'

function New-IncidentRow($end, $reason) {
    $duration = if ($end) { ([datetimeoffset]::Parse($end) - [datetimeoffset]::Parse($first.Time)).TotalSeconds }
    [pscustomobject]@{
        FirstMiss = $first.Time
        LastMiss = $last.Time
        FirstInternetReply = $end
        MissRounds = $missRounds
        ObservedSpanSeconds = ([datetimeoffset]::Parse($last.Time) - [datetimeoffset]::Parse($first.Time)).TotalSeconds
        EstimatedSeconds = $duration
        GatewayReplies = $gatewayReplies
        EndReason = $reason
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Report') {
    $dir = (Resolve-Path -LiteralPath $Report).ProviderPath
    $raw = Join-Path $dir 'samples.csv'
    $hourly = [ordered]@{}
    $first = $null
    $previous = $null
    $incidents = @(
        Import-Csv -LiteralPath $raw | ForEach-Object {
            $row = $_
            $now = [datetimeoffset]::Parse($row.Time)
            $hour = $now.ToString('yyyy-MM-dd HH:00 zzz')
            if (!$hourly.Contains($hour)) {
                $hourly[$hour] = [pscustomobject]@{
                    LocalHour=$hour; Rounds=0; GatewayMisses=0; InternetAMisses=0; InternetBMisses=0
                    SharedMissRounds=0; IncidentStarts=0; ProbeErrorRounds=0; SharedMissPct=$null
                }
            }
            $h = $hourly[$hour]
            $h.Rounds++
            $unknown = $row.InternetAStatus -eq 'ProbeError' -or $row.InternetBStatus -eq 'ProbeError'
            foreach ($key in 'Gateway','InternetA','InternetB') {
                if ($row."${key}Status" -notin 'Success','ProbeError') { $h."${key}Misses"++ }
            }
            if ($unknown -or $row.GatewayStatus -eq 'ProbeError') { $h.ProbeErrorRounds++ }
            $shared = !$unknown -and $row.InternetAStatus -ne 'Success' -and $row.InternetBStatus -ne 'Success'
            $delta = if ($previous) { ($now - $previous).TotalSeconds }
            $gap = $previous -and ($delta -gt 2 * [int]$row.IntervalSeconds -or $delta -le 0)
            if ($first -and ($gap -or $unknown -or !$shared)) {
                if ($gap) { New-IncidentRow $null 'Sampling gap' }
                elseif ($unknown) { New-IncidentRow $null 'Probe error' }
                else { New-IncidentRow $row.Time 'Internet reply' }
                $first = $null
            }
            if ($shared) {
                if (!$first) {
                    $first = $row
                    $missRounds = $gatewayReplies = 0
                    $h.IncidentStarts++
                }
                $last = $row
                $missRounds++
                $h.SharedMissRounds++
                if ($row.GatewayStatus -eq 'Success') { $gatewayReplies++ }
            }
            $previous = $now
        }
        if ($first) { New-IncidentRow $null 'End of capture' }
    )
    foreach ($h in $hourly.Values) {
        $h.SharedMissPct = [math]::Round(100 * $h.SharedMissRounds / $h.Rounds, 2)
    }
    $hourly.Values | Export-Csv -LiteralPath (Join-Path $dir 'hourly.csv') -NoTypeInformation
    $incidents | Export-Csv -LiteralPath (Join-Path $dir 'incidents.csv') -NoTypeInformation
    Write-Host "$($incidents.Count) shared-loss episodes. Reports: $dir\hourly.csv and $dir\incidents.csv"
    return
}

if ($TimeoutMs -gt 1000 * $IntervalSeconds) { throw 'TimeoutMs must not exceed the sampling interval.' }
if (!$Gateway) {
    $route = Find-NetRoute -RemoteIPAddress $InternetA.IPAddressToString |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } | Select-Object -First 1
    if (!$route) { throw 'Cannot determine gateway. Supply -Gateway with the wired gateway address from ipconfig.' }
    $Gateway = [ipaddress]$route.NextHop
}
$addresses = @($Gateway,$InternetA,$InternetB)
if (@($addresses | Select-Object -ExpandProperty IPAddressToString -Unique).Count -ne 3) {
    throw 'Use three different probe addresses.'
}
$dir = Join-Path $OutputDirectory ("PacketLoss-{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date),$PID)
$dir = (New-Item -ItemType Directory -Path $dir).FullName
$raw = Join-Path $dir 'samples.csv'
Write-Host "Gateway: $Gateway   Internet A: $InternetA   Internet B: $InternetB"
Write-Host "Recording in $dir (Ctrl+C to stop)"
$pings = @($addresses | ForEach-Object { New-Object System.Net.NetworkInformation.Ping })
$keys = 'Gateway','InternetA','InternetB'
try {
    for ($n = 1; !$Rounds -or $n -le $Rounds; $n++) {
        $clock = [diagnostics.stopwatch]::StartNew()
        $row = [ordered]@{ Time=[datetimeoffset]::Now.ToString('o'); IntervalSeconds=$IntervalSeconds }
        $tasks = @($null,$null,$null)
        for ($i=0; $i -lt 3; $i++) {
            try { $tasks[$i] = $pings[$i].SendPingAsync($addresses[$i], $TimeoutMs) }
            catch { $tasks[$i] = $null }
        }
        for ($i=0; $i -lt 3; $i++) {
            $key = $keys[$i]
            $row[$key] = $addresses[$i].IPAddressToString
            $row["${key}Status"] = 'ProbeError'
            $row["${key}Ms"] = $null
            if ($tasks[$i]) {
                try {
                    $reply = $tasks[$i].GetAwaiter().GetResult()
                    $row["${key}Status"] = $reply.Status.ToString()
                    if ($reply.Status -eq 'Success') { $row["${key}Ms"] = $reply.RoundtripTime }
                } catch { Write-Verbose $_ }
            }
        }
        [pscustomobject]$row | Export-Csv -LiteralPath $raw -Append -NoTypeInformation
        $wait = 1000 * $IntervalSeconds - $clock.ElapsedMilliseconds
        if ($wait -gt 0 -and (!$Rounds -or $n -lt $Rounds)) { Start-Sleep -Milliseconds $wait }
    }
} finally {
    foreach ($ping in $pings) { $ping.Dispose() }
}
