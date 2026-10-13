<#
.SYNOPSIS
  Quick deployable HTTP server for loadbalancer.org testing.
  SmartData Technologies Limited - Motijheel, Dhaka
  Zero dependencies - PowerShell 5.1 + .NET HttpListener only.

.USAGE
  Run as Administrator:
    powershell -ExecutionPolicy Bypass -File LbTestServer.ps1 -Port 80
    powershell -ExecutionPolicy Bypass -File LbTestServer.ps1 -Port 80 -BackendName "WEB-01"

  Endpoints:
    /            - branded status page (shows which backend served you)
    /api/info    - JSON with backend + client + headers (good for LB persistence tests)
    /health      - plain "OK" for loadbalancer.org health checks (also /healthz, /lb-check)

.NOTES
  If you get "Access is denied" on Start():
    netsh http add urlacl url=http://+:80/ user=Everyone
  Or just run PowerShell as Administrator.
#>
param(
  [int]$Port = 80,
  [string]$BackendName = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"
$StartTime = Get-Date

if ([string]::IsNullOrWhiteSpace($BackendName)) { $BackendName = $env:COMPUTERNAME }
if ([string]::IsNullOrWhiteSpace($BackendName)) { $BackendName = "WIN-SERVER" }
$BackendName = $BackendName.Trim()

# ---- Backend color (stable per backend name, so you can SEE round-robin) ----
$Palette = @("#0B5FFF", "#007A33", "#D7263D", "#7B2CBF", "#EA6A00", "#00838F", "#5D4037", "#1565C0")
$hash = 0
foreach ($c in $BackendName.ToCharArray()) { $hash += [int]$c }
$BackendColor = $Palette[$hash % $Palette.Count]

function Get-LocalIps {
  try {
    $ips = @()
    $addrs = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())
    foreach ($a in $addrs) {
      if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $ips += $a.IPAddressToString
      }
    }
    if ($ips.Count -eq 0) { $ips += "127.0.0.1" }
    return ($ips -join ", ")
  } catch { return "unknown" }
}
$LocalIps = Get-LocalIps

function HtmlEncode([string]$s) {
  if ($null -eq $s) { return "" }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

function Write-Response($ctx, [string]$body, [string]$contentType = "text/html; charset=utf-8", [int]$status = 200) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = $contentType
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.OutputStream.Close()
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://+:$Port/"
$listener.Prefixes.Add($prefix)

try {
  $listener.Start()
} catch {
  Write-Host ""
  Write-Host "FAILED to listen on $prefix" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host ""
  Write-Host "Fix (run as Administrator once):" -ForegroundColor Yellow
  Write-Host "  netsh http add urlacl url=http://+:$Port/ user=Everyone" -ForegroundColor Yellow
  Write-Host "Then re-run this script as Administrator." -ForegroundColor Yellow
  exit 1
}

$script:RequestCount = 0

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " SmartData Technologies Limited - LB Test Server" -ForegroundColor Cyan
Write-Host " Head Office: 2nd Floor, Rahman Mansion, 161 Motijheel C/A, Dhaka 1000" -ForegroundColor Gray
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " Backend : $BackendName ($BackendColor)" -ForegroundColor Green
Write-Host " LocalIP : $LocalIps" -ForegroundColor Green
Write-Host " Listen  : http://0.0.0.0:$Port/  (health: /health)" -ForegroundColor Green
Write-Host " Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

# Open firewall (best effort, needs admin)
try {
  $ruleName = "LB-Test-Server-$Port"
  $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if (-not $existing) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Firewall: opened inbound TCP $Port" -ForegroundColor Gray
  }
} catch { }

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
  } catch { break }

  $script:RequestCount++
  $req = $ctx.Request
  $path = $req.Url.AbsolutePath
  $method = $req.HttpMethod
  $clientIp = $ctx.Request.RemoteEndPoint.Address.ToString()
  $xff = $req.Headers["X-Forwarded-For"]
  if ([string]::IsNullOrWhiteSpace($xff)) { $xff = "-" }
  $nowUtc = (Get-Date).ToUniversalTime()
  $nowDhaka = $nowUtc.AddHours(6)
  $uptime = [int]((Get-Date) - $StartTime).TotalSeconds
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

  Write-Host "[$ts] #$($script:RequestCount) $method $path from $clientIp XFF=$xff -> $BackendName"

  # ---- Health checks (loadbalancer.org VIP health check target) ----
  if ($path -eq "/health" -or $path -eq "/healthz" -or $path -eq "/lb-check" -or $path -eq "/ping") {
    Write-Response $ctx "OK - $BackendName #$($script:RequestCount)" "text/plain; charset=utf-8" 200
    continue
  }
  if ($path -eq "/favicon.ico") {
    $ctx.Response.StatusCode = 204
    $ctx.Response.OutputStream.Close()
    continue
  }

  # ---- Collect headers ----
  $headersHtml = ""
  $headersObj = @{}
  foreach ($k in $req.Headers.AllKeys) {
    $v = $req.Headers[$k]
    $headersObj[$k] = $v
    $headersHtml += "<tr><td><code>$(HtmlEncode $k)</code></td><td>$(HtmlEncode $v)</td></tr>`n"
  }
  $hostHdr = $req.Headers["Host"]
  if ([string]::IsNullOrWhiteSpace($hostHdr)) { $hostHdr = "-" }
  $realIp = $req.Headers["X-Real-IP"]
  if ([string]::IsNullOrWhiteSpace($realIp)) { $realIp = "-" }
  $fwdProto = $req.Headers["X-Forwarded-Proto"]
  if ([string]::IsNullOrWhiteSpace($fwdProto)) { $fwdProto = "-" }
  $ua = $req.UserAgent
  if ([string]::IsNullOrWhiteSpace($ua)) { $ua = "-" }

  # ---- JSON endpoint ----
  if ($path -eq "/api/info" -or $path -eq "/api" -or $path -eq "/json") {
    $obj = [ordered]@{
      backend       = $BackendName
      hostname      = [System.Net.Dns]::GetHostName()
      localIps      = $LocalIps
      port          = $Port
      requestCount  = $script:RequestCount
      uptimeSeconds = $uptime
      timestampUtc  = $nowUtc.ToString("o")
      timestampDhaka= $nowDhaka.ToString("yyyy-MM-dd HH:mm:ss") + " +06:00 (Asia/Dhaka)"
      clientIp      = $clientIp
      xForwardedFor = $xff
      xRealIp       = $realIp
      xForwardedProto = $fwdProto
      hostHeader    = $hostHdr
      method        = $method
      path          = $req.Url.PathAndQuery
      userAgent     = $ua
      headers       = $headersObj
    }
    $json = ($obj | ConvertTo-Json -Depth 5)
    Write-Response $ctx $json "application/json; charset=utf-8" 200
    continue
  }

  # ---- Main page ----
  if ($path -eq "/" -or $path -eq "/index.html" -or $path -eq "/status") {
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="10">
<title>$([System.Net.WebUtility]::HtmlEncode($BackendName)) - SmartData LB Test</title>
<style>
*{box-sizing:border-box}body{font-family:'Segoe UI',Arial,sans-serif;margin:0;background:#f1f3f6;color:#1a1a1a}
.top{background:#0b1c33;color:#fff;padding:14px 22px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap}
.top b{font-size:18px}.top small{opacity:.8}
.wrap{max-width:980px;margin:22px auto;padding:0 16px}
.backend{background:$BackendColor;color:#fff;border-radius:12px;padding:26px;text-align:center;box-shadow:0 4px 14px rgba(0,0,0,.18)}
.backend h1{margin:0;font-size:44px;letter-spacing:1px}
.backend p{margin:6px 0;font-size:17px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:14px}
@media(max-width:700px){.grid{grid-template-columns:1fr}}
.card{background:#fff;border-radius:10px;padding:16px 18px;box-shadow:0 2px 8px rgba(0,0,0,.08)}
.card h2{margin:0 0 10px;font-size:16px;text-transform:uppercase;color:#555;letter-spacing:.5px}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:6px 8px;border-bottom:1px solid #eee;word-break:break-all}
td:first-child{color:#555;white-space:nowrap;width:170px}
code{background:#eef1f5;padding:2px 6px;border-radius:4px;font-size:13px}
.btns{margin-top:14px;display:flex;gap:10px;flex-wrap:wrap}
a.btn{display:inline-block;background:#0b1c33;color:#fff;text-decoration:none;padding:9px 16px;border-radius:6px;font-size:14px}
a.btn.light{background:#fff;color:#0b1c33;border:1px solid #0b1c33}
.footer{text-align:center;color:#777;font-size:13px;margin:22px 0 30px;line-height:1.6}
.big{font-size:15px;background:rgba(255,255,255,.18);display:inline-block;padding:6px 14px;border-radius:20px;margin-top:10px}
</style>
</head>
<body>
<div class="top"><div><b>SmartData Technologies Limited</b><br><small>161 Motijheel C/A, Dhaka 1000 &bull; +880 2-57160986 &bull; LB Test Node</small></div><div><small>Asia/Dhaka: $(HtmlEncode $nowDhaka.ToString("yyyy-MM-dd HH:mm:ss"))</small></div></div>
<div class="wrap">
<div class="backend">
<div style="font-size:13px;opacity:.9;letter-spacing:2px">YOU WERE SERVED BY</div>
<h1>$(HtmlEncode $BackendName)</h1>
<p><code style="background:rgba(255,255,255,.2);color:#fff">$LocalIps : $Port</code></p>
<div class="big">Request #$($script:RequestCount) &bull; Uptime ${uptime}s &bull; $method $(HtmlEncode $req.Url.PathAndQuery)</div>
</div>
<div class="grid">
<div class="card"><h2>Client (as seen by backend)</h2><table>
<tr><td>Remote IP</td><td><b>$(HtmlEncode $clientIp)</b></td></tr>
<tr><td>X-Forwarded-For</td><td><b>$(HtmlEncode $xff)</b></td></tr>
<tr><td>X-Real-IP</td><td>$(HtmlEncode $realIp)</td></tr>
<tr><td>X-Forwarded-Proto</td><td>$(HtmlEncode $fwdProto)</td></tr>
<tr><td>Host header</td><td>$(HtmlEncode $hostHdr)</td></tr>
<tr><td>User-Agent</td><td>$(HtmlEncode $ua)</td></tr>
</table></div>
<div class="card"><h2>Backend</h2><table>
<tr><td>Backend name</td><td><b>$(HtmlEncode $BackendName)</b></td></tr>
<tr><td>Hostname</td><td>$(HtmlEncode ([System.Net.Dns]::GetHostName()))</td></tr>
<tr><td>Local IPs</td><td>$(HtmlEncode $LocalIps)</td></tr>
<tr><td>Port</td><td>$Port</td></tr>
<tr><td>Time (Dhaka)</td><td>$(HtmlEncode $nowDhaka.ToString("yyyy-MM-dd HH:mm:ss")) +06:00</td></tr>
<tr><td>Time (UTC)</td><td>$(HtmlEncode $nowUtc.ToString("yyyy-MM-dd HH:mm:ss"))</td></tr>
</table></div>
</div>
<div class="card" style="margin-top:14px"><h2>All request headers</h2><table>$headersHtml</table>
<div class="btns"><a class="btn" href="/api/info">View JSON</a><a class="btn light" href="/health">Health check</a><a class="btn light" href="/">Refresh now</a></div>
<p style="font-size:13px;color:#666">LB test tip: hit the loadbalancer.org VIP repeatedly — the big backend name above should rotate across your real servers (round-robin). If it sticks to one, persistence/sticky is on. Check <code>X-Forwarded-For</code> shows the real client IP through the LB.</p>
</div>
</div>
<div class="footer">SmartData Technologies Limited &bull; Head Office: 2nd Floor, Rahman Mansion, 161 Motijheel C/A, Dhaka 1000 &bull; info@smartdataltd.com<br>Loadbalancer.org backend test page — auto-refreshes every 10s</div>
</body>
</html>
"@
    Write-Response $ctx $html "text/html; charset=utf-8" 200
    continue
  }

  Write-Response $ctx "<h1>404</h1><p>Unknown path: $(HtmlEncode $path)</p><p><a href='/'>/</a> <a href='/api/info'>/api/info</a> <a href='/health'>/health</a></p>" "text/html; charset=utf-8" 404
}
