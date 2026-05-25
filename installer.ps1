#Requires -RunAsAdministrator

# ============================================================
#  USER CONFIGURABLE VARIABLES
# ============================================================
$global:PublicScriptUrl = "https://raw.githubusercontent.com/Pascaruuu/installscript/main/installer.ps1"
$RepoOwner              = "Pascaruuu"
$RepoName               = "Invoice-recording-system"
$PrivateScriptPath      = "scripts/setup.ps1"
# ============================================================

# --- Self-Elevation Check via EncodedCommand ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $scriptString = $MyInvocation.MyCommand.ScriptBlock.ToString()
    if ($scriptString) {
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptString))
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand" -Verb RunAs
    } else {
        Write-Host "ERROR: Please run PowerShell as Administrator." -ForegroundColor Red
    }
    exit
}

# --- Setup Paths ---
$installDir = Join-Path $env:USERPROFILE "ocr-system"

if (!(Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
$envFile = Join-Path $installDir ".env"

# --- Read/Get GHCR Token ---
$existingGhcrToken = ""
if (Test-Path $envFile) {
    $line = Get-Content -Path $envFile | Where-Object { $_ -match "^\s*GHCR_TOKEN\s*=" } | Select-Object -First 1
    if ($line) {
        $val = $line -replace "^\s*GHCR_TOKEN\s*=\s*", ""
        $existingGhcrToken = $val.Trim().Trim('"').Trim("'")
    }
}

if ([string]::IsNullOrWhiteSpace($existingGhcrToken)) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  GITHUB CONTAINER REGISTRY (GHCR) AUTHENTICATION" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Generate a token at: https://github.com/settings/tokens" -ForegroundColor Cyan
    
    $ghcrUser = ""
    while ([string]::IsNullOrWhiteSpace($ghcrUser)) {
        $ghcrUser = Read-Host "Enter GitHub Username"
    }
    
    $ghcrTokenPlain = ""
    while ([string]::IsNullOrWhiteSpace($ghcrTokenPlain)) {
        $inputVal = Read-Host "Enter GitHub PAT (read:packages)" -AsSecureString
        $ghcrTokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($inputVal))
    }
    
    $existingGhcrToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${ghcrUser}:${ghcrTokenPlain}"))
    
    # Save/update in .env
    if (Test-Path $envFile) {
        $content = Get-Content -Path $envFile
        if ($content -match "GHCR_TOKEN=") {
            $content = $content -replace '^GHCR_TOKEN=.*', "GHCR_TOKEN=`"$existingGhcrToken`""
            Set-Content -Path $envFile -Value $content
        } else {
            $content += "`nGHCR_TOKEN=`"$existingGhcrToken`""
            Set-Content -Path $envFile -Value $content
        }
    } else {
        Set-Content -Path $envFile -Value "GHCR_TOKEN=`"$existingGhcrToken`""
    }
    Write-Host "Saved GHCR credentials to $envFile" -ForegroundColor Green
}

# --- Decode Credentials for API & Docker ---
$decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($existingGhcrToken))
if ($decoded -match "^([^:]+):(.+)$") {
    $ghcrUser = $Matches[1]
    $ghcrTokenPlain = $Matches[2]
} else {
    Write-Host "ERROR: Invalid GHCR_TOKEN format in .env file." -ForegroundColor Red
    exit 1
}

# --- Docker Login ---
Write-Host "Authenticating with GitHub Container Registry..." -ForegroundColor Yellow
$ghcrTokenPlain | docker login ghcr.io -u $ghcrUser --password-stdin
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker login to ghcr.io failed. Please check your credentials." -ForegroundColor Red
    exit 1
}
Write-Host "Docker authenticated successfully." -ForegroundColor Green


# --- Fetch setup.ps1 via GitHub API ---
Write-Host "Downloading private setup.ps1 script..." -ForegroundColor Yellow
$headers = @{
    "Authorization" = "token $ghcrTokenPlain"
    "Accept"        = "application/vnd.github.v3.raw"
}
try {
    # Ensure TLS 1.2 is enabled
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    $privateScriptContent = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoOwner/$RepoName/contents/$PrivateScriptPath" -Headers $headers
} catch {
    Write-Host "ERROR: Failed to download setup.ps1 from private repo via GitHub API: $_" -ForegroundColor Red
    exit 1
}

# --- Execute setup.ps1 in memory ---
Write-Host "Executing setup.ps1 in memory..." -ForegroundColor Green
Invoke-Expression $privateScriptContent
