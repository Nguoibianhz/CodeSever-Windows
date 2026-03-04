param(
  [Parameter(Mandatory = $true)][string]$OutLogPath,
  [Parameter(Mandatory = $true)][string]$ErrLogPath,
  [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$pattern = "https://[a-z0-9-]+\.trycloudflare\.com"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

while ((Get-Date) -lt $deadline) {
  $combined = ""
  foreach ($path in @($OutLogPath, $ErrLogPath)) {
    if (Test-Path -Path $path) {
      $content = Get-Content -Path $path -Raw -ErrorAction SilentlyContinue
      if ($null -ne $content) {
        $combined += "`n$content"
      }
    }
  }

  if ($combined -match $pattern) {
    Write-Output $matches[0]
    exit 0
  }

  Start-Sleep -Seconds 2
}

throw "Timed out waiting for cloudflared tunnel URL after $TimeoutSeconds seconds."
