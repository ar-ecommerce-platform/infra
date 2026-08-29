<#
  Runs the whole platform WITHOUT Docker: builds each bootJar, then launches
  each service in its own window with the right port and wiring.

    pwsh infra/scripts/run-local.ps1              # build + run everything
    pwsh infra/scripts/run-local.ps1 -SkipBuild   # just run (jars already built)
    pwsh infra/scripts/run-local.ps1 -Stop        # kill everything started here

  Requires JDK 21 on JAVA_HOME. Docker (docker-compose.yml) is the supported path;
  this is a convenience for debugging a single service against the rest.
#>
param(
  [switch]$SkipBuild,
  [switch]$Stop
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot/../.."
$pidFile = "$PSScriptRoot/.run-local.pids"

if ($Stop) {
  if (Test-Path $pidFile) {
    Get-Content $pidFile | ForEach-Object {
      try { Stop-Process -Id $_ -Force -ErrorAction Stop; Write-Host "stopped $_" } catch {}
    }
    Remove-Item $pidFile
  } else { Write-Host "nothing to stop" }
  return
}

# name -> port ; started in this order
$services = [ordered]@{
  "discovery-server"     = 8761
  "config-server"        = 8888
  "auth-service"         = 8081
  "user-service"         = 8087
  "product-service"      = 8083
  "inventory-service"    = 8084
  "payment-service"      = 8085
  "notification-service" = 8086
  "order-service"        = 8082
  "api-gateway"          = 8080
}

if (-not $SkipBuild) {
  foreach ($name in $services.Keys) {
    Write-Host "building $name ..." -ForegroundColor Cyan
    & "$root/$name/gradlew" -p "$root/$name" bootJar --no-daemon --console=plain | Out-Null
  }
}

$env:EUREKA_CLIENT_SERVICEURL_DEFAULTZONE = "http://localhost:8761/eureka/"
$env:CONFIG_REPO_LOCATIONS = "file:$root/config-repo,file:$root/config-repo/{application}"
if (-not $env:JWT_SECRET) { $env:JWT_SECRET = "dev-only-not-a-real-secret-change-me-0000000000000000" }

$pids = @()
foreach ($entry in $services.GetEnumerator()) {
  $name = $entry.Key; $port = $entry.Value
  $jar = Get-ChildItem "$root/$name/build/libs/*.jar" | Select-Object -First 1
  Write-Host "starting $name on $port" -ForegroundColor Green
  $p = Start-Process -PassThru -FilePath "java" `
    -ArgumentList "-jar", "`"$($jar.FullName)`"", "--server.port=$port"
  $pids += $p.Id
  Start-Sleep -Seconds ($(if ($name -eq "discovery-server" -or $name -eq "config-server") { 15 } else { 6 }))
}
$pids | Set-Content $pidFile
Write-Host "`nAll started. Stop with: pwsh infra/scripts/run-local.ps1 -Stop"
