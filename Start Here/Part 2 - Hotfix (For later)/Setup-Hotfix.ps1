# Adds the hotfix environments on top of the core workshop setup.
#
# Everyone can own at most 3 Developer environments, and the core workshop uses
# all three (DEV, TEST, PROD). So the two hotfix environments are owned by a
# separate SERVICE ACCOUNT that this script creates:
#
#   1. Service account (Entra ID user) with a Power Apps Developer Plan license
#   2. HFXDEV and HFXTEST Developer environments, owned by the service account
#   3. YOU as System Administrator in both, so you can work in them
#   4. Your pipeline service principal (from the core setup) as System Administrator in both
#   5. Azure DevOps service connections for both
#
# Run Setup-Core.ps1 in the 'Part 1 - Set Up' folder first. Safe to run again.

[CmdletBinding()]
param(
    [string]$Region = 'unitedstates',

    [string]$ServiceAccountName = 'alm.serviceaccount',

    [string]$UsageLocation = 'US',

    [switch]$SwitchAccount,

    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Part 1 - Set Up\WorkshopCommon.ps1')

$envSuffixes = @('HFXDEV', 'HFXTEST')

# ---------------------------------------------------------------------------
Write-Section "1. Tools, sign-in and core setup"
# ---------------------------------------------------------------------------
if (-not (Test-WorkshopTools)) { exit 1 }

if (-not (Test-Path $script:StateFile))
{
    Write-Bad "Can't find my-alm-setup.json. Run Setup-Core.ps1 in the 'Part 1 - Set Up' folder first."
    exit 1
}
$saved = Get-Content $script:StateFile -Raw | ConvertFrom-Json
$state = [ordered]@{}
foreach ($p in $saved.PSObject.Properties) { $state[$p.Name] = $p.Value }
function Save-State { $state | ConvertTo-Json -Depth 10 | Set-Content -Path $script:StateFile -Encoding UTF8 }

if (-not $state.AppId -or -not $state.Environments)
{
    Write-Bad "The core setup didn't finish. Run Setup-Core.ps1 in the 'Part 1 - Set Up' folder again first."
    exit 1
}

$account = Connect-WorkshopAzure -SwitchAccount:$SwitchAccount -TenantId $state.TenantId -UseDeviceCode:$UseDeviceCode
$tenantId = $account.tenantId
$upn = $account.user.name
Write-Ok "Signed in as $upn (tenant $tenantId)"

if (-not (Connect-WorkshopPac -TenantId $tenantId -UseDeviceCode:$UseDeviceCode))
{
    Write-Bad "Power Platform CLI isn't signed in to the same tenant. Run: pac auth create --tenant $tenantId"
    exit 1
}
Write-Ok "Power Platform CLI is signed in to the same tenant"
Write-Ok "Found your core setup (service principal $($state.AppName))"

$prefix = $state.Prefix
$activeRoles = @(Get-MyActiveRoleIds)
$R = $script:RoleIds
$canCreateUsers = ($activeRoles -contains $R.GlobalAdministrator) -or ($activeRoles -contains $R.UserAdministrator)
$isPowerPlatformAdmin = ($activeRoles -contains $R.GlobalAdministrator) -or ($activeRoles -contains $R.PowerPlatformAdministrator)
if (-not $canCreateUsers -or -not $isPowerPlatformAdmin)
{
    Write-Bad "The hotfix course needs you to create a user and environments for that user."
    if (-not $canCreateUsers) { Write-Hint "Missing: 'User Administrator' role in Entra ID" }
    if (-not $isPowerPlatformAdmin) { Write-Hint "Missing: 'Power Platform Administrator' role" }
    Write-Hint "Run Test-Readiness.ps1 in the 'Part 1 - Set Up' folder for a message you can send your IT admin."
    exit 1
}
Write-Ok "You have the roles needed for the hotfix course"

# ---------------------------------------------------------------------------
Write-Section "2. Service account"
# ---------------------------------------------------------------------------
$domain = $upn.Split('@')[1]
$svcUpn = "$ServiceAccountName@$domain".ToLower()
$svcUser = $null
try { $svcUser = Invoke-Graph GET "/users/$([uri]::EscapeDataString($svcUpn))?`$select=id,userPrincipalName,usageLocation" } catch { }
$newAccount = $false

function New-ServiceAccountPassword
{
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $body = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    return "Hfx!$body#9"
}

if ($svcUser)
{
    Write-Ok "Service account $svcUpn already exists"
    if (-not $state.ServiceAccountPassword)
    {
        # Needed to act as the service account inside the environments it owns
        Write-Step "No saved password for it - setting a new one..."
        $state.ServiceAccountPassword = New-ServiceAccountPassword
        Invoke-Graph PATCH "/users/$($svcUser.id)" @{ passwordProfile = @{ password = $state.ServiceAccountPassword; forceChangePasswordNextSignIn = $false } } | Out-Null
        Write-Ok "Password reset"
    }
}
else
{
    Write-Step "Creating service account $svcUpn..."
    $state.ServiceAccountPassword = New-ServiceAccountPassword
    $svcUser = Invoke-Graph POST "/users" @{
        accountEnabled    = $true
        displayName       = 'ALM Service Account'
        mailNickname      = ($ServiceAccountName -replace '[^A-Za-z0-9]', '')
        userPrincipalName = $svcUpn
        usageLocation     = $UsageLocation
        passwordProfile   = @{ password = $state.ServiceAccountPassword; forceChangePasswordNextSignIn = $false }
    }
    Write-Ok "Created service account"
    $newAccount = $true
}
$state.ServiceAccount = $svcUpn
Save-State

if (-not $svcUser.usageLocation)
{
    Invoke-Graph PATCH "/users/$($svcUser.id)" @{ usageLocation = $UsageLocation } | Out-Null
}

# Developer Plan license - needed so the service account can own Developer environments
$svcLicenses = Invoke-Graph GET "/users/$($svcUser.id)/licenseDetails?`$select=skuPartNumber"
if (@($svcLicenses.value | Where-Object { $_.skuPartNumber -eq 'POWERAPPS_DEV' }).Count -gt 0)
{
    Write-Ok "Service account already has the Developer Plan"
}
else
{
    $skus = Invoke-Graph GET "/subscribedSkus?`$select=skuId,skuPartNumber"
    $devSku = $skus.value | Where-Object { $_.skuPartNumber -eq 'POWERAPPS_DEV' } | Select-Object -First 1
    if (-not $devSku)
    {
        Write-Bad "Your tenant has no Power Apps Developer Plan licenses to give the service account."
        Write-Hint "Sign in to https://aka.ms/PowerAppsDevPlan as $svcUpn (password in my-alm-setup.json),"
        Write-Hint "sign up for the Developer Plan, then run this script again."
        exit 1
    }
    Invoke-Graph POST "/users/$($svcUser.id)/assignLicense" @{ addLicenses = @(@{ skuId = $devSku.skuId }); removeLicenses = @() } | Out-Null
    Write-Ok "Assigned the Developer Plan to the service account"
}

if ($newAccount)
{
    Write-Step "Waiting 30 seconds for the new account to reach Power Platform..."
    Start-Sleep -Seconds 30
}

# ---------------------------------------------------------------------------
Write-Section "3. Hotfix environments (owned by the service account)"
# ---------------------------------------------------------------------------
# You can't see these through the normal list until you're added to them,
# so use the admin view from PAC CLI.
function Get-AdminEnvironment($name)
{
    $list = pac admin list --json 2>&1 | Out-String
    try { return (ConvertFrom-Json $list | ForEach-Object { $_ } | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1) }
    catch { return $null }
}

$tenantShort = Get-TenantShortName
$hotfixEnvs = @()
foreach ($suffix in $envSuffixes)
{
    $name = "$prefix-$suffix"
    $hf = Get-AdminEnvironment $name
    if ($hf)
    {
        Write-Ok "$name already exists - reusing it"
    }
    else
    {
        $envDomain = Get-EnvironmentDomain $tenantShort $prefix $suffix
        Write-Step "Creating $name ($envDomain) for the service account - this usually takes 2-5 minutes..."
        $out = pac admin create --name $name --type Developer --domain $envDomain --region $Region --user $svcUser.id 2>&1 | Out-String
        if ($out -match 'Error:')
        {
            Write-Bad "Couldn't create $name"
            Write-Hint ($out.Trim())
            exit 1
        }
        Write-Ok "Created $name"
        Write-Step "Waiting 30 seconds for Dataverse to finish provisioning..."
        Start-Sleep -Seconds 30
        $hf = Get-AdminEnvironment $name
        if (-not $hf) { Write-Bad "Created $name but can't find it yet. Run this script again in a few minutes."; exit 1 }
    }
    $hotfixEnvs += [PSCustomObject]@{ DisplayName = $hf.DisplayName; Id = $hf.EnvironmentId; Url = $hf.EnvironmentUrl }
}
$state.HotfixEnvironments = @($hotfixEnvs | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Id = $_.Id; Url = $_.Url } })
Save-State

# ---------------------------------------------------------------------------
Write-Section "4. You and your service principal as System Administrator"
# ---------------------------------------------------------------------------
function Invoke-WithRetry($label, [scriptblock]$action)
{
    for ($attempt = 1; $attempt -le 4; $attempt++)
    {
        try { & $action; return $true }
        catch
        {
            Write-Warn "$label - attempt $attempt of 4 failed: $(Get-ErrorText $_)"
            if ($attempt -lt 4) { Start-Sleep -Seconds 30 }
        }
    }
    return $false
}

foreach ($e in $hotfixEnvs)
{
    Write-Step "$($e.DisplayName)"
    $ok = Invoke-WithRetry "Adding you" { Add-UserToDataverseEnvironment $e.Url $upn $svcUpn $state.ServiceAccountPassword $tenantId }
    if (-not $ok) { Write-Bad "Couldn't add you to $($e.DisplayName). Run this script again in a few minutes."; exit 1 }

    $ok = Invoke-WithRetry "Adding the service principal" { Add-SPNToDataverseEnvironment $e.Url $state.AppId $svcUpn $state.ServiceAccountPassword $tenantId | Out-Null }
    if (-not $ok) { Write-Bad "Couldn't add the service principal to $($e.DisplayName). Run this script again in a few minutes."; exit 1 }
    Write-Ok "$($e.DisplayName) done"
}

# ---------------------------------------------------------------------------
Write-Section "5. Azure DevOps service connections"
# ---------------------------------------------------------------------------
$orgUrl = "https://dev.azure.com/$($state.AdoOrganization)"
$connectionProblems = 0
try { $project = Invoke-Ado GET "$orgUrl/_apis/projects/$([uri]::EscapeDataString($state.AdoProject))?api-version=7.1" }
catch { $project = $null }

if (-not $project -or -not $state.ClientSecret)
{
    Write-Warn "Skipping service connections - the core Azure DevOps project or secret isn't available."
    $connectionProblems++
}
else
{
    foreach ($e in $hotfixEnvs)
    {
        $connName = $e.DisplayName
        $existing = Invoke-Ado GET "$orgUrl/$($project.id)/_apis/serviceendpoint/endpoints?endpointNames=$([uri]::EscapeDataString($connName))&api-version=7.1-preview.4"
        if (@($existing.value).Count -gt 0) { Write-Ok "Service connection '$connName' already exists"; continue }
        $body = @{
            name          = $connName
            type          = 'powerplatform-spn'
            url           = $e.Url
            description   = "Service principal $($state.AppName) -> $connName"
            authorization = @{
                scheme     = 'None'
                parameters = @{ tenantId = $tenantId; applicationId = $state.AppId; clientSecret = $state.ClientSecret }
            }
            isShared      = $false
            isReady       = $true
            serviceEndpointProjectReferences = @(@{ projectReference = @{ id = $project.id; name = $project.name }; name = $connName })
        }
        try
        {
            $endpoint = Invoke-Ado POST "$orgUrl/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4" $body
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
if ($connectionProblems -gt 0)
{
    Write-Hint "You can create them by hand: Project settings > Service connections > New > Power Platform."
}

# ---------------------------------------------------------------------------
Write-Section "Done"
# ---------------------------------------------------------------------------
Save-State
Write-Host ""
Write-Host "  Hotfix environments:" -ForegroundColor Green
foreach ($e in $hotfixEnvs) { Write-Host "    $($e.DisplayName)  $($e.Url)" }
Write-Host "  Service account: $svcUpn" -ForegroundColor Green
Write-Host ""
Write-Host "  The service account password is saved in $($script:StateFile)." -ForegroundColor Yellow
Write-Host "  Keep that file private." -ForegroundColor Yellow
