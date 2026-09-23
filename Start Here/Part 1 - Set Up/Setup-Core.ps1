# Sets up everything for the core ALM workshop in YOUR tenant, as YOU:
#
#   1. DEV, TEST and PROD Developer environments (only the ones you don't have yet)
#   2. An app registration + service principal for your pipelines, with a secret
#   3. That service principal as System Administrator in all three environments
#   4. An Azure DevOps project with the Power Platform Build Tools and one
#      service connection per environment
#
# Safe to run again: every step checks what already exists and skips it.
# Your details (environment URLs, app ID, secret) are saved to ..\my-alm-setup.json.
#
#   .\Setup-Core.ps1
#   .\Setup-Core.ps1 -Region europe          # environments outside the US
#   .\Setup-Core.ps1 -SwitchAccount          # sign in with a different account

[CmdletBinding()]
param(
    [string]$Prefix = 'ALM',

    [string]$Region = 'unitedstates',

    [string]$AdoOrganization,

    [string]$ProjectName = 'ALM-Workshop',

    [string]$AppName = 'ALM-Workshop-Pipelines',

    [string]$TenantId,

    [switch]$SwitchAccount,

    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkshopCommon.ps1')

$envSuffixes = @('DEV', 'TEST', 'PROD')

# ---------------------------------------------------------------------------
Write-Section "1. Tools and sign-in"
# ---------------------------------------------------------------------------
if (-not (Test-WorkshopTools)) { exit 1 }

$account = Connect-WorkshopAzure -SwitchAccount:$SwitchAccount -TenantId $TenantId -UseDeviceCode:$UseDeviceCode
$tenantId = $account.tenantId
$upn = $account.user.name
Write-Ok "Signed in as $upn (tenant $tenantId)"

if (-not (Connect-WorkshopPac -TenantId $tenantId -UseDeviceCode:$UseDeviceCode))
{
    Write-Bad "Power Platform CLI isn't signed in to the same tenant. Run: pac auth create --tenant $tenantId"
    exit 1
}
Write-Ok "Power Platform CLI is signed in to the same tenant"

$me = Invoke-Graph GET "/me?`$select=id,userPrincipalName"
$tenantShort = Get-TenantShortName

$state = [ordered]@{}
if (Test-Path $script:StateFile)
{
    $saved = Get-Content $script:StateFile -Raw | ConvertFrom-Json
    if ($saved.TenantId -eq $tenantId) { foreach ($p in $saved.PSObject.Properties) { $state[$p.Name] = $p.Value } }
    else { Write-Warn "Ignoring my-alm-setup.json - it's from a different tenant" }
}
$state.TenantId = $tenantId
$state.SignedInAs = $upn
$state.Prefix = $Prefix

function Save-State { $state | ConvertTo-Json -Depth 10 | Set-Content -Path $script:StateFile -Encoding UTF8 }

# ---------------------------------------------------------------------------
Write-Section "2. Azure DevOps organization"
# ---------------------------------------------------------------------------
if (-not $AdoOrganization -and $state.AdoOrganization) { $AdoOrganization = $state.AdoOrganization }
$org = Select-AdoOrganization $tenantId $AdoOrganization
$orgUrl = "https://dev.azure.com/$org"
$state.AdoOrganization = $org
Save-State

# ---------------------------------------------------------------------------
Write-Section "3. Power Platform environments"
# ---------------------------------------------------------------------------
$environments = @(Get-MyEnvironments)
$workshopEnvs = @()
foreach ($suffix in $envSuffixes)
{
    $name = "$Prefix-$suffix"
    $existing = $environments | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1
    if ($existing)
    {
        Write-Ok "$name already exists - reusing it"
    }
    else
    {
        $owned = @($environments | Where-Object { $_.Sku -eq 'Developer' -and $_.OwnerId -eq $me.id }).Count
        if ($owned -ge $script:DeveloperEnvironmentLimit)
        {
            Write-Bad "Can't create $name - you already own $owned Developer environments (the limit)."
            Write-Hint "Delete one at https://admin.powerplatform.microsoft.com, then run this script again."
            exit 1
        }

        $domain = Get-EnvironmentDomain $tenantShort $Prefix $suffix
        Write-Step "Creating $name ($domain) in $Region - this usually takes 2-5 minutes..."
        $out = pac admin create --name $name --type Developer --domain $domain --region $Region 2>&1 | Out-String
        if ($out -match 'Error:')
        {
            Write-Bad "Couldn't create $name"
            Write-Hint ($out.Trim())
            Write-Hint "Run .\Test-Readiness.ps1 to see what's missing."
            exit 1
        }
        Write-Ok "Created $name"
        $environments = @(Get-MyEnvironments)
    }
    $workshopEnvs += (Wait-EnvironmentReady $name)
}

$state.Environments = @($workshopEnvs | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Id = $_.Id; Url = $_.Url } })
Save-State
foreach ($e in $workshopEnvs) { Write-Hint "$($e.DisplayName): $($e.Url)" }

# ---------------------------------------------------------------------------
Write-Section "4. App registration (service principal) for your pipelines"
# ---------------------------------------------------------------------------
$app = az ad app list --display-name $AppName -o json 2>$null | ConvertFrom-Json | ForEach-Object { $_ } | Select-Object -First 1
$newlyCreated = $false
if ($app)
{
    Write-Ok "App registration '$AppName' already exists (app ID $($app.appId))"
}
else
{
    Write-Step "Creating app registration '$AppName'..."
    $app = az ad app create --display-name $AppName -o json 2>$null | ConvertFrom-Json
    if (-not $app -or -not $app.appId)
    {
        Write-Bad "Couldn't create the app registration. You may not have permission - run .\Test-Readiness.ps1."
        exit 1
    }
    Write-Ok "Created app registration (app ID $($app.appId))"
    $newlyCreated = $true
}

$sp = az ad sp show --id $app.appId -o json 2>$null | ConvertFrom-Json
if (-not $sp)
{
    $sp = az ad sp create --id $app.appId -o json 2>$null | ConvertFrom-Json
    if (-not $sp) { Write-Bad "Couldn't create the service principal."; exit 1 }
    Write-Ok "Created service principal"
    $newlyCreated = $true
}
else { Write-Ok "Service principal already exists" }

# Reuse the saved secret if it belongs to this app; otherwise add a new one (old ones keep working)
if ($state.AppId -eq $app.appId -and $state.ClientSecret)
{
    Write-Ok "Reusing the secret saved in my-alm-setup.json (expires $($state.ClientSecretExpires))"
}
else
{
    Write-Step "Creating a client secret (valid for 1 year)..."
    $secret = az ad app credential reset --id $app.appId --append --display-name "ALM workshop" --years 1 -o json 2>$null | ConvertFrom-Json
    if (-not $secret -or -not $secret.password) { Write-Bad "Couldn't create a client secret."; exit 1 }
    $state.ClientSecret = $secret.password
    $state.ClientSecretExpires = (Get-Date).AddYears(1).ToString('yyyy-MM-dd')
    Write-Ok "Created client secret"
}
$state.AppName = $AppName
$state.AppId = $app.appId
$state.ServicePrincipalObjectId = $sp.id
Save-State

if ($newlyCreated)
{
    Write-Step "Waiting 60 seconds for the new service principal to reach Dataverse..."
    Start-Sleep -Seconds 60
}

# ---------------------------------------------------------------------------
Write-Section "5. Service principal as System Administrator in each environment"
# ---------------------------------------------------------------------------
foreach ($e in $workshopEnvs)
{
    Write-Step "$($e.DisplayName)"
    $done = $false
    for ($attempt = 1; $attempt -le 5 -and -not $done; $attempt++)
    {
        try
        {
            Add-SPNToDataverseEnvironment $e.Url $app.appId | Out-Null
            $done = $true
        }
        catch
        {
            Write-Warn "Attempt $attempt of 5 failed: $(Get-ErrorText $_)"
            if ($attempt -lt 5) { Start-Sleep -Seconds 30 }
        }
    }
    if (-not $done) { Write-Bad "Couldn't add the service principal to $($e.DisplayName). Run this script again in a few minutes."; exit 1 }
    Write-Ok "$($e.DisplayName) done"
}

# ---------------------------------------------------------------------------
Write-Section "6. Azure DevOps project"
# ---------------------------------------------------------------------------
$project = $null
try { $project = Invoke-Ado GET "$orgUrl/_apis/projects/$([uri]::EscapeDataString($ProjectName))?api-version=7.1" } catch { }
if ($project)
{
    Write-Ok "Project '$ProjectName' already exists"
}
else
{
    Write-Step "Creating project '$ProjectName'..."
    $processes = Invoke-Ado GET "$orgUrl/_apis/process/processes?api-version=7.1"
    $process = @($processes.value | Where-Object { $_.name -eq 'Agile' }) + @($processes.value | Where-Object { $_.isDefault }) | Select-Object -First 1
    $body = @{
        name         = $ProjectName
        description  = 'Power Platform ALM workshop'
        visibility   = 'private'
        capabilities = @{
            versioncontrol  = @{ sourceControlType = 'Git' }
            processTemplate = @{ templateTypeId = $process.id }
        }
    }
    try { $op = Invoke-Ado POST "$orgUrl/_apis/projects?api-version=7.1" $body }
    catch { Write-Bad "Couldn't create the project: $(Get-ErrorText $_)"; exit 1 }

    $deadline = (Get-Date).AddMinutes(5)
    do
    {
        Start-Sleep -Seconds 5
        $op = Invoke-Ado GET "$orgUrl/_apis/operations/$($op.id)?api-version=7.1"
    } while ($op.status -notin @('succeeded', 'failed', 'cancelled') -and (Get-Date) -lt $deadline)
    if ($op.status -ne 'succeeded') { Write-Bad "Project creation ended with status '$($op.status)'."; exit 1 }

    $project = Invoke-Ado GET "$orgUrl/_apis/projects/$([uri]::EscapeDataString($ProjectName))?api-version=7.1"
    Write-Ok "Created project '$ProjectName'"
}
$state.AdoProject = $ProjectName
$state.AdoProjectUrl = "$orgUrl/$([uri]::EscapeDataString($ProjectName))"
Save-State

# ---------------------------------------------------------------------------
Write-Section "7. Power Platform Build Tools and service connections"
# ---------------------------------------------------------------------------
$extUrl = "https://extmgmt.dev.azure.com/$org/_apis/extensionmanagement/installedextensionsbyname/microsoft-IsvExpTools/PowerPlatform-BuildTools?api-version=7.1-preview.1"
$extInstalled = $false
try { Invoke-Ado GET $extUrl | Out-Null; $extInstalled = $true; Write-Ok "Power Platform Build Tools are already installed" } catch { }
if (-not $extInstalled)
{
    try
    {
        Invoke-Ado POST $extUrl | Out-Null
        $extInstalled = $true
        Write-Ok "Installed Power Platform Build Tools"
    }
    catch
    {
        Write-Warn "Couldn't install Power Platform Build Tools: $(Get-ErrorText $_)"
        Write-Hint "Install it by hand: https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.PowerPlatform-BuildTools"
        Write-Hint "Then run this script again to create the service connections."
    }
}

$connectionProblems = 0
if ($extInstalled)
{
    foreach ($e in $workshopEnvs)
    {
        $connName = $e.DisplayName
        $existing = Invoke-Ado GET "$orgUrl/$($project.id)/_apis/serviceendpoint/endpoints?endpointNames=$([uri]::EscapeDataString($connName))&api-version=7.1-preview.4"
        if (@($existing.value).Count -gt 0)
        {
            Write-Ok "Service connection '$connName' already exists"
            continue
        }
        $body = @{
            name          = $connName
            type          = 'powerplatform-spn'
            url           = $e.Url
            description   = "Service principal $AppName -> $($e.DisplayName)"
            authorization = @{
                scheme     = 'None'
                parameters = @{ tenantId = $tenantId; applicationId = $app.appId; clientSecret = $state.ClientSecret }
            }
            isShared      = $false
            isReady       = $true
            serviceEndpointProjectReferences = @(@{ projectReference = @{ id = $project.id; name = $project.name }; name = $connName })
        }
        try
        {
            $endpoint = Invoke-Ado POST "$orgUrl/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4" $body
            # Let every pipeline in the project use it, so nobody gets stuck on an approval prompt
            try { Invoke-Ado PATCH "$orgUrl/$($project.id)/_apis/pipelines/pipelinePermissions/endpoint/$($endpoint.id)?api-version=7.1-preview.1" @{ allPipelines = @{ authorized = $true } } | Out-Null } catch { }
            Write-Ok "Created service connection '$connName'"
        }
        catch
        {
            $connectionProblems++
            Write-Warn "Couldn't create service connection '$connName': $(Get-ErrorText $_)"
        }
    }
}
if ($connectionProblems -gt 0 -or -not $extInstalled)
{
    Write-Hint "You can create service connections by hand: Project settings > Service connections > New > Power Platform."
    Write-Hint "Use the tenant ID, app ID and secret from my-alm-setup.json."
}

# ---------------------------------------------------------------------------
Write-Section "Done"
# ---------------------------------------------------------------------------
Save-State
Write-Host ""
Write-Host "  Your environments:" -ForegroundColor Green
foreach ($e in $workshopEnvs) { Write-Host "    $($e.DisplayName)  $($e.Url)" }
Write-Host "  Azure DevOps project: $($state.AdoProjectUrl)" -ForegroundColor Green
Write-Host "  Service principal:    $AppName (app ID $($app.appId))" -ForegroundColor Green
Write-Host ""
Write-Host "  Everything (including the client secret) is saved in:" -ForegroundColor Yellow
Write-Host "    $($script:StateFile)" -ForegroundColor Yellow
Write-Host "  Keep that file private - the secret gives full access to your environments." -ForegroundColor Yellow
