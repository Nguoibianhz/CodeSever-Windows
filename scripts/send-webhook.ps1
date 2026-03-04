param(
  [Parameter(Mandatory = $true)][string]$WebhookUrl,
  [string]$TunnelUrl = "",
  [ValidateSet("success", "error")][string]$Status = "success",
  [string]$Message = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
  return
}

$emoji = if ($Status -eq "success") { "[OK]" } else { "[ERROR]" }
$title = if ($Status -eq "success") { "Code Server Started" } else { "Code Server Failed" }
$description = if ([string]::IsNullOrWhiteSpace($Message)) {
  if ($Status -eq "success") { "Tunnel is live." } else { "Startup failed." }
} else {
  $Message
}

$contentParts = @("$emoji $title")
if (-not [string]::IsNullOrWhiteSpace($TunnelUrl)) {
  $contentParts += "URL: $TunnelUrl"
}

$payload = @{
  username = "CodeServer Bot"
  content = ($contentParts -join "`n")
  embeds = @(
    @{
      title = $title
      description = $description
      color = if ($Status -eq "success") { 5763719 } else { 15548997 }
      timestamp = (Get-Date).ToUniversalTime().ToString("o")
      fields = @(
        @{
          name = "Tunnel URL"
          value = if ([string]::IsNullOrWhiteSpace($TunnelUrl)) { "N/A" } else { $TunnelUrl }
          inline = $false
        }
      )
    }
  )
}

Invoke-RestMethod `
  -Method Post `
  -Uri $WebhookUrl `
  -ContentType "application/json" `
  -Body ($payload | ConvertTo-Json -Depth 6) | Out-Null
