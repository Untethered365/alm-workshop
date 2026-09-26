# Adds the hotfix environments on top of the core workshop setup.
#
# Everyone can own at most 3 Developer environments, and the core workshop uses
# all three (DEV, TEST, PROD). So the two hotfix environments are owned by a
# separate SERVICE ACCOUNT that this script creates. The hotfix pipeline also signs
# in as that account with a username and password, so it must not require MFA.
#
#   1. Service account (Entra ID user) with a Power Apps Developer Plan license
#   2. HFXDEV and HFXTEST Developer environments, created BY the service account
#      (so they count against its 3 slots, not yours)
#   3. YOU and your pipeline service principal as System Administrator in both
#
# It does NOT create Azure DevOps service connections or variable groups - you
# build those in the hotfix lessons. It prints the values you'll need.
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
$mfaVideo = 'https://youtu.be/JyYZGscr5lU'

# ---------------------------------------------------------------------------
Write-Section "1. Sign-in and core setup"
# ---------------------------------------------------------------------------
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
Write-Ok "Found your core setup (service principal $($state.AppName))"

$prefix = $state.Prefix
$me = Invoke-Graph GET "/me?`$select=id"
$activeRoles = @(Get-MyActiveRoleIds)
$R = $script:RoleIds
if (-not (($activeRoles -contains $R.GlobalAdministrator) -or ($activeRoles -contains $R.UserAdministrator)))
{
    Write-Bad "The hotfix course needs you to create a user account (the service account)."
    Write-Hint "Missing: 'User Administrator' role in Entra ID (or Global Administrator)."
    Write-Hint "Run Test-Readiness.ps1 in the 'Part 1 - Set Up' folder for a message you can send your IT admin."
    exit 1
}
Write-Ok "You can create the service account"

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
$state.ServiceAccountObjectId = $svcUser.id
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

# ---------------------------------------------------------------------------
Write-Section "3. Service account can sign in without MFA"
# ---------------------------------------------------------------------------
# The hotfix pipeline signs in as the service account with just a password, and so
# does this script. Anything that forces MFA on that account breaks both.
$securityDefaults = Get-SecurityDefaultsEnabled

$svcBapToken = $null
$lastError = $null
$attempts = if ($newAccount) { 8 } else { 1 }
for ($i = 1; $i -le $attempts -and -not $svcBapToken; $i++)
{
    try { $svcBapToken = Get-PasswordToken 'https://service.powerapps.com/' $svcUpn $state.ServiceAccountPassword $tenantId -ClientId $script:AzureCliClientId }
    catch
    {
        $lastError = Get-ErrorText $_
        if ($lastError -match 'AADSTS500(76|79)|AADSTS50158|multi-factor|MFA') { break }
        if ($i -lt $attempts) { Write-Step "  New account not ready to sign in yet - waiting 15 seconds..."; Start-Sleep -Seconds 15 }
    }
}

if (-not $svcBapToken)
{
    if ($lastError -match 'AADSTS500(76|79)|AADSTS50158|multi-factor|MFA')
    {
        Write-Bad "The service account is being asked for MFA, so it can't sign in with just a password."
        if ($securityDefaults) { Write-Hint "Your tenant has 'security defaults' turned on, which forces MFA." }
        Write-Hint "Own workshop tenant: turn off security defaults (Entra admin center > Overview > Properties >"
        Write-Hint "  Manage security defaults > Disabled). This video walks through it: $mfaVideo"
        Write-Hint "Company tenant: ask IT to exclude $svcUpn from MFA with a Conditional Access policy."
        Write-Hint "Then run this script again."
    }
    else
    {
        Write-Bad "The service account couldn't sign in: $lastError"
        Write-Hint "Run this script again in a few minutes - new accounts can take a while to be ready."
    }
    exit 1
}
Write-Ok "Service account signs in with its password"
# The Azure CLI sign-in usually isn't allowed to read the security defaults setting ($null),
# so unless we know it's off, remind people - it can pass today and break in two weeks.
if ($securityDefaults -ne $false)
{
    Write-Warn "Sign-in works today, but if MFA is still enforced on this account (for example by"
    Write-Hint "'security defaults'), Microsoft starts demanding MFA setup after about 14 days and the"
    Write-Hint "hotfix pipeline will fail. If you haven't yet, do Step 1 in this folder's README:"
    Write-Hint "  own tenant: turn off security defaults ($mfaVideo)"
    Write-Hint "  company tenant: ask IT to exclude $svcUpn from MFA"
}

# ---------------------------------------------------------------------------
Write-Section "4. Hotfix environments (owned by the service account)"
# ---------------------------------------------------------------------------
# List with your admin view; create as the service account so it owns them
$svcEnvs = @(Get-MyEnvironments -Admin | Where-Object { $_.OwnerId -eq $svcUser.id })
$hotfixEnvs = @()
foreach ($suffix in $envSuffixes)
{
    $name = "$prefix-$suffix"
    $existing = $svcEnvs | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1
    $databaseRequested = $false
    if ($existing)
    {
        if (-not $existing.HasDataverse -and $existing.Provisioning -eq 'Succeeded')
        {
            Write-Step "$name has no Dataverse database - adding one (usually 2-5 minutes)..."
            Add-DataverseDatabase $existing.Id -Token $svcBapToken
            $databaseRequested = $true
        }
        else { Write-Ok "$name already exists - reusing it" }
        $envId = $existing.Id
    }
    else
    {
        $owned = @($svcEnvs | Where-Object { $_.Sku -eq 'Developer' }).Count
        if ($owned -ge $script:DeveloperEnvironmentLimit)
        {
            Write-Bad "Can't create $name - the service account already owns $owned Developer environments (the limit)."
            exit 1
        }
        Write-Step "Creating $name in $Region as the service account, then adding its database - usually 2-5 minutes..."
        try
        {
            $envId = New-DeveloperEnvironment $name $Region -Token $svcBapToken
            Add-DataverseDatabase $envId -Token $svcBapToken
        }
        catch
        {
            Write-Bad "Couldn't create $($name): $(Get-ErrorText $_)"
            exit 1
        }
        Write-Ok "Created $name"
        $databaseRequested = $true
    }
    $ready = Wait-EnvironmentReady $name -EnvironmentId $envId -DatabaseRequested:$databaseRequested -Admin
    $hotfixEnvs += $ready
    $svcEnvs = @(Get-MyEnvironments -Admin | Where-Object { $_.OwnerId -eq $svcUser.id })
}
$state.HotfixEnvironments = @($hotfixEnvs | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Id = $_.Id; Url = $_.Url } })
Save-State

# ---------------------------------------------------------------------------
Write-Section "5. You and your service principal as System Administrator"
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
    # The service account owns the environment, so act as it to let everyone else in
    $svcDvToken = Get-PasswordToken $e.Url.TrimEnd('/') $svcUpn $state.ServiceAccountPassword $tenantId -ClientId $script:AzureCliClientId

    $ok = Invoke-WithRetry "Adding you" { Add-EntraUserToDataverse $e.Url $e.Id $me.id $svcDvToken }
    if (-not $ok) { Write-Bad "Couldn't add you to $($e.DisplayName). Run this script again in a few minutes."; exit 1 }

    $ok = Invoke-WithRetry "Adding the service principal" { Add-SPNToDataverseEnvironment $e.Url $state.AppId $svcUpn $state.ServiceAccountPassword $tenantId | Out-Null }
    if (-not $ok) { Write-Bad "Couldn't add the service principal to $($e.DisplayName). Run this script again in a few minutes."; exit 1 }
    Write-Ok "$($e.DisplayName) done"
}

# ---------------------------------------------------------------------------
Write-Section "Done - values for the hotfix lessons"
# ---------------------------------------------------------------------------
Save-State
Write-Host ""
foreach ($e in $hotfixEnvs)
{
    Write-Host "  $($e.DisplayName)" -ForegroundColor Green
    Write-Host "    BuildTools.EnvironmentUrl  $($e.Url)"
    Write-Host "    EnvironmentID              $($e.Id)"
}
Write-Host ""
Write-Host "  Service account (for the username/password service connection):" -ForegroundColor Green
Write-Host "    Username  $svcUpn"
Write-Host "    Password  saved in my-alm-setup.json (ServiceAccountPassword)"
Write-Host ""
Write-Host "  Next: the hotfix lessons have you create the service connections and variable groups." -ForegroundColor Yellow
Write-Host "  Keep my-alm-setup.json private - it holds the service account password and client secret." -ForegroundColor Yellow
