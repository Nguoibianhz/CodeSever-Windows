param(
  [switch]$SkipWebhook,
  [switch]$SkipTunnel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repoRoot

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO] $Message"
}

function Write-Warn {
  param([string]$Message)
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
  param([string]$Message)
  Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -Path $Path)) {
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
  }
}

function Expand-BinaryPartsToZip {
  param(
    [string[]]$PartFiles,
    [string]$OutputZip
  )

  Ensure-Directory -Path (Split-Path -Path $OutputZip -Parent)
  $outStream = [System.IO.File]::Open($OutputZip, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
  try {
    foreach ($part in $PartFiles) {
      $inStream = [System.IO.File]::OpenRead($part)
      try {
        $inStream.CopyTo($outStream)
      } finally {
        $inStream.Dispose()
      }
    }
  } finally {
    $outStream.Dispose()
  }
}

function Ensure-OfflineBundleExtracted {
  param(
    [string]$RepoRoot,
    [string]$RuntimeDir,
    [string]$BinDir,
    [string]$ProxyDir
  )

  $offlineDir = Join-Path $RepoRoot "offline"
  if (-not (Test-Path -Path $offlineDir)) {
    return
  }

  $binPartPattern = Join-Path $offlineDir "bin-pack.zip.part*"
  $binParts = Get-ChildItem -Path $binPartPattern -File -ErrorAction SilentlyContinue | Sort-Object Name
  if (-not (Test-Path -Path $BinDir) -and $binParts.Count -gt 0) {
    $tempZip = Join-Path $RuntimeDir "bin-pack.offline.zip"
    Write-Info "Extracting offline binary bundle from repo package."
    Expand-BinaryPartsToZip -PartFiles ($binParts.FullName) -OutputZip $tempZip
    Expand-Archive -Path $tempZip -DestinationPath $RepoRoot -Force
  }

  $proxyNodeModules = Join-Path $ProxyDir "node_modules"
  $proxyZip = Join-Path $offlineDir "proxy-node_modules.zip"
  if (-not (Test-Path -Path $proxyNodeModules) -and (Test-Path -Path $proxyZip)) {
    Write-Info "Extracting offline proxy dependencies."
    Expand-Archive -Path $proxyZip -DestinationPath $ProxyDir -Force
  }
}

function Read-DotEnv {
  param([string]$Path)
  $result = @{}
  if (-not (Test-Path -Path $Path)) {
    return $result
  }

  Get-Content -Path $Path | ForEach-Object {
    $line = $_.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith("#")) {
      return
    }

    $parts = $line -split "=", 2
    if ($parts.Count -ne 2) {
      return
    }

    $key = $parts[0].Trim()
    $value = $parts[1].Trim()
    if ($key.Length -gt 0) {
      $result[$key] = $value
    }
  }

  return $result
}

function Download-File {
  param(
    [string]$Url,
    [string]$Destination
  )

  Ensure-Directory -Path (Split-Path -Path $Destination -Parent)
  Write-Info "Downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

function Wait-ForLocalPort {
  param(
    [int]$Port,
    [int]$TimeoutSeconds
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $client = $null
    try {
      $client = [System.Net.Sockets.TcpClient]::new()
      $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
      $ok = $async.AsyncWaitHandle.WaitOne(1000, $false)
      if ($ok -and $client.Connected) {
        $client.EndConnect($async) | Out-Null
        $client.Dispose()
        return $true
      }
    } catch {
      # Service is not ready yet.
    } finally {
      if ($null -ne $client) {
        $client.Dispose()
      }
    }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Get-ListeningProcessId {
  param([int]$Port)

  try {
    $connection = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $connection) {
      return [int]$connection.OwningProcess
    }
  } catch {
    return $null
  }

  return $null
}

function Ensure-Cloudflared {
  param([string]$BinDir)

  $cloudflaredExe = Join-Path $BinDir "cloudflared.exe"
  if (Test-Path -Path $cloudflaredExe) {
    return $cloudflaredExe
  }

  $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
  Download-File -Url $url -Destination $cloudflaredExe
  return $cloudflaredExe
}

function Ensure-Node {
  param(
    [string]$BinDir,
    [string]$DownloadsDir,
    [string]$RuntimeDir,
    [string]$NodeVersion
  )

  $forceLocalNode = ($env:FORCE_LOCAL_NODE -eq "1" -or $env:FORCE_LOCAL_NODE -eq "true")
  if (-not $forceLocalNode) {
    $systemNode = Get-Command node -ErrorAction SilentlyContinue
    $systemNpm = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -ne $systemNode -and $null -ne $systemNpm) {
      $npmExecutable = $systemNpm.Source
      $npmCmdCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
      if ($null -ne $npmCmdCommand -and -not [string]::IsNullOrWhiteSpace($npmCmdCommand.Source)) {
        $npmExecutable = $npmCmdCommand.Source
      } elseif ($npmExecutable.ToLowerInvariant().EndsWith(".ps1")) {
        $cmdCandidate = [System.IO.Path]::ChangeExtension($npmExecutable, ".cmd")
        if (Test-Path -Path $cmdCandidate) {
          $npmExecutable = $cmdCandidate
        }
      }

      Write-Info "Using system Node.js: $($systemNode.Source)"
      return @{
        NodeHome = (Split-Path -Path $systemNode.Source -Parent)
        NodeExe = $systemNode.Source
        NpmCmd = $npmExecutable
      }
    }
  }

  $nodeHome = Join-Path $BinDir "node"
  $nodeExe = Join-Path $nodeHome "node.exe"
  if (Test-Path -Path $nodeExe) {
    return @{
      NodeHome = $nodeHome
      NodeExe = $nodeExe
      NpmCmd = (Join-Path $nodeHome "npm.cmd")
    }
  }

  $zipName = "node-v$NodeVersion-win-x64.zip"
  $archivePath = Join-Path $DownloadsDir $zipName
  $url = "https://nodejs.org/dist/v$NodeVersion/$zipName"
  Download-File -Url $url -Destination $archivePath

  $extractDir = Join-Path $RuntimeDir "node-extract"
  if (Test-Path -Path $extractDir) {
    Remove-Item -Path $extractDir -Recurse -Force
  }
  Ensure-Directory -Path $extractDir

  Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
  $expandedFolder = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
  if ($null -eq $expandedFolder) {
    throw "Failed to extract Node.js from $archivePath"
  }

  if (Test-Path -Path $nodeHome) {
    Remove-Item -Path $nodeHome -Recurse -Force
  }
  Move-Item -Path $expandedFolder.FullName -Destination $nodeHome

  return @{
    NodeHome = $nodeHome
    NodeExe = (Join-Path $nodeHome "node.exe")
    NpmCmd = (Join-Path $nodeHome "npm.cmd")
  }
}

function Ensure-CodeServer {
  param(
    [string]$BinDir,
    [string]$DownloadsDir,
    [string]$NpmCmd
  )

  $targetDir = Join-Path $BinDir "code-server"
  $candidateCmd = Join-Path $targetDir "bin\code-server.cmd"
  $candidateExe = Join-Path $targetDir "code-server.exe"
  if ((Test-Path -Path $candidateCmd) -or (Test-Path -Path $candidateExe)) {
    $filePath = if (Test-Path -Path $candidateExe) { $candidateExe } else { $candidateCmd }
    return @{
      FilePath = $filePath
      WorkingDirectory = $repoRoot
      Source = "portable"
    }
  }

  $npmInstallDir = Join-Path $BinDir "code-server-npm"
  $npmCodeServerCmd = Join-Path $npmInstallDir "node_modules\.bin\code-server.cmd"
  if (Test-Path -Path $npmCodeServerCmd) {
    Ensure-CodeServerNpmDependencies -NpmCmd $NpmCmd -NpmInstallDir $npmInstallDir
    return @{
      FilePath = $npmCodeServerCmd
      WorkingDirectory = $npmInstallDir
      Source = "npm"
    }
  }

  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Warn "tar command not found. Will skip portable code-server archive extraction."
  } else {
    $releaseApi = "https://api.github.com/repos/coder/code-server/releases/latest"
    $headers = @{
      "User-Agent" = "windows-code-server-bootstrap"
      "Accept" = "application/vnd.github+json"
    }

    Write-Info "Resolving latest code-server release metadata."
    $release = Invoke-RestMethod -Method Get -Uri $releaseApi -Headers $headers
    $asset = $release.assets |
      Where-Object { $_.name -match "(win32-x64|windows-amd64).*(\.tar\.gz|\.zip)$" } |
      Select-Object -First 1

    if ($null -ne $asset) {
      $archivePath = Join-Path $DownloadsDir $asset.name
      Download-File -Url $asset.browser_download_url -Destination $archivePath

      if ($asset.name.EndsWith(".zip")) {
        Expand-Archive -Path $archivePath -DestinationPath $BinDir -Force
      } else {
        $null = & tar -xzf $archivePath -C $BinDir
        if ($LASTEXITCODE -ne 0) {
          throw "Failed to extract code-server archive."
        }
      }

      $expandedFolder = Get-ChildItem -Path $BinDir -Directory |
        Where-Object { $_.Name -match "^code-server-.*(win32-x64|windows-amd64)$" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

      if ($null -ne $expandedFolder) {
        if (Test-Path -Path $targetDir) {
          Remove-Item -Path $targetDir -Recurse -Force
        }
        Move-Item -Path $expandedFolder.FullName -Destination $targetDir

        $portableCmd = Join-Path $targetDir "bin\code-server.cmd"
        $portableExe = Join-Path $targetDir "code-server.exe"
        $filePath = if (Test-Path -Path $portableExe) { $portableExe } else { $portableCmd }
        if (Test-Path -Path $filePath) {
          return @{
            FilePath = $filePath
            WorkingDirectory = $repoRoot
            Source = "portable"
          }
        }
      }
    } else {
      Write-Warn "Latest release has no Windows portable asset. Falling back to npm package."
    }
  }

  $npmInstallDir = Join-Path $BinDir "code-server-npm"
  Ensure-Directory -Path $npmInstallDir

  $packageJsonPath = Join-Path $npmInstallDir "package.json"
  if (-not (Test-Path -Path $packageJsonPath)) {
    Set-Content -Path $packageJsonPath -Encoding ascii -Value @"
{
  "name": "local-code-server-runtime",
  "private": true
}
"@
  }

  $npmCodeServerCmd = Join-Path $npmInstallDir "node_modules\.bin\code-server.cmd"
  if (-not (Test-Path -Path $npmCodeServerCmd)) {
    Write-Info "Installing code-server from npm."
    $npmProcess = Start-Process `
      -FilePath $NpmCmd `
      -ArgumentList @("install", "code-server@latest", "--ignore-scripts", "--no-audit", "--no-fund") `
      -WorkingDirectory $npmInstallDir `
      -NoNewWindow `
      -PassThru `
      -Wait

    if ($npmProcess.ExitCode -ne 0) {
      throw "Failed to install code-server from npm (exit code $($npmProcess.ExitCode))."
    }
  }

  if (-not (Test-Path -Path $npmCodeServerCmd)) {
    throw "code-server was installed from npm, but launch command was not found."
  }

  Ensure-CodeServerNpmDependencies -NpmCmd $NpmCmd -NpmInstallDir $npmInstallDir

  return @{
    FilePath = $npmCodeServerCmd
    WorkingDirectory = $npmInstallDir
    Source = "npm"
  }
}

function Ensure-CodeServerNpmDependencies {
  param(
    [string]$NpmCmd,
    [string]$NpmInstallDir
  )

  $codeServerRoot = Join-Path $NpmInstallDir "node_modules\code-server"
  if (-not (Test-Path -Path $codeServerRoot)) {
    throw "code-server package directory is missing at $codeServerRoot"
  }

  $vscodeDir = Join-Path $codeServerRoot "lib\vscode"
  $extensionsDir = Join-Path $vscodeDir "extensions"
  $telemetryPkg = Join-Path $vscodeDir "node_modules\@microsoft\1ds-core-js"

  if (-not (Test-Path -Path $telemetryPkg)) {
    Write-Info "Bootstrapping VS Code server dependencies."
    $vscodeInstall = Start-Process `
      -FilePath $NpmCmd `
      -ArgumentList @("install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund") `
      -WorkingDirectory $vscodeDir `
      -NoNewWindow `
      -PassThru `
      -Wait
    if ($vscodeInstall.ExitCode -ne 0) {
      throw "Failed to install VS Code dependencies (exit code $($vscodeInstall.ExitCode))."
    }
  }

  $extensionsNodeModules = Join-Path $extensionsDir "node_modules"
  if (-not (Test-Path -Path $extensionsNodeModules)) {
    Write-Info "Bootstrapping VS Code extension dependencies."
    $extensionsInstall = Start-Process `
      -FilePath $NpmCmd `
      -ArgumentList @("install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund") `
      -WorkingDirectory $extensionsDir `
      -NoNewWindow `
      -PassThru `
      -Wait
    if ($extensionsInstall.ExitCode -ne 0) {
      throw "Failed to install VS Code extension dependencies (exit code $($extensionsInstall.ExitCode))."
    }
  }

  $asarPath = Join-Path $vscodeDir "node_modules.asar"
  $nodeModulesPath = Join-Path $vscodeDir "node_modules"
  if (-not (Test-Path -Path $asarPath)) {
    try {
      New-Item -Path $asarPath -ItemType Junction -Target $nodeModulesPath -Force | Out-Null
    } catch {
      Write-Warn "Could not create node_modules.asar junction: $($_.Exception.Message)"
    }
  }

  Ensure-CodeServerWindowsRegistryFallback -CodeServerRoot $codeServerRoot
}

function Ensure-CodeServerWindowsRegistryFallback {
  param([string]$CodeServerRoot)

  $registryFile = Join-Path $CodeServerRoot "lib\vscode\node_modules\@vscode\windows-registry\dist\index.js"
  if (Test-Path -Path $registryFile) {
    $content = Get-Content -Path $registryFile -Raw
    $original = "const windowRegistry = process.platform === 'win32' ? require('../build/Release/winregistry.node') : null;"
    $replacement = @"
let windowRegistry = null;
if (process.platform === 'win32') {
    try {
        windowRegistry = require('../build/Release/winregistry.node');
    }
    catch (_a) {
        windowRegistry = null;
    }
}
"@
    $updated = $false
    if ($content.Contains($original)) {
      $content = $content.Replace($original, $replacement.TrimEnd())
      $updated = $true
    }
    if ($content.Contains("throw new Error('GetStringRegKey is only available on Windows.');")) {
      $content = $content.Replace("throw new Error('GetStringRegKey is only available on Windows.');", "return undefined;")
      $updated = $true
    }
    if ($updated) {
      Set-Content -Path $registryFile -Value $content -Encoding ascii
      Write-Warn "Applied @vscode/windows-registry fallback patch."
    }
  }

  $deviceIdFile = Join-Path $CodeServerRoot "lib\vscode\node_modules\@vscode\deviceid\dist\storage.js"
  if (Test-Path -Path $deviceIdFile) {
    $content = Get-Content -Path $deviceIdFile -Raw
    $original = @"
const windowRegistry = process.platform === "win32"
    ? require("../build/Release/windows.node")
    : null;
"@
    $replacement = @"
let windowRegistry = null;
if (process.platform === "win32") {
    try {
        windowRegistry = require("../build/Release/windows.node");
    }
    catch (_a) {
        windowRegistry = null;
    }
}
"@
    if ($content.Contains($original.Trim())) {
      $patched = $content.Replace($original.Trim(), $replacement.TrimEnd())
      Set-Content -Path $deviceIdFile -Value $patched -Encoding ascii
      Write-Warn "Applied @vscode/deviceid fallback patch."
    }
  }

  $spdlogFile = Join-Path $CodeServerRoot "lib\vscode\node_modules\@vscode\spdlog\index.js"
  if (Test-Path -Path $spdlogFile) {
    $content = Get-Content -Path $spdlogFile -Raw
    if (-not $content.Contains("CODEX_SPDLOG_FALLBACK")) {
      $patched = @"
// CODEX_SPDLOG_FALLBACK
const path = require('path');
const mkdirp = require('mkdirp');

let spdlog = null;
try {
  spdlog = require('bindings')('spdlog');
} catch (_err) {
  spdlog = null;
}

class NoopLogger {
  trace() {}
  debug() {}
  info() {}
  warn() {}
  error() {}
  critical() {}
  flush() {}
  drop() {}
}

const backend = spdlog || {
  version: () => 'fallback',
  setLevel: () => {},
  setFlushOn: () => {},
  Logger: NoopLogger
};

exports.version = backend.version;
exports.setLevel = backend.setLevel;
exports.setFlushOn = backend.setFlushOn;
exports.Logger = backend.Logger;

function createRotatingLogger(name, filepath, maxFileSize, maxFiles) {
  return createLogger('rotating', name, filepath, maxFileSize, maxFiles);
}

function createAsyncRotatingLogger(name, filepath, maxFileSize, maxFiles) {
  return createLogger('rotating_async', name, filepath, maxFileSize, maxFiles);
}

async function createLogger(loggerType, name, filepath, maxFileSize, maxFiles) {
  const dirname = path.dirname(filepath);
  await mkdirp(dirname);
  if (!spdlog) {
    return new NoopLogger();
  }
  return new spdlog.Logger(loggerType, name, filepath, maxFileSize, maxFiles);
}

exports.createRotatingLogger = createRotatingLogger;
exports.createAsyncRotatingLogger = createAsyncRotatingLogger;
"@
      Set-Content -Path $spdlogFile -Value $patched -Encoding ascii
      Write-Warn "Applied @vscode/spdlog fallback patch."
    }
  }
}

function Ensure-ProxyDependencies {
  param(
    [string]$NpmCmd,
    [string]$ProxyDir
  )

  $httpProxyModule = Join-Path $ProxyDir "node_modules\http-proxy"
  $jwtModule = Join-Path $ProxyDir "node_modules\jsonwebtoken"
  if ((Test-Path -Path $httpProxyModule) -and (Test-Path -Path $jwtModule)) {
    return
  }

  Write-Info "Installing npm dependencies for JWT proxy."
  $npmProcess = Start-Process `
    -FilePath $NpmCmd `
    -ArgumentList @("install", "--no-audit", "--no-fund") `
    -WorkingDirectory $ProxyDir `
    -NoNewWindow `
    -PassThru `
    -Wait

  if ($npmProcess.ExitCode -ne 0) {
    throw "npm install failed with exit code $($npmProcess.ExitCode)"
  }
}

function Write-CodeServerConfig {
  param(
    [string]$Path,
    [int]$Port
  )

  Ensure-Directory -Path (Split-Path -Path $Path -Parent)
  $yaml = @"
bind-addr: 127.0.0.1:$Port
auth: none
cert: false
disable-telemetry: true
"@
  Set-Content -Path $Path -Value $yaml -Encoding ascii
}

function Start-LoggedProcess {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$WorkingDirectory,
    [string]$StdOutLog,
    [string]$StdErrLog
  )

  Set-Content -Path $StdOutLog -Value "" -Encoding ascii
  Set-Content -Path $StdErrLog -Value "" -Encoding ascii

  $launchPath = $FilePath
  $launchArgs = $ArgumentList
  $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
  if ($ext -eq ".cmd" -or $ext -eq ".bat") {
    $cmdLine = "`"$FilePath`""
    foreach ($arg in $ArgumentList) {
      if ($arg -match "[\s`"]") {
        $escaped = $arg.Replace('"', '\"')
        $cmdLine += " `"$escaped`""
      } else {
        $cmdLine += " $arg"
      }
    }
    $launchPath = "cmd.exe"
    $launchArgs = @("/c", $cmdLine)
  }

  Write-Info "Starting $Name"
  $process = Start-Process `
    -FilePath $launchPath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $WorkingDirectory `
    -RedirectStandardOutput $StdOutLog `
    -RedirectStandardError $StdErrLog `
    -WindowStyle Hidden `
    -PassThru

  if ($null -eq $process) {
    throw "Failed to start process: $Name"
  }
  return $process
}

function Save-PidMap {
  param(
    [string]$Path,
    [hashtable]$Map
  )
  $Map | ConvertTo-Json | Set-Content -Path $Path -Encoding ascii
}

$startedProcesses = @()
$tunnelUrl = ""
$cloudflaredPid = $null

try {
  $binDir = Join-Path $repoRoot "bin"
  $downloadsDir = Join-Path $repoRoot "downloads"
  $runtimeDir = Join-Path $repoRoot "runtime"
  $logsDir = Join-Path $repoRoot "logs"
  $proxyDir = Join-Path $repoRoot "proxy"
  $configDir = Join-Path $repoRoot "config\code-server"
  $storageRoot = Join-Path $repoRoot "storage\code-server"
  $userDataDir = Join-Path $storageRoot "user-data"
  $extensionsDir = Join-Path $storageRoot "extensions"
  $workspacesRoot = Join-Path $storageRoot "workspaces"
  $codeServerLogsDir = Join-Path $storageRoot "logs"
  $envPath = Join-Path $repoRoot ".env"
  $exampleEnvPath = Join-Path $repoRoot ".env.example"
  $pidFile = Join-Path $runtimeDir "pids.json"

  @(
    $binDir,
    $downloadsDir,
    $runtimeDir,
    $logsDir,
    $configDir,
    $storageRoot,
    $userDataDir,
    $extensionsDir,
    $workspacesRoot,
    $codeServerLogsDir
  ) | ForEach-Object { Ensure-Directory -Path $_ }

  Ensure-OfflineBundleExtracted -RepoRoot $repoRoot -RuntimeDir $runtimeDir -BinDir $binDir -ProxyDir $proxyDir

  if (-not (Test-Path -Path $envPath)) {
    if (Test-Path -Path $exampleEnvPath) {
      Copy-Item -Path $exampleEnvPath -Destination $envPath
      Write-Info "Created .env from .env.example"
    } else {
      throw "Missing .env and .env.example"
    }
  }

  $defaults = @{
    CODE_SERVER_PASSWORD = "HieuDz@999"
    JWT_SECRET = "HieuDz@999"
    TOKEN_TTL = "12h"
    CODE_SERVER_PORT = "8080"
    PROXY_PORT = "8443"
    WORKSPACE_DIR = "storage/code-server/workspaces"
    NODE_VERSION = "20.19.0"
    DISCORD_WEBHOOK_URL = "https://discord.com/api/webhooks/1478741648056909824/zKZXSMs3sXHVcFXfaDIOmIQQoVnuAZzXbXLz0liuhTVZQ2CAivtMHQRuFAl0HJH5vKDL"
  }
  $envMap = Read-DotEnv -Path $envPath
  foreach ($k in $defaults.Keys) {
    if (-not $envMap.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($envMap[$k])) {
      $envMap[$k] = $defaults[$k]
    }
  }

  [int]$codeServerPort = [int]$envMap.CODE_SERVER_PORT
  [int]$proxyPort = [int]$envMap.PROXY_PORT
  $workspaceDir = Join-Path $repoRoot $envMap.WORKSPACE_DIR
  Ensure-Directory -Path $workspaceDir

  $ownedCloudflaredPath = Join-Path $binDir "cloudflared.exe"
  $existingCloudflared = Get-Process cloudflared -ErrorAction SilentlyContinue
  foreach ($proc in $existingCloudflared) {
    if (-not [string]::IsNullOrWhiteSpace($proc.Path) -and $proc.Path -ieq $ownedCloudflaredPath) {
      try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        Write-Warn "Stopped stale cloudflared process (PID $($proc.Id))."
      } catch {
        Write-Warn "Could not stop stale cloudflared process (PID $($proc.Id)): $($_.Exception.Message)"
      }
    }
  }

  $codePortPid = Get-ListeningProcessId -Port $codeServerPort
  if ($null -ne $codePortPid) {
    throw "Port $codeServerPort is already in use by PID $codePortPid. Run stop.bat or free the port."
  }

  $proxyPortPid = Get-ListeningProcessId -Port $proxyPort
  if ($null -ne $proxyPortPid) {
    throw "Port $proxyPort is already in use by PID $proxyPortPid. Run stop.bat or free the port."
  }

  $codeServerConfigPath = Join-Path $configDir "config.yaml"
  Write-CodeServerConfig -Path $codeServerConfigPath -Port $codeServerPort

  $node = Ensure-Node -BinDir $binDir -DownloadsDir $downloadsDir -RuntimeDir $runtimeDir -NodeVersion $envMap.NODE_VERSION
  $cloudflaredExe = Ensure-Cloudflared -BinDir $binDir
  $codeServerRuntime = Ensure-CodeServer -BinDir $binDir -DownloadsDir $downloadsDir -NpmCmd $node.NpmCmd

  Ensure-ProxyDependencies -NpmCmd $node.NpmCmd -ProxyDir $proxyDir

  $codeServerFile = $codeServerRuntime.FilePath
  if (-not (Test-Path -Path $codeServerFile)) {
    throw "Could not locate code-server executable at $codeServerFile"
  }
  $codeServerWorkingDir = $codeServerRuntime.WorkingDirectory
  Write-Info "Using code-server source: $($codeServerRuntime.Source)"

  $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $codeStdOut = Join-Path $logsDir "code-server.out.$runStamp.log"
  $codeStdErr = Join-Path $logsDir "code-server.err.$runStamp.log"
  $proxyStdOut = Join-Path $logsDir "proxy.out.$runStamp.log"
  $proxyStdErr = Join-Path $logsDir "proxy.err.$runStamp.log"
  $cloudStdOut = Join-Path $logsDir "cloudflared.out.$runStamp.log"
  $cloudStdErr = Join-Path $logsDir "cloudflared.err.$runStamp.log"

  $codeServerArgs = @(
    "--bind-addr", "127.0.0.1:$codeServerPort",
    "--auth", "none",
    "--disable-telemetry",
    "--user-data-dir", $userDataDir,
    "--extensions-dir", $extensionsDir,
    "--config", $codeServerConfigPath,
    $workspaceDir
  )

  $codeServerProcess = Start-LoggedProcess `
    -Name "code-server" `
    -FilePath $codeServerFile `
    -ArgumentList $codeServerArgs `
    -WorkingDirectory $codeServerWorkingDir `
    -StdOutLog $codeStdOut `
    -StdErrLog $codeStdErr
  $startedProcesses += [PSCustomObject]@{ Name = "code-server"; Process = $codeServerProcess }

  if (-not (Wait-ForLocalPort -Port $codeServerPort -TimeoutSeconds 120)) {
    throw "code-server did not open port $codeServerPort. Check $codeStdErr"
  }
  Write-Info "code-server is listening on 127.0.0.1:$codeServerPort"

  $proxyScriptPath = Join-Path $proxyDir "server.js"
  $oldProxyPort = $env:PROXY_PORT
  $oldCodePort = $env:CODE_SERVER_PORT
  $oldTargetUrl = $env:TARGET_URL
  $oldJwtSecret = $env:JWT_SECRET
  $oldPassword = $env:CODE_SERVER_PASSWORD
  $oldTokenTtl = $env:TOKEN_TTL

  $env:PROXY_PORT = "$proxyPort"
  $env:CODE_SERVER_PORT = "$codeServerPort"
  $env:TARGET_URL = "http://127.0.0.1:$codeServerPort"
  $env:JWT_SECRET = "$($envMap.JWT_SECRET)"
  $env:CODE_SERVER_PASSWORD = "$($envMap.CODE_SERVER_PASSWORD)"
  $env:TOKEN_TTL = "$($envMap.TOKEN_TTL)"

  $proxyProcess = Start-LoggedProcess `
    -Name "jwt-proxy" `
    -FilePath $node.NodeExe `
    -ArgumentList @($proxyScriptPath) `
    -WorkingDirectory $proxyDir `
    -StdOutLog $proxyStdOut `
    -StdErrLog $proxyStdErr
  $startedProcesses += [PSCustomObject]@{ Name = "jwt-proxy"; Process = $proxyProcess }

  $env:PROXY_PORT = $oldProxyPort
  $env:CODE_SERVER_PORT = $oldCodePort
  $env:TARGET_URL = $oldTargetUrl
  $env:JWT_SECRET = $oldJwtSecret
  $env:CODE_SERVER_PASSWORD = $oldPassword
  $env:TOKEN_TTL = $oldTokenTtl

  if (-not (Wait-ForLocalPort -Port $proxyPort -TimeoutSeconds 60)) {
    throw "JWT proxy did not open port $proxyPort. Check $proxyStdErr"
  }
  Write-Info "JWT proxy is listening on 127.0.0.1:$proxyPort"

  if (-not $SkipTunnel) {
    $cloudArgs = @(
      "tunnel",
      "--no-autoupdate",
      "--url",
      "http://127.0.0.1:$proxyPort",
      "--loglevel",
      "info"
    )
    $cloudflaredProcess = Start-LoggedProcess `
      -Name "cloudflared" `
      -FilePath $cloudflaredExe `
      -ArgumentList $cloudArgs `
      -WorkingDirectory $repoRoot `
      -StdOutLog $cloudStdOut `
      -StdErrLog $cloudStdErr
    $cloudflaredPid = $cloudflaredProcess.Id
    $startedProcesses += [PSCustomObject]@{ Name = "cloudflared"; Process = $cloudflaredProcess }

    $waitScript = Join-Path $PSScriptRoot "wait-url.ps1"
    $tunnelUrl = & $waitScript -OutLogPath $cloudStdOut -ErrLogPath $cloudStdErr -TimeoutSeconds 120
    if ([string]::IsNullOrWhiteSpace($tunnelUrl)) {
      throw "cloudflared started but no tunnel URL found."
    }
    Write-Info "Tunnel URL: $tunnelUrl"

    if (-not $SkipWebhook -and -not [string]::IsNullOrWhiteSpace($envMap.DISCORD_WEBHOOK_URL)) {
      $webhookScript = Join-Path $PSScriptRoot "send-webhook.ps1"
      & $webhookScript `
        -WebhookUrl $envMap.DISCORD_WEBHOOK_URL `
        -TunnelUrl $tunnelUrl `
        -Status "success" `
        -Message "Code Server is online."
      Write-Info "Sent startup notification to Discord webhook."
    }
  } else {
    Write-Warn "Tunnel step skipped by -SkipTunnel."
  }

  Save-PidMap -Path $pidFile -Map @{
    code_server = $codeServerProcess.Id
    jwt_proxy = $proxyProcess.Id
    cloudflared = $cloudflaredPid
  }

  Write-Host ""
  Write-Info "System is running. Press Ctrl+C to stop."
  Write-Info "Local login page: http://127.0.0.1:$proxyPort/login"
  if (-not [string]::IsNullOrWhiteSpace($tunnelUrl)) {
    Write-Info "Public URL: $tunnelUrl"
  }

  while ($true) {
    foreach ($item in $startedProcesses) {
      $proc = $item.Process
      if ($proc.HasExited) {
        throw "$($item.Name) exited unexpectedly with code $($proc.ExitCode)."
      }
    }
    Start-Sleep -Seconds 3
  }
} catch {
  $message = $_.Exception.Message
  $isUserStop = $_.Exception -is [System.Management.Automation.PipelineStoppedException]
  if ($isUserStop) {
    Write-Warn "Shutdown requested by user."
    exit 0
  }

  Write-Fail $message
  $envMapSafe = $null
  try {
    $envMapSafe = Read-DotEnv -Path (Join-Path $repoRoot ".env")
  } catch {
    $envMapSafe = @{}
  }

  if (-not $SkipWebhook -and $null -ne $envMapSafe -and $envMapSafe.ContainsKey("DISCORD_WEBHOOK_URL") -and -not [string]::IsNullOrWhiteSpace($envMapSafe.DISCORD_WEBHOOK_URL)) {
    try {
      $webhookScript = Join-Path $PSScriptRoot "send-webhook.ps1"
      & $webhookScript -WebhookUrl $envMapSafe.DISCORD_WEBHOOK_URL -TunnelUrl $tunnelUrl -Status "error" -Message $message
    } catch {
      Write-Warn "Failed to send error webhook: $($_.Exception.Message)"
    }
  }
  exit 1
} finally {
  foreach ($item in $startedProcesses) {
    try {
      if ($null -ne $item.Process -and -not $item.Process.HasExited) {
        Stop-Process -Id $item.Process.Id -Force -ErrorAction Stop
      }
    } catch {
      Write-Warn "Could not stop $($item.Name): $($_.Exception.Message)"
    }
  }

  $pidPath = Join-Path $repoRoot "runtime\pids.json"
  if (Test-Path -Path $pidPath) {
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
  }
}
