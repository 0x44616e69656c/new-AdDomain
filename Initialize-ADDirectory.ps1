<#
.SYNOPSIS
    Configures post-promotion AD services and populates the directory with lab data.
.DESCRIPTION
    Validates domain services, enables the Recycle Bin, deploys the Enterprise CA,
    configures DNS forwarders, time synchronization, and firewall, creates the OU hierarchy, and
    populates the directory with users, groups, computers, and service accounts.
    Deploys baseline GPOs, configures the password policy, creates AD site topology,
    runs functional validation tests, and exports summary artifacts.

    Removes the AD-Populate-PostPromotion scheduled task on startup if present,
    so it does not re-run at subsequent logons.

    Run as: Domain Administrator (post-promotion).
.EXAMPLE
    .\Initialize-ADDirectory.ps1
    .\Initialize-ADDirectory.ps1 -UserCount 500 -GroupCount 25
.NOTES
    Version:      1.0.0
    Author:       Daniel Owen
    Release Date: 2026-06-01
    Requirements: Windows Server 2025, PowerShell 5.1+, Domain Administrator
#>

#region Parameters
param(
    [int]$UserCount            = 1000,
    [int]$GroupCount           = 50,
    [int]$ComputerCount        = 0,
    [ValidateRange(4, 94)][int]$PasswordLength = 20,
    [int]$MinGroupMembers      = 2,
    [int]$MaxGroupMembers      = 10,
    [int]$MinDA                = 2,
    [int]$MaxDA                = 10,
    [int]$MaxGroupNestingDepth = 3,
    [int]$RandomSeed           = 0
)
#endregion

$ErrorActionPreference = 'Stop'

#region Dot-Source Include Files
$configPath   = Join-Path $PSScriptRoot "include\global-config.ps1"
$logFuncsPath = Join-Path $PSScriptRoot "include\Write-LogFunctions.ps1"

if (-not (Test-Path $configPath)) {
    Write-Error "global-config.ps1 not found at: $configPath. Ensure the include directory is present in the same directory as this script."
    exit 1
}
if (-not (Test-Path $logFuncsPath)) {
    Write-Error "Write-LogFunctions.ps1 not found at: $logFuncsPath. Ensure the include directory is present in the same directory as this script."
    exit 1
}

. $configPath
. $logFuncsPath
#endregion

#region Script-Local Configuration
$transcriptPath        = "$logPath\Initialize-ADDirectory-$(Get-Date -Format yyyyMMddHHmmss).log"
#endregion

#region Functions

#region --- Retry Wrapper ---
function Invoke-ADWriteWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$OperationName,
        [int]$RetryCount    = 12,
        [int]$RetryDelaySec = 10
    )
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            & $Operation
            return
        } catch {
            Write-LogWarn "Attempt $attempt of $RetryCount failed for [$OperationName]: $_"
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySec
            } else {
                Write-LogError "All $RetryCount attempts exhausted for [$OperationName]. Last error: $_"
                throw
            }
        }
    }
}
#endregion

#region --- Scheduled Task ---
function Remove-PopulateScheduledTask {
    param([string]$TaskNameParam)
    try {
        if (Get-ScheduledTask -TaskName $TaskNameParam -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskNameParam -Confirm:$false
            Write-LogInfo "Scheduled task '$TaskNameParam' removed."
        }
    } catch {
        Write-LogWarn "Could not remove scheduled task '$TaskNameParam': $_"
    }
}
#endregion

#region --- Pre-Flight Checks ---
function Test-DomainPrerequisites {
    param(
        [string]$DomainNameParam,
        [string]$ArtifactsPathParam
    )
    $allPassed = $true

    # Elevated session
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-LogError "Script must run in an elevated (Administrator) session."
        $allPassed = $false
    }

    # AD module
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-LogInfo "ActiveDirectory module loaded."
    } catch {
        Write-LogError "Failed to import ActiveDirectory module: $_"
        return $false
    }

    # LDAP responsiveness
    try {
        $null = Get-ADDomain -ErrorAction Stop
        Write-LogInfo "AD domain is responsive."
    } catch {
        Write-LogError "AD domain is not responding. Ensure this server has completed DC promotion and rebooted: $_"
        $allPassed = $false
    }

    # Domain Admin membership
    try {
        $currentSam  = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
        $daMembers   = Get-ADGroupMember -Identity "Domain Admins" -Recursive -ErrorAction Stop
        $isMember    = $daMembers | Where-Object { $_.SamAccountName -eq $currentSam }
        if (-not $isMember) {
            Write-LogError "Current account '$currentSam' is not a member of Domain Admins."
            $allPassed = $false
        } else {
            Write-LogInfo "Domain Admins membership verified for '$currentSam'."
        }
    } catch {
        Write-LogError "Failed to verify Domain Admins membership: $_"
        $allPassed = $false
    }

    # DNS resolution
    try {
        $null = Resolve-DnsName $DomainNameParam -ErrorAction Stop
        Write-LogInfo "DNS resolution for '$DomainNameParam' succeeded."
    } catch {
        Write-LogError "DNS resolution for '$DomainNameParam' failed. DNS service may not be ready: $_"
        $allPassed = $false
    }

    # Artifacts path
    try {
        $null = New-Item -ItemType Directory -Path $ArtifactsPathParam -Force
        Write-LogInfo "Artifacts directory verified."
    } catch {
        Write-LogError "Failed to create artifacts directory: $_"
        $allPassed = $false
    }

    if ($allPassed) {
        Write-LogSuccess "All pre-flight checks passed."
    }
    return $allPassed
}
#endregion

#region --- Service Readiness ---
function Wait-ForADServices {
    param(
        [string[]]$ServiceNames       = @('NTDS', 'DNS', 'Netlogon', 'kdc'),
        [int]$TimeoutSeconds          = 300,
        [int]$PollIntervalSeconds     = 10
    )
    try {
        foreach ($serviceName in $ServiceNames) {
            Write-LogInfo "Waiting for service: $serviceName"
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $ready = $false
            while ((Get-Date) -lt $deadline) {
                $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-LogSuccess "Service '$serviceName' is running."
                    $ready = $true
                    break
                }
                Write-LogDebug "Service '$serviceName' not ready. Retrying in $PollIntervalSeconds seconds..."
                Start-Sleep -Seconds $PollIntervalSeconds
            }
            if (-not $ready) {
                throw "Timeout waiting for service '$serviceName' after $TimeoutSeconds seconds."
            }
        }
    } catch {
        Write-LogError "Service readiness check failed: $_"
        throw
    }
}
#endregion

#region --- Post-Promotion Services ---
function Enable-ADRecycleBin {
    param([string]$DomainNameParam)
    try {
        # EnabledScopes is non-empty once the feature is enabled anywhere in the forest/config set.
        # Checking this directly avoids relying on Enable-ADOptionalFeature's "already exists" error text.
        $recycleBinFeature = Get-ADOptionalFeature -Identity 'Recycle Bin Feature'
        if ($recycleBinFeature.EnabledScopes) {
            Write-LogInfo "AD Recycle Bin is already enabled."
            return
        }

        $null = Enable-ADOptionalFeature `
            -Identity 'Recycle Bin Feature' `
            -Scope    ForestOrConfigurationSet `
            -Target   $DomainNameParam `
            -Confirm:$false
        Write-LogSuccess "AD Recycle Bin enabled."
    } catch {
        Write-LogError "Failed to enable AD Recycle Bin: $_"
        throw
    }
}

function Install-EnterpriseRootCA {
    param(
        [string]$CACommonNameParam,
        [int]$CAKeyLengthParam,
        [string]$CAHashAlgorithmParam,
        [int]$CAValidityYearsParam,
        [string]$CADatabasePathParam,
        [string]$CALogPathParam
    )
    try {
        # ADCS-Cert-Authority is installed here, post-promotion -- Install-ADDSForest refuses to promote a
        # server with the Certificate Server role present, so it cannot be installed alongside AD-DS.
        $caFeature = Get-WindowsFeature -Name ADCS-Cert-Authority
        if (-not $caFeature.Installed) {
            Write-LogInfo "Installing AD CS Certification Authority feature..."
            $featureResult = Install-WindowsFeature -Name 'ADCS-Cert-Authority', 'RSAT-ADCS' -IncludeManagementTools
            if (-not $featureResult.Success) {
                throw "ADCS-Cert-Authority feature installation reported failure. Review output above."
            }
            Write-LogSuccess "AD CS Certification Authority feature installed."
        }

        Import-Module ADCSDeployment -ErrorAction Stop

        # A configured CA writes its active CA name to this registry value. Checking the value -- rather than
        # whether the CertSvc service merely exists -- reliably distinguishes a configured CA from a host where
        # only the AD CS role binaries are installed, so CA configuration is never skipped on a clean first run.
        $caConfigRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
        $caIsConfigured  = $null -ne (Get-ItemProperty -Path $caConfigRegPath -Name 'Active' -ErrorAction SilentlyContinue)

        if ($caIsConfigured) {
            Write-LogInfo "An Enterprise CA is already configured on this host. Skipping CA installation."
            $certSvc = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
            if ($certSvc -and $certSvc.Status -ne 'Running') {
                Write-LogInfo "CertSvc is not running (status: $($certSvc.Status)). Starting service."
                Start-Service -Name CertSvc
                Write-LogSuccess "CertSvc started."
            }
            return
        }

        Install-AdcsCertificationAuthority `
            -CAType              EnterpriseRootCA `
            -CACommonName        $CACommonNameParam `
            -KeyLength           $CAKeyLengthParam `
            -HashAlgorithmName   $CAHashAlgorithmParam `
            -ValidityPeriod      Years `
            -ValidityPeriodUnits $CAValidityYearsParam `
            -DatabaseDirectory   $CADatabasePathParam `
            -LogDirectory        $CALogPathParam `
            -Force

        Start-Service -Name CertSvc
        Write-LogSuccess "Enterprise Root CA '$CACommonNameParam' deployed and service started."
    } catch {
        Write-LogError "CA deployment failed: $_"
        throw
    }
}

function Set-TimeConfiguration {
    param([string[]]$NtpServersParam)
    try {
        $ntpList = $NtpServersParam -join ','
        $null = w32tm /config /manualpeerlist:$ntpList /syncfromflags:manual /reliable:yes /update
        if ($LASTEXITCODE -ne 0) {
            throw "w32tm /config failed with exit code $LASTEXITCODE."
        }
        $null = Restart-Service W32Time -Force
        $null = w32tm /resync /force
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "w32tm /resync returned exit code $LASTEXITCODE. Time sync may not be immediate."
        }
        Write-LogSuccess "NTP configured: $ntpList"
    } catch {
        Write-LogError "Time configuration failed: $_"
        throw
    }
}

function Test-FirewallRules {
    # Validates, but does not create. DC firewall rules are typically auto-provisioned on WS2025.
    $requiredPorts = @(
        @{ Port = 53;  Protocol = 'TCP'; Description = 'DNS' },
        @{ Port = 53;  Protocol = 'UDP'; Description = 'DNS' },
        @{ Port = 88;  Protocol = 'TCP'; Description = 'Kerberos' },
        @{ Port = 88;  Protocol = 'UDP'; Description = 'Kerberos' },
        @{ Port = 135; Protocol = 'TCP'; Description = 'RPC Endpoint Mapper' },
        @{ Port = 389; Protocol = 'TCP'; Description = 'LDAP' },
        @{ Port = 389; Protocol = 'UDP'; Description = 'LDAP' },
        @{ Port = 445; Protocol = 'TCP'; Description = 'SMB' },
        @{ Port = 636; Protocol = 'TCP'; Description = 'LDAPS' },
        @{ Port = 80;  Protocol = 'TCP'; Description = 'Certificate Services HTTP' },
        @{ Port = 443; Protocol = 'TCP'; Description = 'Certificate Services HTTPS' }
    )
    try {
        # Get-NetFirewallPortFilter has no -Protocol/-LocalPort filter parameters -- its only
        # parameter set is -AssociatedNetFirewallRule/-PolicyStore/-GPOSession/-CimSession.
        # Retrieve every port filter once and filter Protocol/LocalPort client-side per port below.
        $allPortFilters = Get-NetFirewallPortFilter
    } catch {
        Write-LogWarn "Could not retrieve firewall port filters, skipping firewall validation: $_"
        return
    }

    foreach ($portDef in $requiredPorts) {
        try {
            $rules = $allPortFilters |
                Where-Object { $_.Protocol -eq $portDef.Protocol -and $_.LocalPort -contains "$($portDef.Port)" } |
                Get-NetFirewallRule | Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq $true }
            if ($rules) {
                Write-LogInfo "Firewall rule verified: $($portDef.Description) ($($portDef.Protocol)/$($portDef.Port))"
            } else {
                Write-LogWarn "No active inbound rule found for $($portDef.Description) ($($portDef.Protocol)/$($portDef.Port)) -- Windows Server 2025 may manage this automatically."
            }
        } catch {
            Write-LogWarn "Firewall check error for port $($portDef.Port): $_"
        }
    }
}

function Set-DnsForwarders {
    param([string[]]$ForwardersParam)
    try {
        Import-Module DnsServer -ErrorAction Stop
        $null = Set-DnsServerForwarder -IPAddress $ForwardersParam -UseRootHint $false
        Write-LogSuccess "DNS forwarders configured: $($ForwardersParam -join ', ') (root hints disabled)"
    } catch {
        Write-LogError "DNS forwarder configuration failed: $_"
        throw
    }
}

function Export-DiagnosticReports {
    param([string]$LogPathParam)
    # Diagnostic reports are informational -- failures warn but do not abort the deployment.
    $timestamp = Get-Date -Format yyyyMMddHHmmss
    try {
        dcdiag /v | Out-File "$LogPathParam\dcdiag-$timestamp.txt" -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "dcdiag exited with code $LASTEXITCODE. See $LogPathParam\dcdiag-$timestamp.txt."
        } else {
            Write-LogInfo "dcdiag report saved: $LogPathParam\dcdiag-$timestamp.txt"
        }
    } catch {
        Write-LogWarn "dcdiag report export failed: $_"
    }
    try {
        repadmin /replsummary | Out-File "$LogPathParam\repadmin-$timestamp.txt" -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "repadmin exited with code $LASTEXITCODE. See $LogPathParam\repadmin-$timestamp.txt."
        } else {
            Write-LogInfo "repadmin report saved: $LogPathParam\repadmin-$timestamp.txt"
        }
    } catch {
        Write-LogWarn "repadmin report export failed: $_"
    }
}
#endregion

#region --- CSV Validation ---
function Test-AllCsvFiles {
    param([string]$CsvBasePath)
    $failures = @()
    $csvSpecs  = @(
        @{ File = 'first.csv';           Headers = @('FirstName');                 MinRows = 50  },
        @{ File = 'last.csv';            Headers = @('LastName');                  MinRows = 50  },
        @{ File = 'words.csv';           Headers = @('Word');                      MinRows = 20  },
        @{ File = 'departments.csv';     Headers = @('Department');                MinRows = 5   },
        @{ File = 'titles.csv';          Headers = @('Title');                     MinRows = 10  },
        @{ File = 'offices.csv';         Headers = @('Office');                    MinRows = 1   },
        @{ File = 'cities.csv';          Headers = @('City', 'State');             MinRows = 1   },
        @{ File = 'companies.csv';       Headers = @('Company');                   MinRows = 1   },
        @{ File = 'streets.csv';         Headers = @('Street');                    MinRows = 5   },
        @{ File = 'computers.csv';       Headers = @('Seed');                      MinRows = 5   },
        @{ File = 'serviceaccounts.csv'; Headers = @('Name', 'Description', 'SPN'); MinRows = 3 }
    )

    foreach ($spec in $csvSpecs) {
        $filePath = Join-Path $CsvBasePath $($spec.File)
        if (-not (Test-Path $filePath)) {
            $failures += "MISSING: $($spec.File)"
            continue
        }
        try {
            $data = Import-Csv $filePath
            # Guard: Select-Object -First 1 returns $null on an empty dataset, causing .PSObject.Properties to throw.
            # The MinRows check below is the correct surface for zero-row files.
            if ($data.Count -gt 0) {
                foreach ($header in $spec.Headers) {
                    if ($null -eq ($data | Select-Object -First 1).PSObject.Properties[$header]) {
                        $failures += "MISSING HEADER '$header' in $($spec.File)"
                    }
                }
            }
            if ($data.Count -lt $spec.MinRows) {
                $failures += "TOO FEW ROWS in $($spec.File): found $($data.Count), need $($spec.MinRows)"
            }
        } catch {
            $failures += "UNREADABLE: $($spec.File) -- $_"
        }
    }

    if ($failures.Count -gt 0) {
        foreach ($f in $failures) { Write-LogError $f }
        throw "CSV validation failed with $($failures.Count) error(s). Fix the issues above before running."
    }
    Write-LogSuccess "All $($csvSpecs.Count) CSV files validated."
}

function Import-LabCsvData {
    param([string]$CsvPathParam)
    try {
        $script:firstNames      = Import-Csv "$CsvPathParam\first.csv"
        $script:lastNames       = Import-Csv "$CsvPathParam\last.csv"
        $script:wordSeeds       = Import-Csv "$CsvPathParam\words.csv"
        $script:departments     = Import-Csv "$CsvPathParam\departments.csv"
        $script:titles          = Import-Csv "$CsvPathParam\titles.csv"
        $script:offices         = Import-Csv "$CsvPathParam\offices.csv"
        $script:cities          = Import-Csv "$CsvPathParam\cities.csv"
        $script:companies       = Import-Csv "$CsvPathParam\companies.csv"
        $script:streets         = Import-Csv "$CsvPathParam\streets.csv"
        $script:computerSeeds   = Import-Csv "$CsvPathParam\computers.csv"
        $script:serviceAcctDefs = Import-Csv "$CsvPathParam\serviceaccounts.csv"
        Write-LogInfo "All CSV data loaded."
    } catch {
        Write-LogError "CSV data import failed: $_"
        throw
    }
}
#endregion

#region --- OU Structure ---
function New-OUIfNotExists {
    param([string]$Name, [string]$Path)
    try {
        $fullPath = "OU=$Name,$Path"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$fullPath'" -ErrorAction SilentlyContinue)) {
            $localOUName = $Name
            $localPath   = $Path
            Invoke-ADWriteWithRetry -OperationName "New-ADOU $localOUName" -Operation {
                # Lab: protection disabled for easier environment teardown.
                $null = New-ADOrganizationalUnit -Name $localOUName -Path $localPath -ProtectedFromAccidentalDeletion $false
            }
            Write-LogSuccess "Created OU: $fullPath"
        } else {
            Write-LogInfo "OU already exists, skipping: $fullPath"
        }
    } catch {
        Write-LogError "Failed to create OU '$Name': $_"
        throw
    }
}

function New-OUStructure {
    param(
        [string]$DomainDNParam,
        [string[]]$OUNamesParam
    )
    try {
        foreach ($ouName in $OUNamesParam) {
            New-OUIfNotExists -Name $ouName -Path $DomainDNParam
        }
        Write-LogSuccess "OU structure complete: $($OUNamesParam.Count) OUs verified."
    } catch {
        Write-LogError "OU structure creation failed: $_"
        throw
    }
}
#endregion

#region --- Helper Functions ---
function Get-RandomIdentity {
    param([array]$FirstNamesData, [array]$LastNamesData)
    $firstName = $($FirstNamesData | Get-Random).FirstName
    $lastName  = $($LastNamesData  | Get-Random).LastName
    return [pscustomobject]@{
        GivenName   = $firstName
        Surname     = $lastName
        DisplayName = "$firstName $lastName"
    }
}

function New-CompliantPassword {
    param([int]$Length)
    # Range 33-126 covers all printable ASCII (94 chars). $Length must be <= 94 for no-replacement pick.
    if ($Length -gt 94) {
        throw "PasswordLength $Length exceeds maximum of 94 (printable ASCII range 33-126 has 94 characters)."
    }
    # The complexity do/while requires upper, lower, digit, and symbol. A length below 4 can never satisfy
    # all four classes, so the loop would spin forever -- reject it up front.
    if ($Length -lt 4) {
        throw "PasswordLength $Length is below the minimum of 4 needed to satisfy all four complexity classes (upper, lower, digit, symbol)."
    }
    do {
        $rawPassword = -join ((33..126) | Get-Random -Count $Length | ForEach-Object { [char]$_ })
    } while (
        $rawPassword -notmatch '[A-Z]' -or
        $rawPassword -notmatch '[a-z]' -or
        $rawPassword -notmatch '\d'    -or
        $rawPassword -notmatch '[^a-zA-Z0-9]'
    )
    return [pscustomobject]@{
        Plain  = $rawPassword
        Secure = ConvertTo-SecureString $rawPassword -AsPlainText -Force
    }
}

function Get-SanitizedSamBase {
    param([string]$GivenName, [string]$Surname)
    $initial = $GivenName.Substring(0, 1)
    $cleaned = ($initial + $Surname) -replace "[^a-zA-Z0-9\-]", ""
    $cleaned = $cleaned.ToLower()
    if ($cleaned.Length -gt 18) { $cleaned = $cleaned.Substring(0, 18) }
    return $cleaned
}

function Resolve-UniqueSam {
    param([string]$BaseSam)
    $sam    = $BaseSam
    $suffix = 0
    # $sam derives from Get-SanitizedSamBase, which strips everything except [a-zA-Z0-9-], so it can
    # never contain a single quote -- the -Filter is injection-safe here without ConvertTo-AdFilterValue.
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        $suffix++
        $sam = "$BaseSam$suffix"
    }
    return $sam
}

function ConvertTo-AdFilterValue {
    # Escapes single quotes for safe interpolation into an AD -Filter string literal.
    # AD -Filter uses PowerShell expression syntax: a single quote inside a single-quoted value must be
    # doubled, otherwise a value like "O'Brien" produces a malformed filter that errors -- and under
    # -ErrorAction SilentlyContinue that error is swallowed, silently defeating the duplicate check.
    param([string]$Value)
    return $Value.Replace("'", "''")
}
#endregion

#region --- Group Creation ---
function New-LabGroups {
    param([int]$Count, [array]$WordSeeds, [string]$TargetOU)
    $groupTypes    = @(
        @{ Scope = 'Global';      Category = 'Security'     },
        @{ Scope = 'Universal';   Category = 'Security'     },
        @{ Scope = 'DomainLocal'; Category = 'Security'     },
        @{ Scope = 'Global';      Category = 'Distribution' },
        @{ Scope = 'Universal';   Category = 'Distribution' }
    )
    $createdGroups = [System.Collections.Generic.List[string]]::new()

    for ($i = 1; $i -le $Count; $i++) {
        try {
            $word       = $($WordSeeds | Get-Random).Word
            $typeChoice = $groupTypes[$i % $groupTypes.Count]
            $groupName  = "$word-GRP-$i"

            if (-not (Get-ADGroup -Filter "Name -eq '$(ConvertTo-AdFilterValue -Value $groupName)'" -ErrorAction SilentlyContinue)) {
                $localGroupName  = $groupName
                $localScope      = $($typeChoice.Scope)
                $localCategory   = $($typeChoice.Category)
                $localTargetOU   = $TargetOU
                Invoke-ADWriteWithRetry -OperationName "New-ADGroup $localGroupName" -Operation {
                    $null = New-ADGroup `
                        -Name          $localGroupName `
                        -GroupScope    $localScope `
                        -GroupCategory $localCategory `
                        -Path          $localTargetOU
                }
                Write-LogInfo "Created group: $groupName ($($typeChoice.Scope) $($typeChoice.Category))"
            } else {
                Write-LogInfo "Group already exists, skipping: $groupName"
            }
            $createdGroups.Add($groupName)
        } catch {
            Write-LogError "Failed to create group $($i): $_"
            throw
        }
    }
    Write-LogSuccess "Group creation complete: $($createdGroups.Count) groups."
    return $createdGroups
}
#endregion

#region --- Nested Group Memberships ---
function Set-NestedGroupMemberships {
    param(
        [System.Collections.Generic.List[string]]$GroupNames,
        [int]$MaxDepth
    )

    # Forward graph: key = group, value = set of groups it directly contains.
    # Reverse graph: key = group, value = set of groups that directly contain it.
    # The reverse graph lets us measure how deep a group already sits before adding a new edge.
    $membershipGraph = @{}
    $reverseGraph    = @{}
    $groupObjects    = @{}
    foreach ($name in $GroupNames) {
        $membershipGraph[$name] = [System.Collections.Generic.HashSet[string]]::new()
        $reverseGraph[$name]    = [System.Collections.Generic.HashSet[string]]::new()
        try {
            $groupObjects[$name] = Get-ADGroup -Identity $name -Properties GroupScope, GroupCategory -ErrorAction SilentlyContinue
        } catch {
            Write-LogWarn "Could not load group object for nesting compatibility check '$name': $_"
        }
    }

    function Test-ScopeCompatible {
        param([string]$ContainerName, [string]$MemberName, [hashtable]$GroupObjectsMapParam)
        $containerScope = $GroupObjectsMapParam[$ContainerName].GroupScope
        $memberScope    = $GroupObjectsMapParam[$MemberName].GroupScope
        switch ($containerScope) {
            'DomainLocal' { return $memberScope -in @('Global', 'Universal', 'DomainLocal') }
            'Universal'   { return $memberScope -in @('Global', 'Universal') }
            'Global'      { return $memberScope -eq 'Global' }
            default       { return $false }
        }
    }

    function Test-WouldCreateCycle {
        param([string]$ContainerName, [string]$MemberName, [hashtable]$MembershipGraphMapParam)
        # DFS from MemberName: if ContainerName is reachable, adding the edge creates a cycle.
        $visited = [System.Collections.Generic.HashSet[string]]::new()
        $stack   = [System.Collections.Generic.Stack[string]]::new()
        $null    = $stack.Push($MemberName)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            if ($current -eq $ContainerName) { return $true }
            if ($visited.Contains($current))  { continue }
            $null = $visited.Add($current)
            foreach ($child in $MembershipGraphMapParam[$current]) {
                $null = $stack.Push($child)
            }
        }
        return $false
    }

    function Get-DownwardDepth {
        param([string]$Node, [hashtable]$ForwardGraphMapParam)
        # Groups in the longest chain that STARTS at $Node and descends through its members.
        # Graph is kept acyclic by the cycle check, so this recursion always terminates.
        $deepestChild = 0
        foreach ($child in $ForwardGraphMapParam[$Node]) {
            $childDepth = Get-DownwardDepth -Node $child -ForwardGraphMapParam $ForwardGraphMapParam
            if ($childDepth -gt $deepestChild) { $deepestChild = $childDepth }
        }
        return 1 + $deepestChild
    }

    function Get-UpwardDepth {
        param([string]$Node, [hashtable]$ReverseGraphMapParam)
        # Groups in the longest chain that ENDS at $Node, ascending through its containers.
        $deepestParent = 0
        foreach ($parent in $ReverseGraphMapParam[$Node]) {
            $parentDepth = Get-UpwardDepth -Node $parent -ReverseGraphMapParam $ReverseGraphMapParam
            if ($parentDepth -gt $deepestParent) { $deepestParent = $parentDepth }
        }
        return 1 + $deepestParent
    }

    $nestingAttempts = [math]::Min($GroupNames.Count * 2, 100)
    $shuffled        = $GroupNames | Sort-Object { Get-Random }

    for ($i = 0; $i -lt $nestingAttempts; $i++) {
        $containerName = $shuffled[$i % $shuffled.Count]
        $memberName    = $shuffled[($i + 1) % $shuffled.Count]

        if ($containerName -eq $memberName) { continue }
        if ($membershipGraph[$containerName].Contains($memberName)) { continue }
        if (-not (Test-ScopeCompatible -ContainerName $containerName -MemberName $memberName -GroupObjectsMapParam $groupObjects)) {
            Write-LogDebug "Scope incompatible: cannot nest $memberName into $containerName."
            continue
        }
        if (Test-WouldCreateCycle -ContainerName $containerName -MemberName $memberName -MembershipGraphMapParam $membershipGraph) {
            Write-LogDebug "Cycle rejected: $memberName into $containerName would create a cycle."
            continue
        }
        # Enforce the nesting-depth ceiling. The longest chain through the proposed edge is the groups
        # already above the container plus the groups already below the member; reject if it exceeds MaxDepth.
        $resultingDepth = (Get-UpwardDepth   -Node $containerName -ReverseGraphMapParam $reverseGraph) +
                          (Get-DownwardDepth -Node $memberName    -ForwardGraphMapParam $membershipGraph)
        if ($resultingDepth -gt $MaxDepth) {
            Write-LogDebug "Depth limit: nesting $memberName into $containerName would create a chain of $resultingDepth groups (max $MaxDepth)."
            continue
        }

        try {
            $localContainer = $containerName
            $localMember    = $memberName
            Invoke-ADWriteWithRetry -OperationName "Nest $localMember into $localContainer" -Operation {
                $null = Add-ADGroupMember -Identity $localContainer -Members $localMember
            }
            $null = $membershipGraph[$containerName].Add($memberName)
            $null = $reverseGraph[$memberName].Add($containerName)
            Write-LogInfo "Nested '$memberName' into '$containerName'."
        } catch {
            Write-LogError "Failed to nest '$memberName' into '$containerName': $_"
            throw
        }
    }
    Write-LogSuccess "Nested group memberships applied."
}
#endregion

#region --- User Creation ---
function New-LabUsers {
    param(
        [int]$Count,
        [string]$UpnPatternParam,
        [string]$DomainNameParam,
        [string]$UsersOUParam,
        [int]$PasswordLengthParam,
        [array]$FirstNamesData,
        [array]$LastNamesData,
        [array]$DepartmentsData,
        [array]$TitlesData,
        [array]$ActiveCompaniesData,
        [array]$OfficesData,
        [array]$CitiesData,
        [array]$StreetsData,
        [int]$PctRemoteUsersParam,
        [string]$SharedCityName,
        [string]$SharedCityState
    )
    # Guard against an unsatisfiable run: each user needs a unique "First Last" display name (the object CN).
    # The pool of distinct combinations is FirstNames x LastNames; requesting more than that makes the
    # identity-reroll do/while below spin forever. This checks the static CSV pool only -- not names already
    # present in AD from a prior run -- so a near-exhausted domain can still slow the reroll loop.
    $maxUniqueIdentities = $FirstNamesData.Count * $LastNamesData.Count
    if ($Count -gt $maxUniqueIdentities) {
        throw "Requested user count ($Count) exceeds the $maxUniqueIdentities unique first/last name combinations available ($($FirstNamesData.Count) first x $($LastNamesData.Count) last). Add more names to first.csv/last.csv or lower -UserCount."
    }

    $createdUsers     = [System.Collections.Generic.List[object]]::new()
    # Display names already used this run. A duplicate "First Last" would collide on the object CN
    # (-Name), which must be unique in the OU. Per design, a duplicate identity is discarded and a
    # wholly new random user is rolled (see the do/while below) rather than mangling the name.
    $usedDisplayNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 1; $i -le $Count; $i++) {
        try {
            # Roll a fresh identity until its display name is unused this run and absent from AD, so the
            # object CN (-Name) is guaranteed unique. Colliding identities are thrown away outright.
            do {
                $identity = Get-RandomIdentity -FirstNamesData $FirstNamesData -LastNamesData $LastNamesData
            } while (
                $usedDisplayNames.Contains($identity.DisplayName) -or
                (Get-ADUser -Filter "Name -eq '$(ConvertTo-AdFilterValue -Value $($identity.DisplayName))'" -ErrorAction SilentlyContinue)
            )
            $null       = $usedDisplayNames.Add($identity.DisplayName)

            $samBase    = Get-SanitizedSamBase -GivenName $($identity.GivenName) -Surname $($identity.Surname)
            $sam        = Resolve-UniqueSam   -BaseSam $samBase

            switch ($UpnPatternParam) {
                'firstlast' { $upn = "$($identity.GivenName.ToLower()).$($identity.Surname.ToLower())@$DomainNameParam" }
                'f_last'    { $upn = "$($identity.GivenName.Substring(0,1).ToLower())_$($identity.Surname.ToLower())@$DomainNameParam" }
                default     { $upn = "$sam@$DomainNameParam" }
            }

            $department  = $($DepartmentsData | Get-Random).Department
            $title       = $($TitlesData      | Get-Random).Title
            $company     = $($ActiveCompaniesData | Get-Random).Company
            $isRemote    = (Get-Random -Minimum 1 -Maximum 101) -le $PctRemoteUsersParam
            if ($isRemote) {
                $office     = 'Remote'
                $cityRecord = $CitiesData | Get-Random
            } else {
                $office     = $($OfficesData | Get-Random).Office
                $cityRecord = [pscustomobject]@{ City = $SharedCityName; State = $SharedCityState }
            }
            $street      = "$(Get-Random -Minimum 100 -Maximum 9999) $($($StreetsData | Get-Random).Street)"
            $phone       = "555-555-$(Get-Random -Minimum 1000 -Maximum 9999)"
            $employeeId  = $i.ToString().PadLeft(6, '0')
            $pwResult    = New-CompliantPassword -Length $PasswordLengthParam

            $localSam        = $sam
            $localUpn        = $upn
            $localDisplay    = $identity.DisplayName
            $localGiven      = $identity.GivenName
            $localSurname    = $identity.Surname
            $localDept       = $department
            $localTitle      = $title
            $localCompany    = $company
            $localOffice     = $office
            $localCity       = $($cityRecord.City)
            $localState      = $($cityRecord.State)
            $localStreet     = $street
            $localPhone      = $phone
            $localEmpId      = $employeeId
            $localPwSecure   = $pwResult.Secure
            $localUsersOU    = $UsersOUParam

            Invoke-ADWriteWithRetry -OperationName "New-ADUser $localSam" -Operation {
                $null = New-ADUser `
                    -GivenName         $localGiven `
                    -Surname           $localSurname `
                    -DisplayName       $localDisplay `
                    -Name              $localDisplay `
                    -SamAccountName    $localSam `
                    -UserPrincipalName $localUpn `
                    -Department        $localDept `
                    -Title             $localTitle `
                    -Company           $localCompany `
                    -Office            $localOffice `
                    -StreetAddress     $localStreet `
                    -City              $localCity `
                    -State             $localState `
                    -OfficePhone       $localPhone `
                    -EmailAddress      $localUpn `
                    -EmployeeID        $localEmpId `
                    -AccountPassword   $localPwSecure `
                    -Enabled           $true `
                    -Path              $localUsersOU
            }

            $createdUsers.Add([pscustomobject]@{
                Sam         = $sam
                DisplayName = $identity.DisplayName
                UPN         = $upn
                Department  = $department
                EmployeeID  = $employeeId
                Password    = $pwResult.Plain
            })

            if ($i % 100 -eq 0) {
                Write-LogInfo "User creation progress: $i of $Count"
            }
        } catch {
            $displayName = if ($null -ne $identity) { $identity.DisplayName } else { 'unknown' }
            Write-LogError "Failed to create user $i ($displayName): $_"
            throw
        }
    }
    Write-LogSuccess "Created $($createdUsers.Count) users."
    return $createdUsers
}
#endregion

#region --- User Manager Assignment ---
function Set-UserManagers {
    param([System.Collections.Generic.List[object]]$Users)
    try {
        $byDept = $Users | Group-Object Department
        foreach ($deptGroup in $byDept) {
            if ($deptGroup.Count -lt 2) { continue }
            $managerUser = $deptGroup.Group | Get-Random
            $managerDN   = (Get-ADUser -Identity $($managerUser.Sam)).DistinguishedName
            foreach ($user in $deptGroup.Group) {
                if ($user.Sam -eq $managerUser.Sam) { continue }
                try {
                    $localSam       = $($user.Sam)
                    $localManagerDN = $managerDN
                    Invoke-ADWriteWithRetry -OperationName "Set-Manager $localSam" -Operation {
                        $null = Set-ADUser -Identity $localSam -Manager $localManagerDN
                    }
                } catch {
                    Write-LogWarn "Could not set manager for '$($user.Sam)': $_"
                }
            }
        }
        Write-LogSuccess "Manager assignments complete."
    } catch {
        Write-LogError "Manager assignment phase failed: $_"
        throw
    }
}
#endregion

#region --- User State Randomization ---
function Set-UserStateRandomization {
    param(
        [System.Collections.Generic.List[object]]$Users,
        [int]$PctDisabledParam,
        [int]$PctPwExpiredParam,
        [int]$PctPwNeverExpiresParam,
        [int]$PctSmartcardParam,
        [int]$PctLockedParam,
        [string]$DisabledUsersOUParam,
        [string]$DomainNameParam,
        [int]$LockoutThresholdParam
    )
    $pctSum = $PctDisabledParam + $PctPwExpiredParam + $PctPwNeverExpiresParam + $PctSmartcardParam + $PctLockedParam
    if ($pctSum -gt 100) {
        throw "User state percentages sum to $pctSum%, which exceeds 100. Reduce one or more of: PctDisabled ($PctDisabledParam), PctPwExpired ($PctPwExpiredParam), PctPwNeverExpires ($PctPwNeverExpiresParam), PctSmartcard ($PctSmartcardParam), PctLocked ($PctLockedParam)."
    }

    # Cumulative percentage thresholds
    $thresholdDisabled    = $PctDisabledParam
    $thresholdPwExpired   = $PctDisabledParam + $PctPwExpiredParam
    $thresholdPwNever     = $PctDisabledParam + $PctPwExpiredParam + $PctPwNeverExpiresParam
    $thresholdSmartcard   = $PctDisabledParam + $PctPwExpiredParam + $PctPwNeverExpiresParam + $PctSmartcardParam
    $thresholdLocked      = $PctDisabledParam + $PctPwExpiredParam + $PctPwNeverExpiresParam + $PctSmartcardParam + $PctLockedParam

    # AD rejects direct writes to lockoutTime (only 0 is permitted, for unlocking). A "Locked"
    # user is instead produced below by exceeding the real lockout threshold with failed binds,
    # which yields a genuine LockedOut account plus Security Events 4625/4740.
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $adContext = [System.DirectoryServices.AccountManagement.PrincipalContext]::new('Domain', $DomainNameParam)
    } catch {
        Write-LogError "Failed to create PrincipalContext for '$DomainNameParam': $_"
        throw
    }

    foreach ($user in $Users) {
        $roll = Get-Random -Minimum 1 -Maximum 101
        try {
            $localSam = $($user.Sam)
            if ($roll -le $thresholdDisabled) {
                Invoke-ADWriteWithRetry -OperationName "Disable $localSam" -Operation {
                    $null = Disable-ADAccount -Identity $localSam
                }
                $localUserDN = (Get-ADUser -Identity $localSam).DistinguishedName
                $localDisOU  = $DisabledUsersOUParam
                Invoke-ADWriteWithRetry -OperationName "Move $localSam to DisabledUsers" -Operation {
                    $null = Move-ADObject -Identity $localUserDN -TargetPath $localDisOU
                }

            } elseif ($roll -le $thresholdPwExpired) {
                Invoke-ADWriteWithRetry -OperationName "PwExpire $localSam" -Operation {
                    $null = Set-ADUser -Identity $localSam -ChangePasswordAtLogon $true
                }

            } elseif ($roll -le $thresholdPwNever) {
                Invoke-ADWriteWithRetry -OperationName "PwNeverExpires $localSam" -Operation {
                    $null = Set-ADUser -Identity $localSam -PasswordNeverExpires $true
                }

            } elseif ($roll -le $thresholdSmartcard) {
                Invoke-ADWriteWithRetry -OperationName "Smartcard $localSam" -Operation {
                    $null = Set-ADUser -Identity $localSam -SmartcardLogonRequired $true
                }

            } elseif ($roll -le $thresholdLocked) {
                $wrongPassword = [guid]::NewGuid().ToString()
                for ($bindAttempt = 1; $bindAttempt -le ($LockoutThresholdParam + 1); $bindAttempt++) {
                    $null = $adContext.ValidateCredentials($localSam, $wrongPassword)
                }
                Write-LogInfo "Locked $localSam via $($LockoutThresholdParam + 1) failed bind attempts."
            }
        } catch {
            Write-LogError "User state randomization failed for '$($user.Sam)': $_"
            throw
        }
    }
    $adContext.Dispose()
    Write-LogSuccess "User state randomization complete."
}
#endregion

#region --- Group Membership Assignment ---
function Set-GroupMemberships {
    param(
        [System.Collections.Generic.List[string]]$GroupNames,
        [array]$UserSams,
        [int]$MinMembers,
        [int]$MaxMembers
    )
    foreach ($groupName in $GroupNames) {
        try {
            $memberCount  = Get-Random -Minimum $MinMembers -Maximum ($MaxMembers + 1)
            $selectedSams = $UserSams | Get-Random -Count $memberCount
            $localGroup   = $groupName
            $localMembers = $selectedSams
            Invoke-ADWriteWithRetry -OperationName "Add-ADGroupMember $localGroup" -Operation {
                $null = Add-ADGroupMember -Identity $localGroup -Members $localMembers
            }
        } catch {
            Write-LogError "Membership assignment failed for group '$groupName': $_"
            throw
        }
    }
    Write-LogSuccess "Group membership assignment complete."
}
#endregion

#region --- Domain Admins Population ---
function Set-DomainAdminMemberships {
    param([array]$UserSams, [int]$MinDAParam, [int]$MaxDAParam)
    try {
        $daCount   = Get-Random -Minimum $MinDAParam -Maximum ($MaxDAParam + 1)
        $daMembers = $UserSams | Get-Random -Count $daCount
        $localDA   = $daMembers
        Invoke-ADWriteWithRetry -OperationName "Add-ADGroupMember Domain Admins" -Operation {
            $null = Add-ADGroupMember -Identity "Domain Admins" -Members $localDA
        }
        Write-LogSuccess "Added $daCount users to Domain Admins."
    } catch {
        Write-LogError "Domain Admins population failed: $_"
        throw
    }
}
#endregion

#region --- Service Account Generation ---
function New-ServiceAccounts {
    param(
        [array]$ServiceAccountDefs,
        [string]$TargetOU,
        [int]$PasswordLengthParam
    )
    foreach ($def in $ServiceAccountDefs) {
        try {
            $samName = "svc_$($def.Name)"
            if (Get-ADUser -Filter "SamAccountName -eq '$(ConvertTo-AdFilterValue -Value $samName)'" -ErrorAction SilentlyContinue) {
                Write-LogInfo "Service account '$samName' already exists, skipping."
                continue
            }
            $pwResult       = New-CompliantPassword -Length $PasswordLengthParam
            $localSam       = $samName
            $localDesc      = $($def.Description)
            $localPwSecure  = $pwResult.Secure
            $localTargetOU  = $TargetOU
            Invoke-ADWriteWithRetry -OperationName "New-ADUser $localSam" -Operation {
                $null = New-ADUser `
                    -Name                $localSam `
                    -SamAccountName      $localSam `
                    -Description         $localDesc `
                    -AccountPassword     $localPwSecure `
                    -Enabled             $true `
                    -PasswordNeverExpires $true `
                    -Path                $localTargetOU
            }
            if ($def.SPN -and $def.SPN.Trim() -ne '') {
                $localSamForSpn = $samName
                $localSpn       = $($def.SPN)
                Invoke-ADWriteWithRetry -OperationName "Set-SPN $localSamForSpn" -Operation {
                    $null = Set-ADUser -Identity $localSamForSpn -ServicePrincipalNames @{ Add = $localSpn }
                }
            }
            Write-LogSuccess "Created service account: $samName"
        } catch {
            Write-LogError "Failed to create service account '$($def.Name)': $_"
            throw
        }
    }
}
#endregion

#region --- Computer Object Population ---
function New-ComputerObjects {
    param(
        [int]$Count,
        [array]$Seeds,
        [string]$WorkstationPrefixParam,
        [string]$ServerPrefixParam,
        [string]$LaptopPrefixParam,
        [string]$WorkstationsOUParam,
        [string]$ServersOUParam
    )
    $typeDistributions = @(
        @{ Prefix = $WorkstationPrefixParam; TargetOU = $WorkstationsOUParam; Count = [math]::Ceiling($Count * 0.6) },
        @{ Prefix = $ServerPrefixParam;      TargetOU = $ServersOUParam;      Count = [math]::Floor($Count * 0.2)   },
        @{ Prefix = $LaptopPrefixParam;      TargetOU = $WorkstationsOUParam; Count = [math]::Floor($Count * 0.2)   }
    )

    foreach ($typeDef in $typeDistributions) {
        for ($i = 1; $i -le $typeDef.Count; $i++) {
            try {
                $seed        = $($Seeds | Get-Random).Seed
                $indexStr    = "-$i"
                $maxSeedLen  = 15 - $($typeDef.Prefix).Length - 1 - $indexStr.Length
                if ($maxSeedLen -lt 1) { $maxSeedLen = 1 }
                $truncSeed   = if ($seed.Length -gt $maxSeedLen) { $seed.Substring(0, $maxSeedLen) } else { $seed }
                $computerName = "$($typeDef.Prefix)-$truncSeed$indexStr"

                if (-not (Get-ADComputer -Filter "Name -eq '$(ConvertTo-AdFilterValue -Value $computerName)'" -ErrorAction SilentlyContinue)) {
                    $localName = $computerName
                    $localOU   = $($typeDef.TargetOU)
                    Invoke-ADWriteWithRetry -OperationName "New-ADComputer $localName" -Operation {
                        $null = New-ADComputer -Name $localName -Path $localOU
                    }
                    Write-LogInfo "Created computer: $computerName"
                } else {
                    Write-LogInfo "Computer already exists, skipping: $computerName"
                }
            } catch {
                Write-LogError "Failed to create computer object $i ($($typeDef.Prefix)): $_"
                throw
            }
        }
    }
    Write-LogSuccess "Computer object creation complete."
}
#endregion

#region --- GPO Deployment ---
function Set-GPOBaseline {
    param(
        [string]$DomainNameParam,
        [string]$DomainDNParam,
        [string]$WorkstationsOUParam,
        [string]$ServersOUParam
    )
    Import-Module GroupPolicy -ErrorAction Stop
    # Creates empty GPO stubs and links them to their target scopes.
    # Policy settings must be configured separately via GPMC or Group Policy cmdlets.
    $gpoDefinitions = @(
        @{ Name = 'Lab-PasswordPolicy';      LinkTarget = $DomainDNParam       },
        @{ Name = 'Lab-WorkstationBaseline'; LinkTarget = $WorkstationsOUParam },
        @{ Name = 'Lab-ServerBaseline';      LinkTarget = $ServersOUParam      },
        @{ Name = 'Lab-WindowsUpdate';       LinkTarget = $DomainDNParam       },
        @{ Name = 'Lab-Autoenrollment';      LinkTarget = $DomainDNParam       },
        @{ Name = 'Lab-RDP-Policy';          LinkTarget = $DomainDNParam       }
    )

    foreach ($gpoDef in $gpoDefinitions) {
        try {
            $existingGPO = Get-GPO -Name $($gpoDef.Name) -Domain $DomainNameParam -ErrorAction SilentlyContinue
            if (-not $existingGPO) {
                $localGPOName = $($gpoDef.Name)
                $localDomain  = $DomainNameParam
                Invoke-ADWriteWithRetry -OperationName "New-GPO $localGPOName" -Operation {
                    $null = New-GPO -Name $localGPOName -Domain $localDomain
                }
                Write-LogSuccess "Created GPO: $($gpoDef.Name)"
            } else {
                Write-LogInfo "GPO already exists, skipping creation: $($gpoDef.Name)"
            }

            $existingLinks = (Get-GPInheritance -Target $($gpoDef.LinkTarget) -Domain $DomainNameParam -ErrorAction SilentlyContinue).GpoLinks |
                Where-Object { $_.DisplayName -eq $gpoDef.Name }
            if (-not $existingLinks) {
                $localGPOName    = $($gpoDef.Name)
                $localLinkTarget = $($gpoDef.LinkTarget)
                $localDomain     = $DomainNameParam
                Invoke-ADWriteWithRetry -OperationName "New-GPLink $localGPOName" -Operation {
                    $null = New-GPLink -Name $localGPOName -Target $localLinkTarget -Domain $localDomain
                }
                Write-LogSuccess "Linked GPO '$($gpoDef.Name)' to '$($gpoDef.LinkTarget)'."
            } else {
                Write-LogInfo "GPO '$($gpoDef.Name)' already linked, skipping."
            }
        } catch {
            Write-LogError "GPO deployment failed for '$($gpoDef.Name)': $_"
            throw
        }
    }
}
#endregion

#region --- Password Policy ---
function Set-PasswordPolicy {
    param(
        [string]$DomainNameParam,
        [int]$MinPwLenParam,
        [int]$PwHistoryCountParam,
        [int]$LockoutThresholdParam,
        [int]$LockoutDurationMinParam,
        [int]$MaxPwAgeDaysParam
    )
    try {
        $localDomain    = $DomainNameParam
        $localMinLen    = $MinPwLenParam
        $localHistory   = $PwHistoryCountParam
        $localThreshold = $LockoutThresholdParam
        $localLockoutDur = New-TimeSpan -Minutes $LockoutDurationMinParam
        $localMaxAge    = New-TimeSpan -Days $MaxPwAgeDaysParam
        Invoke-ADWriteWithRetry -OperationName "Set-ADDefaultDomainPasswordPolicy $localDomain" -Operation {
            $null = Set-ADDefaultDomainPasswordPolicy `
                -Identity             $localDomain `
                -MinPasswordLength    $localMinLen `
                -PasswordHistoryCount $localHistory `
                -LockoutThreshold     $localThreshold `
                -LockoutDuration      $localLockoutDur `
                -MaxPasswordAge       $localMaxAge `
                -ComplexityEnabled    $true
        }
        Write-LogSuccess "Domain password policy configured."
    } catch {
        Write-LogError "Password policy configuration failed: $_"
        throw
    }
}
#endregion

#region --- AD Site Topology ---
function Set-ADSiteTopology {
    param(
        [string]$PrimarySiteNameParam,
        [string]$PrimarySubnetParam
    )
    try {
        if (-not (Get-ADReplicationSite -Filter "Name -eq '$PrimarySiteNameParam'" -ErrorAction SilentlyContinue)) {
            $localSiteName = $PrimarySiteNameParam
            Invoke-ADWriteWithRetry -OperationName "New-ADReplicationSite $localSiteName" -Operation {
                $null = New-ADReplicationSite -Name $localSiteName
            }
            Write-LogSuccess "Created AD site: $PrimarySiteNameParam"
        } else {
            Write-LogInfo "AD site already exists, skipping: $PrimarySiteNameParam"
        }

        if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$PrimarySubnetParam'" -ErrorAction SilentlyContinue)) {
            $localSubnet   = $PrimarySubnetParam
            $localSiteName = $PrimarySiteNameParam
            Invoke-ADWriteWithRetry -OperationName "New-ADReplicationSubnet $localSubnet" -Operation {
                $null = New-ADReplicationSubnet -Name $localSubnet -Site $localSiteName
            }
            Write-LogSuccess "Created subnet: $PrimarySubnetParam in site $PrimarySiteNameParam"
        } else {
            Write-LogInfo "Subnet already exists, skipping: $PrimarySubnetParam"
        }
    } catch {
        Write-LogError "AD site topology configuration failed: $_"
        throw
    }
}
#endregion

#region --- Functional Tests ---
function Invoke-FunctionalTests {
    param(
        [string]$UsersOUParam,
        [string]$DisabledUsersOUParam,
        [string]$DomainNameParam,
        [int]$MinDAParam,
        [int]$ExpectedUserCountParam,
        [string]$CACommonNameParam
    )
    $testResults = [System.Collections.Generic.List[object]]::new()

    function Add-TestResult {
        param([string]$TestName, [bool]$Passed, [string]$Detail)
        $testResults.Add([pscustomobject]@{
            TestName  = $TestName
            Result    = if ($Passed) { 'PASS' } else { 'FAIL' }
            Detail    = $Detail
            Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        })
        if ($Passed) {
            Write-LogSuccess "TEST PASS: $TestName -- $Detail"
        } else {
            Write-LogWarn "TEST FAIL: $TestName -- $Detail"
        }
    }

    # LDAP query
    try {
        $userCount = (Get-ADUser -Filter * -SearchBase $UsersOUParam -ErrorAction Stop).Count
        Add-TestResult -TestName 'LDAP Query' -Passed ($userCount -gt 0) -Detail "Found $userCount users in $UsersOUParam"
    } catch {
        Add-TestResult -TestName 'LDAP Query' -Passed $false -Detail "$_"
    }

    # DNS resolution
    try {
        $null = Resolve-DnsName $DomainNameParam -ErrorAction Stop
        Add-TestResult -TestName 'DNS Resolution' -Passed $true -Detail "Resolved $DomainNameParam"
    } catch {
        Add-TestResult -TestName 'DNS Resolution' -Passed $false -Detail "$_"
    }

    # Domain Admins populated
    try {
        $daCount = (Get-ADGroupMember -Identity 'Domain Admins' -ErrorAction Stop).Count
        Add-TestResult -TestName 'Domain Admins Populated' -Passed ($daCount -ge $MinDAParam) `
            -Detail "Domain Admins has $daCount members (minimum $MinDAParam)"
    } catch {
        Add-TestResult -TestName 'Domain Admins Populated' -Passed $false -Detail "$_"
    }

    # LDAPS connectivity
    try {
        $ldapsTest = Test-NetConnection -ComputerName localhost -Port 636 -WarningAction SilentlyContinue
        Add-TestResult -TestName 'LDAPS Connectivity' -Passed $($ldapsTest.TcpTestSucceeded) `
            -Detail "Port 636 TCP: $($ldapsTest.TcpTestSucceeded)"
    } catch {
        Add-TestResult -TestName 'LDAPS Connectivity' -Passed $false -Detail "$_"
    }

    # CA service running
    try {
        $certSvc = Get-Service -Name CertSvc -ErrorAction Stop
        Add-TestResult -TestName 'CA Service Running' -Passed ($certSvc.Status -eq 'Running') `
            -Detail "CertSvc status: $($certSvc.Status)"
    } catch {
        Add-TestResult -TestName 'CA Service Running' -Passed $false -Detail "$_"
    }

    # DNS SRV record
    try {
        $null = Resolve-DnsName "_ldap._tcp.dc._msdcs.$DomainNameParam" -Type SRV -ErrorAction Stop
        Add-TestResult -TestName 'DNS SRV Record' -Passed $true `
            -Detail "Resolved _ldap._tcp.dc._msdcs.$DomainNameParam"
    } catch {
        Add-TestResult -TestName 'DNS SRV Record' -Passed $false -Detail "$_"
    }

    # Kerberos tickets
    try {
        $klistOutput = klist
        $hasTickets  = ($klistOutput -join "`n") -match 'Cached Tickets:\s*\(\s*[1-9]'
        Add-TestResult -TestName 'Kerberos Tickets' -Passed $hasTickets `
            -Detail $(if ($hasTickets) { 'Cached Kerberos tickets found in current session' } else { 'No cached tickets -- Kerberos may not be fully operational' })
    } catch {
        Add-TestResult -TestName 'Kerberos Tickets' -Passed $false -Detail "$_"
    }

    # CA certificate published to Trusted Root
    try {
        $caCerts = Get-ChildItem 'Cert:\LocalMachine\Root' |
                       Where-Object { $_.Subject -like "*$CACommonNameParam*" }
        Add-TestResult -TestName 'CA Certificate Published' -Passed ($caCerts.Count -gt 0) `
            -Detail "Trusted Root certs matching '$CACommonNameParam': $($caCerts.Count)"
    } catch {
        Add-TestResult -TestName 'CA Certificate Published' -Passed $false -Detail "$_"
    }

    # User count across Users and DisabledUsers OUs
    try {
        $activeCount   = (Get-ADUser -Filter * -SearchBase $UsersOUParam -ErrorAction Stop).Count
        $disabledCount = (Get-ADUser -Filter * -SearchBase $DisabledUsersOUParam -ErrorAction Stop).Count
        $totalUsers    = $activeCount + $disabledCount
        Add-TestResult -TestName 'User Count' -Passed ($totalUsers -eq $ExpectedUserCountParam) `
            -Detail "Total: $totalUsers (expected $ExpectedUserCountParam; $activeCount active, $disabledCount disabled)"
    } catch {
        Add-TestResult -TestName 'User Count' -Passed $false -Detail "$_"
    }

    $passCount = ($testResults | Where-Object { $_.Result -eq 'PASS' }).Count
    $failCount = ($testResults | Where-Object { $_.Result -eq 'FAIL' }).Count
    Write-LogInfo "Functional tests complete: $passCount passed, $failCount failed."

    return $testResults
}
#endregion

#region --- Artifacts Export ---
function Export-Artifacts {
    param(
        [System.Collections.Generic.List[object]]$Users,
        [System.Collections.Generic.List[object]]$TestResults,
        [string]$ArtifactsPathParam
    )
    try {
        $null = New-Item -ItemType Directory -Path $ArtifactsPathParam -Force
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'

        $Users | Export-Csv "$ArtifactsPathParam\users-$timestamp.csv" -NoTypeInformation
        $Users | ConvertTo-Json | Out-File "$ArtifactsPathParam\users-$timestamp.json" -Encoding utf8
        $TestResults | Export-Csv "$ArtifactsPathParam\test-results-$timestamp.csv" -NoTypeInformation

        Write-LogSuccess "Artifacts exported to '$ArtifactsPathParam'."
    } catch {
        Write-LogError "Artifact export failed: $_"
        throw
    }
}
#endregion

#region --- Deployment Summary ---
function Write-DeploymentSummary {
    param(
        [int]$UserCountParam,
        [int]$GroupCountParam,
        [int]$ServiceAccountCountParam,
        [int]$ComputerCountParam,
        [int]$MinDAParam,
        [int]$MaxDAParam,
        [int]$TestPassCountParam,
        [int]$TestTotalCountParam,
        [string]$ArtifactsPathParam
    )
    Write-Host ""
    Write-Host "===== DEPLOYMENT SUMMARY =====" -ForegroundColor Cyan
    Write-Host "Users created:       $UserCountParam"
    Write-Host "Groups created:      $GroupCountParam"
    Write-Host "Service accounts:    $ServiceAccountCountParam"
    Write-Host "Computer objects:    $ComputerCountParam"
    Write-Host "DA accounts added:   $MinDAParam-$MaxDAParam (random)"
    Write-Host "Tests:               $TestPassCountParam/$TestTotalCountParam passed"
    Write-Host "Artifacts:           $ArtifactsPathParam"
    Write-Host "=============================="
}
#endregion

#endregion

#region Main Execution Block
try {
    Initialize-Logging `
        -LogPathParam    $logPath `
        -ScriptNameParam "Initialize-ADDirectory.ps1" `
        -CsvLogPathParam $csvErrorLogPath
    Start-Transcript -Path $transcriptPath

    Write-LogInfo "Initialize-ADDirectory.ps1 started."

    if ($RandomSeed -ne 0) {
        $null = Get-Random -SetSeed $RandomSeed
        Write-LogInfo "Random seed set to $RandomSeed for reproducible run."
    }

    #region Pre-Flight
    if (-not (Test-DomainPrerequisites -DomainNameParam $domainName -ArtifactsPathParam $artifactsPath)) {
        throw "Pre-flight checks failed. Review errors above before re-running."
    }
    Remove-PopulateScheduledTask -TaskNameParam $scheduledTaskName
    #endregion

    #region Service Readiness
    Wait-ForADServices
    Export-DiagnosticReports -LogPathParam $logPath
    Set-DnsForwarders -ForwardersParam $dnsForwarders
    #endregion

    #region Post-Promotion Services
    Enable-ADRecycleBin -DomainNameParam $domainName
    Install-EnterpriseRootCA `
        -CACommonNameParam    $caCommonName `
        -CAKeyLengthParam     $caKeyLength `
        -CAHashAlgorithmParam $caHashAlgorithm `
        -CAValidityYearsParam $caValidityYears `
        -CADatabasePathParam  $caDatabasePath `
        -CALogPathParam       $caLogPath
    Set-TimeConfiguration -NtpServersParam $ntpServers
    Test-FirewallRules
    #endregion

    #region CSV Validation and Load
    Test-AllCsvFiles  -CsvBasePath  $csvPath
    Import-LabCsvData -CsvPathParam $csvPath
    #endregion

    #region OU Structure
    New-OUStructure `
        -DomainDNParam $domainDN `
        -OUNamesParam  @('Employees', 'Groups', 'Servers', 'Workstations', 'Admins', 'ServiceAccounts', 'DisabledUsers', 'Quarantine')
    #endregion

    #region Directory Population
    $groupNames   = New-LabGroups `
                        -Count      $GroupCount `
                        -WordSeeds  $script:wordSeeds `
                        -TargetOU   $groupsOU

    $availableCompanyCount = $script:companies.Count
    $maxSelectableCount    = [math]::Min($maxCompanyCount, $availableCompanyCount)
    $effectiveMinCompanyCount = [math]::Min($minCompanyCount, $maxSelectableCount)
    $activeCompanyCount    = Get-Random -Minimum $effectiveMinCompanyCount -Maximum ($maxSelectableCount + 1)
    $activeCompanies       = $script:companies | Get-Random -Count $activeCompanyCount
    Write-LogInfo "Selected $activeCompanyCount of $availableCompanyCount companies for this run."

    $sharedCityRecord      = $script:cities | Get-Random
    Write-LogInfo "Non-remote users assigned to: $($sharedCityRecord.City), $($sharedCityRecord.State)"

    $createdUsers = New-LabUsers `
                        -Count               $UserCount `
                        -UpnPatternParam     $upnPattern `
                        -DomainNameParam     $domainName `
                        -UsersOUParam        $usersOU `
                        -PasswordLengthParam $PasswordLength `
                        -FirstNamesData      $script:firstNames `
                        -LastNamesData       $script:lastNames `
                        -DepartmentsData     $script:departments `
                        -TitlesData          $script:titles `
                        -ActiveCompaniesData $activeCompanies `
                        -OfficesData         $script:offices `
                        -CitiesData          $script:cities `
                        -StreetsData         $script:streets `
                        -PctRemoteUsersParam $pctRemoteUsers `
                        -SharedCityName      $($sharedCityRecord.City) `
                        -SharedCityState     $($sharedCityRecord.State)

    Set-NestedGroupMemberships `
        -GroupNames $groupNames `
        -MaxDepth   $MaxGroupNestingDepth

    Set-UserManagers -Users $createdUsers

    Set-UserStateRandomization `
        -Users                  $createdUsers `
        -PctDisabledParam       $pctDisabled `
        -PctPwExpiredParam      $pctPwExpired `
        -PctPwNeverExpiresParam $pctPwNeverExpires `
        -PctSmartcardParam      $pctSmartcard `
        -PctLockedParam         $pctLocked `
        -DisabledUsersOUParam   $disabledUsersOU `
        -DomainNameParam        $domainName `
        -LockoutThresholdParam  $lockoutThreshold

    # Project the SAM list once; reused by group-membership and Domain Admins population below.
    $userSams = $createdUsers | ForEach-Object { $_.Sam }

    Set-GroupMemberships `
        -GroupNames  $groupNames `
        -UserSams    $userSams `
        -MinMembers  $MinGroupMembers `
        -MaxMembers  $MaxGroupMembers

    Set-DomainAdminMemberships `
        -UserSams    $userSams `
        -MinDAParam  $MinDA `
        -MaxDAParam  $MaxDA

    New-ServiceAccounts `
        -ServiceAccountDefs  $script:serviceAcctDefs `
        -TargetOU            $serviceAccountsOU `
        -PasswordLengthParam $PasswordLength

    if ($ComputerCount -gt 0) {
        New-ComputerObjects `
            -Count                  $ComputerCount `
            -Seeds                  $script:computerSeeds `
            -WorkstationPrefixParam $workstationPrefix `
            -ServerPrefixParam      $serverPrefix `
            -LaptopPrefixParam      $laptopPrefix `
            -WorkstationsOUParam    $workstationsOU `
            -ServersOUParam         $serversOU
    }
    #endregion

    #region Infrastructure Configuration
    Set-GPOBaseline `
        -DomainNameParam     $domainName `
        -DomainDNParam       $domainDN `
        -WorkstationsOUParam $workstationsOU `
        -ServersOUParam      $serversOU
    Set-PasswordPolicy `
        -DomainNameParam         $domainName `
        -MinPwLenParam           $minPasswordLength `
        -PwHistoryCountParam     $passwordHistoryCount `
        -LockoutThresholdParam   $lockoutThreshold `
        -LockoutDurationMinParam $lockoutDurationMinutes `
        -MaxPwAgeDaysParam       $maxPasswordAgeDays
    Set-ADSiteTopology `
        -PrimarySiteNameParam $primarySiteName `
        -PrimarySubnetParam   $primarySubnet
    #endregion

    #region Validation and Reporting
    $testResults = Invoke-FunctionalTests `
        -UsersOUParam           $usersOU `
        -DisabledUsersOUParam   $disabledUsersOU `
        -DomainNameParam        $domainName `
        -MinDAParam             $MinDA `
        -ExpectedUserCountParam $UserCount `
        -CACommonNameParam      $caCommonName
    Export-Artifacts -Users $createdUsers -TestResults $testResults -ArtifactsPathParam $artifactsPath

    $passCount = ($testResults | Where-Object { $_.Result -eq 'PASS' }).Count
    Write-DeploymentSummary `
        -UserCountParam           $($createdUsers.Count) `
        -GroupCountParam          $GroupCount `
        -ServiceAccountCountParam $($script:serviceAcctDefs.Count) `
        -ComputerCountParam       $ComputerCount `
        -MinDAParam               $MinDA `
        -MaxDAParam               $MaxDA `
        -TestPassCountParam       $passCount `
        -TestTotalCountParam      $($testResults.Count) `
        -ArtifactsPathParam       $artifactsPath
    #endregion

    Write-LogSuccess "Initialize-ADDirectory.ps1 complete. Review artifacts at '$artifactsPath'."
} catch {
    Write-LogError "Initialize-ADDirectory.ps1 terminated with fatal error: $_"
} finally {
    try { Stop-Transcript } catch { } # Intentional: suppress error if Start-Transcript was never reached
}
#endregion
