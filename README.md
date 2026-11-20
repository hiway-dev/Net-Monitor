# Net Monitor

Track intermittent packet loss on Windows using built-in PowerShell. Every two seconds the monitor sends concurrent ICMP echo requests to the selected gateway, Cloudflare (`1.1.1.1`), and Google (`8.8.8.8`), with a one-second reply deadline. It logs the result and round-trip time for each target, without collecting packet contents.

## Capture

Connect by Ethernet, turn off Wi-Fi and VPN for the test, and keep the PC awake. Open PowerShell in this folder. Check the baseline first:

```powershell
.\Watch-PacketLoss.ps1 -Rounds 5
$run = Get-ChildItem -Directory -Filter 'PacketLoss-*' | Sort-Object Name -Descending | Select-Object -First 1
Import-Csv (Join-Path $run.FullName 'samples.csv') | Format-Table Time,GatewayStatus,InternetAStatus,InternetBStatus
```

If a target never replies even when the connection is healthy, it isn't a useful comparison. Use `-Gateway` to select a known responsive local router or `-InternetB` to substitute a responsive internet IP. If plugged directly into a modem in bridge mode, the detected gateway can be ISP-side, not a local device. If your machine blocks scripts, use your administrator's approved method of running a reviewed local script.

Start a longer run:

```powershell
.\Watch-PacketLoss.ps1
```

Record the local time when you notice symptoms, plus whether a backup, download, or upload was running. Aim for 48-72 hours including both healthy and bad periods. Stop with **Ctrl+C**; each completed round is saved. Each run gets a new folder. To pick where it goes, use `-OutputDirectory`.

## Report

Use the run folder printed by the monitor (substitute its actual name):

```powershell
.\Watch-PacketLoss.ps1 -Report '.\PacketLoss-YYYYMMDD-HHMMSS-PID'
```

| File | What to look for |
| --- | --- |
| `samples.csv` | Exact local timestamps with UTC offsets, addresses, reply statuses, and latencies. Useful for lining up a call drop or modem event with a specific round. An empty latency means no successful reply. |
| `hourly.csv` | Compare `SharedMissPct` and `IncidentStarts` at the same hour across days. `Rounds` is actual coverage, not an assumed full hour. Per-target miss counts also reveal loss that never affected both targets at once. |
| `incidents.csv` | Each run of consecutive rounds where **neither internet target replied successfully**. `EstimatedSeconds` runs from the first miss to the first round in which either target replied. `GatewayReplies` counts successful gateway replies during those missed rounds. |

A single missed round counts. The sampling interval limits timing precision, and shorter disruptions can be missed entirely. Capture end, probe errors, and gaps longer than two intervals leave the duration blank rather than counting unobserved time as downtime. `ObservedSpanSeconds` measures first to last observed miss. `ProbeErrorRounds` flags rounds with a local probe error at any target; those errors do not count as packet misses.

If a **local router** keeps replying while both internet targets repeatedly miss, those timestamps are useful evidence for the ISP to compare with modem signal and event history. If the local router also misses, check the PC, Ethernet link, and router before assigning blame. Loss to just one target may be path-specific or ICMP rate limiting. Ping alone doesn't prove a Spectrum fault or measure application traffic loss.
