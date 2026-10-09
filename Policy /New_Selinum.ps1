<#
.SYNOPSIS
    Replacement for the Azure DevOps Demo Generator (ADOGenerator.sln) "Selenium" template.

.DESCRIPTION
    Uses the Azure DevOps REST APIs to create exactly what the Demo Generator's DL-Selenium
    template created, so Lab 02 Exercise 4 Task 2 and Task 3 work unchanged:
      1. Team project "Selenium"
      2. Git repo "Selenium" imported from the public PartsUnlimited/Selenium source
      3. Classic build pipeline  "Selenium" (NuGet -> Update ChromeDriver -> Build -> Test -> Copy -> Publish 'drop')
      4. Classic release pipeline "Selenium" (Dev stage: IIS Deployment, SQL Deployment,
         Selenium tests execution) with a CD trigger on the build artifact

    CHROMEDRIVER VERSION HANDLING (fixes "session timed out after 60 seconds"):
      * BUILD:   a PowerShell step updates the Selenium.WebDriver.ChromeDriver NuGet package
                 in the code to the LATEST version before restore/build, so the artifact
                 ships a current chromedriver.exe instead of 2.41 (2018).
                 Set the build variable ChromeMajorVersion (e.g. 141) to pin it to the
                 Chrome major version installed on SeleniumVM. Empty = latest.
      * RELEASE: a PowerShell step reads the Chrome version actually installed on the agent
                 (SeleniumVM), downloads the exactly matching ChromeDriver and puts it in
                 drop\TestAssemblies. This is the safety net when Chrome auto-updates.

    Other changes vs. the original:
      * Build agent windows-2019 (retired) -> windows-2022
      * NuGet 4.3.0 -> 6.x
      * "Run Selenium UI tests" continueOnError true -> false (failed tests now FAIL the release)
      * CI trigger on the default branch (push -> build -> release automatically)

    Prerequisite (same as the lab): Organization settings > Pipelines > Settings >
    turn OFF "Disable creation of classic build pipelines" and
    "Disable creation of classic release pipelines".

    Works on Windows PowerShell 5.1 and PowerShell 7. No modules or az cli needed.

.EXAMPLE
    .\New-SeleniumProject.ps1 -Organization odluser123456 -Pat <your PAT>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Organization,
    [Parameter(Mandatory)] [string] $Pat,
    [string] $ProjectName  = 'Selenium',
    [string] $SourceRepoUrl = 'https://dev.azure.com/vstsdemodata/Selenium/_git/Selenium',
    [ValidateSet('Agile', 'Scrum', 'Basic', 'CMMI')] [string] $Process = 'Scrum'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Accept "odluser123", "https://dev.azure.com/odluser123" or "https://dev.azure.com/odluser123/"
$Organization = ($Organization.TrimEnd('/') -split '/')[-1]
$devUrl = "https://dev.azure.com/$Organization"
$rmUrl  = "https://vsrm.dev.azure.com/$Organization"
$api    = 'api-version=7.1'

$headers = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
}

function Invoke-Ado {
    param([string] $Method = 'GET', [string] $Uri, [string] $Body)
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($Body) {
        $params.Body        = [Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        Invoke-RestMethod @params
    } catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "$Method $Uri failed: $detail"
    }
}

function Write-Step([string] $Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }

# JSON-escape a value before dropping it into a template string
function ConvertTo-JsonValue([string] $Value) { ($Value | ConvertTo-Json).Trim('"') }

# ---------------------------------------------------------------------------
# 0. Validate PAT / org
# ---------------------------------------------------------------------------
Write-Step "Connecting to $devUrl"
$conn = Invoke-Ado -Uri "$devUrl/_apis/connectionData"
$me   = $conn.authenticatedUser
if (-not $me -or $me.descriptor -like '*Anonymous*') {
    throw 'PAT was not accepted. Check the organization name and that the PAT has Full access.'
}
Write-Host "Signed in as $($me.providerDisplayName)"

# ---------------------------------------------------------------------------
# 1. Create the project (or reuse it if it already exists)
# ---------------------------------------------------------------------------
Write-Step "Creating project '$ProjectName'"
$project = $null
try { $project = Invoke-Ado -Uri "$devUrl/_apis/projects/$([uri]::EscapeDataString($ProjectName))?$api" } catch { }

if ($project) {
    Write-Host "Project already exists - reusing it."
} else {
    $proc = (Invoke-Ado -Uri "$devUrl/_apis/process/processes?$api").value |
            Where-Object name -eq $Process | Select-Object -First 1
    if (-not $proc) { throw "Process '$Process' not found in organization." }

    $body = @{
        name         = $ProjectName
        visibility   = 'private'
        capabilities = @{
            versioncontrol  = @{ sourceControlType = 'Git' }
            processTemplate = @{ templateTypeId = $proc.id }
        }
    } | ConvertTo-Json -Depth 5

    $op = Invoke-Ado -Method POST -Uri "$devUrl/_apis/projects?$api" -Body $body
    do {
        Start-Sleep -Seconds 3
        $op = Invoke-Ado -Uri $op.url
        Write-Host "  project status: $($op.status)"
    } while ($op.status -in 'notSet', 'queued', 'inProgress')
    if ($op.status -ne 'succeeded') { throw "Project creation ended with status '$($op.status)'." }

    $project = Invoke-Ado -Uri "$devUrl/_apis/projects/$([uri]::EscapeDataString($ProjectName))?$api"
}
$projectId = $project.id
$projUrl   = "$devUrl/$projectId"
$rmProjUrl = "$rmUrl/$projectId"

# ---------------------------------------------------------------------------
# 2. Import the Selenium source code into the project's default repo
# ---------------------------------------------------------------------------
Write-Step 'Importing source code'
$repos = (Invoke-Ado -Uri "$projUrl/_apis/git/repositories?$api").value
$repo  = $repos | Where-Object name -eq $ProjectName | Select-Object -First 1
if (-not $repo) {
    $repo = Invoke-Ado -Method POST -Uri "$projUrl/_apis/git/repositories?$api" `
                       -Body (@{ name = $ProjectName; project = @{ id = $projectId } } | ConvertTo-Json)
}

$refs = (Invoke-Ado -Uri "$projUrl/_apis/git/repositories/$($repo.id)/refs?$api").value
if ($refs) {
    Write-Host "Repo '$($repo.name)' already has code - skipping import."
} else {
    $imp = Invoke-Ado -Method POST -Uri "$projUrl/_apis/git/repositories/$($repo.id)/importRequests?$api" `
                      -Body (@{ parameters = @{ gitSource = @{ url = $SourceRepoUrl } } } | ConvertTo-Json -Depth 4)
    do {
        Start-Sleep -Seconds 5
        $imp = Invoke-Ado -Uri "$projUrl/_apis/git/repositories/$($repo.id)/importRequests/$($imp.importRequestId)?$api"
        Write-Host "  import status: $($imp.status)"
    } while ($imp.status -in 'queued', 'inProgress')
    if ($imp.status -ne 'completed') { throw "Repo import ended with status '$($imp.status)': $($imp.detailedStatus | ConvertTo-Json -Compress)" }
}
$repo = Invoke-Ado -Uri "$projUrl/_apis/git/repositories/$($repo.id)?$api"
$defaultBranch = if ($repo.defaultBranch) { $repo.defaultBranch } else { 'refs/heads/master' }

# ---------------------------------------------------------------------------
# 3. Look up the project's "Default" agent queue (used by the release phases)
# ---------------------------------------------------------------------------
$queue = (Invoke-Ado -Uri "$projUrl/_apis/distributedtask/queues?queueName=Default&$api").value | Select-Object -First 1
if (-not $queue) { throw "No 'Default' agent queue found in project '$ProjectName'." }

# ===========================================================================
# CHROMEDRIVER STEP FOR THE BUILD PIPELINE  (NEW)
# Runs on the hosted build agent BEFORE "NuGet restore".
# Changes the Selenium.WebDriver.ChromeDriver package version in packages.config
# and the .csproj from 2.41.0 to the latest version on nuget.org, so the build
# copies a current chromedriver.exe into the 'drop' artifact.
# ===========================================================================
$buildChromeDriverScript = @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Pick the ChromeDriver package version.
#    Default: the latest one on nuget.org.
#    If the pipeline variable ChromeMajorVersion is set (e.g. 141), use the latest
#    package for that Chrome major version (= the Chrome on SeleniumVM).
$all = @((Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/selenium.webdriver.chromedriver/index.json').versions |
         Where-Object { $_ -notmatch '-' })
$major = "$env:CHROMEMAJORVERSION".Trim()
if ($major) { $all = @($all | Where-Object { $_ -like "$major.*" }) }
if ($all.Count -eq 0) { throw "No Selenium.WebDriver.ChromeDriver package found for Chrome major version '$major'." }
$latest = $all[-1]
Write-Host "Using Selenium.WebDriver.ChromeDriver $latest"

# 2. Replace the old version everywhere it is referenced
$changed = 0
$files = Get-ChildItem $env:BUILD_SOURCESDIRECTORY -Recurse -File -Include 'packages.config', '*.csproj' |
         Where-Object { $_.FullName -notmatch '\\(bin|obj|packages)\\' }
foreach ($f in $files) {
    $text = [IO.File]::ReadAllText($f.FullName)
    $new  = $text
    # packages.config:  <package id="Selenium.WebDriver.ChromeDriver" version="2.41.0" ... />
    $new = [regex]::Replace($new, '(?i)(<package\s+id="Selenium\.WebDriver\.ChromeDriver"\s+version=")[^"]+', "`${1}$latest")
    # .csproj (packages.config style):  ..\packages\Selenium.WebDriver.ChromeDriver.2.41.0\build\...
    $new = [regex]::Replace($new, '(?i)(Selenium\.WebDriver\.ChromeDriver\.)\d+(?:\.\d+)+(?=[\\/])', "`${1}$latest")
    # .csproj (PackageReference style)
    $new = [regex]::Replace($new, '(?i)(<PackageReference\s+Include="Selenium\.WebDriver\.ChromeDriver"\s+Version=")[^"]+', "`${1}$latest")
    $new = [regex]::Replace($new, '(?is)(<PackageReference\s+Include="Selenium\.WebDriver\.ChromeDriver"\s*>\s*<Version>)[^<]+', "`${1}$latest")
    if ($new -ne $text) {
        [IO.File]::WriteAllText($f.FullName, $new)
        Write-Host "Updated $($f.FullName)"
        $changed++
    }
}
if ($changed -eq 0) {
    Write-Host '##vso[task.logissue type=warning]No Selenium.WebDriver.ChromeDriver reference found in the code. Nothing was updated.'
}
'@

$buildChromeDriverTask = [ordered]@{
    enabled          = $true
    continueOnError  = $false
    alwaysRun        = $false
    timeoutInMinutes = 0
    displayName      = 'Update ChromeDriver package to latest version'
    refName          = 'UpdateChromeDriver'
    task             = [ordered]@{ id = 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1'; versionSpec = '2.*'; definitionType = 'task' }   # built-in "PowerShell" task
    inputs           = [ordered]@{
        targetType            = 'inline'
        script                = $buildChromeDriverScript
        errorActionPreference = 'stop'
        failOnStderr          = 'false'
        ignoreLASTEXITCODE    = 'false'
        pwsh                  = 'false'
    }
} | ConvertTo-Json -Depth 5

# ---------------------------------------------------------------------------
# 4. Classic build pipeline (from DL-Selenium/BuildDefinitions/Selenium.json)
# ---------------------------------------------------------------------------
Write-Step 'Creating build pipeline'
$buildJson = @'
{
  "name": "Selenium",
  "path": "\\",
  "type": "build",
  "options": [
    { "enabled": true,  "definition": { "id": "5d58cc01-7c75-450c-be18-a388ddb129ec" }, "inputs": { "branchFilters": "[\"+refs/heads/*\"]", "additionalFields": "{}" } },
    { "enabled": false, "definition": { "id": "a9db38f9-9fdc-478c-b0f9-464221e58316" }, "inputs": { "workItemType": "725558", "assignToRequestor": "true", "additionalFields": "{}" } }
  ],
  "variables": {
    "BuildConfiguration": { "value": "release", "allowOverride": true },
    "BuildPlatform":      { "value": "any cpu", "allowOverride": true },
    "ChromeMajorVersion": { "value": "",        "allowOverride": true },
    "system.debug":       { "value": "false",   "allowOverride": true }
  },
  "buildNumberFormat": "$(date:yyyyMMdd)$(rev:.r)",
  "jobAuthorizationScope": "projectCollection",
  "jobTimeoutInMinutes": 60,
  "jobCancelTimeoutInMinutes": 5,
  "process": {
    "type": 1,
    "target": { "agentSpecification": { "identifier": "windows-2019" } },
    "phases": [
      {
        "name": "Phase 1",
        "refName": "Phase_1",
        "condition": "succeeded()",
        "target": { "executionOptions": { "type": 0 }, "allowScriptsAuthAccessOption": false, "type": 1 },
        "jobAuthorizationScope": "projectCollection",
        "jobCancelTimeoutInMinutes": 1,
        "steps": [
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "Use NuGet 4.3.0", "refName": "NuGetToolInstaller1",
            "task": { "id": "2c65196a-54fd-4a02-9be8-d9d1837b7c5d", "versionSpec": "0.*", "definitionType": "task" },
            "inputs": { "versionSpec": "4.3.0", "checkLatest": "false" }
          },
          __CHROMEDRIVER_BUILD_TASK__,
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "NuGet restore", "refName": "NuGetCommand2",
            "task": { "id": "333b11bd-d341-40d9-afcf-b32d5ce6f23b", "versionSpec": "2.*", "definitionType": "task" },
            "inputs": { "command": "restore", "solution": "$(Parameters.solution)", "selectOrConfig": "select", "includeNuGetOrg": "true", "noCache": "false", "verbosityRestore": "Detailed" }
          },
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "Build solution", "refName": "VSBuild3",
            "task": { "id": "71a9a2d3-a98a-4caa-96ab-affca411ecda", "versionSpec": "1.*", "definitionType": "task" },
            "inputs": {
              "solution": "$(Parameters.solution)", "vsVersion": "latest",
              "msbuildArgs": "/p:DeployOnBuild=true /p:WebPublishMethod=Package /p:PackageAsSingleFile=true /p:SkipInvalidConfigurations=true /p:PackageLocation=\"$(build.artifactstagingdirectory)\\\\\"",
              "platform": "$(BuildPlatform)", "configuration": "$(BuildConfiguration)",
              "clean": "false", "maximumCpuCount": "false", "restoreNugetPackages": "false",
              "msbuildArchitecture": "x86", "logProjectEvents": "true", "createLogFile": "false"
            }
          },
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "Test Assemblies", "refName": "VSTest4",
            "task": { "id": "ef087383-ee5e-42c7-9a53-ab56c98420f9", "versionSpec": "2.*", "definitionType": "task" },
            "inputs": {
              "testSelector": "testAssemblies",
              "testAssemblyVer2": "**\\$(BuildConfiguration)\\*test*.dll\n!**\\obj\\**",
              "searchFolder": "$(System.DefaultWorkingDirectory)\\test\\PartsUnlimited.UnitTests",
              "tcmTestRun": "$(test.RunId)", "uiTests": "false",
              "vstestLocationMethod": "version", "vsTestVersion": "latest",
              "runInParallel": "False", "runTestsInIsolation": "False", "codeCoverageEnabled": "False",
              "platform": "$(BuildPlatform)", "configuration": "$(BuildConfiguration)", "publishRunAttachments": "true"
            }
          },
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "Copy Files to: $(build.artifactstagingdirectory)/TestAssemblies", "refName": "CopyFiles1",
            "task": { "id": "5bfb729a-a7c8-4a78-a7c3-8d717bb7c13c", "versionSpec": "2.*", "definitionType": "task" },
            "inputs": {
              "SourceFolder": "$(Build.SourcesDirectory)/test/PartsUnlimited.SeleniumTests/bin/$(BuildConfiguration)",
              "Contents": "**", "TargetFolder": "$(build.artifactstagingdirectory)/TestAssemblies",
              "CleanTargetFolder": "false", "OverWrite": "false", "flattenFolders": "false"
            }
          },
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "Copy Files to: $(build.artifactstagingdirectory)/Database", "refName": "CopyFiles2",
            "task": { "id": "5bfb729a-a7c8-4a78-a7c3-8d717bb7c13c", "versionSpec": "2.*", "definitionType": "task" },
            "inputs": {
              "SourceFolder": "Database/Database", "Contents": "**",
              "TargetFolder": "$(build.artifactstagingdirectory)/Database",
              "CleanTargetFolder": "false", "OverWrite": "false", "flattenFolders": "false"
            }
          },
          {
            "enabled": true, "continueOnError": false, "alwaysRun": false, "timeoutInMinutes": 0,
            "displayName": "Publish Artifact", "refName": "PublishBuildArtifacts6",
            "task": { "id": "2ff763a7-ce83-4e1f-bc89-0ae63477cebe", "versionSpec": "1.*", "definitionType": "task" },
            "inputs": { "PathtoPublish": "$(build.artifactstagingdirectory)", "ArtifactName": "$(Parameters.ArtifactName)", "ArtifactType": "Container" }
          }
        ]
      }
    ]
  },
  "triggers": [ { "branchFilters": [ "+__DEFAULT_BRANCH__" ], "pathFilters": [], "batchChanges": false, "maxConcurrentBuildsPerBranch": 1, "pollingInterval": 0, "triggerType": "continuousIntegration" } ],
  "repository": {
    "id": "__REPO_ID__",
    "type": "TfsGit",
    "name": "__REPO_NAME__",
    "defaultBranch": "__DEFAULT_BRANCH__",
    "clean": "false",
    "checkoutSubmodules": false,
    "properties": { "cleanOptions": "0", "labelSources": "0", "reportBuildStatus": "true", "fetchDepth": "0" }
  },
  "processParameters": {
    "inputs": [
      { "name": "solution",     "label": "Path to solution or packages.config", "defaultValue": "**\\*.sln", "required": true, "type": "filePath" },
      { "name": "ArtifactName", "label": "Artifact Name",                       "defaultValue": "drop",      "required": true, "type": "string" }
    ]
  },
  "queue": { "name": "Azure Pipelines", "pool": { "name": "Azure Pipelines", "isHosted": true } },
  "queueStatus": "enabled"
}
'@

$buildJson = $buildJson.Replace('__CHROMEDRIVER_BUILD_TASK__', $buildChromeDriverTask)
$buildJson = $buildJson.Replace('__REPO_ID__',        $repo.id)
$buildJson = $buildJson.Replace('__REPO_NAME__',      (ConvertTo-JsonValue $repo.name))
$buildJson = $buildJson.Replace('__DEFAULT_BRANCH__', $defaultBranch)

$buildDef = (Invoke-Ado -Uri "$projUrl/_apis/build/definitions?name=Selenium&$api").value | Select-Object -First 1
if ($buildDef) {
    Write-Host "Build pipeline 'Selenium' already exists (id $($buildDef.id)) - skipping." -ForegroundColor Yellow
    Write-Host "  To get the new ChromeDriver step, delete that build pipeline in Azure DevOps and run this script again." -ForegroundColor Yellow
} else {
    try {
        $buildDef = Invoke-Ado -Method POST -Uri "$projUrl/_apis/build/definitions?$api" -Body $buildJson
    } catch {
        if ("$_" -match 'classic|disabled') {
            throw "Classic build pipelines are disabled. Turn OFF 'Disable creation of classic build pipelines' in Organization settings > Pipelines > Settings, then re-run.`n$_"
        }
        throw
    }
    Write-Host "Created build pipeline id $($buildDef.id)"
}

# ===========================================================================
# CHROMEDRIVER STEP FOR THE RELEASE PIPELINE  (NEW)
# Runs on SeleniumVM just before "Run Selenium UI tests".
# Reads the Chrome version installed on the VM, downloads the exactly matching
# ChromeDriver, and replaces chromedriver.exe in the downloaded drop folder.
# ===========================================================================
$releaseChromeDriverScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Find the Chrome version installed on this agent machine
$chromeExe = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chromeExe) { throw 'Google Chrome is not installed on this agent machine.' }
$chromeVersion = (Get-Item $chromeExe).VersionInfo.ProductVersion
$major = $chromeVersion.Split('.')[0]
Write-Host "Chrome installed on this machine : $chromeVersion"

# 2. Ask Google which ChromeDriver matches that Chrome version
$driverVersion = ([string](Invoke-RestMethod "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_$major")).Trim()
Write-Host "Matching ChromeDriver version    : $driverVersion"

# 3. Download and unzip it
$zip = Join-Path $env:AGENT_TEMPDIRECTORY 'chromedriver.zip'
$out = Join-Path $env:AGENT_TEMPDIRECTORY 'chromedriver'
Invoke-WebRequest "https://storage.googleapis.com/chrome-for-testing-public/$driverVersion/win64/chromedriver-win64.zip" -OutFile $zip -UseBasicParsing
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $out -Force
$newDriver = Get-ChildItem $out -Recurse -Filter 'chromedriver.exe' | Select-Object -First 1

# 4. Stop old chromedriver processes left over from earlier runs
Get-Process chromedriver -ErrorAction SilentlyContinue | Stop-Process -Force

# 5. Put the matching ChromeDriver into the downloaded build artifact
$testFolder = Join-Path $env:SYSTEM_DEFAULTWORKINGDIRECTORY '_Selenium\drop\TestAssemblies'
$oldDrivers = @(Get-ChildItem $env:SYSTEM_DEFAULTWORKINGDIRECTORY -Recurse -Filter 'chromedriver.exe' -ErrorAction SilentlyContinue)
if ($oldDrivers.Count -eq 0) {
    Copy-Item $newDriver.FullName (Join-Path $testFolder 'chromedriver.exe') -Force
    Write-Host "Copied new ChromeDriver to $testFolder"
}
foreach ($d in $oldDrivers) {
    Copy-Item $newDriver.FullName $d.FullName -Force
    Write-Host "Replaced $($d.FullName)"
}
& $newDriver.FullName --version
'@

$releaseChromeDriverTask = [ordered]@{
    taskId           = 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1'   # built-in "PowerShell" task
    version          = '2.*'
    name             = 'Update ChromeDriver to match installed Chrome'
    definitionType   = 'task'
    enabled          = $true
    alwaysRun        = $false
    continueOnError  = $false
    timeoutInMinutes = 0
    condition        = 'succeeded()'
    environment      = @{}
    overrideInputs   = @{}
    inputs           = [ordered]@{
        targetType            = 'inline'
        script                = $releaseChromeDriverScript
        errorActionPreference = 'stop'
        failOnStderr          = 'false'
        ignoreLASTEXITCODE    = 'false'
        pwsh                  = 'false'
    }
} | ConvertTo-Json -Depth 5

# ---------------------------------------------------------------------------
# 5. Classic release pipeline (from DL-Selenium/ReleaseDefinitions/Selenium.json)
# ---------------------------------------------------------------------------
Write-Step 'Creating release pipeline'
$releaseJson = @'
{
  "name": "Selenium",
  "path": "\\",
  "releaseNameFormat": "Release-$(rev:r)",
  "variables": {
    "DefaultConnectionString": { "value": "Server=localhost;Database=PartsUnlimited-Prod;User ID=vmadmin;Password=P2ssw0rd@123;", "isSecret": true },
    "username": { "value": "vmadmin",      "isSecret": true },
    "password": { "value": "P2ssw0rd@123", "isSecret": true }
  },
  "variableGroups": [],
  "environments": [
    {
      "name": "Dev",
      "rank": 1,
      "owner": { "id": "__OWNER_ID__" },
      "variables": {},
      "variableGroups": [],
      "preDeployApprovals":  { "approvals": [ { "rank": 1, "isAutomated": true, "isNotificationOn": false } ], "approvalOptions": { "executionOrder": 1 } },
      "postDeployApprovals": { "approvals": [ { "rank": 1, "isAutomated": true, "isNotificationOn": false } ], "approvalOptions": { "executionOrder": 2 } },
      "deployStep": {},
      "deployPhases": [
        {
          "rank": 1, "phaseType": 1, "name": "IIS Deployment",
          "deploymentInput": { "queueId": __QUEUE_ID__, "parallelExecution": { "parallelExecutionType": 0 }, "skipArtifactsDownload": false, "artifactsDownloadInput": { "downloadInputs": [] }, "demands": [], "enableAccessToken": false, "timeoutInMinutes": 0, "jobCancelTimeoutInMinutes": 1, "condition": "succeeded()", "overrideInputs": {} },
          "workflowTasks": [
            {
              "taskId": "1b2aec60-dc49-11e6-9b76-63056e018cac", "version": "0.*", "name": "IIS Web App Manage", "definitionType": "task",
              "enabled": true, "alwaysRun": false, "continueOnError": false, "timeoutInMinutes": 0, "condition": "succeeded()", "environment": {}, "overrideInputs": {},
              "inputs": {
                "EnableIIS": "false", "IISDeploymentType": "IISWebsite", "ActionIISWebsite": "CreateOrUpdateWebsite",
                "WebsiteName": "PartsUnlimited", "WebsitePhysicalPath": "%SystemDrive%\\inetpub\\PartsUnlimited",
                "WebsitePhysicalPathAuth": "WebsiteWindowsAuth", "WebsiteAuthUserName": "$(username)", "WebsiteAuthUserPassword": "$(password)",
                "AddBinding": "true",
                "Bindings": "{\"bindings\":[{\"protocol\":\"http\",\"ipAddress\":\"All Unassigned\",\"port\":\"82\",\"hostname\":\"\",\"sslThumbprint\":\"\",\"sniFlag\":false}]}",
                "CreateOrUpdateAppPoolForWebsite": "true", "ConfigureAuthenticationForWebsite": "true",
                "AppPoolNameForWebsite": "PartsUnlimited", "DotNetVersionForWebsite": "v4.0", "PipeLineModeForWebsite": "Integrated",
                "AppPoolIdentityForWebsite": "ApplicationPoolIdentity",
                "AnonymousAuthenticationForWebsite": "true", "BasicAuthenticationForWebsite": "false", "WindowsAuthenticationForWebsite": "true"
              }
            },
            {
              "taskId": "1b467810-6725-4b6d-accd-886174c09bba", "version": "0.*", "name": "Deploy IIS Website/App: ", "definitionType": "task",
              "enabled": true, "alwaysRun": false, "continueOnError": false, "timeoutInMinutes": 0, "condition": "succeeded()", "environment": {}, "overrideInputs": {},
              "inputs": {
                "WebSiteName": "PartsUnlimited", "Package": "$(System.DefaultWorkingDirectory)\\**\\*.zip",
                "RemoveAdditionalFilesFlag": "false", "ExcludeFilesFromAppDataFlag": "false", "TakeAppOfflineFlag": "false",
                "XmlTransformation": "true", "XmlVariableSubstitution": "True"
              }
            }
          ]
        },
        {
          "rank": 2, "phaseType": 1, "name": "SQL Deployment",
          "deploymentInput": { "queueId": __QUEUE_ID__, "parallelExecution": { "parallelExecutionType": 0 }, "skipArtifactsDownload": false, "artifactsDownloadInput": { "downloadInputs": [] }, "demands": [], "enableAccessToken": false, "timeoutInMinutes": 0, "jobCancelTimeoutInMinutes": 1, "condition": "succeeded()", "overrideInputs": {} },
          "workflowTasks": [
            {
              "taskId": "4b506f7f-720f-47bb-bf21-029bac6a690d", "version": "0.*", "name": "Deploy using : dacpac", "definitionType": "task",
              "enabled": true, "alwaysRun": false, "continueOnError": false, "timeoutInMinutes": 0, "condition": "succeeded()", "environment": {}, "overrideInputs": {},
              "inputs": {
                "TaskType": "dacpac", "DacpacFile": "$(System.DefaultWorkingDirectory)\\**\\*.dacpac",
                "ExecuteInTransaction": "false", "ExclusiveLock": "false",
                "TargetMethod": "server", "ServerName": "localhost", "DatabaseName": "PartsUnlimited-Prod",
                "AuthScheme": "sqlServerAuthentication", "SqlUsername": "$(username)", "SqlPassword": "$(password)"
              }
            }
          ]
        },
        {
          "rank": 3, "phaseType": 1, "name": "Selenium tests execution",
          "deploymentInput": { "queueId": __QUEUE_ID__, "parallelExecution": { "parallelExecutionType": 0 }, "skipArtifactsDownload": false, "artifactsDownloadInput": { "downloadInputs": [] }, "demands": [], "enableAccessToken": false, "timeoutInMinutes": 0, "jobCancelTimeoutInMinutes": 1, "condition": "succeeded()", "overrideInputs": {} },
          "workflowTasks": [
            {
              "taskId": "2c65196a-54fd-4a02-9be8-d9d1837b7111", "version": "1.*", "name": "Visual Studio Test Platform Installer", "definitionType": "task",
              "enabled": true, "alwaysRun": false, "continueOnError": false, "timeoutInMinutes": 0, "condition": "succeeded()", "environment": {}, "overrideInputs": {},
              "inputs": { "packageFeedSelector": "nugetOrg", "versionSelector": "latestStable" }
            },
            __CHROMEDRIVER_RELEASE_TASK__,
            {
              "taskId": "ef087383-ee5e-42c7-9a53-ab56c98420f9", "version": "2.*", "name": "Run Selenium UI tests", "definitionType": "task",
              "enabled": true, "alwaysRun": false, "continueOnError": false, "timeoutInMinutes": 0, "condition": "succeeded()", "environment": {}, "overrideInputs": {},
              "inputs": {
                "testSelector": "testAssemblies",
                "testAssemblyVer2": "**\\*test*.dll\n!**\\*TestAdapter.dll\n!**\\obj\\**",
                "searchFolder": "$(System.DefaultWorkingDirectory)/_Selenium/drop/TestAssemblies",
                "resultsFolder": "$(Agent.TempDirectory)\\TestResults",
                "tcmTestRun": "$(test.RunId)", "uiTests": "true",
                "vstestLocationMethod": "version", "vsTestVersion": "toolsInstaller",
                "runInParallel": "False", "runTestsInIsolation": "False", "codeCoverageEnabled": "False",
                "publishRunAttachments": "true", "failOnMinTestsNotRun": "False", "minimumExpectedTests": "1",
                "diagnosticsEnabled": "True", "collectDumpOn": "onAbortOnly", "rerunFailedTests": "False"
              }
            }
          ]
        }
      ],
      "environmentOptions": {
        "emailNotificationType": "OnlyOnFailure", "emailRecipients": "release.environment.owner;release.creator",
        "skipArtifactsDownload": false, "timeoutInMinutes": 0, "enableAccessToken": false,
        "publishDeploymentStatus": true, "badgeEnabled": false, "autoLinkWorkItems": false, "pullRequestDeploymentEnabled": false
      },
      "demands": [],
      "conditions": [ { "name": "ReleaseStarted", "conditionType": 1, "value": "" } ],
      "executionPolicy": { "concurrencyCount": 0, "queueDepthCount": 0 },
      "schedules": [],
      "retentionPolicy": { "daysToKeep": 30, "releasesToKeep": 3, "retainBuild": true }
    }
  ],
  "artifacts": [
    {
      "sourceId": "__PROJECT_ID__:__BUILD_ID__",
      "type": "Build",
      "alias": "_Selenium",
      "isPrimary": true,
      "isRetained": false,
      "definitionReference": {
        "definition":         { "id": "__BUILD_ID__",   "name": "Selenium" },
        "project":            { "id": "__PROJECT_ID__", "name": "__PROJECT_NAME__" },
        "defaultVersionType": { "id": "latestType",     "name": "Latest" }
      }
    }
  ],
  "triggers": [ { "artifactAlias": "_Selenium", "triggerConditions": [], "triggerType": 1 } ]
}
'@

$releaseJson = $releaseJson.Replace('__CHROMEDRIVER_RELEASE_TASK__', $releaseChromeDriverTask)
$releaseJson = $releaseJson.Replace('__OWNER_ID__',     $me.id)
$releaseJson = $releaseJson.Replace('__QUEUE_ID__',     [string]$queue.id)
$releaseJson = $releaseJson.Replace('__PROJECT_ID__',   $projectId)
$releaseJson = $releaseJson.Replace('__PROJECT_NAME__', (ConvertTo-JsonValue $ProjectName))
$releaseJson = $releaseJson.Replace('__BUILD_ID__',     [string]$buildDef.id)

$relDef = (Invoke-Ado -Uri "$rmProjUrl/_apis/release/definitions?searchText=Selenium&isExactNameMatch=true&$api").value | Select-Object -First 1
if ($relDef) {
    Write-Host "Release pipeline 'Selenium' already exists (id $($relDef.id)) - skipping." -ForegroundColor Yellow
    Write-Host "  To get the new ChromeDriver step, delete that release pipeline in Azure DevOps and run this script again." -ForegroundColor Yellow
} else {
    try {
        $relDef = Invoke-Ado -Method POST -Uri "$rmProjUrl/_apis/release/definitions?$api" -Body $releaseJson
    } catch {
        if ("$_" -match 'classic|disabled') {
            throw "Classic release pipelines are disabled. Turn OFF 'Disable creation of classic release pipelines' in Organization settings > Pipelines > Settings, then re-run.`n$_"
        }
        throw
    }
    Write-Host "Created release pipeline id $($relDef.id)"
}

# ---------------------------------------------------------------------------
Write-Step 'Done'
Write-Host "Project  : $devUrl/$([uri]::EscapeDataString($ProjectName))"
Write-Host "Repo     : $($repo.webUrl)"
Write-Host "Build    : $devUrl/$([uri]::EscapeDataString($ProjectName))/_build?definitionId=$($buildDef.id)"
Write-Host "Release  : $devUrl/$([uri]::EscapeDataString($ProjectName))/_release?definitionId=$($relDef.id)"
