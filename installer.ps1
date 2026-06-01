#Requires -RunAsAdministrator

# ============================================================
#  USER CONFIGURABLE VARIABLES
# ============================================================
$global:PublicScriptUrl = "https://raw.githubusercontent.com/Pascaruuu/installscript/main/installer.ps1"
$RepoOwner              = "Pascaruuu"
$RepoName               = "Invoice-recording-system"
$PrivateScriptPath      = "scripts/setup.ps1"
$RepoBranch             = "6-prototype"
# ============================================================

# --- Self-Elevation Check via EncodedCommand ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $scriptString = $MyInvocation.MyCommand.ScriptBlock.ToString()
    if ($scriptString) {
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptString))
        Start-Process powershell.exe -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand" -Verb RunAs
    } else {
        Write-Host "ERROR: Please run PowerShell as Administrator." -ForegroundColor Red
        Write-Host "Press Enter to exit..."
        Read-Host
    }
    exit
}

try {
    # --- Setup Paths ---
    $installDir = Join-Path $env:USERPROFILE "ocr-system"

    if (!(Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    $envFile = Join-Path $installDir ".env"

    # --- Read/Get and Verify GHCR Token ---
    $validCredentials = $false
    $privateScriptContent = ""

    while (-not $validCredentials) {
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
                $inputUser = Read-Host "Enter GitHub Username"
                if ($null -ne $inputUser) {
                    $ghcrUser = $inputUser.Trim()
                }
            }
            
            $ghcrTokenPlain = ""
            while ([string]::IsNullOrWhiteSpace($ghcrTokenPlain)) {
                $inputVal = Read-Host "Enter GitHub PAT (requires: read:packages AND repo)" -AsSecureString
                $decrypted = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($inputVal))
                if ($null -ne $decrypted) {
                    $ghcrTokenPlain = $decrypted.Trim()
                }
            }
            
            $existingGhcrToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${ghcrUser}:${ghcrTokenPlain}"))
        } else {
            # --- Decode Credentials for API ---
            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($existingGhcrToken))
            if ($decoded -match "^([^:]+):(.+)$") {
                $ghcrUser = $Matches[1]
                $ghcrTokenPlain = $Matches[2]
            } else {
                Write-Host "WARNING: Invalid GHCR_TOKEN format in .env file. Clearing and re-prompting." -ForegroundColor Yellow
                $existingGhcrToken = ""
                if (Test-Path $envFile) {
                    $content = Get-Content -Path $envFile | Where-Object { $_ -notmatch "^\s*GHCR_TOKEN\s*=" }
                    Set-Content -Path $envFile -Value $content
                }
                continue
            }
        }

        # --- Fetch setup.ps1 via GitHub API to verify credentials ---
        Write-Host "Downloading and verifying setup.ps1 from private repo..." -ForegroundColor Yellow
        $headers = @{
            "Authorization" = "Bearer $ghcrTokenPlain"
            "Accept"        = "application/vnd.github.v3.raw"
        }
        try {
            # Ensure TLS 1.2 is enabled
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $privateScriptContent = Invoke-RestMethod -Uri "https://api.github.com/repos/$($RepoOwner)/$($RepoName)/contents/$($PrivateScriptPath)?ref=$($RepoBranch)" -Headers $headers
            $validCredentials = $true

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
            Write-Host "Saved verified GHCR credentials to $envFile" -ForegroundColor Green
        } catch {
            Write-Host "ERROR: Credentials invalid or failed download setup.ps1: $_" -ForegroundColor Red
            Write-Host "Clearing credentials and trying again..." -ForegroundColor Yellow
            $existingGhcrToken = ""
            if (Test-Path $envFile) {
                $content = Get-Content -Path $envFile | Where-Object { $_ -notmatch "^\s*GHCR_TOKEN\s*=" }
                Set-Content -Path $envFile -Value $content
            }
        }
    }

    # --- Execute setup.ps1 in memory ---
    Write-Host "Executing setup.ps1 in memory..." -ForegroundColor Green
    Invoke-Expression $privateScriptContent
}
catch {
    Write-Host "ERROR: An unexpected error occurred: $_" -ForegroundColor Red
    Write-Host "Error Details: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
}
finally {
    Write-Host ""
    Write-Host "Press Enter to exit..." -ForegroundColor Yellow
    Read-Host | Out-Null
}
