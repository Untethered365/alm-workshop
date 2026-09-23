# Read-only check: "Am I ready for the ALM workshop?"
#
# Signs you in, then checks your permissions in Entra ID, Power Platform and
# Azure DevOps. It does NOT create or change anything.
#
#   .\Test-Readiness.ps1                  # uses your current sign-in, or opens one
#   .\Test-Readiness.ps1 -SwitchAccount   # sign in with a different account
#
# Every problem it finds is listed at the end, with what to ask your IT admin for.

[CmdletBinding()]
param(
    [string]$Prefix = 'ALM',

    [string]$AdoOrganization,

    [string]$TenantId,

    [switch]$SwitchAccount,

    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkshopCommon.ps1')

$results = @()
function Add-Result($area, $status, $text, $fix = $null, $forIt = $null, [switch]$HotfixOnly)
{
    $script:results += [PSCustomObject]@{ Area = $area; Status = $status; Text = $text; Fix = $fix; ForIt = $forIt; HotfixOnly = [bool]$HotfixOnly }
    switch ($status)
    {
        'OK'   { Write-Ok $text }
        'FAIL' { Write-Bad $text }
        'WARN' { Write-Warn $text }
    }
    if ($fix) { Write-Hint $fix }
}

# ---------------------------------------------------------------------------
Write-Section "1. Tools"
# ---------------------------------------------------------------------------
if (-not (Test-WorkshopTools))
{
    Write-Host ""
    Write-Host "  Install the missing tools, then run this check again." -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
Write-Section "2. Sign-in"
# ---------------------------------------------------------------------------
$account = Connect-WorkshopAzure -SwitchAccount:$SwitchAccount -TenantId $TenantId -UseDeviceCode:$UseDeviceCode
$tenantId = $account.tenantId
$upn = $account.user.name
Write-Ok "Azure CLI signed in as $upn"
Write-Hint "Tenant: $tenantId"

if ($upn -match '#EXT#' -or $upn -match '@(outlook|hotmail|live|gmail|yahoo)\.')
{
    Add-Result 'Sign-in' 'FAIL' "You're signed in with a personal or guest account ($upn)." `
        "Create a work account inside your tenant (README: 'Create your work account') and sign in with that, using -SwitchAccount."
}

if (Connect-WorkshopPac -TenantId $tenantId -UseDeviceCode:$UseDeviceCode)
{
    Add-Result 'Sign-in' 'OK' "Power Platform CLI is signed in to the same tenant"
}
else
{
    Add-Result 'Sign-in' 'FAIL' "Power Platform CLI is not signed in to tenant $tenantId." `
        "Run: pac auth create --tenant $tenantId   (sign in with $upn)"
}

$me = Invoke-Graph GET "/me?`$select=id,displayName,userPrincipalName"
$activeRoles = @(Get-MyActiveRoleIds)
$eligibleRoles = Get-MyEligibleRoleIds $me.id
$R = $script:RoleIds

function Test-HasRole([string[]]$ids) { foreach ($id in $ids) { if ($activeRoles -contains $id) { return $true } }; return $false }
function Test-EligibleRole([string[]]$ids) { if ($null -eq $eligibleRoles) { return $false }; foreach ($id in $ids) { if ($eligibleRoles -contains $id) { return $true } }; return $false }

$isGlobalAdmin = Test-HasRole @($R.GlobalAdministrator)
if ($isGlobalAdmin) { Write-Ok "You are a Global Administrator" }

# ---------------------------------------------------------------------------
Write-Section "3. Entra ID (app registration for your pipelines)"
# ---------------------------------------------------------------------------
$appRoles = @($R.GlobalAdministrator, $R.ApplicationAdministrator, $R.CloudApplicationAdministrator, $R.ApplicationDeveloper)
if (Test-HasRole $appRoles)
{
    Add-Result 'Entra ID' 'OK' "You can create app registrations"
}
else
{
    $usersCanRegister = $null
    try
    {
        $policy = Invoke-Graph GET "/policies/authorizationPolicy"
        if ($policy.value) { $policy = $policy.value[0] }
        $usersCanRegister = $policy.defaultUserRolePermissions.allowedToCreateApps
    }
    catch { }

    if ($usersCanRegister -eq $true)
    {
        Add-Result 'Entra ID' 'OK' "You can create app registrations (your tenant allows all users to)"
    }
    elseif (Test-EligibleRole $appRoles)
    {
        Add-Result 'Entra ID' 'FAIL' "You have an app-registration role, but it isn't switched on right now." `
            "Activate it in Privileged Identity Management (https://aka.ms/pim), then run this check again."
    }
    elseif ($usersCanRegister -eq $false)
    {
        Add-Result 'Entra ID' 'FAIL' "You can't create app registrations in this tenant." `
            $null "The 'Application Developer' role (or Application Administrator) in Entra ID"
    }
    else
    {
        Add-Result 'Entra ID' 'WARN' "Couldn't confirm whether you can create app registrations." `
            "Your account isn't allowed to read that setting. Setup will stop with a clear error if you can't."
    }
}

# ---------------------------------------------------------------------------
Write-Section "4. Power Platform (your DEV, TEST and PROD environments)"
# ---------------------------------------------------------------------------
$envNames = @('DEV', 'TEST', 'PROD') | ForEach-Object { "$Prefix-$_" }
$environments = @()
try { $environments = @(Get-MyEnvironments) }
catch
{
    Add-Result 'Power Platform' 'FAIL' "Couldn't read your Power Platform environments: $(Get-ErrorText $_)" `
        "Sign in once at https://make.powerapps.com with $upn, then run this check again."
}

$alreadyThere = @($environments | Where-Object { $envNames -contains $_.DisplayName })
$myDeveloperEnvs = @($environments | Where-Object { $_.Sku -eq 'Developer' -and $_.OwnerId -eq $me.id })
$needed = $envNames.Count - $alreadyThere.Count
$free = $script:DeveloperEnvironmentLimit - $myDeveloperEnvs.Count

foreach ($e in $alreadyThere) { Write-Ok "$($e.DisplayName) already exists - setup will reuse it" }

if ($needed -eq 0)
{
    Add-Result 'Power Platform' 'OK' "All three workshop environments already exist"
}
elseif ($free -ge $needed)
{
    Add-Result 'Power Platform' 'OK' "You have room for $needed more Developer environment(s) ($($myDeveloperEnvs.Count) of $($script:DeveloperEnvironmentLimit) used)"
}
else
{
    $list = ($myDeveloperEnvs | ForEach-Object { $_.DisplayName }) -join ', '
    Add-Result 'Power Platform' 'FAIL' "You need $needed more Developer environment(s) but only have $([Math]::Max($free,0)) free (limit is $($script:DeveloperEnvironmentLimit) per person)." `
        "Delete $($needed - [Math]::Max($free,0)) you no longer need at https://admin.powerplatform.microsoft.com. Yours: $list"
}

$isPowerPlatformAdmin = $isGlobalAdmin -or (Test-HasRole @($R.PowerPlatformAdministrator))
$settings = Get-TenantPowerPlatformSettings
if ($settings -and $settings.powerPlatform.governance.disableDeveloperEnvironmentCreationByNonAdminUsers -eq $true -and -not $isPowerPlatformAdmin)
{
    Add-Result 'Power Platform' 'FAIL' "Your tenant only lets admins create Developer environments." `
        $null "Either the 'Power Platform Administrator' role, or for an admin to allow Developer environment creation for everyone (Power Platform admin center > Settings > Tenant settings > Developer environment assignments)"
}
elseif (-not $settings -and -not $isPowerPlatformAdmin -and $needed -gt 0)
{
    Add-Result 'Power Platform' 'WARN' "Couldn't read whether your tenant allows non-admins to create Developer environments." `
        "Most tenants allow it. Setup will tell you if yours doesn't."
}
elseif ($needed -gt 0)
{
    Add-Result 'Power Platform' 'OK' "You're allowed to create Developer environments"
}

try
{
    $licenses = Invoke-Graph GET "/me/licenseDetails?`$select=skuPartNumber"
    if (@($licenses.value | Where-Object { $_.skuPartNumber -eq 'POWERAPPS_DEV' }).Count -gt 0)
    {
        Add-Result 'Power Platform' 'OK' "You have the Power Apps Developer Plan"
    }
    else
    {
        Add-Result 'Power Platform' 'WARN' "You don't have the Power Apps Developer Plan yet." `
            "Sign up (free) at https://aka.ms/PowerAppsDevPlan with $upn. Some tenants create Developer environments without it."
    }
}
catch { Add-Result 'Power Platform' 'WARN' "Couldn't read your licenses." }

# ---------------------------------------------------------------------------
Write-Section "5. Azure DevOps"
# ---------------------------------------------------------------------------
try
{
    $orgs = @(Get-MyAdoOrganizations $tenantId)
    $mine = @($orgs | Where-Object { $_.InThisTenant })
    if ($AdoOrganization) { $mine = @($mine | Where-Object { $_.Name -eq $AdoOrganization }) }

    if ($mine.Count -ge 1)
    {
        Add-Result 'Azure DevOps' 'OK' "Azure DevOps org(s) in this tenant: $(($mine | ForEach-Object { $_.Name }) -join ', ')"
    }
    else
    {
        Add-Result 'Azure DevOps' 'FAIL' "No Azure DevOps org connected to this tenant." `
            "Follow 'D. Create your Azure DevOps organization' in 'Part 1 - Set Up\README.md', including adding $upn to the org."
    }
    foreach ($o in ($orgs | Where-Object { -not $_.InThisTenant }))
    {
        Write-Hint "(Ignoring '$($o.Name)' - it belongs to a different tenant.)"
    }
}
catch
{
    Add-Result 'Azure DevOps' 'FAIL' "Couldn't reach Azure DevOps: $(Get-ErrorText $_)" `
        "Sign in once at https://aex.dev.azure.com with $upn, then run this check again."
}

# ---------------------------------------------------------------------------
Write-Section "6. Hotfix course only (skip if you're not taking it)"
# ---------------------------------------------------------------------------
if (Test-HasRole @($R.GlobalAdministrator, $R.UserAdministrator))
{
    Add-Result 'Hotfix' 'OK' "You can create the service account" -HotfixOnly
}
else
{
    Add-Result 'Hotfix' 'WARN' "You can't create user accounts, which the hotfix course needs." `
        $null "The 'User Administrator' role in Entra ID (hotfix course only)" -HotfixOnly
}
if (-not $isPowerPlatformAdmin)
{
    Add-Result 'Hotfix' 'WARN' "You can't create environments owned by another account, which the hotfix course needs." `
        $null "The 'Power Platform Administrator' role (hotfix course only)" -HotfixOnly
}
try
{
    $skus = Invoke-Graph GET "/subscribedSkus?`$select=skuPartNumber,prepaidUnits,consumedUnits"
    $devSku = $skus.value | Where-Object { $_.skuPartNumber -eq 'POWERAPPS_DEV' } | Select-Object -First 1
    if ($devSku -and ($devSku.prepaidUnits.enabled - $devSku.consumedUnits) -gt 0)
    {
        Add-Result 'Hotfix' 'OK' "Developer Plan licenses are available for the service account" -HotfixOnly
    }
    else
    {
        Add-Result 'Hotfix' 'WARN' "No spare Developer Plan license for the service account." `
            "Signing up for the Developer Plan yourself (section 4) usually adds these to your tenant." -HotfixOnly
    }
}
catch { Add-Result 'Hotfix' 'WARN' "Couldn't read your tenant's licenses." -HotfixOnly }

# ---------------------------------------------------------------------------
Write-Section "Summary"
# ---------------------------------------------------------------------------
$core = @($results | Where-Object { -not $_.HotfixOnly })
$failures = @($core | Where-Object { $_.Status -eq 'FAIL' })
$warnings = @($core | Where-Object { $_.Status -eq 'WARN' })
$hotfixIssues = @($results | Where-Object { $_.HotfixOnly -and $_.Status -ne 'OK' })

if ($failures.Count -eq 0)
{
    Write-Host ""
    Write-Host "  You're ready for the core workshop." -ForegroundColor Green
    if ($warnings.Count -gt 0) { Write-Host "  ($($warnings.Count) warning(s) above - worth a read, but they won't stop you.)" -ForegroundColor Yellow }
    Write-Host "  Next: .\Setup-Core.ps1"
}
else
{
    Write-Host ""
    Write-Host "  Not ready yet - $($failures.Count) thing(s) to fix:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "   - $($f.Text)" -ForegroundColor Red }
}

$askIt = @($results | Where-Object { $_.ForIt -and $_.Status -ne 'OK' })
if ($askIt.Count -gt 0)
{
    Write-Host ""
    Write-Host "  ----- Copy this to your IT admin -----" -ForegroundColor Cyan
    Write-Host "  Hi, for a Power Platform ALM workshop I need the following for my account"
    Write-Host "  $upn in tenant $tenantId`:"
    foreach ($a in $askIt) { Write-Host "   - $($a.ForIt)" }
    Write-Host "  Thanks!"
    Write-Host "  --------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Can't get these? Create your own free tenant instead - you'll be its admin."
    Write-Host "  See 'Path 2' in the README."
}

if ($hotfixIssues.Count -gt 0 -and $failures.Count -eq 0)
{
    Write-Host ""
    Write-Host "  Taking the hotfix course too? Sort out the $($hotfixIssues.Count) hotfix warning(s) above first." -ForegroundColor Yellow
}

if ($failures.Count -gt 0) { exit 1 }
exit 0
