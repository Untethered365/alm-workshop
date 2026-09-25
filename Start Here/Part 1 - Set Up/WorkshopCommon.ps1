# Shared helpers for the self-service ALM workshop scripts.
# Dot-source this file; it is not meant to be run on its own.
#
# Everything here runs as the ATTENDEE, in their own tenant. All tokens come from a
# single Azure CLI sign-in (Graph, Power Platform, Dataverse, Azure DevOps). The PAC CLI
# isn't used: its environment creation is broken (see New-DeveloperEnvironment).
#
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads non-ASCII characters
# in files without a BOM.

$script:AdoResource = '499b84ac-1321-427f-aa17-267ca6975798'
$script:PowerPlatformResource = 'https://service.powerapps.com/'
$script:BapBase = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:StateFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'my-alm-setup.json'
$script:DeveloperEnvironmentLimit = 3
# Public client used for username/password sign-ins (the Azure CLI's own app ID)
$script:AzureCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'

# Web request progress bars leave blank lines behind in the output and slow requests down
$ProgressPreference = 'SilentlyContinue'

# Entra ID built-in role template IDs (identical in every tenant)
$script:RoleIds = @{
    GlobalAdministrator          = '62e90394-69f5-4237-9190-012177145e10'
    UserAdministrator            = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
    ApplicationAdministrator     = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
    CloudApplicationAdministrator = '158c047a-c907-4556-b7ef-446551a6b5f7'
    ApplicationDeveloper         = 'cf1c38e5-3621-4004-a7cb-879624dced7c'
    PowerPlatformAdministrator   = '11648597-926c-4cf3-9c36-bcebb0ba8dcc'
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
function Write-Section($text)
{
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
    Write-Host " $text" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
}

function Write-Step($text) { Write-Host "  $text" }
function Write-Ok($text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Bad($text)  { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Warn($text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Write-Hint($text) { Write-Host "         $text" -ForegroundColor Gray }

function Get-ErrorText($err)
{
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { return $err.ErrorDetails.Message }
    return $err.Exception.Message
}

# ---------------------------------------------------------------------------
# Tools and sign-in
# ---------------------------------------------------------------------------
function Test-WorkshopTools
{
    $ok = $true
    if (Get-Command az -ErrorAction SilentlyContinue) { Write-Ok "Azure CLI is installed" }
    else
    {
        Write-Bad "Azure CLI is not installed"
        Write-Hint "Install it from https://aka.ms/installazurecliwindows then open a NEW PowerShell window"
        $ok = $false
    }
    return $ok
}

# Runs the Azure CLI and returns its output, or $null if it failed. Use this for every az call:
# under Windows PowerShell 5.1 with $ErrorActionPreference = 'Stop', anything az writes to
# stderr (even a harmless warning) is turned into a script-ending error, 2>$null or not.
function Invoke-Az
{
    $ErrorActionPreference = 'Continue'
    $out = & az @args 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

# Same, parsed from JSON (az ... -o json)
function Invoke-AzJson
{
    $out = Invoke-Az @args
    if (-not $out) { return $null }
    return (($out | Out-String) | ConvertFrom-Json)
}

# Signs in to Azure CLI (tenant-level, no subscription needed) and returns the account.
# Reuses a saved session unless -SwitchAccount is passed, or the session has expired
# (for example Microsoft wants MFA again) - then it opens the sign-in page.
function Connect-WorkshopAzure([switch]$SwitchAccount, [string]$TenantId, [switch]$UseDeviceCode)
{
    $ErrorActionPreference = 'Continue'
    $account = $null
    if (-not $SwitchAccount) { $account = Invoke-AzJson account show -o json }
    if ($account -and $TenantId -and $account.tenantId -ne $TenantId) { $account = $null }
    if ($account -and -not (Invoke-Az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv))
    {
        Write-Step "Your saved sign-in for $($account.user.name) has expired."
        if (-not $TenantId) { $TenantId = $account.tenantId }
        $account = $null
    }

    if (-not $account)
    {
        Write-Step "Opening the Microsoft sign-in page for Azure CLI..."
        Write-Hint "The browser window can open BEHIND this one - check your taskbar."
        $loginArgs = @('login', '--allow-no-subscriptions', '--only-show-errors', '-o', 'none')
        if ($TenantId) { $loginArgs += @('--tenant', $TenantId) }
        if ($UseDeviceCode) { $loginArgs += '--use-device-code' }
        & az @loginArgs
        if ($LASTEXITCODE -ne 0) { throw "Azure CLI sign-in did not complete." }

        # An account that can see several tenants must pick one explicitly
        if (-not $TenantId)
        {
            $tenants = @(Invoke-AzJson account tenant list -o json | ForEach-Object { $_ })
            if ($tenants.Count -gt 1)
            {
                Write-Host ""
                Write-Host "  Your account can see more than one tenant. Which one is for this workshop?"
                for ($i = 0; $i -lt $tenants.Count; $i++)
                {
                    $label = $tenants[$i].displayName
                    if (-not $label) { $label = $tenants[$i].defaultDomain }
                    Write-Host ("    [{0}] {1}  ({2})" -f ($i + 1), $label, $tenants[$i].defaultDomain)
                }
                $choice = 0
                while ($choice -lt 1 -or $choice -gt $tenants.Count)
                {
                    $answer = Read-Host "  Enter a number"
                    [int]::TryParse($answer, [ref]$choice) | Out-Null
                }
                $picked = $tenants[$choice - 1].tenantId
                $account = Invoke-AzJson account show -o json
                if (-not $account -or $account.tenantId -ne $picked)
                {
                    $loginArgs = @('login', '--allow-no-subscriptions', '--only-show-errors', '-o', 'none', '--tenant', $picked)
                    if ($UseDeviceCode) { $loginArgs += '--use-device-code' }
                    & az @loginArgs
                    if ($LASTEXITCODE -ne 0) { throw "Azure CLI sign-in to the selected tenant did not complete." }
                }
            }
        }
        $account = Invoke-AzJson account show -o json
    }
    if (-not $account) { throw "Azure CLI is not signed in." }
    return $account
}

# ---------------------------------------------------------------------------
# REST helpers (tokens all come from the Azure CLI sign-in)
# ---------------------------------------------------------------------------
function Get-WorkshopToken($resource)
{
    $token = Invoke-Az account get-access-token --resource $resource --query accessToken -o tsv
    if (-not $token) { throw "Could not get an access token for $resource. Your sign-in may have expired - run the script again, or add -SwitchAccount." }
    return $token
}

function Invoke-WorkshopRest($Method, $Uri, $Resource, $Body = $null, $ExtraHeaders = @{}, $Token = $null)
{
    if (-not $Token) { $Token = Get-WorkshopToken $Resource }
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body)
    {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
        $params.ContentType = 'application/json'
    }
    elseif ($Method -ne 'GET')
    {
        # Without this, PowerShell labels a body-less POST as a form post, which Azure DevOps rejects
        $params.Body = ''
        $params.ContentType = 'application/json'
    }
    return Invoke-RestMethod @params
}

function Invoke-Graph($Method, $Path, $Body = $null)
{
    return Invoke-WorkshopRest $Method "https://graph.microsoft.com/v1.0$Path" 'https://graph.microsoft.com' $Body
}

function Invoke-Ado($Method, $Uri, $Body = $null)
{
    return Invoke-WorkshopRest $Method $Uri $script:AdoResource $Body
}

# ---------------------------------------------------------------------------
# Entra ID
# ---------------------------------------------------------------------------
function Get-MyActiveRoleIds
{
    $roles = Invoke-Graph GET "/me/transitiveMemberOf/microsoft.graph.directoryRole?`$select=displayName,roleTemplateId"
    return @($roles.value | ForEach-Object { $_.roleTemplateId })
}

# Roles the user could activate through Privileged Identity Management but has not.
# Returns $null when the tenant or the user cannot read this (common, not an error).
function Get-MyEligibleRoleIds($userId)
{
    try
    {
        $r = Invoke-Graph GET "/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=principalId eq '$userId'"
        return @($r.value | ForEach-Object { $_.roleDefinitionId })
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Power Platform
# ---------------------------------------------------------------------------
# Environments the signed-in user can see, flattened to the fields the scripts use.
# -Admin lists every environment in the tenant (needs an admin), including ones owned by the
# hotfix service account. (Listing AS a brand-new service account fails with CRMRequestFailed 404.)
function Get-MyEnvironments([switch]$Admin)
{
    $scope = if ($Admin) { '/scopes/admin' } else { '' }
    $r = Invoke-WorkshopRest GET "$($script:BapBase)$scope/environments?api-version=2020-10-01" $script:PowerPlatformResource
    return @($r.value | ForEach-Object {
        $p = $_.properties
        $owner = $null
        if ($p.usedBy) { $owner = $p.usedBy.id } elseif ($p.createdBy) { $owner = $p.createdBy.id }
        [PSCustomObject]@{
            Id          = $_.name
            DisplayName = $p.displayName
            Sku         = $p.environmentSku
            OwnerId     = $owner
            Url         = if ($p.linkedEnvironmentMetadata) { $p.linkedEnvironmentMetadata.instanceUrl } else { $null }
            State       = if ($p.linkedEnvironmentMetadata) { $p.linkedEnvironmentMetadata.instanceState } else { $null }
            Provisioning = $p.provisioningState
            HasDataverse = [bool]($p.linkedEnvironmentMetadata -and $p.linkedEnvironmentMetadata.instanceUrl)
        }
    })
}

function Get-TenantPowerPlatformSettings
{
    try
    {
        return Invoke-WorkshopRest POST "$($script:BapBase)/listTenantSettings?api-version=2020-10-01" $script:PowerPlatformResource @{}
    }
    catch { return $null }
}

# Creates a Developer environment (without a database yet - add one with Add-DataverseDatabase)
# and returns its ID. Uses the Power Platform API directly because 'pac admin create --type Developer'
# fails with "macroRegion '<region>' is not valid" (PAC CLI 2.4 through 2.12, September 2026): the
# service now wants a macroRegion instead of a location for Developer environments.
function New-DeveloperEnvironment($displayName, $region, $Token = $null)
{
    # Only unitedstates -> north-america is confirmed; other regions try the old form first
    $macroRegions = @{ unitedstates = 'north-america' }
    $attempts = @()
    if ($macroRegions.ContainsKey($region)) { $attempts += @{ macroRegion = $macroRegions[$region] } }
    else { $attempts += @{ location = $region }; $attempts += @{ macroRegion = $region } }

    $lastError = $null
    foreach ($where in $attempts)
    {
        $body = @{ properties = @{ displayName = $displayName; environmentSku = 'Developer' } }
        foreach ($k in $where.Keys) { $body[$k] = $where[$k] }
        try
        {
            $created = Invoke-WorkshopRest POST "$($script:BapBase)/environments?api-version=2020-10-01" $script:PowerPlatformResource $body -Token $Token
            return $created.name
        }
        catch { $lastError = Get-ErrorText $_ }
    }
    throw $lastError
}

function Rename-WorkshopEnvironment($environmentId, $newName)
{
    Invoke-WorkshopRest PATCH "$($script:BapBase)/scopes/admin/environments/$($environmentId)?api-version=2020-10-01" $script:PowerPlatformResource @{ properties = @{ displayName = $newName } } | Out-Null
}

# Adds a Dataverse database to an environment that doesn't have one (the "Add Dataverse"
# button in the admin center; same call as New-AdminPowerAppCdsDatabase). Runs in the background.
function Add-DataverseDatabase($environmentId, $Token = $null)
{
    $body = @{ baseLanguage = 1033; currency = @{ code = 'USD' }; templates = @() }
    Invoke-WorkshopRest POST "$($script:BapBase)/environments/$($environmentId)/provisionInstance?api-version=2018-01-01" $script:PowerPlatformResource $body -Token $Token | Out-Null
}

# Waits until an environment (matched by ID if given, otherwise by display name) has a ready Dataverse database.
# -DatabaseRequested: a database was just requested, so don't treat "no database yet" as a failure.
function Wait-EnvironmentReady($displayName, $timeoutMinutes = 20, $EnvironmentId = $null, [switch]$DatabaseRequested, [switch]$Admin)
{
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $noDatabaseChecks = 0
    while ((Get-Date) -lt $deadline)
    {
        if ($EnvironmentId) { $env = Get-MyEnvironments -Admin:$Admin | Where-Object { $_.Id -eq $EnvironmentId } | Select-Object -First 1 }
        else { $env = Get-MyEnvironments -Admin:$Admin | Where-Object { $_.DisplayName -eq $displayName } | Select-Object -First 1 }
        if ($env -and $env.Url -and $env.State -eq 'Ready' -and $env.Provisioning -eq 'Succeeded') { return $env }
        # Finished provisioning but still no database after a few checks means it never will - stop waiting
        if ($env -and $env.Provisioning -match 'Failed') { throw "Environment '$($env.DisplayName)' is in a failed state ($($env.Provisioning)). Check it at https://admin.powerplatform.microsoft.com." }
        if (-not $DatabaseRequested -and $env -and $env.Provisioning -eq 'Succeeded' -and -not $env.HasDataverse) { $noDatabaseChecks++ } else { $noDatabaseChecks = 0 }
        if ($noDatabaseChecks -ge 6)
        {
            throw "Environment '$($env.DisplayName)' has no Dataverse database. Delete it at https://admin.powerplatform.microsoft.com (Manage > Environments), then run this script again so it can be recreated with one."
        }
        Write-Step "  Waiting for $displayName to be ready..."
        Start-Sleep -Seconds 30
    }
    throw "Environment $displayName was not ready after $timeoutMinutes minutes."
}

# Registers an Entra ID application as a Dataverse application user with System Administrator.
# Uses the Dataverse REST API directly because pac admin assign-user --application-user has a known
# NullReferenceException bug in PAC CLI 2.4.x when the app user does not yet exist in the environment.
# $fallbackUpn/$fallbackPassword are used when the signed-in user has no role in the environment
# (the hotfix environments, which the service account owns).
function Add-SPNToDataverseEnvironment($envUrl, $appId, $fallbackUpn = "", $fallbackPassword = "", $tenantId = "")
{
    $resource = $envUrl.TrimEnd('/')

    $workingToken = $null
    $myToken = Invoke-Az account get-access-token --resource $resource --query accessToken -o tsv
    if ($myToken)
    {
        try
        {
            $testHeaders = @{ Authorization = "Bearer $myToken"; Accept = "application/json"; "OData-MaxVersion" = "4.0"; "OData-Version" = "4.0" }
            Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers?`$select=systemuserid&`$top=1" -Headers $testHeaders -ErrorAction Stop | Out-Null
            $workingToken = $myToken
        }
        catch { Write-Step "  You don't have a role in $envUrl yet - using the fallback account" }
    }

    if (-not $workingToken -and $fallbackUpn -and $fallbackPassword -and $tenantId)
    {
        $workingToken = Get-PasswordToken $resource $fallbackUpn $fallbackPassword $tenantId
    }
    if (-not $workingToken) { throw "Could not get a working Dataverse access token for $resource" }

    $headers = @{
        Authorization      = "Bearer $workingToken"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        "Content-Type"     = "application/json"
    }

    $existing = Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers?`$filter=applicationid eq '$appId'&`$select=systemuserid" -Headers $headers -ErrorAction Stop
    if ($existing.value.Count -gt 0)
    {
        $sysUserId = $existing.value[0].systemuserid
        Write-Step "  Application user already exists"
    }
    else
    {
        $bu = Invoke-RestMethod -Uri "$resource/api/data/v9.2/businessunits?`$filter=parentbusinessunitid eq null&`$select=businessunitid" -Headers $headers -ErrorAction Stop
        $buId = $bu.value[0].businessunitid

        $createHeaders = $headers.Clone()
        $createHeaders["Prefer"] = "return=representation"
        $body = @{ applicationid = $appId; "businessunitid@odata.bind" = "/businessunits($buId)" } | ConvertTo-Json
        $created = Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers?`$select=systemuserid" -Method POST -Headers $createHeaders -Body $body -ErrorAction Stop
        $sysUserId = $created.systemuserid
        Write-Step "  Created application user"
    }

    Grant-SystemAdministrator $resource $headers $sysUserId
    return $sysUserId
}

function Grant-SystemAdministrator($resource, $headers, $sysUserId)
{
    $roles = Invoke-RestMethod -Uri "$resource/api/data/v9.2/roles?`$filter=name eq 'System Administrator' and _parentroleid_value eq null&`$select=roleid" -Headers $headers -ErrorAction Stop
    $roleId = $roles.value[0].roleid

    $currentRoles = Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers($sysUserId)/systemuserroles_association?`$select=name" -Headers $headers -ErrorAction Stop
    if (-not ($currentRoles.value | Where-Object { $_.name -eq "System Administrator" }))
    {
        $roleRef = @{ "@odata.id" = "$resource/api/data/v9.2/roles($roleId)" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers($sysUserId)/systemuserroles_association/`$ref" -Method POST -Headers $headers -Body $roleRef -ErrorAction Stop | Out-Null
        Write-Step "  Granted System Administrator"
    }
    else { Write-Step "  System Administrator already assigned" }
}

# Username/password token for an account with no MFA (the hotfix service account).
function Get-PasswordToken($resource, $upn, $password, $tenantId, $ClientId = "1950a258-227b-4e31-a9cf-717495945fc2")
{
    $tokenBody = @{
        grant_type = "password"
        username   = $upn
        password   = $password
        client_id  = $ClientId
        scope      = "$resource/.default"
    }
    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -ErrorAction Stop
    return $tokenResponse.access_token
}

# Adds an Entra ID user to a Dataverse environment as System Administrator.
# The user is synced in with the Power Platform admin "addUser" call (needs you to be an admin):
# a user record created directly in Dataverse stays DISABLED and can't be given a role.
# The role is then assigned with $token, which must have admin rights in the environment
# (the hotfix service account owns those environments).
function Add-EntraUserToDataverse($envUrl, $envId, $userObjectId, $token)
{
    $resource = $envUrl.TrimEnd('/')
    Invoke-WorkshopRest POST "$($script:BapBase)/scopes/admin/environments/$envId/addUser?api-version=2020-10-01" $script:PowerPlatformResource @{ ObjectId = $userObjectId } | Out-Null

    $headers = @{
        Authorization      = "Bearer $token"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        "Content-Type"     = "application/json"
    }
    $dvUser = $null
    for ($i = 0; $i -lt 12 -and -not $dvUser; $i++)
    {
        $r = Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers?`$filter=azureactivedirectoryobjectid eq $userObjectId&`$select=systemuserid,isdisabled" -Headers $headers -ErrorAction Stop
        $dvUser = $r.value | Where-Object { -not $_.isdisabled } | Select-Object -First 1
        if (-not $dvUser) { Write-Step "  Waiting for the user to finish syncing..."; Start-Sleep -Seconds 10 }
    }
    if (-not $dvUser) { throw "User $userObjectId didn't appear as an enabled user in $envUrl" }
    Grant-SystemAdministrator $resource $headers $dvUser.systemuserid
}

# $true/$false for Microsoft's tenant-wide "security defaults" (which enforce MFA), $null if unreadable.
function Get-SecurityDefaultsEnabled
{
    try { return [bool](Invoke-Graph GET "/policies/identitySecurityDefaultsEnforcementPolicy").isEnabled }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Azure DevOps
# ---------------------------------------------------------------------------
# The tenant an Azure DevOps org is connected to. Returned by the service on any request,
# signed in or not. Empty/all-zero means the org is not connected to Entra ID.
function Get-AdoOrgTenant($orgName)
{
    $value = $null
    try
    {
        $r = Invoke-WebRequest -Uri "https://dev.azure.com/$orgName/_apis/connectionData" -Method Head -UseBasicParsing -ErrorAction Stop
        $value = $r.Headers['X-VSS-ResourceTenant']
    }
    catch
    {
        $resp = $_.Exception.Response
        if ($resp)
        {
            try { $value = $resp.Headers['X-VSS-ResourceTenant'] } catch { }
            if (-not $value) { try { $value = @($resp.Headers.GetValues('X-VSS-ResourceTenant'))[0] } catch { } }
        }
    }
    if ($value -is [array]) { $value = $value[0] }
    return "$value"
}

# Azure DevOps orgs the signed-in user belongs to, split by whether they are in this tenant.
function Get-MyAdoOrganizations($tenantId)
{
    $me = Invoke-Ado GET "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1"
    $accounts = Invoke-Ado GET "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$($me.id)&api-version=7.1"
    $result = @()
    foreach ($a in @($accounts.value))
    {
        $orgTenant = Get-AdoOrgTenant $a.accountName
        $result += [PSCustomObject]@{
            Name         = $a.accountName
            TenantId     = $orgTenant
            InThisTenant = ($orgTenant -match [regex]::Escape($tenantId))
        }
    }
    return $result
}

