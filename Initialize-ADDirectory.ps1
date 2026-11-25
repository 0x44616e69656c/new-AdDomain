<#
.SYNOPSIS
    Configures post-promotion AD services and populates the directory with lab data.
.DESCRIPTION
    Validates domain services, enables the Recycle Bin, deploys the Enterprise CA,
    configures DNS forwarders, time synchronization, and firewall, creates the OU hierarchy, and
    populates the directory with users, groups, computers, and service accounts.
    Deploys baseline GPOs, configures the password policy, puts the DC in its primary
    site with the DC's own subnet, runs functional validation tests, and exports
    summary artifacts.

    The domain and site values come from include\global-config.ps1 and, when present,
    the build profile include\build-profile.psd1. The profile's results are logged
    after the "started" line, and a profile error stops the run before anything is
    changed. Service account SPNs in config\serviceaccounts.csv may name hosts with the
    {DomainName} placeholder, which is replaced with the build's domain.

    The site step renames Default-First-Site-Name to the requested site name, so the DC
    stays in the default site link, and creates the subnet the DC's address sits in
    ('Auto') or the requested subnet when it contains that address. A name already
    taken, a DC already in another site, or a subnet held by another site is reported
    with a warning and a failed test row, never a stop.

    It runs when something starts it after the promotion reboot: build-lab, unattended
    and with -LaunchId, the AD-Populate-PostPromotion logon task, or you by hand. It
    removes that scheduled task on startup if present, so it does not re-run at
    subsequent logons. The CSV files are validated first, so a CSV fix plus a logon
    re-runs population.

    A build profile's Population, DomainAdminCount and PopulationSeed set this run's
    population. Every run logs the random seed it used, drawn when none was given, so a
    population can be repeated, and writes artifacts\population-result.json when it
    starts and when it ends, which build-lab reads to know how the run went. The
    artifacts folder also gets a comparison export of the users, groups and memberships
    made, for telling two builds apart. Passwords come from a cryptographic generator,
    so a seed never repeats them, and none of those files holds one.

    Settings you keep from build to build go in overrides\overrides.psd1, which
    global-config.ps1 reads. OVERRIDE.md lists them. A file under overrides\config
    replaces the shipped CSV of the same name. The script logs its version in the
    "started" line and stops before any change when include\global-config.ps1 is older
    than the release it needs.

    Run as: Domain Administrator (post-promotion).
.PARAMETER UserCount
    The number of users to create.
    The default can also be set in overrides\overrides.psd1, key UserCount. A value given
    here wins over it.
.PARAMETER GroupCount
    The number of groups to create before nesting.
    The default can also be set in overrides\overrides.psd1, key GroupCount. A value given
    here wins over it.
.PARAMETER ComputerCount
    The number of computer objects to create. 0 skips computer creation.
    The default can also be set in overrides\overrides.psd1, key ComputerCount. A value given
    here wins over it.
.PARAMETER PasswordLength
    The length of each generated password, 4 to 94. A length below the domain's
    effective MinPasswordLength, or below the minimum the domain enforces before this
    script sets its policy, is raised to the larger, with a warning.
    The default can also be set in overrides\overrides.psd1, key PasswordLength. A value given
    here wins over it.
.PARAMETER MinGroupMembers
    The fewest members assigned to each group.
    The default can also be set in overrides\overrides.psd1, key MinGroupMembers. A value given
    here wins over it.
.PARAMETER MaxGroupMembers
    The most members assigned to each group.
    The default can also be set in overrides\overrides.psd1, key MaxGroupMembers. A value given
    here wins over it.
.PARAMETER MinDA
    The fewest users added to Domain Admins. The number is random within the range.
    The default can also be set in overrides\overrides.psd1, key MinDA. A value given
    here wins over it.
.PARAMETER MaxDA
    The most users added to Domain Admins.
    The default can also be set in overrides\overrides.psd1, key MaxDA. A value given
    here wins over it.
.PARAMETER MaxGroupNestingDepth
    The deepest group-in-group nesting.
    The default can also be set in overrides\overrides.psd1, key MaxGroupNestingDepth. A value given
    here wins over it.
.PARAMETER RandomSeed
    Seeds the random number generator for a reproducible population. 0 draws a seed,
    logs it and uses it, so each run differs and any run can be repeated from its log. A
    build profile sets it as PopulationSeed. A value given here replaces the profile's,
    with a warning when they differ.
    The default can also be set in overrides\overrides.psd1, key RandomSeed. A value given
    here wins over it.
.PARAMETER Population
    How much of the directory to fill. Full is 1000 users and 50 groups, what every
    release has built. Minimal is 25 users and 5 groups. None creates no users, groups, service accounts or Domain
    Admins, and still builds the OUs, the CA, the GPOs, the password policy and the site.
    A count given on the command line wins over the preset. A build profile's Population
    also sets it, and a value given here replaces the profile's, with a warning when they
    differ.
    The default can also be set in overrides\overrides.psd1, key Population. A value given
    here wins over it.
.PARAMETER DomainAdminCount
    A fixed number of generated users added to Domain Admins, 0 or more. Left out, the
    number is random from -MinDA to -MaxDA. A build profile's DomainAdminCount also sets
    it, and a value given here replaces the profile's, with a warning when they differ.
    The default can also be set in overrides\overrides.psd1, key DomainAdminCount. A value
    given here wins over it.
.PARAMETER LaunchId
    An identifier build-lab passes for each launch, written back in the completion
    marker so build-lab can tell its own run's result. Leave it out for a run by hand.
.EXAMPLE
    .\Initialize-ADDirectory.ps1
    .\Initialize-ADDirectory.ps1 -UserCount 500 -GroupCount 25
    .\Initialize-ADDirectory.ps1 -Population Minimal -DomainAdminCount 0 -RandomSeed 20261028
.NOTES
    Version:      2.2.0
    Author:       Daniel Owen
    Release Date: 2026-11-25
    SPDX-License-Identifier: MIT
    Requirements: Windows Server 2025, PowerShell 5.1+, Domain Administrator
.LINK
    https://github.com/0x44616e69656c/new-AdDomain
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
    [int]$RandomSeed           = 0,
    [ValidateSet('Full', 'Minimal', 'None')][string]$Population = 'Full',
    [ValidateRange(0, 2147483647)][int]$DomainAdminCount,
    [string]$LaunchId          = ''
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

#region Override File Parameters
# The override file's values for this script's parameters, which global-config.ps1 read.
# Each is applied here, at script level, with Set-Variable, so the parameter's own
# attributes check it. A function or a scriptblock run with & would set a copy and leave
# the parameter alone. A parameter given on the command line keeps its value. A refused
# value leaves the default, and the run stops once logging has started.
$overrideAssignmentResult  = $null
$overrideAssignmentRefused = [System.Collections.Generic.List[object]]::new()
$overrideAssignedKeys      = @{}
if (-not $overrideFileError -and $null -ne $overrideFileResult -and
    (Get-Command -Name 'Get-OverrideParameterAssignment' -CommandType Function -ErrorAction SilentlyContinue)) {
    $overrideAssignmentResult = Get-OverrideParameterAssignment -OverrideFile $overrideFileResult -CatalogPath $overrideFileCatalogPath -BoundParameters $PSBoundParameters
    foreach ($overrideAssignment in @($overrideAssignmentResult.Assignments)) {
        try {
            Set-Variable -Name $overrideAssignment.ParameterName -Value $overrideAssignment.Value
            $overrideAssignedKeys[$overrideAssignment.ParameterName] = $overrideAssignment.Key
        } catch {
            $overrideAssignmentRefused.Add($overrideAssignment)
        }
    }
}
#endregion

#region Script-Local Configuration
# Equal to the Version line above. The "started" line logs it.
$scriptVersion               = '2.2.0'
# The oldest include\global-config.ps1 this script runs with: the first published one
# that hands it the population settings, $buildProfilePopulation.
$requiredGlobalConfigVersion = '2.2.0'
$transcriptPath        = "$logPath\Initialize-ADDirectory-$(Get-Date -Format yyyyMMddHHmmss).log"
# The completion marker's fields, artifacts\population-result.json. A field this run
# hasn't reached yet stays null, so a reader can tell "not known" from a value.
$populationResult = [ordered]@{
    MarkerVersion     = 1
    LaunchId          = $LaunchId
    State             = 'Running'
    StartedUtc        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    FinishedUtc       = ''
    ScriptVersion     = $scriptVersion
    Population        = $null
    DomainAdminCount  = $null
    RandomSeed        = $null
    RandomSeedSource  = $null
    UsersCreated      = 0
    GroupsCreated     = 0
    DomainAdminsAdded = 0
    TestsPassed       = 0
    TestsFailed       = 0
    FailedTests       = @()
    Error             = ''
    ArtifactFiles     = @()
}
$populationFailed = $false
#endregion

#region Functions

#region --- Retry Wrapper ---
function Invoke-ADWriteWithRetry {
    # Runs Operation, and again after a failure, up to RetryCount attempts in all.
    # TestLanded is for a create: a script block that returns true when the object Operation
    # makes exists. With it, each attempt after the first asks it first. A create can fail
    # after it has made its object (New-ADUser leaves the account behind, disabled, when
    # Windows refuses its password), and running it again only gives "already exists". So
    # the create runs again only when the check says the object isn't there. When the object
    # is there, this stops with a message naming it. A check that fails counts as a failed
    # attempt, never as "not there".
    param(
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$OperationName,
        [int]$RetryCount    = 12,
        [int]$RetryDelaySec = 10,
        [scriptblock]$TestLanded
    )
    $operationError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $objectLanded     = $false
        $operationStarted = $false
        try {
            if ($attempt -gt 1 -and $null -ne $TestLanded) {
                $objectLanded = [bool](& $TestLanded)
            }
            if (-not $objectLanded) {
                $operationStarted = $true
                & $Operation
                return
            }
        } catch {
            if ($operationStarted) { $operationError = $_ }
            Write-LogWarn "Attempt $attempt of $RetryCount failed for [$OperationName]: $_"
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySec
            } else {
                Write-LogError "All $RetryCount attempts exhausted for [$OperationName]. Last error: $_"
                throw
            }
            continue
        }
        $landedMessage = "[$OperationName] failed, and a check shows the object was made anyway, so it isn't made again. It may be incomplete (a user whose password Windows refused is left disabled with no password). Delete it, then build the lab again. The error was: $operationError"
        Write-LogError $landedMessage
        throw $landedMessage
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
        # /manualpeerlist takes a space-delimited list, with more than one peer in
        # quotation marks, as one argument (Microsoft, "Windows Time Service Tools and
        # Settings"). A comma would separate a peer from its flags, such as ,0x8. One peer
        # is passed as before.
        $ntpList = @($NtpServersParam) -join ' '
        $peerListArgument = if (@($NtpServersParam).Count -gt 1) { "/manualpeerlist:`"$ntpList`"" } else { "/manualpeerlist:$ntpList" }
        $null = w32tm /config $peerListArgument /syncfromflags:manual /reliable:yes /update
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
    # CsvFilePathsParam maps each CSV name to the file to read, which global-config.ps1
    # resolved: a replacement under overrides\config, or the shipped config\ file.
    param(
        [System.Collections.IDictionary]$CsvFilePathsParam,
        [string]$DomainNameParam
    )
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
        $filePath = [string]$CsvFilePathsParam[$($spec.File)]
        if (-not $filePath -or -not (Test-Path -LiteralPath $filePath)) {
            $failures += "MISSING: $($spec.File)"
            continue
        }
        try {
            # @() so a single row counts as one. Windows PowerShell 5.1 gives one row as a lone object with no Count.
            $data = @(Import-Csv -LiteralPath $filePath)
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

    # A brace left in an SPN after {DomainName} substitution is a misspelled placeholder
    # such as {Domain}. Test-ServicePrincipalNamePlaceholder comes from include\BuildProfile.ps1.
    $serviceAccountCsvPath = [string]$CsvFilePathsParam['serviceaccounts.csv']
    if ($serviceAccountCsvPath -and (Test-Path -LiteralPath $serviceAccountCsvPath)) {
        try {
            foreach ($placeholderRow in @(Test-ServicePrincipalNamePlaceholder -CsvPath $serviceAccountCsvPath -DomainName $DomainNameParam)) {
                $failures += "UNRESOLVED PLACEHOLDER in serviceaccounts.csv row $($placeholderRow.RowNumber) (Name '$($placeholderRow.Name)'): SPN '$($placeholderRow.ServicePrincipalName)' still holds a brace after {DomainName} substitution ('$($placeholderRow.ResolvedServicePrincipalName)'). Write the placeholder as {DomainName}."
            }
            # A literal SPN naming a host in another domain is allowed, so it is only a
            # WARN. It is how a 1.0 CSV's lab.local SPNs look in a lab.test forest.
            foreach ($otherDomainRow in @(Test-ServicePrincipalNameDomain -CsvPath $serviceAccountCsvPath -DomainName $DomainNameParam)) {
                Write-LogWarn "serviceaccounts.csv row $($otherDomainRow.RowNumber) (Name '$($otherDomainRow.Name)'): SPN '$($otherDomainRow.ServicePrincipalName)' names host '$($otherDomainRow.HostName)', which is outside the build's domain '$DomainNameParam'. It is written as given. If it should follow the domain, write it as '$($otherDomainRow.SuggestedServicePrincipalName)'."
            }
        } catch {
            $failures += "UNREADABLE: serviceaccounts.csv -- $_"
        }
    }

    if ($failures.Count -gt 0) {
        foreach ($f in $failures) { Write-LogError $f }
        throw "CSV validation failed with $($failures.Count) error(s). Fix the issues above before running."
    }
    Write-LogSuccess "All $($csvSpecs.Count) CSV files validated."
}

function Import-LabCsvData {
    # CsvFilePathsParam maps each CSV name to the file to read, as for Test-AllCsvFiles.
    param([System.Collections.IDictionary]$CsvFilePathsParam)
    try {
        # @() so a single row counts as one. Windows PowerShell 5.1 gives one row as a lone object with no Count.
        $script:firstNames      = @(Import-Csv -LiteralPath $CsvFilePathsParam['first.csv'])
        $script:lastNames       = @(Import-Csv -LiteralPath $CsvFilePathsParam['last.csv'])
        $script:wordSeeds       = @(Import-Csv -LiteralPath $CsvFilePathsParam['words.csv'])
        $script:departments     = @(Import-Csv -LiteralPath $CsvFilePathsParam['departments.csv'])
        $script:titles          = @(Import-Csv -LiteralPath $CsvFilePathsParam['titles.csv'])
        $script:offices         = @(Import-Csv -LiteralPath $CsvFilePathsParam['offices.csv'])
        $script:cities          = @(Import-Csv -LiteralPath $CsvFilePathsParam['cities.csv'])
        $script:companies       = @(Import-Csv -LiteralPath $CsvFilePathsParam['companies.csv'])
        $script:streets         = @(Import-Csv -LiteralPath $CsvFilePathsParam['streets.csv'])
        $script:computerSeeds   = @(Import-Csv -LiteralPath $CsvFilePathsParam['computers.csv'])
        $script:serviceAcctDefs = @(Import-Csv -LiteralPath $CsvFilePathsParam['serviceaccounts.csv'])
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

function Get-CryptoRandomCharacter {
    # Count distinct character codes from printable ASCII 33 to 126, drawn with a
    # cryptographic generator. A partial Fisher-Yates shuffle keeps them distinct, and each
    # index is drawn by rejection sampling, so no character is likelier than another.
    # RandomNumberGenerator.GetInt32 is .NET Core only, so the index is drawn here.
    param([ValidateRange(0, 94)][int]$Count)
    $characterPool = [int[]](33..126)
    $randomBytes   = New-Object -TypeName byte[] -ArgumentList 4
    $generator     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($poolIndex = 0; $poolIndex -lt $Count; $poolIndex++) {
            $span  = [uint64]($characterPool.Length - $poolIndex)
            $limit = [uint64]4294967296 - ([uint64]4294967296 % $span)
            do {
                $generator.GetBytes($randomBytes)
                $draw = [uint64][System.BitConverter]::ToUInt32($randomBytes, 0)
            } while ($draw -ge $limit)
            $pickIndex = $poolIndex + [int]($draw % $span)
            $swapValue = $characterPool[$poolIndex]
            $characterPool[$poolIndex] = $characterPool[$pickIndex]
            $characterPool[$pickIndex] = $swapValue
        }
    } finally {
        $generator.Dispose()
    }
    if ($Count -eq 0) { return }
    return $characterPool[0..($Count - 1)]
}

function New-CompliantPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The lab generates each password here and keeps the plain text too, because the users export in the artifacts folder lists every generated password.')]
    # SamAccountName and DisplayName are the account's names. A password that holds one is
    # drawn again. NameRedraws in the result counts those draws.
    param(
        [int]$Length,
        [string]$SamAccountName,
        [string]$DisplayName
    )
    # Range 33-126 covers all printable ASCII (94 chars). $Length must be <= 94 for no-replacement pick.
    if ($Length -gt 94) {
        throw "PasswordLength $Length exceeds maximum of 94 (printable ASCII range 33-126 has 94 characters)."
    }
    # The complexity check requires upper, lower, digit, and symbol. A length below 4 can never satisfy
    # all four classes, so every draw would be refused -- reject it up front.
    if ($Length -lt 4) {
        throw "PasswordLength $Length is below the minimum of 4 needed to satisfy all four complexity classes (upper, lower, digit, symbol)."
    }
    # Windows refuses a password that holds the account's names when "Password must meet
    # complexity requirements" is on (Microsoft Learn, "Password must meet complexity
    # requirements"): the whole samAccountName, when it has 3 or more characters, and each
    # token of 3 or more characters of the displayName, split at commas, periods, hyphens,
    # underscores, spaces, pound signs and tabs. Neither check is case-sensitive.
    $nameTokens = [System.Collections.Generic.List[string]]::new()
    if ($SamAccountName.Length -ge 3) { $nameTokens.Add($SamAccountName) }
    foreach ($displayToken in $DisplayName.Split([char[]]@(',', '.', '-', '_', ' ', '#', "`t"))) {
        if ($displayToken.Length -ge 3) { $nameTokens.Add($displayToken) }
    }
    # The characters come from a cryptographic generator, outside Get-Random's seeded
    # stream, so a seed never repeats a password. Every refused draw counts toward one
    # bound, so no name and no defect can keep this drawing forever. At length 4 about 7
    # draws in 100 hold all four classes, so 1000 refused draws in a row don't happen by
    # chance.
    $maxDraws    = 1000
    $nameRedraws = 0
    for ($draw = 1; $draw -le $maxDraws; $draw++) {
        $rawPassword = -join (Get-CryptoRandomCharacter -Count $Length | ForEach-Object { [char]$_ })
        if ($rawPassword -cnotmatch '[A-Z]' -or
            $rawPassword -cnotmatch '[a-z]' -or
            $rawPassword -notmatch '\d'    -or
            $rawPassword -notmatch '[^a-zA-Z0-9]') {
            continue
        }
        $holdsName = $false
        foreach ($nameToken in $nameTokens) {
            if ($rawPassword.IndexOf($nameToken, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $holdsName = $true
                break
            }
        }
        if ($holdsName) {
            $nameRedraws++
            continue
        }
        return [pscustomobject]@{
            Plain       = $rawPassword
            Secure      = ConvertTo-SecureString $rawPassword -AsPlainText -Force
            NameRedraws = $nameRedraws
        }
    }
    $accountText = if ($SamAccountName) { "'$SamAccountName'" } else { 'an account with no name given' }
    throw "Couldn't draw a $Length-character password for $accountText that holds an upper-case letter, a lower-case letter, a digit and a symbol and none of the account's names, in $maxDraws draws. Check the names for this account (first.csv and last.csv, or serviceaccounts.csv) and PasswordLength, then build the lab again."
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

function Resolve-PopulationSetting {
    <#
    .SYNOPSIS
        Works out this run's population settings, with the lines to log. No AD call.
    .DESCRIPTION
        Per setting the first that holds a value wins: the command line, the build
        profile, the override file, the default. The profile, the override file and the
        default arrive merged in PopulationProfile (global-config.ps1's
        $buildProfilePopulation), so this adds the command line, the presets and the
        counts. A count comes from the command line, then the preset of a Population given
        on the command line or in the profile, then the override file, then the preset of
        the override file's Population, then the value the script holds. A command-line
        value that differs from the profile's logs a WARN naming both, and an equal one
        an INFO. A preset that would clash with a count somebody set in the same pair
        gives way to it, with a WARN.
    .PARAMETER PopulationProfile
        $buildProfilePopulation: PopulationSeed, Population, DomainAdminCount and
        PopulationSource. $null gives the defaults.
    .PARAMETER BoundParameter
        A copy of the script's $PSBoundParameters.
    .PARAMETER CountValue
        The values the script holds for UserCount, GroupCount, ComputerCount,
        MinGroupMembers, MaxGroupMembers, MinDA and MaxDA, after the override file and the
        count-pair check.
    .PARAMETER OverrideAssignedKey
        Parameter name to key, for each value the override file assigned.
    .PARAMETER OverrideLabel
        The override file's label, "Override file '<path>'".
    .PARAMETER ProfilePath
        The build profile read, or empty.
    .OUTPUTS
        PSCustomObject with Population, DomainAdminMode (Fixed or Random),
        DomainAdminCount (the fixed count, or $null), MinDA, MaxDA, DomainAdminSourceText,
        PopulationSeed (Random or a whole number), SeedSource (Parameter, Profile,
        OverrideFile or Default), SeedSourceText, Counts, Info and Warnings (lists) and
        SettingsLine.
    #>
    param (
        [AllowNull()][object]$PopulationProfile,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameter,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CountValue,
        [AllowNull()][System.Collections.IDictionary]$OverrideAssignedKey,
        [AllowNull()][AllowEmptyString()][string]$OverrideLabel,
        [AllowNull()][AllowEmptyString()][string]$ProfilePath
    )
    $infoLines    = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $profileText  = "build profile '$ProfilePath'"
    $overrideText = 'the override file'
    if ($OverrideLabel) { $overrideText = $OverrideLabel.Substring(0, 1).ToLowerInvariant() + $OverrideLabel.Substring(1) }
    $assignedKeys = @{}
    if ($null -ne $OverrideAssignedKey) { foreach ($assignedName in @($OverrideAssignedKey.get_Keys())) { $assignedKeys[[string]$assignedName] = $true } }

    # The profile, the override file and the default, merged by Get-BuildProfile.
    $merged       = @{ PopulationSeed = 'Random'; Population = 'Full'; DomainAdminCount = 'Random' }
    $mergedSource = @{ PopulationSeed = 'Default'; Population = 'Default'; DomainAdminCount = 'Default' }
    if ($null -ne $PopulationProfile) {
        foreach ($keyName in @('PopulationSeed', 'Population', 'DomainAdminCount')) {
            if ($null -ne $PopulationProfile.$keyName) {
                $merged[$keyName] = $PopulationProfile.$keyName
                if ($null -ne $PopulationProfile.PopulationSource -and $PopulationProfile.PopulationSource.Contains($keyName)) { $mergedSource[$keyName] = [string]$PopulationProfile.PopulationSource[$keyName] }
            }
        }
    }

    # A bound parameter against the profile's value for the same setting. A command-line
    # value over an override file value already has the reader's INFO line.
    $compareWithProfile = {
        param ([string]$ParameterText, [string]$KeyName, [object]$BoundValue)
        if ($mergedSource[$KeyName] -eq 'Profile') {
            if ([string]::Equals([string]$BoundValue, [string]$merged[$KeyName], [System.StringComparison]::OrdinalIgnoreCase)) {
                $infoLines.Add("Initialize-ADDirectory.ps1 $ParameterText matches $KeyName $($merged[$KeyName]) from $profileText.")
            } else {
                $warningLines.Add("Initialize-ADDirectory.ps1 $ParameterText replaces $KeyName $($merged[$KeyName]) from $profileText.")
            }
        } elseif ($mergedSource[$KeyName] -ne 'OverrideFile') {
            $infoLines.Add("Initialize-ADDirectory.ps1 $ParameterText is used.")
        }
    }

    #region Population
    if ($BoundParameter.Contains('Population')) {
        $boundPopulation = ([string]$BoundParameter['Population']).Trim()
        $populationValue = [string](@('Full', 'Minimal', 'None') | Where-Object { $_ -eq $boundPopulation } | Select-Object -First 1)
        & $compareWithProfile "-Population $boundPopulation" 'Population' $populationValue
        $populationSource = 'Parameter'
    } else {
        $populationValue  = [string]$merged['Population']
        $populationSource = $mergedSource['Population']
    }
    $populationOrigin = switch ($populationSource) {
        'Parameter'    { "Population $populationValue from the command line" }
        'Profile'      { "Population $populationValue from $profileText" }
        'OverrideFile' { "Population $populationValue from $overrideText" }
        default        { "Population $populationValue" }
    }
    #endregion

    #region The seed
    if ($BoundParameter.Contains('RandomSeed')) {
        $boundSeed  = [int]$BoundParameter['RandomSeed']
        $seedValue  = if ($boundSeed -eq 0) { 'Random' } else { $boundSeed }
        & $compareWithProfile "-RandomSeed $boundSeed" 'PopulationSeed' $seedValue
        $seedSource = 'Parameter'
    } else {
        $seedValue  = $merged['PopulationSeed']
        $seedSource = $mergedSource['PopulationSeed']
    }
    #endregion

    #region Domain Admins
    $minDA = [int]$CountValue['MinDA']
    $maxDA = [int]$CountValue['MaxDA']
    $rangeParameters = @(@('MinDA', 'MaxDA') | Where-Object { $BoundParameter.Contains($_) } | ForEach-Object { "-$_ $($BoundParameter[$_])" })
    $domainAdminCount = $null
    if ($BoundParameter.Contains('DomainAdminCount')) {
        $domainAdminMode   = 'Fixed'
        $domainAdminCount  = [int]$BoundParameter['DomainAdminCount']
        $domainAdminSource = 'Parameter'
        & $compareWithProfile "-DomainAdminCount $domainAdminCount" 'DomainAdminCount' $domainAdminCount
    } elseif ($rangeParameters.Count -gt 0) {
        # -MinDA or -MaxDA on the command line means Random within the range given.
        $domainAdminMode   = 'Random'
        $domainAdminSource = 'Parameter'
        $rangeText = $rangeParameters -join ' '
        if ($mergedSource['DomainAdminCount'] -eq 'Profile' -and $merged['DomainAdminCount'] -isnot [string]) {
            $warningLines.Add("Initialize-ADDirectory.ps1 $rangeText replaces DomainAdminCount $($merged['DomainAdminCount']) from $profileText with Random from $minDA to $maxDA.")
        } elseif ($mergedSource['DomainAdminCount'] -eq 'Profile') {
            $infoLines.Add("Initialize-ADDirectory.ps1 $rangeText gives DomainAdminCount Random from $profileText the range $minDA to $maxDA.")
        } elseif ($mergedSource['DomainAdminCount'] -eq 'OverrideFile') {
            $infoLines.Add("$($OverrideLabel): DomainAdminCount=$($merged['DomainAdminCount']) not used; the command line gave $rangeText, so the count is random from $minDA to $maxDA.")
        }
    } elseif ($mergedSource['DomainAdminCount'] -ne 'Default' -and $merged['DomainAdminCount'] -isnot [string]) {
        # A fixed count beats a range from the same layer or a lower one.
        $domainAdminMode   = 'Fixed'
        $domainAdminCount  = [int]$merged['DomainAdminCount']
        $domainAdminSource = $mergedSource['DomainAdminCount']
        $passedOver = @(@('MinDA', 'MaxDA') | Where-Object { $assignedKeys.ContainsKey($_) } | ForEach-Object { "$_=$($CountValue[$_])" })
        if ($passedOver.Count -gt 0) {
            $countOrigin = if ($domainAdminSource -eq 'Profile') { "from $profileText" } else { 'from the same file' }
            $infoLines.Add("$($OverrideLabel): $($passedOver -join ' and ') not used; DomainAdminCount $domainAdminCount $countOrigin sets a fixed count.")
        }
    } else {
        $domainAdminMode   = 'Random'
        $domainAdminSource = $mergedSource['DomainAdminCount']
        if ($domainAdminSource -eq 'Default' -and ($assignedKeys.ContainsKey('MinDA') -or $assignedKeys.ContainsKey('MaxDA'))) { $domainAdminSource = 'OverrideFile' }
    }
    #endregion

    #region The counts and the presets
    $presets = @{
        Full    = @{ UserCount = 1000; GroupCount = 50; ComputerCount = 0; MinGroupMembers = 2; MaxGroupMembers = 10 }
        Minimal = @{ UserCount = 25; GroupCount = 5; ComputerCount = 0; MinGroupMembers = 2; MaxGroupMembers = 5 }
        None    = @{ UserCount = 0; GroupCount = 0; ComputerCount = 0 }
    }
    $preset      = $presets[$populationValue]
    $presetGiven = @('Parameter', 'Profile') -contains $populationSource
    $counts      = [ordered]@{}
    $countSource = @{}
    foreach ($countName in @('UserCount', 'GroupCount', 'ComputerCount', 'MinGroupMembers', 'MaxGroupMembers')) {
        $heldValue = [int]$CountValue[$countName]
        $hasPreset = $preset.ContainsKey($countName)
        if ($BoundParameter.Contains($countName)) {
            $counts[$countName]      = $heldValue
            $countSource[$countName] = 'Parameter'
            if ($hasPreset -and $populationSource -ne 'Default' -and $preset[$countName] -ne $heldValue) {
                $infoLines.Add("Initialize-ADDirectory.ps1 -$countName $heldValue replaces Population $($populationValue)'s $($preset[$countName]).")
            }
        } elseif ($hasPreset -and $presetGiven) {
            $counts[$countName]      = [int]$preset[$countName]
            $countSource[$countName] = 'Preset'
            if ($assignedKeys.ContainsKey($countName) -and $heldValue -ne $preset[$countName]) {
                $infoLines.Add("$($OverrideLabel): $countName=$heldValue not used; $populationOrigin sets $($preset[$countName]).")
            }
        } elseif ($assignedKeys.ContainsKey($countName)) {
            $counts[$countName]      = $heldValue
            $countSource[$countName] = 'OverrideFile'
        } elseif ($hasPreset -and $populationSource -eq 'OverrideFile') {
            $counts[$countName]      = [int]$preset[$countName]
            $countSource[$countName] = 'Preset'
        } else {
            $counts[$countName]      = $heldValue
            $countSource[$countName] = 'Default'
        }
    }
    # A preset gives way to a group member count somebody set, rather than clash with it.
    if ($counts['MinGroupMembers'] -gt $counts['MaxGroupMembers']) {
        foreach ($pairSide in @(@('MaxGroupMembers', 'MinGroupMembers', 'above', 'raising'), @('MinGroupMembers', 'MaxGroupMembers', 'below', 'lowering'))) {
            $presetName = $pairSide[0]
            $setName    = $pairSide[1]
            if ($countSource[$presetName] -ne 'Preset' -or $countSource[$setName] -eq 'Preset' -or $countSource[$setName] -eq 'Default') { continue }
            $setterText = if ($countSource[$setName] -eq 'Parameter') { "Initialize-ADDirectory.ps1 -$setName $($counts[$setName])" } else { "$($OverrideLabel): $setName=$($counts[$setName])" }
            $warningLines.Add("$setterText is $($pairSide[2]) Population $($populationValue)'s $presetName $($counts[$presetName]); $($pairSide[3]) $presetName to $($counts[$setName]).")
            $counts[$presetName] = $counts[$setName]
            break
        }
    }
    $counts['MinDA'] = $minDA
    $counts['MaxDA'] = $maxDA
    #endregion

    #region The line that names every value and its source
    $shortSource = @{ Parameter = 'command line'; Profile = $profileText; OverrideFile = $overrideText; Default = 'default' }
    $domainAdminText = if ($domainAdminMode -eq 'Fixed') { [string]$domainAdminCount } else { 'Random' }
    $settingParts = @(
        @('Population', $populationValue, $populationSource),
        @('DomainAdminCount', $domainAdminText, $domainAdminSource),
        @('PopulationSeed', [string]$seedValue, $seedSource))
    $distinctSources = @($settingParts | ForEach-Object { $_[2] } | Select-Object -Unique)
    if ($distinctSources.Count -eq 1) {
        $commonText = switch ($distinctSources[0]) {
            'Parameter'    { '(from the command line)' }
            'Profile'      { "(from $profileText)" }
            'OverrideFile' { "(from $overrideText)" }
            default        { '(Initialize-ADDirectory.ps1 defaults)' }
        }
        $settingsLine = "Population settings: $((@($settingParts | ForEach-Object { "$($_[0])=$($_[1])" })) -join ', ') $commonText"
    } else {
        $settingsLine = "Population settings: $((@($settingParts | ForEach-Object { "$($_[0])=$($_[1]) ($($shortSource[$_[2]]))" })) -join ', ')"
    }
    $seedSourceText = switch ($seedSource) {
        'Parameter'    { 'from the command line' }
        'Profile'      { "from $profileText" }
        'OverrideFile' { "from $overrideText" }
        default        { $null }
    }
    $domainAdminSourceText = switch ($domainAdminSource) {
        'Parameter'    { 'the command line' }
        'Profile'      { $profileText }
        'OverrideFile' { $overrideText }
        default        { 'the default' }
    }
    #endregion

    return [pscustomobject]@{
        Population            = $populationValue
        DomainAdminMode       = $domainAdminMode
        DomainAdminCount      = $domainAdminCount
        MinDA                 = $minDA
        MaxDA                 = $maxDA
        DomainAdminSourceText = $domainAdminSourceText
        PopulationSeed        = $seedValue
        SeedSource            = $seedSource
        SeedSourceText        = $seedSourceText
        Counts                = $counts
        Info                  = [string[]]$infoLines.ToArray()
        Warnings              = [string[]]$warningLines.ToArray()
        SettingsLine          = $settingsLine
    }
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
        [string]$EmployeeOUParam,
        [int]$PasswordLengthParam,
        [array]$FirstNamesData,
        [array]$LastNamesData,
        [array]$DepartmentsData,
        [array]$TitlesData,
        [array]$ActiveCompaniesData,
        [array]$OfficesData,
        [array]$CitiesData,
        [array]$StreetsData,
        [int]$PctRemoteParam,
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
    $nameRedrawTotal  = 0

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
            $isRemote    = (Get-Random -Minimum 1 -Maximum 101) -le $PctRemoteParam
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
            # The final sam, after Resolve-UniqueSam, since that is the one Windows checks.
            $pwResult    = New-CompliantPassword -Length $PasswordLengthParam -SamAccountName $sam -DisplayName $($identity.DisplayName)
            $nameRedrawTotal += $pwResult.NameRedraws

            $localSam        = $sam
            $localSamFilter  = ConvertTo-AdFilterValue -Value $sam
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
            $localUsersOU    = $EmployeeOUParam

            # -ErrorAction Stop, so a lookup that fails is a failed attempt, not "not there".
            Invoke-ADWriteWithRetry -OperationName "New-ADUser $localSam" -TestLanded {
                [bool](Get-ADUser -Filter "SamAccountName -eq '$localSamFilter'" -ErrorAction Stop)
            } -Operation {
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
    Write-LogInfo "Generated passwords for $($createdUsers.Count) users: $nameRedrawTotal held the account's name and were drawn again."
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
            # Get-Random -Count refuses 0 on Windows PowerShell 5.1, so a draw of 0 skips the group.
            if ($memberCount -eq 0) {
                Write-LogInfo "Group '$groupName': the member count drawn is 0, so no members were added."
                continue
            }
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
    # Adds generated users to Domain Admins: a fixed count, or a count drawn from the
    # range, capped at the users created. Population None with a random count adds nobody.
    # Returns Mode, Range, FixedCount, Requested, Target, CapApplied and Added (the
    # sAMAccountName values added).
    param(
        [array]$UserSams,
        [ValidateSet('Fixed', 'Random')][string]$ModeParam = 'Random',
        [int]$FixedCountParam,
        [int]$MinDAParam,
        [int]$MaxDAParam,
        [string]$PopulationParam = 'Full',
        [string]$SourceParam = 'the default'
    )
    $userList = @($UserSams | Where-Object { $_ })
    $result = [pscustomobject]@{
        Mode       = $ModeParam
        Range      = $(if ($ModeParam -eq 'Random') { "$MinDAParam to $MaxDAParam" } else { $null })
        FixedCount = $(if ($ModeParam -eq 'Fixed') { $FixedCountParam } else { $null })
        Requested  = 0
        Target     = 0
        CapApplied = $false
        Added      = [string[]]@()
    }
    try {
        if ($ModeParam -eq 'Fixed') {
            $result.Requested = $FixedCountParam
            $askedText = "DomainAdminCount $FixedCountParam from $SourceParam"
        } elseif ($PopulationParam -eq 'None') {
            Write-LogInfo 'Domain Admins: Population None with a random count adds nobody.'
            return $result
        } else {
            $result.Requested = Get-Random -Minimum $MinDAParam -Maximum ($MaxDAParam + 1)
            $askedText = "the count drawn, $($result.Requested) (MinDA $MinDAParam to MaxDA $MaxDAParam),"
        }
        $result.Target = $result.Requested
        if ($result.Target -gt $userList.Count) {
            $result.CapApplied = $true
            $result.Target     = $userList.Count
            $noneText = if ($PopulationParam -eq 'None') { ' (Population None)' } else { '' }
            if ($userList.Count -eq 0) {
                Write-LogWarn "Domain Admins: $askedText is more than the 0 users created$noneText; adding nobody."
                return $result
            }
            Write-LogWarn "Domain Admins: $askedText is more than the $($userList.Count) users created; adding all $($userList.Count)."
        }
        # Get-Random -Count refuses 0 on Windows PowerShell 5.1, so a target of 0 adds nobody.
        if ($result.Target -eq 0) {
            if ($ModeParam -eq 'Fixed') { Write-LogInfo 'Domain Admins: the count is 0, so nobody was added.' }
            else { Write-LogInfo 'Domain Admins: the count drawn is 0, so nobody was added.' }
            return $result
        }
        # @() so a single user counts as one.
        $daMembers = @($userList | Get-Random -Count $result.Target)
        $localDA   = $daMembers
        Invoke-ADWriteWithRetry -OperationName "Add-ADGroupMember Domain Admins" -Operation {
            $null = Add-ADGroupMember -Identity "Domain Admins" -Members $localDA
        }
        $result.Added = [string[]]$daMembers
        Write-LogSuccess "Added $($daMembers.Count) $(if ($daMembers.Count -eq 1) { 'user' } else { 'users' }) to Domain Admins."
        return $result
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
        [int]$PasswordLengthParam,
        [string]$DomainNameParam
    )
    $createdServiceCount = 0
    $nameRedrawTotal     = 0
    foreach ($def in $ServiceAccountDefs) {
        try {
            $samName = "svc_$($def.Name)"
            if (Get-ADUser -Filter "SamAccountName -eq '$(ConvertTo-AdFilterValue -Value $samName)'" -ErrorAction SilentlyContinue) {
                Write-LogInfo "Service account '$samName' already exists, skipping."
                continue
            }
            # New-ADUser below sets no displayName, so Windows checks only the sam. The sam
            # goes in as the display name too, which costs a few draws at most and still holds
            # if a displayName is ever added.
            $pwResult       = New-CompliantPassword -Length $PasswordLengthParam -SamAccountName $samName -DisplayName $samName
            $nameRedrawTotal += $pwResult.NameRedraws
            $localSam       = $samName
            $localSamFilter = ConvertTo-AdFilterValue -Value $samName
            $localDesc      = $($def.Description)
            $localPwSecure  = $pwResult.Secure
            $localTargetOU  = $TargetOU
            # -ErrorAction Stop, so a lookup that fails is a failed attempt, not "not there".
            Invoke-ADWriteWithRetry -OperationName "New-ADUser $localSam" -TestLanded {
                [bool](Get-ADUser -Filter "SamAccountName -eq '$localSamFilter'" -ErrorAction Stop)
            } -Operation {
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
                # {DomainName} becomes the build's domain. An SPN without it is written as given.
                $localSpn       = Resolve-ServicePrincipalName -ServicePrincipalName $($def.SPN) -DomainName $DomainNameParam
                Invoke-ADWriteWithRetry -OperationName "Set-SPN $localSamForSpn" -Operation {
                    $null = Set-ADUser -Identity $localSamForSpn -ServicePrincipalNames @{ Add = $localSpn }
                }
            }
            Write-LogSuccess "Created service account: $samName"
            $createdServiceCount++
        } catch {
            Write-LogError "Failed to create service account '$($def.Name)': $_"
            throw
        }
    }
    Write-LogInfo "Generated passwords for $createdServiceCount service accounts: $nameRedrawTotal held the account's name and were drawn again."
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
        for ($i = 1; $i -le $typeDef['Count']; $i++) {
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
function Resolve-DomainPasswordFloor {
    # The shortest password the generated accounts can have. The users are created under the
    # domain's own policy, before Set-PasswordPolicy runs, so a password must meet both the
    # minimum the run will set and the one the domain enforces now, read here and never
    # assumed. A read that fails is no stop: the floor is the larger of the configured
    # minimum and 7, the Default Domain Policy's minimum on Microsoft's page, with a WARN.
    # Returns Length (PasswordLength, raised when it is below the floor), Floor,
    # CurrentMinimum ($null when the read failed) and Warnings. Never throws.
    param(
        [Parameter(Mandatory)][int]$PasswordLengthParam,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceParam,
        [AllowNull()][object]$EffectiveMinimumParam,
        [Parameter(Mandatory)][string]$DomainNameParam
    )
    $warningLines     = [System.Collections.Generic.List[string]]::new()
    $configuredLength = 0
    if ($null -ne ($EffectiveMinimumParam -as [int])) { $configuredLength = [int]$EffectiveMinimumParam }
    $currentMinimum = $null
    try {
        $currentMinimum = [int](Get-ADDefaultDomainPasswordPolicy -Identity $DomainNameParam -ErrorAction Stop).MinPasswordLength
    } catch {
        $warningLines.Add("Domain password policy: the domain's current minimum password length couldn't be read ($(($_.Exception.Message -replace '\s*\r?\n\s*', ' ').Trim())), so generated passwords are at least $([math]::Max($configuredLength, 7)) characters, the larger of MinPasswordLength $configuredLength and 7, the Default Domain Policy's minimum.")
    }
    $floor = if ($null -ne $currentMinimum) { [math]::Max($configuredLength, $currentMinimum) } else { [math]::Max($configuredLength, 7) }
    # -PasswordLength takes at most 94, the printable characters a password draws from.
    if ($floor -gt 94) {
        $warningLines.Add("Domain password policy: the minimum password length, $floor, is more than the 94 characters a generated password can hold, so generated passwords use 94 and account creation may fail.")
        $floor = 94
    }
    $length = $PasswordLengthParam
    if ($PasswordLengthParam -lt $floor) {
        $length = $floor
        if ($null -ne $currentMinimum -and $currentMinimum -ge $floor -and $currentMinimum -gt $configuredLength) {
            $warningLines.Add("$($SourceParam): PasswordLength=$PasswordLengthParam is below the domain's current minimum password length $currentMinimum, which the users are created under before this run sets the policy; generated passwords use $floor characters.")
        } else {
            $warningLines.Add("$($SourceParam): PasswordLength=$PasswordLengthParam is below the minimum password length $floor; generated passwords use $floor characters.")
        }
    }
    return [pscustomobject]@{
        Length         = $length
        Floor          = $floor
        CurrentMinimum = $currentMinimum
        Warnings       = [string[]]$warningLines.ToArray()
    }
}

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
        # The lockout duration must be at least the observation window. The window is 10
        # minutes, as a new build leaves it, or the duration when that is shorter. Left
        # alone, a duration under 10 minutes would break that rule.
        $localObservationWindow = New-TimeSpan -Minutes ([math]::Min($LockoutDurationMinParam, 10))
        $localMaxAge    = New-TimeSpan -Days $MaxPwAgeDaysParam
        Invoke-ADWriteWithRetry -OperationName "Set-ADDefaultDomainPasswordPolicy $localDomain" -Operation {
            $null = Set-ADDefaultDomainPasswordPolicy `
                -Identity                 $localDomain `
                -MinPasswordLength        $localMinLen `
                -PasswordHistoryCount     $localHistory `
                -LockoutThreshold         $localThreshold `
                -LockoutDuration          $localLockoutDur `
                -LockoutObservationWindow $localObservationWindow `
                -MaxPasswordAge           $localMaxAge `
                -ComplexityEnabled        $true
        }
        Write-LogSuccess "Domain password policy configured."
    } catch {
        Write-LogError "Password policy configuration failed: $_"
        throw
    }
}
#endregion

#region --- AD Site Topology ---
function ConvertTo-LdapFilterValue {
    # Escapes a value for an LDAP filter (RFC 4515): backslash, asterisk, parentheses, NUL.
    param([Parameter(Mandatory)][string]$Value)
    $escaped = $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
    return $escaped.Replace([string][char]0, '\00')
}

function Get-DomainControllerSite {
    # Reads the DC's site from its server object under CN=Sites in the configuration
    # partition: the server object whose serverReference holds this DC's computer DN.
    # Not from the DC locator, so a site renamed seconds earlier reads correctly.
    # Returns the site object (Name, DistinguishedName). Throws when it can't be read.
    param(
        [Parameter(Mandatory)][string]$ComputerNameParam,
        [Parameter(Mandatory)][string]$ConfigurationNCParam
    )
    $computerDN    = (Get-ADComputer -Identity $ComputerNameParam).DistinguishedName
    $serverObjects = @(Get-ADObject -SearchBase "CN=Sites,$ConfigurationNCParam" -LDAPFilter "(&(objectClass=server)(serverReference=$(ConvertTo-LdapFilterValue -Value $computerDN)))")
    if ($serverObjects.Count -ne 1) {
        throw "Found $($serverObjects.Count) server objects under CN=Sites for '$computerDN', not exactly one."
    }
    $serverDN = [string]$serverObjects[0].DistinguishedName
    $dcSites  = @(Get-ADReplicationSite -Filter * | Where-Object {
        $serverDN.EndsWith(",CN=Servers,$($_.DistinguishedName)", [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($dcSites.Count -ne 1) {
        throw "Found $($dcSites.Count) sites holding the server object '$serverDN', not exactly one."
    }
    return $dcSites[0]
}

function Get-DomainControllerIPv4Address {
    # Works out the DC's IPv4 address and prefix length: the address AD holds for this DC
    # when it is on a local adapter, otherwise the one manual IPv4 address when there is
    # exactly one. IPAddress is $null when neither gives an answer.
    param([Parameter(Mandatory)][string]$ComputerNameParam)
    $adAddress = $null
    try {
        $adAddress = [string](Get-ADDomainController -Identity $ComputerNameParam).IPv4Address
    } catch {
        $adAddress = $null
    }
    $localAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    if ($adAddress) {
        $adAddressEntry = @($localAddresses | Where-Object { [string]$_.IPAddress -eq $adAddress })
        if ($adAddressEntry.Count -ge 1) {
            return [pscustomobject]@{ IPAddress = $adAddress; PrefixLength = [int]$adAddressEntry[0].PrefixLength; Source = 'the address AD holds for this DC'; AdAddress = $adAddress; ManualCount = 0 }
        }
    }
    $manualAddresses = @($localAddresses | Where-Object { [string]$_.PrefixOrigin -eq 'Manual' })
    if ($manualAddresses.Count -eq 1) {
        return [pscustomobject]@{ IPAddress = [string]$manualAddresses[0].IPAddress; PrefixLength = [int]$manualAddresses[0].PrefixLength; Source = 'the only manual IPv4 address on this server'; AdAddress = $adAddress; ManualCount = 1 }
    }
    return [pscustomobject]@{ IPAddress = $null; PrefixLength = 0; Source = $null; AdAddress = $adAddress; ManualCount = $manualAddresses.Count }
}

function Get-FreeSiteName {
    # The next free suffixed name for a site: <base>-2, <base>-3 and so on, compared
    # without regard to case. The base is shortened so the whole name stays within 63
    # characters, and a hyphen left at the end of the shortened base is trimmed.
    param(
        [Parameter(Mandatory)][string]$BaseNameParam,
        [AllowEmptyCollection()][string[]]$ExistingNamesParam = @()
    )
    for ($suffixNumber = 2; ; $suffixNumber++) {
        $suffix   = "-$suffixNumber"
        $baseName = $BaseNameParam
        if ($baseName.Length + $suffix.Length -gt 63) {
            $baseName = $baseName.Substring(0, 63 - $suffix.Length).TrimEnd('-')
        }
        $candidateName = "$baseName$suffix"
        if (@($ExistingNamesParam | Where-Object { $_ -eq $candidateName }).Count -eq 0) {
            return $candidateName
        }
    }
}

function Invoke-NltestDsRegDns {
    # Runs nltest /dsregdns, which makes Netlogon register the DC's DNS records at once.
    # Returns the exit code and the output on one line. A separate function so the
    # offline tests can stand in for it.
    $ErrorActionPreference = 'Continue'    # stderr from a native command must not throw here
    $nltestPath   = Join-Path -Path $env:SystemRoot -ChildPath 'System32\nltest.exe'
    $nltestOutput = & $nltestPath /dsregdns 2>&1
    $nltestExit   = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $nltestExit
        Output   = ((@($nltestOutput) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' ')
    }
}

function Set-ADSiteTopology {
    # Puts the DC in its primary site and gives that site the DC's subnet. Never throws.
    # Site cases, checked in order: 1, the DC is already in a site with the requested
    # name; 2, it is in Default-First-Site-Name and the name is free, so that site is
    # renamed; 3, it is in Default-First-Site-Name and the name is taken, so the site
    # is renamed to the next free suffixed name; 4, it is in another site, which is kept.
    # Renaming rather than moving keeps the DC's site in DEFAULTIPSITELINK.
    # Returns what it ended with, for the test rows.
    param(
        [Parameter(Mandatory)][string]$PrimarySiteNameParam,
        [Parameter(Mandatory)][string]$PrimarySubnetParam,
        [Parameter(Mandatory)][string]$DomainNameParam,
        [Parameter(Mandatory)][string]$ComputerNameParam,
        [int]$RenameAttemptLimitParam = 5
    )
    $defaultSiteName = 'Default-First-Site-Name'
    $result = [pscustomobject]@{
        RequestedSiteName     = $PrimarySiteNameParam
        SiteName              = $null
        SiteDistinguishedName = $null
        SiteCase              = 0
        RequestedSubnet       = $PrimarySubnetParam
        Subnet                = $null
        SubnetFellBackToAuto  = $false
        DcAddress             = $null
        DcPrefixLength        = 0
        SubnetHeldBySite      = $null
        ConfigurationNC       = $null
        StepError             = $null
    }
    try {
        $configurationNC        = [string](Get-ADRootDSE).configurationNamingContext
        $result.ConfigurationNC = $configurationNC

        #region Site
        $dcSite = Get-DomainControllerSite -ComputerNameParam $ComputerNameParam -ConfigurationNCParam $configurationNC
        $allSites = @(Get-ADReplicationSite -Filter *)
        if ($dcSite.Name -eq $PrimarySiteNameParam) {
            $result.SiteCase = 1
            Write-LogInfo "Site topology: the DC is already in site '$($dcSite.Name)', the requested name. No rename needed."
        } elseif ($dcSite.Name -eq $defaultSiteName) {
            if (@($allSites | Where-Object { $_.Name -eq $PrimarySiteNameParam }).Count -eq 0) {
                $result.SiteCase = 2
                $candidateName   = $PrimarySiteNameParam
            } else {
                $result.SiteCase = 3
                $candidateName   = Get-FreeSiteName -BaseNameParam $PrimarySiteNameParam -ExistingNamesParam @($allSites | ForEach-Object { [string]$_.Name })
            }
            $renamed = $false
            for ($renameAttempt = 1; $renameAttempt -le $RenameAttemptLimitParam; $renameAttempt++) {
                # One attempt per name, then a re-read: a retried rename after a lost reply
                # would fail on the name that already took.
                $renameError = $null
                try {
                    Rename-ADObject -Identity $dcSite.DistinguishedName -NewName $candidateName
                } catch {
                    $renameError = $_
                }
                $dcSiteNow = Get-DomainControllerSite -ComputerNameParam $ComputerNameParam -ConfigurationNCParam $configurationNC
                if ($dcSiteNow.Name -eq $candidateName) {
                    $dcSite  = $dcSiteNow
                    $renamed = $true
                    break
                }
                if ($null -eq $renameError) {
                    $renameError = "the DC's site still reads '$($dcSiteNow.Name)' after the rename"
                }
                Write-LogWarn "Site topology: renaming site '$defaultSiteName' to '$candidateName' failed: $(Get-BuildProfileSingleLine -Text "$renameError"). The DC is in site '$($dcSiteNow.Name)'; keeping it."
                $dcSite = $dcSiteNow
                $sitesNow = @(Get-ADReplicationSite -Filter *)
                $candidateNowTaken = @($sitesNow | Where-Object { $_.Name -eq $candidateName }).Count -gt 0
                if ($dcSiteNow.Name -ne $defaultSiteName -or -not $candidateNowTaken) {
                    break
                }
                # The name was taken between the read and the rename: try the next free one.
                $result.SiteCase = 3
                $candidateName   = Get-FreeSiteName -BaseNameParam $PrimarySiteNameParam -ExistingNamesParam @($sitesNow | ForEach-Object { [string]$_.Name })
            }
            if ($renamed) {
                if ($result.SiteCase -eq 2) {
                    Write-LogSuccess "Site topology: renamed site '$defaultSiteName' to '$PrimarySiteNameParam'. The DC is in site '$PrimarySiteNameParam'."
                } else {
                    Write-LogWarn "Site topology: a site named '$PrimarySiteNameParam' already exists and does not hold the DC; renamed '$defaultSiteName' to '$($dcSite.Name)' instead. The requested name was not applied. See the ""Primary site name"" test row."
                }
                $nltestResult = Invoke-NltestDsRegDns
                if ($nltestResult.ExitCode -eq 0) {
                    Write-LogInfo "Site topology: nltest /dsregdns succeeded."
                } else {
                    Write-LogWarn "Site topology: nltest /dsregdns failed with exit code $($nltestResult.ExitCode): $($nltestResult.Output). Netlogon was not forced to register the DC's records for site '$($dcSite.Name)'. See the ""Site locator record"" test row."
                }
            }
        } else {
            $result.SiteCase = 4
            Write-LogWarn "Site topology: the DC is in site '$($dcSite.Name)', not '$defaultSiteName'; keeping that site. The requested name '$PrimarySiteNameParam' was not applied. See the ""Primary site name"" test row."
        }
        $result.SiteName              = [string]$dcSite.Name
        $result.SiteDistinguishedName = [string]$dcSite.DistinguishedName
        #endregion

        #region Subnet
        $dcAddress = Get-DomainControllerIPv4Address -ComputerNameParam $ComputerNameParam
        if (-not $dcAddress.IPAddress) {
            $adAddressText = if ($dcAddress.AdAddress) { $dcAddress.AdAddress } else { 'no address' }
            Write-LogWarn "Site topology: can't work out the DC's IPv4 address. AD holds $adAddressText for this DC, which is not on a local adapter, and this server has $($dcAddress.ManualCount) manual IPv4 addresses, not exactly one. Skipping the subnet step for PrimarySubnet $PrimarySubnetParam. See the ""DC site subnet"" test row."
            return $result
        }
        $result.DcAddress      = $dcAddress.IPAddress
        $result.DcPrefixLength = $dcAddress.PrefixLength
        Write-LogInfo "Site topology: the DC's address is $($dcAddress.IPAddress)/$($dcAddress.PrefixLength), from $($dcAddress.Source)."

        $autoSubnet = Get-IPv4NetworkAddress -IPAddress $dcAddress.IPAddress -PrefixLength $dcAddress.PrefixLength
        if ($PrimarySubnetParam -eq 'Auto') {
            $targetSubnet = $autoSubnet
        } elseif (Test-IPv4AddressInSubnet -IPAddress $dcAddress.IPAddress -Subnet $PrimarySubnetParam) {
            $targetSubnet = $PrimarySubnetParam
        } else {
            Write-LogWarn "Site topology: PrimarySubnet $PrimarySubnetParam does not contain the DC's address $($dcAddress.IPAddress); using Auto, $autoSubnet, instead. See the ""Requested subnet"" test row."
            $targetSubnet                = $autoSubnet
            $result.SubnetFellBackToAuto = $true
        }
        $result.Subnet = $targetSubnet

        $existingSubnet = @(Get-ADObject -SearchBase "CN=Subnets,CN=Sites,$configurationNC" -LDAPFilter '(objectClass=subnet)' -Properties siteObject |
            Where-Object { [string]$_.Name -eq $targetSubnet })
        if ($existingSubnet.Count -gt 0) {
            $subnetSiteDN = [string]$existingSubnet[0].siteObject
            if ($subnetSiteDN -and $subnetSiteDN -eq $dcSite.DistinguishedName) {
                Write-LogInfo "Site topology: subnet $targetSubnet is already in site '$($dcSite.Name)'."
            } elseif (-not $subnetSiteDN) {
                $result.SubnetHeldBySite = ''
                Write-LogWarn "Site topology: subnet $targetSubnet already exists with no site; leaving it as it is. See the ""DC site subnet"" test row."
            } else {
                $holdingSite = @(Get-ADReplicationSite -Filter * | Where-Object { [string]$_.DistinguishedName -eq $subnetSiteDN })
                $holdingSiteName = if ($holdingSite.Count -gt 0) { [string]$holdingSite[0].Name } else { $subnetSiteDN }
                $result.SubnetHeldBySite = $holdingSiteName
                Write-LogWarn "Site topology: subnet $targetSubnet already exists in site '$holdingSiteName'; leaving it there, so the DC's site '$($dcSite.Name)' does not get it. See the ""DC site subnet"" test row."
            }
        } else {
            $localSubnet       = $targetSubnet
            $localSiteName     = [string]$dcSite.Name
            $localSubnetSearch = "CN=Subnets,CN=Sites,$configurationNC"
            try {
                # The operation re-checks first, so a retry after a create that landed
                # without a reply does not try to create the subnet twice.
                Invoke-ADWriteWithRetry -OperationName "New-ADReplicationSubnet $localSubnet" -Operation {
                    $subnetNow = @(Get-ADObject -SearchBase $localSubnetSearch -LDAPFilter '(objectClass=subnet)' | Where-Object { [string]$_.Name -eq $localSubnet })
                    if ($subnetNow.Count -eq 0) {
                        $null = New-ADReplicationSubnet -Name $localSubnet -Site $localSiteName
                    }
                }
                Write-LogSuccess "Site topology: created subnet $targetSubnet in site '$($dcSite.Name)'."
            } catch {
                Write-LogWarn "Site topology: creating subnet $targetSubnet in site '$($dcSite.Name)' failed: $(Get-BuildProfileSingleLine -Text "$_"). See the ""DC site subnet"" test row."
            }
        }
        #endregion
    } catch {
        $result.StepError = Get-BuildProfileSingleLine -Text "$_"
        Write-LogWarn "Site topology: the step stopped early: $(Get-BuildProfileSingleLine -Text "$_"). See the site test rows."
    }
    return $result
}

function Get-SiteTopologyTestRow {
    # The five site and subnet test rows, from what Set-ADSiteTopology ended with and a
    # fresh read of AD. Returns objects with TestName, Passed and Detail. Never throws.
    param(
        [Parameter(Mandatory)][pscustomobject]$SiteTopologyParam,
        [Parameter(Mandatory)][string]$DomainNameParam,
        [Parameter(Mandatory)][string]$ComputerNameParam,
        [int]$LocatorRetryCountParam    = 6,
        [int]$LocatorRetryDelaySecParam = 10
    )
    $topology = $SiteTopologyParam
    $siteCase = $topology.SiteCase
    $newRow = { param($TestName, $Passed, $Detail) [pscustomobject]@{ TestName = $TestName; Passed = [bool]$Passed; Detail = [string]$Detail } }
    $siteUnknownDetail = "The DC's site could not be read: $($topology.StepError)"

    # DC site subnet
    try {
        if (-not $topology.SiteName) {
            & $newRow 'DC site subnet' $false $siteUnknownDetail
        } elseif (-not $topology.DcAddress) {
            & $newRow 'DC site subnet' $false "The DC's IPv4 address could not be worked out, so no subnet was checked (site case $siteCase)"
        } else {
            $siteSubnets = @(Get-ADObject -SearchBase "CN=Subnets,CN=Sites,$($topology.ConfigurationNC)" -LDAPFilter '(objectClass=subnet)' -Properties siteObject |
                Where-Object { [string]$_.siteObject -eq $topology.SiteDistinguishedName })
            $coveringSubnet = @($siteSubnets | Where-Object { Test-IPv4AddressInSubnet -IPAddress $topology.DcAddress -Subnet ([string]$_.Name) })
            if ($coveringSubnet.Count -gt 0) {
                & $newRow 'DC site subnet' $true "Site '$($topology.SiteName)' holds $($coveringSubnet[0].Name), which contains the DC's address $($topology.DcAddress) (site case $siteCase)"
            } else {
                & $newRow 'DC site subnet' $false "Site '$($topology.SiteName)' holds no subnet containing the DC's address $($topology.DcAddress) (site case $siteCase)"
            }
        }
    } catch {
        & $newRow 'DC site subnet' $false "$_"
    }

    # Requested subnet
    if (-not $topology.DcAddress) {
        & $newRow 'Requested subnet' $true "Requested $($topology.RequestedSubnet); the subnet step was skipped because the DC's address is unknown. See ""DC site subnet"""
    } elseif ($topology.SubnetFellBackToAuto) {
        & $newRow 'Requested subnet' $false "Requested $($topology.RequestedSubnet), actual $($topology.Subnet): the requested subnet does not contain the DC's address $($topology.DcAddress)"
    } else {
        & $newRow 'Requested subnet' $true "Requested $($topology.RequestedSubnet), actual $($topology.Subnet)"
    }

    # Primary site name
    if (-not $topology.SiteName) {
        & $newRow 'Primary site name' $false $siteUnknownDetail
    } elseif ($topology.SiteName -eq $topology.RequestedSiteName) {
        & $newRow 'Primary site name' $true "Requested '$($topology.RequestedSiteName)', actual '$($topology.SiteName)'"
    } else {
        & $newRow 'Primary site name' $false "Requested '$($topology.RequestedSiteName)', actual '$($topology.SiteName)' (site case $siteCase)"
    }

    # Site link membership
    try {
        if (-not $topology.SiteName) {
            & $newRow 'Site link membership' $false $siteUnknownDetail
        } else {
            $siteLinks = @(Get-ADObject -SearchBase "CN=IP,CN=Inter-Site Transports,CN=Sites,$($topology.ConfigurationNC)" -LDAPFilter '(objectClass=siteLink)' -Properties siteList |
                Where-Object { @($_.siteList | ForEach-Object { [string]$_ }) -contains $topology.SiteDistinguishedName })
            if ($siteLinks.Count -gt 0) {
                & $newRow 'Site link membership' $true "Site '$($topology.SiteName)' is in IP site link '$($siteLinks[0].Name)'"
            } else {
                & $newRow 'Site link membership' $false "No IP site link includes site '$($topology.SiteName)'"
            }
        }
    } catch {
        & $newRow 'Site link membership' $false "$_"
    }

    # Site locator record
    if (-not $topology.SiteName) {
        & $newRow 'Site locator record' $false $siteUnknownDetail
    } else {
        $recordName   = "_ldap._tcp.$($topology.SiteName)._sites.dc._msdcs.$DomainNameParam"
        $dcHostName   = "$ComputerNameParam.$DomainNameParam"
        $lastOutcome  = 'no answer'
        $recordFound  = $false
        for ($locatorAttempt = 1; $locatorAttempt -le $LocatorRetryCountParam; $locatorAttempt++) {
            try {
                # Whether Resolve-DnsName answers from the client cache is not documented,
                # so the cache is cleared before each try.
                Clear-DnsClientCache
                $srvRecords = @(Resolve-DnsName -Name $recordName -Type SRV -DnsOnly -ErrorAction Stop)
                $targets    = @($srvRecords | Where-Object { $_.PSObject.Properties.Name -contains 'NameTarget' } | ForEach-Object { ([string]$_.NameTarget).TrimEnd('.') })
                if (@($targets | Where-Object { $_ -eq $dcHostName }).Count -gt 0) {
                    $recordFound = $true
                    break
                }
                $lastOutcome = "targets: $(if ($targets.Count -gt 0) { $targets -join ', ' } else { 'none' })"
            } catch {
                $lastOutcome = "$_"
            }
            if ($locatorAttempt -lt $LocatorRetryCountParam) { Start-Sleep -Seconds $LocatorRetryDelaySecParam }
        }
        if ($recordFound) {
            & $newRow 'Site locator record' $true "Resolved $recordName to $dcHostName"
        } else {
            & $newRow 'Site locator record' $false "$recordName did not resolve to $dcHostName within $($LocatorRetryCountParam * $LocatorRetryDelaySecParam) seconds: $lastOutcome"
        }
    }
}

function Get-ServiceAccountSpnTestRow {
    # The "Service account SPNs" row: each CSV row with an SPN must have its account hold
    # that SPN after {DomainName} substitution. Returns one object with TestName, Passed
    # and Detail. Never throws.
    param(
        [AllowEmptyCollection()][array]$ServiceAccountDefsParam,
        [Parameter(Mandatory)][string]$DomainNameParam
    )
    try {
        $spnRows    = @($ServiceAccountDefsParam | Where-Object { $_.SPN -and "$($_.SPN)".Trim() -ne '' })
        $mismatches = [System.Collections.Generic.List[string]]::new()
        foreach ($spnRow in $spnRows) {
            $samName     = "svc_$($spnRow.Name)"
            $expectedSpn = Resolve-ServicePrincipalName -ServicePrincipalName $($spnRow.SPN) -DomainName $DomainNameParam
            $account     = Get-ADUser -Filter "SamAccountName -eq '$(ConvertTo-AdFilterValue -Value $samName)'" -Properties servicePrincipalName
            $heldSpns    = @()
            if ($account) { $heldSpns = @($account.servicePrincipalName | ForEach-Object { [string]$_ }) }
            if ($heldSpns -notcontains $expectedSpn) {
                $heldText = if ($heldSpns.Count -gt 0) { $heldSpns -join ', ' } else { 'none' }
                $mismatches.Add("$samName expected '$expectedSpn', holds '$heldText'")
            }
        }
        if ($mismatches.Count -eq 0) {
            return [pscustomobject]@{ TestName = 'Service account SPNs'; Passed = $true; Detail = "All $($spnRows.Count) CSV rows with an SPN matched" }
        }
        return [pscustomobject]@{ TestName = 'Service account SPNs'; Passed = $false; Detail = "$($mismatches.Count) of $($spnRows.Count) did not match: $($mismatches -join '; ')" }
    } catch {
        return [pscustomobject]@{ TestName = 'Service account SPNs'; Passed = $false; Detail = "$_" }
    }
}
#endregion

#region --- Functional Tests ---
function Invoke-FunctionalTests {
    param(
        [string]$UsersOUParam,
        [string]$DisabledUsersOUParam,
        [string]$DomainNameParam,
        [AllowNull()][object]$DomainAdminResultParam,
        [int]$ExpectedUserCountParam,
        [string]$CACommonNameParam,
        [pscustomobject]$SiteTopologyParam,
        [array]$ServiceAccountDefsParam,
        [string]$ComputerNameParam,
        [string]$PopulationParam = 'Full'
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
        # @() here and in the counts below, so a single object counts as one.
        $userCount = @(Get-ADUser -Filter * -SearchBase $UsersOUParam -ErrorAction Stop).Count
        # With no users expected, a query that answers is the pass.
        $ldapDetail = if ($ExpectedUserCountParam -eq 0) { "Found $userCount users in $UsersOUParam (0 expected)" } else { "Found $userCount users in $UsersOUParam" }
        Add-TestResult -TestName 'LDAP Query' -Passed ($userCount -gt 0 -or $ExpectedUserCountParam -eq 0) -Detail $ldapDetail
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

    # Domain Admins populated: every account population added is a direct member, and it
    # added its target. The built-in members aren't counted, so the group's starting
    # membership doesn't matter.
    try {
        if ($null -eq $DomainAdminResultParam) { throw 'Domain Admins population reported no result.' }
        $daMembers = @(Get-ADGroupMember -Identity 'Domain Admins' -ErrorAction Stop | ForEach-Object { [string]$_.SamAccountName })
        $daAdded   = @($DomainAdminResultParam.Added | Where-Object { $_ })
        $daMissing = @($daAdded | Where-Object { $daMembers -notcontains $_ })
        $daMode    = if ($DomainAdminResultParam.Mode -eq 'Fixed') { "fixed $($DomainAdminResultParam.FixedCount)" } else { "random, $($DomainAdminResultParam.Range)" }
        $daDetail  = "Mode $daMode, target $($DomainAdminResultParam.Target), $($daAdded.Count) added"
        if ($DomainAdminResultParam.CapApplied) { $daDetail += ", capped from $($DomainAdminResultParam.Requested) at the users created" }
        if ($daMissing.Count -gt 0) { $daDetail += ", not members: $($daMissing -join ', ')" }
        Add-TestResult -TestName 'Domain Admins Populated' -Passed ($daMissing.Count -eq 0 -and $daAdded.Count -eq [int]$DomainAdminResultParam.Target) -Detail $daDetail
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
        $caCerts = @(Get-ChildItem 'Cert:\LocalMachine\Root' |
                       Where-Object { $_.Subject -like "*$CACommonNameParam*" })
        Add-TestResult -TestName 'CA Certificate Published' -Passed ($caCerts.Count -gt 0) `
            -Detail "Trusted Root certs matching '$CACommonNameParam': $($caCerts.Count)"
    } catch {
        Add-TestResult -TestName 'CA Certificate Published' -Passed $false -Detail "$_"
    }

    # User count across Users and DisabledUsers OUs
    try {
        $activeCount   = @(Get-ADUser -Filter * -SearchBase $UsersOUParam -ErrorAction Stop).Count
        $disabledCount = @(Get-ADUser -Filter * -SearchBase $DisabledUsersOUParam -ErrorAction Stop).Count
        $totalUsers    = $activeCount + $disabledCount
        Add-TestResult -TestName 'User Count' -Passed ($totalUsers -eq $ExpectedUserCountParam) `
            -Detail "Total: $totalUsers (expected $ExpectedUserCountParam; $activeCount active, $disabledCount disabled)"
    } catch {
        Add-TestResult -TestName 'User Count' -Passed $false -Detail "$_"
    }

    # DC site subnet, Requested subnet, Primary site name, Site link membership, Site locator record
    if ($SiteTopologyParam) {
        foreach ($siteRow in @(Get-SiteTopologyTestRow -SiteTopologyParam $SiteTopologyParam -DomainNameParam $DomainNameParam -ComputerNameParam $ComputerNameParam)) {
            Add-TestResult -TestName $siteRow.TestName -Passed $siteRow.Passed -Detail $siteRow.Detail
        }
    }

    # Service account SPNs. Population None creates no service account, so a PASS would be
    # for work not done.
    if ($PopulationParam -eq 'None') {
        Write-LogInfo 'Service account SPNs: not run, because Population None creates no service account.'
    } else {
        $spnRow = Get-ServiceAccountSpnTestRow -ServiceAccountDefsParam $ServiceAccountDefsParam -DomainNameParam $DomainNameParam
        Add-TestResult -TestName $spnRow.TestName -Passed $spnRow.Passed -Detail $spnRow.Detail
    }

    # @() so a single PASS or FAIL counts as one. Windows PowerShell 5.1 gives one row as a lone object with no Count.
    $passCount = @($testResults | Where-Object { $_.Result -eq 'PASS' }).Count
    $failCount = @($testResults | Where-Object { $_.Result -eq 'FAIL' }).Count
    Write-LogInfo "Functional tests complete: $passCount passed, $failCount failed."

    return $testResults
}
#endregion

#region --- Artifacts Export ---
function Export-Artifacts {
    # Writes the users export (only when users exist; it holds every generated password)
    # and the test results. Returns the names written, the users export left out, for the
    # completion marker.
    param(
        [AllowNull()][System.Collections.Generic.List[object]]$Users,
        [System.Collections.Generic.List[object]]$TestResults,
        [string]$ArtifactsPathParam,
        [string]$TimestampParam
    )
    try {
        $null = New-Item -ItemType Directory -Path $ArtifactsPathParam -Force
        $timestamp = if ($TimestampParam) { $TimestampParam } else { Get-Date -Format 'yyyyMMddHHmmss' }
        # Windows PowerShell 5.1 writes ASCII by default, which turns every non-ASCII
        # character in a name into '?'. Both values write UTF-8 with a byte order mark.
        $csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }

        if (@($Users | Where-Object { $null -ne $_ }).Count -gt 0) {
            $Users | Export-Csv "$ArtifactsPathParam\users-$timestamp.csv" -NoTypeInformation -Encoding $csvEncoding
            $Users | ConvertTo-Json | Out-File "$ArtifactsPathParam\users-$timestamp.json" -Encoding utf8
        } else {
            Write-LogInfo 'Artifacts: no users were created, so there is no users export.'
        }
        $TestResults | Export-Csv "$ArtifactsPathParam\test-results-$timestamp.csv" -NoTypeInformation -Encoding $csvEncoding

        Write-LogSuccess "Artifacts exported to '$ArtifactsPathParam'."
        return [string[]]@("test-results-$timestamp.csv")
    } catch {
        Write-LogError "Artifact export failed: $_"
        throw
    }
}
#endregion

#region --- Completion Marker ---
function Write-PopulationResult {
    # Writes artifacts\population-result.json, the run's completion marker, which build-lab
    # polls. Creates the artifacts folder when it is missing. Writes a temporary file in the
    # same folder, then moves it into place (File.Replace once a marker exists), so a
    # reader never sees half a file. UTF-8 without a byte order mark. It holds no password
    # and no credential. Never throws: a failed write is one WARN, and returns $false.
    param(
        [Parameter(Mandatory)][string]$ArtifactsPathParam,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ResultParam
    )
    $markerPath = Join-Path -Path $ArtifactsPathParam -ChildPath 'population-result.json'
    try {
        if (-not (Test-Path -LiteralPath $ArtifactsPathParam -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $ArtifactsPathParam -Force -ErrorAction Stop
        }
        $temporaryPath = "$markerPath.tmp"
        $markerText    = [pscustomobject]$ResultParam | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($temporaryPath, $markerText, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            # PowerShell passes $null to a .NET string as an empty string, which File.Replace
            # refuses, so the "no backup" argument is [NullString]::Value.
            [System.IO.File]::Replace($temporaryPath, $markerPath, [NullString]::Value)
        } else {
            [System.IO.File]::Move($temporaryPath, $markerPath)
        }
        return $true
    } catch {
        Write-LogWarn "Population result marker '$markerPath' couldn't be written: $($_.Exception.Message) build-lab can't confirm this population without it."
        return $false
    }
}
#endregion

#region --- Population Comparison Export ---
function ConvertTo-ComparisonOrdinalSorted {
    # Rows sorted by their Key property with an ordinal comparison, so two builds sort the
    # same whatever the culture. Each Key is unique. Array.Sort with a keys array and an
    # items array isn't used, because PowerShell hands it a copy of the items and the
    # sorted copy is lost.
    param([AllowEmptyCollection()][object[]]$Rows)
    $sortedRows = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($row in @($Rows | Where-Object { $null -ne $_ })) { $sortedRows[[string]$row.Key] = $row }
    if ($sortedRows.Count -eq 0) { return }
    return @($sortedRows.Values)
}

function Write-ComparisonCsv {
    # One comparison file, UTF-8 with a byte order mark. With no rows, the header line
    # alone, since Export-Csv writes no header for an empty input.
    param(
        [Parameter(Mandatory)][string]$PathParam,
        [Parameter(Mandatory)][string[]]$ColumnsParam,
        [AllowEmptyCollection()][object[]]$RowsParam
    )
    $csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $rows = @($RowsParam | Where-Object { $null -ne $_ } | Select-Object -Property $ColumnsParam)
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $PathParam -NoTypeInformation -Encoding $csvEncoding
    } else {
        $headerLine = (@($ColumnsParam | ForEach-Object { '"' + $_ + '"' }) -join ',') + "`r`n"
        [System.IO.File]::WriteAllText($PathParam, $headerLine, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
    }
}

function Export-PopulationComparisonData {
    # Reads back the users, groups and memberships population made and writes three CSVs
    # to the artifacts folder, with everything that differs between builds by design
    # removed or replaced: no password, SID, GUID or timestamp, the domain written as
    # {DomainDN} and {DomainName}, and the built-in accounts left out. Two builds with one
    # seed and one population give identical files. Read-only. Returns the file names.
    param(
        [Parameter(Mandatory)][string]$ArtifactsPathParam,
        [Parameter(Mandatory)][string]$TimestampParam,
        [Parameter(Mandatory)][string]$DomainNameParam,
        [Parameter(Mandatory)][string]$DomainDNParam,
        [Parameter(Mandatory)][string[]]$UserOUParam,
        [Parameter(Mandatory)][string]$GroupsOUParam,
        [AllowEmptyCollection()][array]$ServiceAccountDefsParam
    )
    $toParentOU = {
        param ([string]$DistinguishedName)
        $parentMatch = [regex]::Match($DistinguishedName, '\A(?:[^,\\]|\\.)+,(.*)\z')
        $parentText  = if ($parentMatch.Success) { $parentMatch.Groups[1].Value } else { '' }
        if ($parentText.EndsWith($DomainDNParam, [System.StringComparison]::OrdinalIgnoreCase)) {
            $parentText = $parentText.Substring(0, $parentText.Length - $DomainDNParam.Length) + '{DomainDN}'
        }
        return $parentText
    }
    $atDomain = "@$DomainNameParam"
    $toDomainPlaceholder = {
        param ([AllowNull()][string]$Address)
        if ($Address -and $Address.EndsWith($atDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $Address.Substring(0, $Address.Length - $atDomain.Length) + '@{DomainName}'
        }
        return [string]$Address
    }
    # SPNs written from a {DomainName} placeholder get the placeholder back.
    $placeholderAccounts = @{}
    foreach ($serviceDef in @($ServiceAccountDefsParam)) {
        if ($serviceDef.SPN -and "$($serviceDef.SPN)" -match '\{DomainName\}') { $placeholderAccounts["svc_$($serviceDef.Name)"] = $true }
    }

    $userProperties = @('GivenName', 'Surname', 'DisplayName', 'UserPrincipalName', 'mail', 'Department', 'Title', 'Company', 'Office', 'StreetAddress', 'City', 'State', 'OfficePhone', 'EmployeeID', 'Description', 'servicePrincipalName', 'userAccountControl', 'pwdLastSet', 'lockoutTime', 'Manager')
    $userObjects = @(foreach ($userOU in $UserOUParam) { Get-ADUser -Filter * -SearchBase $userOU -Properties $userProperties -ErrorAction Stop })
    $samByDN = @{}
    foreach ($userObject in $userObjects) { $samByDN[[string]$userObject.DistinguishedName] = [string]$userObject.SamAccountName }
    $userRows = foreach ($userObject in $userObjects) {
        $flags = [int64]$(if ($null -ne $userObject.userAccountControl) { $userObject.userAccountControl } else { 0 })
        $sam   = [string]$userObject.SamAccountName
        $spns  = [string[]]@($userObject.servicePrincipalName | Where-Object { $_ } | ForEach-Object {
                $spnText = [string]$_
                if ($placeholderAccounts.ContainsKey($sam)) { $spnText = [regex]::Replace($spnText, [regex]::Escape($DomainNameParam), '{DomainName}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
                $spnText
            })
        [System.Array]::Sort($spns, [System.StringComparer]::Ordinal)
        $managerSam = ''
        if ($userObject.Manager) {
            $managerSam = if ($samByDN.ContainsKey([string]$userObject.Manager)) { $samByDN[[string]$userObject.Manager] } else { [string](Get-ADUser -Identity $userObject.Manager -ErrorAction Stop).SamAccountName }
        }
        [pscustomobject][ordered]@{
            Key                   = $sam
            SamAccountName        = $sam
            Name                  = [string]$userObject.Name
            GivenName             = [string]$userObject.GivenName
            Surname               = [string]$userObject.Surname
            DisplayName           = [string]$userObject.DisplayName
            UserPrincipalName     = & $toDomainPlaceholder $userObject.UserPrincipalName
            mail                  = & $toDomainPlaceholder $userObject.mail
            Department            = [string]$userObject.Department
            Title                 = [string]$userObject.Title
            Company               = [string]$userObject.Company
            Office                = [string]$userObject.Office
            StreetAddress         = [string]$userObject.StreetAddress
            City                  = [string]$userObject.City
            State                 = [string]$userObject.State
            OfficePhone           = [string]$userObject.OfficePhone
            EmployeeID            = [string]$userObject.EmployeeID
            Description           = [string]$userObject.Description
            ServicePrincipalNames = $spns -join ';'
            ParentOU              = & $toParentOU ([string]$userObject.DistinguishedName)
            AccountDisabled       = [string](($flags -band 0x0002) -ne 0)
            PasswordNeverExpires  = [string](($flags -band 0x10000) -ne 0)
            SmartcardRequired     = [string](($flags -band 0x40000) -ne 0)
            MustChangePassword    = [string]($null -ne $userObject.pwdLastSet -and [int64]$userObject.pwdLastSet -eq 0)
            LockoutRecorded       = [string]($null -ne $userObject.lockoutTime -and [int64]$userObject.lockoutTime -ne 0)
            Manager               = $managerSam
        }
    }

    $groupObjects = @(Get-ADGroup -Filter * -SearchBase $GroupsOUParam -ErrorAction Stop)
    $groupRows = foreach ($groupObject in $groupObjects) {
        [pscustomobject][ordered]@{
            Key           = [string]$groupObject.Name
            Name          = [string]$groupObject.Name
            GroupScope    = [string]$groupObject.GroupScope
            GroupCategory = [string]$groupObject.GroupCategory
            ParentOU      = & $toParentOU ([string]$groupObject.DistinguishedName)
        }
    }

    # Direct members of each lab group and of Domain Admins, the built-in accounts (RID
    # 500 and the like, SIDs below 1000) left out so the file holds only what population
    # added.
    $membershipRows = foreach ($membershipGroup in @(@($groupObjects | ForEach-Object { [string]$_.Name }) + 'Domain Admins')) {
        foreach ($member in @(Get-ADGroupMember -Identity $membershipGroup -ErrorAction Stop)) {
            $relativeId = -1
            if ($null -ne $member.SID) { $relativeId = [int](([string]$member.SID) -replace '\A.*-', '') }
            if ($relativeId -ge 0 -and $relativeId -lt 1000) { continue }
            $memberName = if ($member.SamAccountName) { [string]$member.SamAccountName } else { [string]$member.Name }
            [pscustomobject][ordered]@{
                Key         = "$membershipGroup$([char]0)$memberName"
                Group       = $membershipGroup
                Member      = $memberName
                MemberClass = [string]$member.objectClass
            }
        }
    }

    $comparisonFiles = @(
        @{ Name = "population-users-$TimestampParam.csv"; Columns = @('SamAccountName', 'Name', 'GivenName', 'Surname', 'DisplayName', 'UserPrincipalName', 'mail', 'Department', 'Title', 'Company', 'Office', 'StreetAddress', 'City', 'State', 'OfficePhone', 'EmployeeID', 'Description', 'ServicePrincipalNames', 'ParentOU', 'AccountDisabled', 'PasswordNeverExpires', 'SmartcardRequired', 'MustChangePassword', 'LockoutRecorded', 'Manager'); Rows = @($userRows) }
        @{ Name = "population-groups-$TimestampParam.csv"; Columns = @('Name', 'GroupScope', 'GroupCategory', 'ParentOU'); Rows = @($groupRows) }
        @{ Name = "population-memberships-$TimestampParam.csv"; Columns = @('Group', 'Member', 'MemberClass'); Rows = @($membershipRows) }
    )
    $writtenNames = [System.Collections.Generic.List[string]]::new()
    foreach ($comparisonFile in $comparisonFiles) {
        $sortedRows = @(ConvertTo-ComparisonOrdinalSorted -Rows $comparisonFile.Rows)
        Write-ComparisonCsv -PathParam (Join-Path -Path $ArtifactsPathParam -ChildPath $comparisonFile.Name) -ColumnsParam $comparisonFile.Columns -RowsParam $sortedRows
        $writtenNames.Add($comparisonFile.Name)
    }
    Write-LogSuccess "Population comparison export written to '$ArtifactsPathParam': $($writtenNames -join ', ')."
    return [string[]]$writtenNames.ToArray()
}
#endregion

#region --- Deployment Summary ---
function Write-DeploymentSummary {
    param(
        [int]$UserCountParam,
        [int]$GroupCountParam,
        [int]$ServiceAccountCountParam,
        [int]$ComputerCountParam,
        [AllowNull()][object]$DomainAdminResultParam,
        [int]$TestPassCountParam,
        [int]$TestTotalCountParam,
        [string]$ArtifactsPathParam
    )
    # The number added, how it was decided, and a cap when one applied.
    $daText = 'none (not run)'
    if ($null -ne $DomainAdminResultParam) {
        $daAddedCount = @($DomainAdminResultParam.Added | Where-Object { $_ }).Count
        $daText = if ($DomainAdminResultParam.Mode -eq 'Fixed') { "$daAddedCount (fixed)" } else { "$daAddedCount (random, $($DomainAdminResultParam.Range))" }
        if ($DomainAdminResultParam.CapApplied) { $daText += ", capped from $($DomainAdminResultParam.Requested) at the users created" }
    }
    Write-Host ""
    Write-Host "===== DEPLOYMENT SUMMARY =====" -ForegroundColor Cyan
    Write-Host "Users created:       $UserCountParam"
    Write-Host "Groups created:      $GroupCountParam"
    Write-Host "Service accounts:    $ServiceAccountCountParam"
    Write-Host "Computer objects:    $ComputerCountParam"
    Write-Host "DA accounts added:   $daText"
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

    Write-LogInfo "Initialize-ADDirectory.ps1 $scriptVersion started."
    # The marker's first write, before any check that can stop the run, so a stop still
    # ends in a Failed marker build-lab can read.
    $null = Write-PopulationResult -ArtifactsPathParam $artifactsPath -ResultParam $populationResult

    if (-not (Test-GlobalConfigVersion -FoundVersionParam $globalConfigVersion -RequiredVersionParam $requiredGlobalConfigVersion -ScriptNameParam 'Initialize-ADDirectory.ps1')) {
        throw "Stopping: include\global-config.ps1 is older than this script needs (error above). Fix it, then run this script again, or log on again if the logon task started it."
    }

    # Override file and build profile results from include\global-config.ps1, logged now
    # that logging has started. The logon task is still registered, so a fixed profile
    # re-runs at logon.
    $buildProfileFailed = Write-BuildProfileResult `
        -SummaryParam  $buildProfileSummary `
        -InfoParam     $buildProfileInfo `
        -WarningsParam $buildProfileWarnings `
        -ErrorParam    $buildProfileError
    if ($buildProfileFailed) {
        throw "Stopping: the build profile check failed (error above). Fix it, then run this script again, or log on again if the logon task started it."
    }

    #region Override File Parameters, Checked
    # The assignments made after global-config.ps1 was loaded, and what they couldn't do.
    if ($null -ne $overrideAssignmentResult) {
        foreach ($overrideLine in @($overrideAssignmentResult.Info)) { if ($overrideLine) { Write-LogInfo $overrideLine } }
        foreach ($overrideLine in @($overrideAssignmentResult.Warnings)) { if ($overrideLine) { Write-LogWarn $overrideLine } }
        if ($overrideAssignmentResult.Error) {
            foreach ($overrideLine in ($overrideAssignmentResult.Error -split '\r?\n')) { if ($overrideLine) { Write-LogError $overrideLine } }
            throw "Stopping: the override file's parameter values couldn't be applied (error above). Fix it, then run this script again, or log on again if the logon task started it."
        }
    }
    if ($overrideAssignmentRefused.Count -gt 0) {
        foreach ($refusedAssignment in $overrideAssignmentRefused) {
            Write-LogError "$($overrideFileLabel): $($refusedAssignment.Key) '$($refusedAssignment.Value)' isn't valid for -$($refusedAssignment.ParameterName), whose own checks refused it. OVERRIDE.md lists its permitted values."
        }
        throw "Stopping: the override file holds a value this script's parameters refuse (error above). Fix it, then run this script again, or log on again if the logon task started it."
    }

    # The count pairs, with the command line's values: a value is set when the command
    # line gave it, the override file gave it, or the script's default differs from the
    # shipped one. An inherited value gives way to a set one with a WARN. Two set values
    # that clash stop the run here, before anything is created.
    foreach ($countPair in @(@('MinGroupMembers', 'MaxGroupMembers'), @('MinDA', 'MaxDA'))) {
        $pairArguments = @{ MinKey = $countPair[0]; MaxKey = $countPair[1] }
        foreach ($pairSide in @(@('Min', $countPair[0]), @('Max', $countPair[1]))) {
            $pairName   = $pairSide[1]
            $pairValue  = [int](Get-Variable -Name $pairName -ValueOnly)
            $pairSource = ''
            if ($PSBoundParameters.ContainsKey($pairName)) {
                $pairSource = 'Command line'
            } elseif ($overrideAssignedKeys.ContainsKey($pairName)) {
                $pairSource = $overrideFileLabel
            } elseif ($null -eq $overrideFileCatalog -or $null -eq $overrideFileCatalog.Settings[$pairName] -or [int]$overrideFileCatalog.Settings[$pairName].Shipped -ne $pairValue) {
                $pairSource = 'Initialize-ADDirectory.ps1'
            }
            $pairArguments["$($pairSide[0])Value"]  = $pairValue
            $pairArguments["$($pairSide[0])Source"] = $pairSource
        }
        $pairResult = Resolve-MinMaxPair @pairArguments
        if ($pairResult.Error) {
            Write-LogError $pairResult.Error
            throw "Stopping: $($countPair[0]) and $($countPair[1]) clash (error above). Fix them, then run this script again, or log on again if the logon task started it."
        }
        if ($pairResult.Warning) {
            Write-LogWarn $pairResult.Warning
            Set-Variable -Name $countPair[0] -Value $pairResult.Min
            Set-Variable -Name $countPair[1] -Value $pairResult.Max
        }
    }

    # Generated passwords are never shorter than the domain's effective minimum, which the
    # policy set before the binds enforces. The length is raised here, before any account,
    # and both account creators are passed it.
    $passwordLengthSource = 'Initialize-ADDirectory.ps1'
    if ($PSBoundParameters.ContainsKey('PasswordLength')) { $passwordLengthSource = 'Command line' }
    elseif ($overrideAssignedKeys.ContainsKey('PasswordLength')) { $passwordLengthSource = $overrideFileLabel }
    $effectiveMinimumLength = $minPasswordLength -as [int]
    if ($null -ne $effectiveMinimumLength) {
        $passwordLengthResult = Resolve-GeneratedPasswordLength -PasswordLength $PasswordLength -Source $passwordLengthSource -MinPasswordLength $effectiveMinimumLength
        if ($passwordLengthResult.Warning) {
            Write-LogWarn $passwordLengthResult.Warning
            Set-Variable -Name 'PasswordLength' -Value $passwordLengthResult.Length
        }
    }

    # One INFO line per shipped default that changed since the previous release, for a
    # setting this run left at that default, the command line's parameters included.
    Write-OverrideChangedDefault -CatalogPathParam $overrideFileCatalogPath -ReleaseTablePathParam $overrideFileReleaseTablePath -CurrentVersionParam $scriptVersion -SetKeyParam $overrideFileSetKeys -BoundParameterNameParam @($PSBoundParameters.get_Keys())
    #endregion

    #region Population Settings
    # The command line, then the build profile, then the override file, then the default.
    # Population's preset sets the counts nobody gave on the command line.
    $boundParameterCopy = @{}
    foreach ($boundName in @($PSBoundParameters.get_Keys())) { $boundParameterCopy[$boundName] = $PSBoundParameters[$boundName] }
    $countValues = [ordered]@{ UserCount = $UserCount; GroupCount = $GroupCount; ComputerCount = $ComputerCount; MinGroupMembers = $MinGroupMembers; MaxGroupMembers = $MaxGroupMembers; MinDA = $MinDA; MaxDA = $MaxDA }
    $populationProfilePath = ''
    if (Test-Path -LiteralPath $buildProfileDataPath -PathType Leaf) { $populationProfilePath = $buildProfileDataPath }
    $populationSettings = Resolve-PopulationSetting `
        -PopulationProfile   $buildProfilePopulation `
        -BoundParameter      $boundParameterCopy `
        -CountValue          $countValues `
        -OverrideAssignedKey $overrideAssignedKeys `
        -OverrideLabel       $overrideFileLabel `
        -ProfilePath         $populationProfilePath
    foreach ($populationLine in @($populationSettings.Info)) { Write-LogInfo $populationLine }
    foreach ($populationLine in @($populationSettings.Warnings)) { Write-LogWarn $populationLine }
    Write-LogInfo $populationSettings.SettingsLine
    $populationResult['Population']       = $populationSettings.Population
    $populationResult['DomainAdminCount'] = if ($populationSettings.DomainAdminMode -eq 'Fixed') { $populationSettings.DomainAdminCount } else { 'Random' }
    foreach ($countName in @('UserCount', 'GroupCount', 'ComputerCount', 'MinGroupMembers', 'MaxGroupMembers')) {
        Set-Variable -Name $countName -Value $populationSettings.Counts[$countName]
    }
    #endregion

    #region Pre-Flight
    if (-not (Test-DomainPrerequisites -DomainNameParam $domainName -ArtifactsPathParam $artifactsPath)) {
        throw "Pre-flight checks failed. Review errors above before re-running."
    }
    #endregion

    #region CSV Validation and Load
    # Before the logon task is removed, so a CSV fix plus a logon re-runs population.
    # Both only read files.
    Test-AllCsvFiles  -CsvFilePathsParam $overrideFileCsvPaths -DomainNameParam $domainName
    Import-LabCsvData -CsvFilePathsParam $overrideFileCsvPaths
    #endregion

    Remove-PopulateScheduledTask -TaskNameParam $scheduledTaskName

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

    #region OU Structure
    New-OUStructure `
        -DomainDNParam $domainDN `
        -OUNamesParam  @('Employees', 'Groups', 'Servers', 'Workstations', 'Admins', 'ServiceAccounts', 'DisabledUsers', 'Quarantine')
    #endregion

    #region Generated Password Floor
    # The users are created under the domain's current policy, before the run sets its
    # own, so the generated length also meets the minimum the domain enforces now, read
    # from the domain before the first account.
    $passwordFloor = Resolve-DomainPasswordFloor `
        -PasswordLengthParam   $PasswordLength `
        -SourceParam           $passwordLengthSource `
        -EffectiveMinimumParam $effectiveMinimumLength `
        -DomainNameParam       $domainName
    foreach ($floorLine in @($passwordFloor.Warnings)) { Write-LogWarn $floorLine }
    if ($passwordFloor.Length -ne $PasswordLength) { Set-Variable -Name 'PasswordLength' -Value $passwordFloor.Length }
    #endregion

    #region Directory Population
    # The seed is set here, after every module import that comes before the first draw, so
    # a module can't change it. With Random a seed is drawn, logged and used, so any run
    # can be repeated from its log.
    if ($populationSettings.PopulationSeed -is [string]) {
        $seedUsed       = Get-Random -Minimum 1 -Maximum 2147483647
        $seedSourceUsed = 'Drawn'
        $seedLine       = "Random seed: $seedUsed (drawn for this run; set PopulationSeed in a build profile to repeat this population)."
    } else {
        $seedUsed       = [int]$populationSettings.PopulationSeed
        $seedSourceUsed = $populationSettings.SeedSource
        $seedLine       = "Random seed: $seedUsed ($($populationSettings.SeedSourceText))."
    }
    $null = Get-Random -SetSeed $seedUsed
    Write-LogInfo $seedLine
    $populationResult['RandomSeed']       = $seedUsed
    $populationResult['RandomSeedSource'] = $seedSourceUsed

    $groupNames   = New-LabGroups `
                        -Count      $GroupCount `
                        -WordSeeds  $script:wordSeeds `
                        -TargetOU   $groupsOU
    $groupList    = @($groupNames | Where-Object { $_ })

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
                        -EmployeeOUParam     $usersOU `
                        -PasswordLengthParam $PasswordLength `
                        -FirstNamesData      $script:firstNames `
                        -LastNamesData       $script:lastNames `
                        -DepartmentsData     $script:departments `
                        -TitlesData          $script:titles `
                        -ActiveCompaniesData $activeCompanies `
                        -OfficesData         $script:offices `
                        -CitiesData          $script:cities `
                        -StreetsData         $script:streets `
                        -PctRemoteParam      $pctRemoteUsers `
                        -SharedCityName      $($sharedCityRecord.City) `
                        -SharedCityState     $($sharedCityRecord.State)
    # A function that returns an empty list hands back nothing, so each step below that
    # reads the users or the groups checks for them itself.
    $userList = @($createdUsers | Where-Object { $null -ne $_ })
    $populationResult['UsersCreated']  = $userList.Count
    $populationResult['GroupsCreated'] = $groupList.Count

    if ($groupList.Count -gt 0) {
        Set-NestedGroupMemberships `
            -GroupNames $groupNames `
            -MaxDepth   $MaxGroupNestingDepth
    } else {
        Write-LogInfo 'Group nesting: no groups were created, so none were nested.'
    }

    if ($userList.Count -gt 0) {
        Set-UserManagers -Users $createdUsers
    } else {
        Write-LogInfo 'Managers: no users were created, so none were assigned.'
    }

    # The password policy is set after the users are created and just before the binds,
    # so the lockout threshold is in force when they run. The service accounts below are
    # created under it. It draws no random number, so the seeded draws are unchanged.
    Set-PasswordPolicy `
        -DomainNameParam         $domainName `
        -MinPwLenParam           $minPasswordLength `
        -PwHistoryCountParam     $passwordHistoryCount `
        -LockoutThresholdParam   $lockoutThreshold `
        -LockoutDurationMinParam $lockoutDurationMinutes `
        -MaxPwAgeDaysParam       $maxPasswordAgeDays

    if ($userList.Count -gt 0) {
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
    } else {
        Write-LogInfo 'User states: no users were created, so none were set.'
    }

    # Project the SAM list once; reused by group-membership and Domain Admins population below.
    $userSams = @($userList | ForEach-Object { $_.Sam })

    if ($userList.Count -eq 0) {
        Write-LogInfo 'Group memberships: no users were created, so none were assigned.'
    } elseif ($groupList.Count -eq 0) {
        Write-LogInfo 'Group memberships: no groups were created, so none were assigned.'
    } else {
        Set-GroupMemberships `
            -GroupNames  $groupNames `
            -UserSams    $userSams `
            -MinMembers  $MinGroupMembers `
            -MaxMembers  $MaxGroupMembers
    }

    $domainAdminResult = Set-DomainAdminMemberships `
        -UserSams        $userSams `
        -ModeParam       $populationSettings.DomainAdminMode `
        -FixedCountParam $(if ($null -ne $populationSettings.DomainAdminCount) { $populationSettings.DomainAdminCount } else { 0 }) `
        -MinDAParam      $MinDA `
        -MaxDAParam      $MaxDA `
        -PopulationParam $populationSettings.Population `
        -SourceParam     $populationSettings.DomainAdminSourceText
    $populationResult['DomainAdminsAdded'] = @($domainAdminResult.Added | Where-Object { $_ }).Count

    if ($populationSettings.Population -eq 'None') {
        Write-LogInfo 'Service accounts: Population None creates none.'
    } else {
        New-ServiceAccounts `
            -ServiceAccountDefs  $script:serviceAcctDefs `
            -TargetOU            $serviceAccountsOU `
            -PasswordLengthParam $PasswordLength `
            -DomainNameParam     $domainName
    }

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
    $siteTopology = Set-ADSiteTopology `
        -PrimarySiteNameParam $primarySiteName `
        -PrimarySubnetParam   $primarySubnet `
        -DomainNameParam      $domainName `
        -ComputerNameParam    $env:COMPUTERNAME
    #endregion

    #region Validation and Reporting
    $testResults = Invoke-FunctionalTests `
        -UsersOUParam            $usersOU `
        -DisabledUsersOUParam    $disabledUsersOU `
        -DomainNameParam         $domainName `
        -DomainAdminResultParam  $domainAdminResult `
        -ExpectedUserCountParam  $UserCount `
        -CACommonNameParam       $caCommonName `
        -SiteTopologyParam       $siteTopology `
        -ServiceAccountDefsParam $script:serviceAcctDefs `
        -ComputerNameParam       $env:COMPUTERNAME `
        -PopulationParam         $populationSettings.Population
    # One timestamp for every file this run writes to artifacts, so the marker's list
    # names them exactly.
    $artifactTimestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $artifactNames = [System.Collections.Generic.List[string]]::new()
    foreach ($artifactName in @(Export-Artifacts -Users $createdUsers -TestResults $testResults -ArtifactsPathParam $artifactsPath -TimestampParam $artifactTimestamp)) { $artifactNames.Add($artifactName) }
    # The comparison export is read-only and only for comparing builds, so a failure is a
    # WARN and the run goes on.
    try {
        $comparisonNames = Export-PopulationComparisonData `
            -ArtifactsPathParam      $artifactsPath `
            -TimestampParam          $artifactTimestamp `
            -DomainNameParam         $domainName `
            -DomainDNParam           $domainDN `
            -UserOUParam             @($usersOU, $disabledUsersOU, $serviceAccountsOU) `
            -GroupsOUParam           $groupsOU `
            -ServiceAccountDefsParam $script:serviceAcctDefs
        foreach ($artifactName in @($comparisonNames)) { $artifactNames.Add($artifactName) }
    } catch {
        Write-LogWarn "Population comparison export failed, so this build can't be compared with another: $_"
    }
    $populationResult['ArtifactFiles'] = [string[]]$artifactNames.ToArray()

    $passCount = @($testResults | Where-Object { $_.Result -eq 'PASS' }).Count
    $populationResult['TestsPassed'] = $passCount
    $populationResult['TestsFailed'] = @($testResults | Where-Object { $_.Result -eq 'FAIL' }).Count
    $populationResult['FailedTests'] = @($testResults | Where-Object { $_.Result -eq 'FAIL' } | ForEach-Object { [pscustomobject][ordered]@{ TestName = [string]$_.TestName; Detail = [string]$_.Detail } })
    $serviceAccountCount = if ($populationSettings.Population -eq 'None') { 0 } else { @($script:serviceAcctDefs).Count }
    Write-DeploymentSummary `
        -UserCountParam           $($userList.Count) `
        -GroupCountParam          $($groupList.Count) `
        -ServiceAccountCountParam $serviceAccountCount `
        -ComputerCountParam       $ComputerCount `
        -DomainAdminResultParam   $domainAdminResult `
        -TestPassCountParam       $passCount `
        -TestTotalCountParam      $(@($testResults).Count) `
        -ArtifactsPathParam       $artifactsPath
    #endregion

    Write-LogSuccess "Initialize-ADDirectory.ps1 complete. Review artifacts at '$artifactsPath'."
} catch {
    Write-LogError "Initialize-ADDirectory.ps1 terminated with fatal error: $_"
    $populationFailed = $true
    $populationResult['Error'] = (([string]$_.Exception.Message) -replace '\s*\r?\n\s*', ' ').Trim()
} finally {
    # The marker's last write. Succeeded means the main block finished. Failed test rows
    # don't make it Failed, since they are warnings by design.
    $populationResult['State']       = if ($populationFailed) { 'Failed' } else { 'Succeeded' }
    $populationResult['FinishedUtc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $null = Write-PopulationResult -ArtifactsPathParam $artifactsPath -ResultParam $populationResult
    try { Stop-Transcript } catch { } # Intentional: suppress error if Start-Transcript was never reached
}
#endregion
