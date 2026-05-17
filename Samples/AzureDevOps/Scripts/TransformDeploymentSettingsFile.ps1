# Script to transform a previously tokenised deployment settings file by replacing environment variables and connection references with their actual values.
param(
    [Parameter(Mandatory=$true)]
    $settingsFilePath,
    $environmentVariablesValues,
    $connectionTokens,
    $environmentUrl,
    $username,
    $password,
    $tenantId,
    $applicationId,
    $clientSecret
)
 
$ErrorActionPreference = 'Stop'
 
function Update-EnvironmentVariables {
    param($property, $environmentVariablesValues)
   
    Write-Host "Processing SchemaName: $($property.SchemaName)"
    foreach($var in $environmentVariablesValues) {
        if($property.Value -eq $var.StaticToken) {
            $property.Value = $var.Value
            Write-Host "Updated value: $($property.Value)"
            return $true
        }
    }
    return $false
}
 
function Update-ConnectionReferences {
    param($property, $tokens, $connections)
    Write-Host "Processing ConnectorId: $($property.ConnectorId)"
    foreach($token in $tokens) {
        if($property.ConnectionId -eq $token.StaticToken) {
            Write-Host "Processing ConnectionId: $($property.ConnectionId)"
            $matchingConnection = $connections |
                Where-Object { $token.ConnectorId.EndsWith($_.ConnectorId) } |
                Select-Object -First 1
           
            if($matchingConnection) {
                $property.ConnectionId = $matchingConnection.ConnectionId
                Write-Host "Updated ConnectionId: $($property.ConnectionId)"
                return $true
            }
        }
    }
    return $false
}
 
try {
    if(-not (Test-Path $settingsFilePath)) {
        throw "Settings file not found at: $settingsFilePath"
    }
 
    $json = Get-Content -Path $settingsFilePath -Raw | ConvertFrom-Json
    $environmentVariablesValues = $environmentVariablesValues | ConvertFrom-Json
    $connectionTokens = $connectionTokens | ConvertFrom-Json
 
    pac auth clear
    if ($username -and $password) {
        Write-Host "Using username and password for authentication"
        pac auth create --name "DeploymentScriptAuth" --username $username --password $password
        pac auth select --name "DeploymentScriptAuth"
    }
    elseif ($applicationId -and $clientSecret) {
        Write-Host "Using applicationId and clientSecret for authentication"
        pac auth create --name "DeploymentScriptAuth" --tenant $tenantId --applicationId $applicationId --clientSecret $clientSecret
        pac auth select --name "DeploymentScriptAuth"
    }
    else {
        throw "No valid authentication method provided. Please provide either username and password, or applicationId and clientSecret."
    }
    Write-Host "Selected environment: $environmentUrl"
    pac org select --environment $environmentUrl
    $connectionList = pac connection list
    $connections = New-Object System.Collections.Generic.List[PSCustomObject]
    if ($connectionList.Count -ge 3){
        for ($i = 2; $i -lt $connectionList.Count; $i++) {
            $connectionValues = $connectionList[$i].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            $connectionObject = [PSCustomObject]@{
                ConnectionId = $connectionValues[0]
                ConnectionName = $connectionValues[1]
                ConnectorId = $connectionValues[2]
                Status = $connectionValues[3]
            }
            $connections.Add($connectionObject) | Out-Null
        }
    }
    
   
    foreach ($object in $json.PSObject.Properties) {
        Write-Host "Processing object: $($object.Name)"
       
        if ([string]::IsNullOrEmpty($object)) {
            Write-Warning "The $($object.Name) array contains a null or empty string value."
            continue
        }
 
        foreach($property in $object.Value) {
            switch($object.Name) {
                "EnvironmentVariables" {
                    if(-not (Update-EnvironmentVariables -property $property -environmentVariablesValues $environmentVariablesValues)) {
                        throw "Failed to find JSON environment variable object with schemaname $($property.Value)."
                    }
                }
                "ConnectionReferences" {
                    if(-not (Update-ConnectionReferences -property $property -tokens $connectionTokens -connections $connections)) {
                        throw "Failed to find matching connection for connector $($property.ConnectorId)."
                    }
                }
            }
        }
    }
 
    $json | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsFilePath
    Write-Host "Successfully updated settings file"
}
catch {
    Write-Error "Error processing settings file: $_"
    throw
}
