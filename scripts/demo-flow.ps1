<#
  End-to-end demo of the platform through the API gateway.

    pwsh infra/scripts/demo-flow.ps1
    pwsh infra/scripts/demo-flow.ps1 -BaseUrl http://localhost:8080

  Assumes the stack is up (docker compose ... up -d) and healthy.
#>
param(
  [string]$BaseUrl = "http://localhost:8080"
)

$ErrorActionPreference = "Stop"
$email = "demo+$(Get-Random)@example.com"
$emailEnc = [uri]::EscapeDataString($email)
$password = "Passw0rd!"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Show($obj) { $obj | ConvertTo-Json -Depth 6 }

Step "Wait for the gateway to route (lb:// routes activate after the first Eureka fetch)"
$ready = $false
foreach ($i in 1..40) {
  try {
    Invoke-RestMethod -Method Post "$BaseUrl/api/auth/register" -ContentType application/json `
      -Body (@{ email = "probe-$i@example.com"; password = "Passw0rd!" } | ConvertTo-Json) `
      -ErrorAction Stop | Out-Null
    $ready = $true; break                      # 201 -> routed + permitAll working
  } catch {
    $sc = $_.Exception.Response.StatusCode.value__
    if ($sc -eq 409) { $ready = $true; break } # route works, email already taken
    Start-Sleep -Seconds 2                     # 401/404/503 -> gateway still warming
  }
}
if (-not $ready) { throw "gateway not routing to auth-service after 80s" }
Write-Host "gateway ready"

Step "Register $email"
Invoke-RestMethod -Method Post "$BaseUrl/api/auth/register" `
  -ContentType application/json `
  -Body (@{ email = $email; password = $password } | ConvertTo-Json) | Out-Null
Write-Host "registered"

Step "Login"
$login = Invoke-RestMethod -Method Post "$BaseUrl/api/auth/login" `
  -ContentType application/json `
  -Body (@{ email = $email; password = $password } | ConvertTo-Json)
$token = $login.token
$auth = @{ Authorization = "Bearer $token" }
Write-Host "token acquired ($($token.Substring(0,16))...)"

Step "Browse products"
$products = Invoke-RestMethod "$BaseUrl/api/products" -Headers $auth
Show $products
$p1 = $products[0].id
$p2 = $products[1].id

Step "Check inventory for product $p1"
Show (Invoke-RestMethod "$BaseUrl/api/inventory/$p1" -Headers $auth)

Step "Place order (2x $p1, 1x $p2)"
$order = Invoke-RestMethod -Method Post "$BaseUrl/api/orders" -Headers $auth `
  -ContentType application/json `
  -Body (@{
      userId = $email
      items  = @(
        @{ productId = $p1; quantity = 2 },
        @{ productId = $p2; quantity = 1 }
      )
    } | ConvertTo-Json)
Show $order
if ($order.status -ne "CONFIRMED") { throw "expected CONFIRMED, got $($order.status)" }

Step "Payment record $($order.paymentId)"
Show (Invoke-RestMethod "$BaseUrl/api/payments/$($order.paymentId)" -Headers $auth)

Step "Notifications for $email"
Show (Invoke-RestMethod "$BaseUrl/api/notifications?userId=$emailEnc" -Headers $auth)

Step "Orders for $email"
Show (Invoke-RestMethod "$BaseUrl/api/orders?userId=$emailEnc" -Headers $auth)

Step "Failure path: unauthenticated order -> 401"
try {
  Invoke-RestMethod -Method Post "$BaseUrl/api/orders" -ContentType application/json `
    -Body (@{ userId = $email; items = @(@{ productId = $p1; quantity = 1 }) } | ConvertTo-Json) | Out-Null
  throw "expected 401"
} catch { Write-Host "got $($_.Exception.Response.StatusCode.value__) as expected" }

Step "Failure path: over-stock order -> 409 REJECTED_STOCK"
try {
  Invoke-RestMethod -Method Post "$BaseUrl/api/orders" -Headers $auth -ContentType application/json `
    -Body (@{ userId = $email; items = @(@{ productId = 5; quantity = 9999 }) } | ConvertTo-Json) | Out-Null
  throw "expected 409"
} catch { Write-Host "got $($_.Exception.Response.StatusCode.value__) as expected" }

Step "Failure path: expensive order over the payment ceiling -> 402 PAYMENT_FAILED"
try {
  Invoke-RestMethod -Method Post "$BaseUrl/api/orders" -Headers $auth -ContentType application/json `
    -Body (@{ userId = $email; items = @(@{ productId = $p1; quantity = 5 }) } | ConvertTo-Json) | Out-Null
  throw "expected 402"
} catch { Write-Host "got $($_.Exception.Response.StatusCode.value__) as expected" }

Write-Host "`nAll demo steps passed." -ForegroundColor Green
