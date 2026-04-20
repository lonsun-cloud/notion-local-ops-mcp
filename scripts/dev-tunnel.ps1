#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Help)

$ErrorActionPreference = 'Stop'

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $RootDir

function Show-Usage {
@'
Usage: .\scripts\dev-tunnel.ps1 [-Help]

Starts the local MCP server and exposes it with cloudflared.

Environment loading order:
1. Current shell environment (wins)
2. .env in the repository root

Required:
- NOTION_LOCAL_OPS_AUTH_TOKEN

Optional:
- NOTION_LOCAL_OPS_WORKSPACE_ROOT (defaults to repo root)
- NOTION_LOCAL_OPS_HOST (defaults to 127.0.0.1)
- NOTION_LOCAL_OPS_PORT (defaults to 8766)
- NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG (named tunnel config path)
- NOTION_LOCAL_OPS_TUNNEL_NAME (optional override for cloudflared tunnel run)
- NOTION_LOCAL_OPS_VENV_PATH (skip venv prompt; use this path directly)

If .\cloudflared.local.yml or .\cloudflared.local.yaml exists, this script
uses that named tunnel config automatically. Otherwise it falls back to a
cloudflared quick tunnel.
'@
}

if ($Help) { Show-Usage; exit 0 }

function Require-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "Missing required command: $Name"
        exit 1
    }
}

function Pick-Python {
    $candidates = @()
    if ($env:PYTHON_BIN) { $candidates += ,@{ Cmd = $env:PYTHON_BIN; Args = @() } }
    $candidates += ,@{ Cmd = 'python3.11'; Args = @() }
    $candidates += ,@{ Cmd = 'python3';    Args = @() }
    $candidates += ,@{ Cmd = 'py';         Args = @('-3.11') }
    $candidates += ,@{ Cmd = 'py';         Args = @('-3') }
    $candidates += ,@{ Cmd = 'python';     Args = @() }

    foreach ($c in $candidates) {
        if (-not (Get-Command $c.Cmd -ErrorAction SilentlyContinue)) { continue }
        try {
            $exe = & $c.Cmd @($c.Args) -c "import sys; sys.stdout.write(sys.executable)" 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $exe) { continue }
            $ver = & $exe -c "import sys; sys.stdout.write('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            $parts = $ver.Split('.')
            if ([int]$parts[0] -gt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 11)) {
                return $exe.Trim()
            }
        } catch { }
    }
    Write-Error "Python 3.11+ is required but no suitable interpreter was found."
    exit 1
}

function Load-EnvFile {
    $envPath = Join-Path $RootDir '.env'
    if (-not (Test-Path $envPath)) { return }
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $trim.Substring(0, $idx).Trim()
        $val = $trim.Substring($idx + 1).Trim()
        if ($val.Length -ge 2 -and
            (($val.StartsWith('"') -and $val.EndsWith('"')) -or
             ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        # current shell env wins over .env values
        if (-not [Environment]::GetEnvironmentVariable($key, 'Process')) {
            [Environment]::SetEnvironmentVariable($key, $val, 'Process')
        }
    }
}

function Resolve-RepoPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ([System.IO.Path]::IsPathRooted($Value)) { return $Value }
    return (Join-Path $RootDir $Value)
}

function Pick-CloudflaredConfig {
    if ($env:NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG) {
        return (Resolve-RepoPath $env:NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG)
    }
    foreach ($name in 'cloudflared.local.yml', 'cloudflared.local.yaml') {
        $path = Join-Path $RootDir $name
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Wait-ForServer {
    param(
        [Parameter(Mandatory)][string]$TargetHost,
        [Parameter(Mandatory)][int]$TargetPort,
        [int]$TimeoutSec = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected) {
                $client.EndConnect($iar) | Out-Null
                return $true
            }
        } catch { }
        finally {
            if ($client) { $client.Close() }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Ensure-Deps {
    param([Parameter(Mandatory)][string]$PyExe)
    $serverExe = Join-Path (Split-Path $PyExe) 'notion-local-ops-mcp.exe'
    $needsInstall = $false
    if (-not (Test-Path -LiteralPath $serverExe)) { $needsInstall = $true }
    if (-not $needsInstall) {
        & $PyExe -c "import fastmcp, uvicorn" *> $null
        if ($LASTEXITCODE -ne 0) { $needsInstall = $true }
    }
    if ($needsInstall) {
        & $PyExe -m pip install -r (Join-Path $RootDir 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { Write-Error "pip install requirements failed"; exit 1 }
        & $PyExe -m pip install -e $RootDir
        if ($LASTEXITCODE -ne 0) { Write-Error "pip install -e failed"; exit 1 }
    }
}

# Preserve shell overrides before loading .env
$Overrides = @{}
foreach ($name in @(
    'NOTION_LOCAL_OPS_HOST',
    'NOTION_LOCAL_OPS_PORT',
    'NOTION_LOCAL_OPS_WORKSPACE_ROOT',
    'NOTION_LOCAL_OPS_STATE_DIR',
    'NOTION_LOCAL_OPS_AUTH_TOKEN',
    'NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG',
    'NOTION_LOCAL_OPS_TUNNEL_NAME',
    'NOTION_LOCAL_OPS_CODEX_COMMAND',
    'NOTION_LOCAL_OPS_CLAUDE_COMMAND',
    'NOTION_LOCAL_OPS_COMMAND_TIMEOUT',
    'NOTION_LOCAL_OPS_DELEGATE_TIMEOUT'
)) {
    $Overrides[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Require-Command cloudflared

# --- Python virtual environment bootstrap ---
if ($env:NOTION_LOCAL_OPS_VENV_PATH) {
    # Non-interactive: env var skips the prompt (for CI / automation)
    $VenvDir = Resolve-RepoPath $env:NOTION_LOCAL_OPS_VENV_PATH
    $VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $VenvPython)) {
        Write-Error "Invalid venv path: $VenvDir (Scripts\python.exe not found)"
        exit 1
    }
} else {
    $hasVenv = Read-Host "Do you have an existing Python virtual environment? [y/N]"
    if ($hasVenv -match '^[Yy]') {
        $userVenvPath = Read-Host "Enter your virtual environment path (e.g. C:\Users\you\myenv)"
        $VenvDir = Resolve-RepoPath $userVenvPath
        $VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $VenvPython)) {
            Write-Error "Invalid venv path: $VenvDir (Scripts\python.exe not found)"
            exit 1
        }
    } else {
        $PythonBin = Pick-Python
        $VenvDir   = Join-Path $RootDir '.venv'
        if (-not (Test-Path -LiteralPath $VenvDir)) {
            Write-Host "Creating virtual environment at $VenvDir..."
            & $PythonBin -m venv $VenvDir
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create venv"; exit 1 }
        }
        $VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $VenvPython)) {
            Write-Error "venv python not found at $VenvPython"
            exit 1
        }
    }
}

$VenvServer = Join-Path $VenvDir 'Scripts\notion-local-ops-mcp.exe'
Ensure-Deps -PyExe $VenvPython

Load-EnvFile

foreach ($kv in $Overrides.GetEnumerator()) {
    if ($kv.Value) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process') }
}

if (-not $env:NOTION_LOCAL_OPS_HOST)           { $env:NOTION_LOCAL_OPS_HOST = '127.0.0.1' }
if (-not $env:NOTION_LOCAL_OPS_PORT)           { $env:NOTION_LOCAL_OPS_PORT = '8766' }
if (-not $env:NOTION_LOCAL_OPS_WORKSPACE_ROOT) { $env:NOTION_LOCAL_OPS_WORKSPACE_ROOT = $RootDir }

if (-not $env:NOTION_LOCAL_OPS_AUTH_TOKEN) {
    Write-Error "Missing NOTION_LOCAL_OPS_AUTH_TOKEN. Set it in .env or export it before running."
    exit 1
}

$ServerUrl    = "http://$($env:NOTION_LOCAL_OPS_HOST):$($env:NOTION_LOCAL_OPS_PORT)"
$ServerStdout = Join-Path $env:TEMP "notion-local-ops-mcp-server.$PID.out.log"
$ServerStderr = Join-Path $env:TEMP "notion-local-ops-mcp-server.$PID.err.log"

Write-Host "Starting notion-local-ops-mcp..."
$ServerProc = Start-Process -FilePath $VenvServer `
    -WorkingDirectory $RootDir `
    -RedirectStandardOutput $ServerStdout `
    -RedirectStandardError  $ServerStderr `
    -NoNewWindow -PassThru

try {
    if (-not (Wait-ForServer -TargetHost $env:NOTION_LOCAL_OPS_HOST -TargetPort ([int]$env:NOTION_LOCAL_OPS_PORT))) {
        Write-Warning "MCP server did not become ready. Recent log output:"
        foreach ($p in @($ServerStderr, $ServerStdout)) {
            if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Tail 40 | Write-Host }
        }
        exit 1
    }

    Write-Host "MCP endpoint: $ServerUrl/mcp"
    Write-Host "Workspace root: $($env:NOTION_LOCAL_OPS_WORKSPACE_ROOT)"
    Write-Host "Server logs: $ServerStdout | $ServerStderr"

    $CloudflaredConfig = Pick-CloudflaredConfig
    if ($CloudflaredConfig) {
        if (-not (Test-Path -LiteralPath $CloudflaredConfig)) {
            Write-Error "cloudflared config not found: $CloudflaredConfig"
            exit 1
        }
        Write-Host "Starting named cloudflared tunnel. Press Ctrl+C to stop both processes."
        Write-Host "cloudflared config: $CloudflaredConfig"
        if ($env:NOTION_LOCAL_OPS_TUNNEL_NAME) {
            & cloudflared tunnel --config $CloudflaredConfig run $env:NOTION_LOCAL_OPS_TUNNEL_NAME
        } else {
            & cloudflared tunnel --config $CloudflaredConfig run
        }
    } else {
        Write-Host "Starting cloudflared quick tunnel. Press Ctrl+C to stop both processes."
        & cloudflared tunnel --url $ServerUrl
    }
}
finally {
    if ($ServerProc -and -not $ServerProc.HasExited) {
        try { Stop-Process -Id $ServerProc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}
