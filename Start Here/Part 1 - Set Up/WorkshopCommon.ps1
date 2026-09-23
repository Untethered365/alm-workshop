# Shared helpers for the self-service ALM workshop scripts.
# Dot-source this file; it is not meant to be run on its own.
#
# Everything here runs as the ATTENDEE, in their own tenant. All tokens come from a
# single Azure CLI sign-in (Graph, Power Platform, Dataverse, Azure DevOps). PAC CLI
# is signed in separately; it adds users to environments owned by someone else (hotfix).
#
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads non-ASCII characters
# in files without a BOM.

$script:AdoResource = '499b84ac-1321-427f-aa17-267ca6975798'
$script:PowerPlatformResource = 'https://service.powerapps.com/'
$script:BapBase = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform'
$script:StateFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'my-alm-setup.json'
$script:DeveloperEnvironmentLimit = 3

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
    if (Get-Command pac -ErrorAction SilentlyContinue)
    {
        Write-Ok "Power Platform CLI (pac) is installed"
        # Old versions break as Microsoft's APIs change, so nudge people to stay current
        $installed = $null
        if ((pac 2>&1 | Out-String) -match 'Version:\s*(\d+\.\d+\.\d+)') { $installed = [version]$Matches[1] }
        $latest = $null
        try
        {
            $versions = (Invoke-RestMethod -Uri 'https://api.nuget.org/v3-flatcontainer/microsoft.powerapps.cli/index.json' -ErrorAction Stop).versions
            $latest = $versions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | ForEach-Object { [version]$_ } | Sort-Object | Select-Object -Last 1
        }
        catch { }
        if ($installed -and $latest -and $installed -lt $latest)
        {
            Write-Warn "Your Power Platform CLI is version $installed; the latest is $latest"
            Write-Hint "Update it with: pac install latest"
        }
    }
    else
    {
        Write-Bad "Power Platform CLI (pac) is not installed"
        Write-Hint "Install it from https://learn.microsoft.com/power-platform/developer/cli/introduction then open a NEW PowerShell window"
        $ok = $false
    }
    return $ok
}

# Signs in to Azure CLI (tenant-level, no subscription needed) and returns the account.
# If already signed in, reuses that session unless -SwitchAccount is passed.
function Connect-WorkshopAzure([switch]$SwitchAccount, [string]$TenantId, [switch]$UseDeviceCode)
{
    $account = $null
    if (-not $SwitchAccount) { $account = az account show -o json 2>$null | ConvertFrom-Json }
    if ($account -and $TenantId -and $account.tenantId -ne $TenantId) { $account = $null }

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
            $tenants = @(az account tenant list -o json 2>$null | ConvertFrom-Json | ForEach-Object { $_ })
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
                $account = az account show -o json 2>$null | ConvertFrom-Json
                if (-not $account -or $account.tenantId -ne $picked)
                {
                    $loginArgs = @('login', '--allow-no-subscriptions', '--only-show-errors', '-o', 'none', '--tenant', $picked)
                    if ($UseDeviceCode) { $loginArgs += '--use-device-code' }
                    & az @loginArgs
                    if ($LASTEXITCODE -ne 0) { throw "Azure CLI sign-in to the selected tenant did not complete." }
                }
            }
        }
        $account = az account show -o json 2>$null | ConvertFrom-Json
    }
    if (-not $account) { throw "Azure CLI is not signed in." }
    return $account
}

function Get-PacTenantId
{
    # pac always exits 0, so read the output instead of $LASTEXITCODE
    $who = pac auth who 2>&1 | Out-String
    if ($who -match 'Tenant Id:\s+([0-9a-fA-F-]{36})') { return $Matches[1] }
    return $null
}

# Makes sure PAC CLI is signed in to the same tenant as Azure CLI.
function Connect-WorkshopPac([string]$TenantId, [switch]$UseDeviceCode)
{
    $pacTenant = Get-PacTenantId
    if ($pacTenant -and $pacTenant -eq $TenantId) { return $true }

    if ($pacTenant) { Write-Step "PAC CLI is signed in to a different tenant ($pacTenant). Signing in again..." }
    else { Write-Step "Opening the Microsoft sign-in page for the Power Platform CLI..." }
    Write-Hint "Sign in with the SAME account you just used."

    $pacArgs = @('auth', 'create', '--tenant', $TenantId)
    if ($UseDeviceCode) { $pacArgs += '--deviceCode' }
    $out = & pac @pacArgs 2>&1 | Out-String
    if ($out -match 'Error:') { Write-Hint ($out.Trim()) }

    $pacTenant = Get-PacTenantId
    return ($pacTenant -eq $TenantId)
}

# ---------------------------------------------------------------------------
# REST helpers (tokens all come from the Azure CLI sign-in)
# ---------------------------------------------------------------------------
function Get-WorkshopToken($resource)
{
    $token = az account get-access-token --resource $resource --query accessToken -o tsv 2>$null
    if (-not $token) { throw "Could not get an access token for $resource. Try signing in again with -SwitchAccount." }
    return $token
}

function Invoke-WorkshopRest($Method, $Uri, $Resource, $Body = $null, $ExtraHeaders = @{})
{
    $headers = @{ Authorization = "Bearer $(Get-WorkshopToken $Resource)"; Accept = 'application/json' }
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

function Get-TenantShortName
{
    $org = Invoke-Graph GET "/organization?`$select=verifiedDomains"
    $initial = $org.value[0].verifiedDomains | Where-Object { $_.isInitial } | Select-Object -First 1
    return ($initial.name -split '\.')[0]
}

# ---------------------------------------------------------------------------
# Power Platform
# ---------------------------------------------------------------------------
# Environments the signed-in user can see, flattened to the fields the scripts use.
function Get-MyEnvironments
{
    $r = Invoke-WorkshopRest GET "$($script:BapBase)/environments?api-version=2020-10-01" $script:PowerPlatformResource
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

# Dataverse domain (the part before .crm.dynamics.com). Lowercase letters and digits only.
function Get-EnvironmentDomain($tenantShort, $prefix, $suffix)
{
    $clean = { param($s, $max) $v = ($s.ToLower() -replace '[^a-z0-9]', ''); if ($v.Length -gt $max) { $v.Substring(0, $max) } else { $v } }
    return (& $clean $tenantShort 8) + (& $clean $prefix 5) + (& $clean $suffix 7)
}

# Creates a Developer environment (without a database yet - add one with Add-DataverseDatabase)
# and returns its ID. Uses the Power Platform API directly because 'pac admin create --type Developer'
# fails with "macroRegion '<region>' is not valid" (PAC CLI 2.4 through 2.12, September 2026): the
# service now wants a macroRegion instead of a location for Developer environments.
function New-DeveloperEnvironment($displayName, $region)
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
            $created = Invoke-WorkshopRest POST "$($script:BapBase)/environments?api-version=2020-10-01" $script:PowerPlatformResource $body
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
function Add-DataverseDatabase($environmentId)
{
    $body = @{ baseLanguage = 1033; currency = @{ code = 'USD' }; templates = @() }
    Invoke-WorkshopRest POST "$($script:BapBase)/environments/$($environmentId)/provisionInstance?api-version=2018-01-01" $script:PowerPlatformResource $body | Out-Null
}

# Waits until an environment (matched by ID if given, otherwise by display name) has a ready Dataverse database.
# -DatabaseRequested: a database was just requested, so don't treat "no database yet" as a failure.
function Wait-EnvironmentReady($displayName, $timeoutMinutes = 20, $EnvironmentId = $null, [switch]$DatabaseRequested)
{
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $noDatabaseChecks = 0
    while ((Get-Date) -lt $deadline)
    {
        if ($EnvironmentId) { $env = Get-MyEnvironments | Where-Object { $_.Id -eq $EnvironmentId } | Select-Object -First 1 }
        else { $env = Get-MyEnvironments | Where-Object { $_.DisplayName -eq $displayName } | Select-Object -First 1 }
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
    $myToken = az account get-access-token --resource $resource --query accessToken -o tsv 2>$null
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

# Assigns a regular Entra ID user as System Administrator in a Dataverse environment.
# PAC CLI provisions the user; the REST API (as $fallbackUpn) finishes the role if PAC fails on that step.
function Add-UserToDataverseEnvironment($envUrl, $userUpn, $fallbackUpn, $fallbackPassword, $tenantId)
{
    $resource = $envUrl.TrimEnd('/')

    $pacOutput = pac admin assign-user --environment $resource --user $userUpn --role "System Administrator" 2>&1
    if (-not ($pacOutput -match "Error:"))
    {
        Write-Step "  Role assigned via PAC CLI"
        return
    }
    if (-not ($pacOutput -match "Successfully assigned user"))
    {
        throw "pac admin assign-user failed: $(($pacOutput | Where-Object { "$_" -match 'Error:' }) -join ' ')"
    }

    Write-Step "  User added but PAC CLI could not assign the role - finishing via the Dataverse API..."
    $token = Get-PasswordToken $resource $fallbackUpn $fallbackPassword $tenantId
    $headers = @{
        Authorization      = "Bearer $token"
        Accept             = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        "Content-Type"     = "application/json"
    }

    $dvUser = $null
    $attempts = 0
    while (-not $dvUser -and $attempts -lt 6)
    {
        $result = Invoke-RestMethod -Uri "$resource/api/data/v9.2/systemusers?`$filter=domainname eq '$userUpn'&`$select=systemuserid" -Headers $headers -ErrorAction Stop
        if ($result.value.Count -gt 0) { $dvUser = $result.value[0] }
        else { $attempts++; Write-Step "  Waiting for the user record to appear..."; Start-Sleep -Seconds 10 }
    }
    if (-not $dvUser) { throw "User record for $userUpn not found in $envUrl after waiting" }

    Grant-SystemAdministrator $resource $headers $dvUser.systemuserid
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
function Get-PasswordToken($resource, $upn, $password, $tenantId)
{
    $tokenBody = @{
        grant_type = "password"
        username   = $upn
        password   = $password
        client_id  = "1950a258-227b-4e31-a9cf-717495945fc2"
        scope      = "$resource/.default"
    }
    $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -ErrorAction Stop
    return $tokenResponse.access_token
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

# Returns the org name to use. Prompts when there is a choice, and waits for the attendee
# to create one when there is none.
function Select-AdoOrganization($tenantId, [string]$Preferred)
{
    while ($true)
    {
        $orgs = @(Get-MyAdoOrganizations $tenantId)
        $mine = @($orgs | Where-Object { $_.InThisTenant })

        if ($Preferred)
        {
            $match = $mine | Where-Object { $_.Name -eq $Preferred }
            if ($match)
            {
                Write-Ok "Using Azure DevOps org: $($match.Name)"
                return $match.Name
            }
            Write-Warn "Azure DevOps org '$Preferred' is not one of your orgs in this tenant - ignoring it"
            $Preferred = $null
        }

        if ($mine.Count -eq 1)
        {
            Write-Ok "Using Azure DevOps org: $($mine[0].Name)"
            return $mine[0].Name
        }
        if ($mine.Count -gt 1)
        {
            Write-Host ""
            Write-Host "  You belong to more than one Azure DevOps org in this tenant. Which one should we use?"
            for ($i = 0; $i -lt $mine.Count; $i++) { Write-Host ("    [{0}] {1}" -f ($i + 1), $mine[$i].Name) }
            $choice = 0
            while ($choice -lt 1 -or $choice -gt $mine.Count)
            {
                [int]::TryParse((Read-Host "  Enter a number"), [ref]$choice) | Out-Null
            }
            return $mine[$choice - 1].Name
        }

        Write-Bad "You don't have an Azure DevOps org connected to this tenant yet."
        foreach ($o in $orgs) { Write-Hint "(Found '$($o.Name)', but it belongs to a different tenant.)" }
        Write-Hint "Follow 'D. Create your Azure DevOps organization' in 'Part 1 - Set Up\README.md'."
        Write-Hint "Make sure your work account is added to the org as a member."
        Read-Host "  Press Enter once that's done"
    }
}
