Start-Transcript -Path "C:\LabFiles\logontask.log" -Append

# This task runs as azureuser at logon, so the profile already exists and
# $env:USERPROFILE is the real one. Nothing here may run before first logon -
# creating C:\Users\azureuser early forces Windows to build the profile as
# C:\Users\azureuser.<COMPUTERNAME> instead, and the attendee then sees empty
# Documents / Downloads folders.
Write-Host "Running as: $env:USERNAME, profile: $env:USERPROFILE"

if ($env:USERPROFILE -ne "C:\Users\azureuser") {
    Write-Host "WARNING: profile is $env:USERPROFILE, not C:\Users\azureuser - a duplicate profile was created. Lab guide paths that hardcode C:\Users\azureuser will not match what the attendee sees."
}

# Selenium folder - created here rather than in psscript-01.ps1 for the reason above
$seleniumDir = Join-Path $env:USERPROFILE "Downloads\selenium"
New-Item -Path $seleniumDir -ItemType Directory -Force | Out-Null
Write-Host "Selenium directory: $seleniumDir"

# Both source trees now ship as zip files at the root of the custom-devops
# folder (siblings of deploy/ and scripts/), instead of being pulled from
# GitHub at logon time. This removes the runtime dependency on git and on
# GitHub availability specifically, while staying consistent with how this
# script itself is fetched onto the VM.
$blobBase = "https://experienceazure.blob.core.windows.net/templates/custom-devops"

$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Expand-ZipFlattened {
    param(
        [Parameter(Mandatory)] [string]$ZipUrl,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [string]$MarkerRelativePath
    )

    $marker   = Join-Path $Destination $MarkerRelativePath
    $stageDir = "$Destination.stage"
    $zipPath  = "$Destination.zip"

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        foreach ($stale in @($Destination, $stageDir, $zipPath)) {
            if (Test-Path $stale) { Remove-Item -Path $stale -Recurse -Force -ErrorAction SilentlyContinue }
        }

        try {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

            New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
            Expand-Archive -Path $zipPath -DestinationPath $stageDir -Force -ErrorAction Stop

            # GitHub-style archives wrap everything in one <repo>-<branch> folder.
            # Move its contents up so the destination has no extra level. -Force on
            # Get-ChildItem is required or dotfiles/dot-folders are left behind.
            $wrapper = Get-ChildItem -Path $stageDir -Directory -Force | Select-Object -First 1
            if (-not $wrapper) { throw "archive contained no top-level folder" }

            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Get-ChildItem -Path $wrapper.FullName -Force |
                Move-Item -Destination $Destination -Force -ErrorAction Stop

            if (-not (Test-Path $marker)) { throw "$MarkerRelativePath missing after extract" }

            Write-Host "Extracted $ZipUrl to $Destination on attempt $attempt"
            return $true
        }
        catch {
            Write-Host "Attempt $attempt failed for $ZipUrl : $($_.Exception.Message) - retrying"
            Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 15
        }
        finally {
            Remove-Item -Path $zipPath  -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "ERROR: failed to extract $ZipUrl to $Destination after 3 attempts"
    return $false
}

# Downloads a single file (e.g. a .ps1 from the blob container) with retries.
# Downloads to a temp file first and only moves it into place once it has been
# validated, so a failed/partial download never leaves a broken file behind.
function Get-FileWithRetry {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Destination,
        [string]$MustContain   # optional text that must appear in the file to count as valid
    )

    $tempPath = "$Destination.download"
    $logUrl   = ($Url -split '\?')[0]   # never write a SAS token to the log

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue

            Invoke-WebRequest -Uri $Url -OutFile $tempPath -UseBasicParsing -ErrorAction Stop

            $item = Get-Item $tempPath -ErrorAction Stop
            if ($item.Length -eq 0) { throw "downloaded file is empty" }

            $content = Get-Content -Path $tempPath -Raw

            # Azure Storage returns an XML error body (e.g. BlobNotFound,
            # PublicAccessNotPermitted, AuthenticationFailed) instead of the file.
            if ($content -match '^\s*(<\?xml[^>]*>\s*)?<Error>') {
                $code = if ($content -match '<Code>([^<]+)</Code>') { $Matches[1] } else { "unknown" }
                throw "Azure Storage returned an error instead of the file (Code: $code)"
            }
            if ($content -match '^\s*(<!DOCTYPE html|<html)') {
                throw "server returned an HTML page instead of the file"
            }
            if ($MustContain -and ($content -notmatch [regex]::Escape($MustContain))) {
                throw "downloaded file does not contain expected text '$MustContain'"
            }

            Move-Item -Path $tempPath -Destination $Destination -Force -ErrorAction Stop

            # Remove the "downloaded from the internet" mark so the attendee can run
            # the script without an execution-policy / security warning.
            Unblock-File -Path $Destination -ErrorAction SilentlyContinue

            Write-Host "Downloaded $logUrl to $Destination ($($item.Length) bytes) on attempt $attempt"
            return $true
        }
        catch {
            # 404 = wrong path/name, 403 = private container or bad SAS token
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $statusText = if ($status) { " (HTTP $status)" } else { "" }

            Write-Host "Attempt $attempt failed for $logUrl$statusText : $($_.Exception.Message) - retrying"
            Start-Sleep -Seconds 15
        }
        finally {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "ERROR: failed to download $logUrl to $Destination after 3 attempts"
    return $false
}

# Define the target directory
$targetDir = Join-Path $env:USERPROFILE "Documents"

# Create the directory if it doesn't exist
if (!(Test-Path -Path $targetDir)) {
    New-Item -Path $targetDir -ItemType Directory -Force
    Write-Host "Created directory: $targetDir"
} else {
    Write-Host "Directory already exists: $targetDir"
}

# AzDevOpsDemoGenerator source now comes from the blob-hosted zip instead of a
# git clone. Extract into a folder named AzDevOpsDemoGenerator so the lab guide
# path C:\Users\azureuser\Documents\AzDevOpsDemoGenerator\src still resolves.
$adoZipUrl = "$blobBase/hack-in-a-day-data-AzDevOpsDemoGenerator.zip"
$cloneDir  = Join-Path $targetDir "AzDevOpsDemoGenerator"

Expand-ZipFlattened -ZipUrl $adoZipUrl -Destination $cloneDir -MarkerRelativePath "src\ADOGenerator.sln" | Out-Null

# eShopOnWeb source into C:\LabFiles\eShopOnWeb, flat - the repo contents sit
# directly in that folder, with no wrapper directory. Now comes from the
# blob-hosted zip instead of a GitHub download.
$eshopZipUrl = "$blobBase/hack-in-a-day-data-gl-implement-devops-github.zip"
$eshopDir    = "C:\LabFiles\eShopOnWeb"

Expand-ZipFlattened -ZipUrl $eshopZipUrl -Destination $eshopDir -MarkerRelativePath "eShopOnWeb.sln" | Out-Null

if (Test-Path (Join-Path $eshopDir "eShopOnWeb.sln")) {
    Write-Host "eShopOnWeb contents:"
    Get-ChildItem -Path $eshopDir -Force | Select-Object -ExpandProperty Name | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
# Powershell folder + New_Selinum.ps1
# Replacement for the Demo Generator "Selenium" template. Now served from the
# same blob container as this script and the zips above (no GitHub dependency).
# The attendee runs it during the lab:
#   cd C:\LabFiles\Powershell
#   .\New_Selinum.ps1 -Organization <org name> -Pat <PAT>
#
# >>> If New_Selinum.ps1 sits in a different folder of the container, change
#     the part after $blobBase below (blob names are case-sensitive). <<<
# ---------------------------------------------------------------------------
$psDir          = "C:\LabFiles\Powershell"
$seleniumPs1    = Join-Path $psDir "New_Selinum.ps1"
$seleniumPs1Url = "$blobBase/scripts/New_Selinum.ps1"

New-Item -Path $psDir -ItemType Directory -Force | Out-Null
Write-Host "Powershell directory: $psDir"

$seleniumOk = Get-FileWithRetry -Url $seleniumPs1Url -Destination $seleniumPs1 -MustContain "Organization"

if ($seleniumOk -and (Test-Path $seleniumPs1)) {
    Write-Host "New_Selinum.ps1 is present at $seleniumPs1"
} else {
    Write-Host "ERROR: New_Selinum.ps1 is NOT present at $seleniumPs1"
}

Unregister-ScheduledTask -TaskName "Setup" -Confirm:$false

Stop-Transcript
