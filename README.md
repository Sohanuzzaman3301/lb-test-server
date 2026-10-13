# LB Test Server — SmartData Technologies Limited (Motijheel, Dhaka)
Zero-dependency HTTP server for testing loadbalancer.org balancers.
Runs on any Windows Server with built-in PowerShell 5.1. No Python, no IIS, no installs.

## Files
- `LbTestServer.ps1` — the server (main file, copy this to each backend)
- `Run-Server.bat` — double-click launcher

## 1. Deploy (do this on EACH backend web server)

1. Copy `LbTestServer.ps1` to the server, e.g. `C:\LBTest\`
2. Open PowerShell **as Administrator**:
```powershell
# Allow script + open firewall + URL reservation (one-time)
Set-ExecutionPolicy Bypass -Scope Process -Force
netsh http add urlacl url=http://+:8080/ user=Everyone
New-NetFirewallRule -DisplayName "LB-Test-8080" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8080
```
3. Start it (different BackendName per server so you can tell them apart):
```powershell
# Server 1:
powershell -ExecutionPolicy Bypass -File C:\LBTest\LbTestServer.ps1 -Port 8080 -BackendName "WEB-01"
# Server 2:
powershell -ExecutionPolicy Bypass -File C:\LBTest\LbTestServer.ps1 -Port 8080 -BackendName "WEB-02"
```
Or just double-click `Run-Server.bat` (then edit BackendName inside if needed).

Verify locally on each backend:
```
http://localhost:8080/          -> big colored backend name page
http://localhost:8080/api/info  -> JSON
http://localhost:8080/health    -> OK
```

## 2. loadbalancer.org config
- **VIP:** e.g. `http://192.168.1.100/` -> pool = `backend1:8080`, `backend2:8080`
- **Health check:** HTTP GET `/health`, expect `200` + body contains `OK`
  - Layer7: set Check URL = `/health`, Check Port = `8080`
  - Layer4 DR/TUN/NAT: health check still works, but X-Forwarded-For will be `-` (expected — L4 preserves source IP, check Remote IP instead)
- **Forwarding:** For L7 SNAT/proxy mode, enable `X-Forwarded-For` insertion so the test page shows real client IP.

## 3. Test plan
1. `curl http://VIP/` repeatedly — backend name should rotate (round-robin).
   ```powershell
   1..10 | % { (Invoke-WebRequest http://VIP/api/info | ConvertFrom-Json).backend }
   ```
2. **Persistence check:** same client hitting VIP 10x — if it sticks to WEB-01, sticky/persistence is ON.
3. **X-Forwarded-For:** compare `Remote IP` vs `X-Forwarded-For` on the page. Through L7 LB, XFF = your PC IP, Remote = LB IP. Through L4, Remote = your PC IP.
4. **Failover:** stop server on WEB-01 (Ctrl+C), refresh VIP — should stick to WEB-02 only.
5. **Health:** `curl http://VIP/health` must always return `OK`.

## 4. Dhaka time / branding
Page shows Asia/Dhaka time (UTC+6), backend color is stable per BackendName, footer shows Motijheel head office.

Company: SmartData Technologies Limited, 2nd Floor, Rahman Mansion, 161 Motijheel C/A, Dhaka 1000, +880 2-57160986, info@smartdataltd.com

## 5. Run as service (optional)
For overnight soak tests, use NSSM or Task Scheduler to run the .ps1 on boot. Or keep the PowerShell window open.

## Troubleshooting
- `Access is denied` on start -> run as Admin, or `netsh http add urlacl url=http://+:8080/ user=Everyone`
- Page loads locally but not via VIP -> firewall on backend blocking 8080, or LB pool port wrong
- Port in use -> change `-Port 8081`
