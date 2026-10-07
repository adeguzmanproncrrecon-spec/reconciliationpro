# Local web server para sa ReconciliationPro (para sa development/testing).
# Kailangan ito dahil hindi gumagana ang Excel export (template fetch at Web Worker) kapag binuksan ang page bilang file://.
#   powershell -ExecutionPolicy Bypass -File tools\serve.ps1            → http://localhost:8080/login.html
#   powershell -ExecutionPolicy Bypass -File tools\serve.ps1 -Port 8090
# Localhost lang (hindi maa-access ng ibang computer). Mga page at js/css/img/templates lang ang ibinibigay
# (hindi ang .env, docs, supabase, tools, o anumang dotfile).
param([int]$Port = 8080)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$types = @{
  '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
  '.json' = 'application/json'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.svg' = 'image/svg+xml'
  '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'; '.pdf' = 'application/pdf'
  '.xlsx' = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
}

$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
try { $l.Start() } catch { Write-Host "Hindi mabuksan ang port $Port (baka may gumagamit na). Subukan: -Port 8090" -ForegroundColor Red; exit 1 }
Write-Host "ReconciliationPro: http://localhost:$Port/login.html" -ForegroundColor Green
Write-Host "Pindutin ang Ctrl+C para itigil."
try { Start-Process "http://localhost:$Port/login.html" } catch {}

while ($l.IsListening) {
  $c = $l.GetContext()
  try {
    $p = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath)
    if ($p -eq '/') { $p = '/login.html' }
    # Allowlist: mga HTML page sa root, at js/, css/, img/, templates/ lang
    $ok = $p -match '^/[A-Za-z0-9_-]+\.html$' -or $p -match '^/(js|css|img|templates)/[A-Za-z0-9_./-]+$'
    $bad = -not $ok -or $p -match '(^|/)\.' -or $p -match '\.\.'
    $f = Join-Path $Root ($p.TrimStart('/') -replace '/', '\')
    if (-not $bad -and (Test-Path -LiteralPath $f -PathType Leaf)) {
      $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
      try {
        $c.Response.ContentType = $types[[IO.Path]::GetExtension($f).ToLower()]
        $c.Response.Headers.Add('Cache-Control', 'no-cache')
        $c.Response.ContentLength64 = $fs.Length
        $fs.CopyTo($c.Response.OutputStream)
      } finally { $fs.Dispose() }
    } else {
      $c.Response.StatusCode = 404
    }
  } catch {
    try { $c.Response.StatusCode = 500 } catch {}
  } finally {
    $c.Response.Close()
  }
}
