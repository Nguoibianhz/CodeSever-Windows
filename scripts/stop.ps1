Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$pidFile = Join-Path $repoRoot "runtime\pids.json"

function Stop-ManagedProcess {
  param(
    [int]$ProcessId,
    [string]$Label
  )

  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    Stop-Process -Id $process.Id -Force -ErrorAction Stop
    Write-Host "[INFO] Stopped $Label (PID $ProcessId)"
  } catch {
    Write-Host "[WARN] Could not stop $Label (PID $ProcessId): $($_.Exception.Message)"
  }
}

function Stop-OrphanByPort {
  param(
    [int]$Port,
    [string]$Label
  )

  $listeners = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
  if ($null -eq $listeners) {
    return
  }

  $pids = $listeners | Select-Object -ExpandProperty OwningProcess -Unique
  foreach ($pidValue in $pids) {
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if ($null -eq $processInfo) {
      continue
    }

    $commandLine = [string]$processInfo.CommandLine
    $exePath = [string]$processInfo.ExecutablePath
    $belongsToStack = $commandLine.Contains($repoRoot) -or $exePath.Contains($repoRoot)
    if (-not $belongsToStack) {
      continue
    }

    Stop-ManagedProcess -ProcessId ([int]$pidValue) -Label "$Label orphan"
  }
}

$stoppedAny = $false
if (Test-Path -Path $pidFile) {
  $content = Get-Content -Path $pidFile -Raw
  if (-not [string]::IsNullOrWhiteSpace($content)) {
    $pidMap = $content | ConvertFrom-Json
    $keys = @("code_server", "jwt_proxy", "cloudflared")

    foreach ($key in $keys) {
      $procId = $pidMap.$key
      if ($null -eq $procId) {
        continue
      }
      Stop-ManagedProcess -ProcessId ([int]$procId) -Label $key
      $stoppedAny = $true
    }
  }

  Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
}

$envPath = Join-Path $repoRoot ".env"
$codeServerPort = 8080
$proxyPort = 8443
if (Test-Path -Path $envPath) {
  foreach ($line in (Get-Content -Path $envPath)) {
    if ($line -match "^\s*CODE_SERVER_PORT\s*=\s*(\d+)\s*$") {
      $codeServerPort = [int]$matches[1]
    }
    if ($line -match "^\s*PROXY_PORT\s*=\s*(\d+)\s*$") {
      $proxyPort = [int]$matches[1]
    }
  }
}

Stop-OrphanByPort -Port $codeServerPort -Label "code_server"
Stop-OrphanByPort -Port $proxyPort -Label "jwt_proxy"

$cloudflaredExe = Join-Path $repoRoot "bin\cloudflared.exe"
$cloudflaredProcs = Get-Process cloudflared -ErrorAction SilentlyContinue
foreach ($proc in $cloudflaredProcs) {
  if (-not [string]::IsNullOrWhiteSpace($proc.Path) -and $proc.Path -ieq $cloudflaredExe) {
    Stop-ManagedProcess -ProcessId $proc.Id -Label "cloudflared orphan"
  }
}

Write-Host "[INFO] Stop completed."
