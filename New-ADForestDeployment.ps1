<#
.SYNOPSIS
    Deploys a Windows Server 2025 Active Directory Domain Controller.
.DESCRIPTION
    Validates server prerequisites, configures static networking, installs
    AD DS and supporting features, promotes the server as a new forest root DC,
    optionally registers a scheduled task to auto-run Initialize-ADDirectory.ps1
    after the promotion reboot, and initiates the reboot.

    Domain identity ($domainName, $forestName, $netBIOSName) is read from
    include\global-config.ps1, the single source of truth shared with
    Initialize-ADDirectory.ps1. To deploy a different domain, place a build profile at
    include\build-profile.psd1 (for example @{ DomainName = 'corp.example.test';
    NetBIOSName = 'CORP' }), or edit global-config.ps1. The profile's results are
    logged after the "started" line, and a profile error stops the run before anything
    is changed.

    Before promotion, after the AD DS role is installed, the forest and domain
    functional level names are checked against the names the installed
    Install-ADDSForest accepts, when its parameter types can be read.

    The reboot only occurs if forest promotion succeeds. If pre-flight checks or
    any earlier step fails, the script exits without rebooting.

    Run as: Local Administrator (pre-domain).
.EXAMPLE
    .\New-ADForestDeployment.ps1
    .\New-ADForestDeployment.ps1 -CreateScheduledTask
.EXAMPLE
    # Unattended (no prompts) -- used by build-lab.ps1 over vmrun guest operations.
    .\New-ADForestDeployment.ps1 -CreateScheduledTask -NonInteractive `
        -StaticIpAddress '192.168.1.50' -PrefixLength 24 -DefaultGateway '192.168.1.1'
.NOTES
    Version:      2.0.0
    Author:       Daniel Owen
    Release Date: 2026-11-05
    Requirements: Windows Server 2025, PowerShell 5.1+, local Administrator
#>

#region Parameters
param(
    [switch]$CreateScheduledTask,

    # When set, the network-configuration step never prompts: it throws a clear error
    # instead of calling Read-Host. Intended for unattended (vmrun/guest-operations) runs.
    [switch]$NonInteractive,

    # Static network values applied only when the selected adapter is found on DHCP (for
    # example after the unattended specialize pass silently fell back to DHCP because the
    # vmxnet3 driver was unavailable). Required together under -NonInteractive in that case.
    [string]$StaticIpAddress,

    [ValidateRange(1, 32)]
    [int]$PrefixLength,

    [string]$DefaultGateway,

    # Selects the adapter by name when more than one eligible adapter is present. Required
    # under -NonInteractive when adapter selection would otherwise be ambiguous.
    [string]$AdapterName
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
# WARNING: Lab environment only. Never use hardcoded credentials in production.
$dsrmPwDontDoThisInProd  = "TestEnvAdminP@ss1!"

$requiredPSVersion       = [version]"5.1"
# $requiredOSBuild is defined in include\global-config.ps1 (shared minimum OS build).
$script2Path             = Join-Path $PSScriptRoot "Initialize-ADDirectory.ps1"
$transcriptPath          = "$logPath\New-ADForestDeployment-$(Get-Date -Format yyyyMMddHHmmss).log"

# Gated to $true only after Install-NewForest succeeds. Controls whether the finally block reboots.
$rebootRequired          = $false
#endregion

#region Functions

function Test-Prerequisites {
    param(
        [string]$DomainNameParam,
        [int]$RequiredOSBuild,
        [version]$RequiredPS
    )
    try {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-LogError "Script must run in an elevated (Administrator) PowerShell session. Re-launch as Administrator."
            return $false
        }

        $os = Get-CimInstance Win32_OperatingSystem
        if ($os.BuildNumber -lt $RequiredOSBuild) {
            Write-LogError "Requires Windows Server build $RequiredOSBuild or later. Detected build: $($os.BuildNumber). Server 2025 (build 26100) is the only tested release. To run on Server 2019 or 2022, set RequiredOSBuild in a build profile (include\build-profile.psd1) to a build of 17763 or higher, the lab's lowest supported build."
            return $false
        }

        if ($PSVersionTable.PSVersion -lt $RequiredPS) {
            Write-LogError "Requires PowerShell $RequiredPS or later. Detected: $($PSVersionTable.PSVersion)."
            return $false
        }

        $execPolicy = Get-ExecutionPolicy
        if ($execPolicy -eq 'Restricted') {
            Write-LogError "Execution policy is Restricted. Set to at least RemoteSigned before running."
            return $false
        }

        $adFeature = Get-WindowsFeature -Name AD-Domain-Services
        if ($adFeature.Installed) {
            Write-LogError "AD-Domain-Services is already installed. This script targets a clean server."
            return $false
        }

        $caFeature = Get-WindowsFeature -Name ADCS-Cert-Authority
        if ($caFeature.Installed) {
            Write-LogError "ADCS-Cert-Authority is already installed. Install-ADDSForest refuses to promote a server with Certificate Server present. Remove the AD CS role before running this script -- it is installed post-promotion by Initialize-ADDirectory.ps1."
            return $false
        }

        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.PartOfDomain) {
            Write-LogError "Server is already domain-joined to '$($cs.Domain)'. Aborting."
            return $false
        }

        try {
            $null = Resolve-DnsName $DomainNameParam -ErrorAction Stop
            Write-LogError "DNS name '$DomainNameParam' already resolves. A conflicting zone may exist."
            return $false
        } catch {
            Write-LogInfo "DNS zone '$DomainNameParam' does not yet resolve. Continuing."
        }

        Write-LogSuccess "All pre-flight checks passed."
        return $true
    } catch {
        Write-LogError "Pre-flight check encountered an unexpected error: $_"
        return $false
    }
}

function Set-StaticNetworkConfiguration {
    # Self-contained: all interactivity/network inputs arrive as parameters so no code path
    # reachable under -NonInteractive can block on Read-Host (a console-less vmrun guest run
    # would hang forever on a prompt).
    param(
        [switch]$NonInteractive,
        [string]$StaticIpAddress,
        [int]$PrefixLength,
        [string]$DefaultGateway,
        [string]$AdapterName
    )
    try {
        # Exclude Wi-Fi (Native 802.11) and virtual/software adapters -- a DC requires a physical wired NIC.
        $eligibleAdapters = @(Get-NetAdapter | Where-Object {
            $_.Status          -eq 'Up'   -and
            $_.HardwareInterface          -and
            $_.PhysicalMediaType -ne 'Native 802.11'
        })

        if ($eligibleAdapters.Count -eq 0) {
            Write-LogError "No eligible network adapters found. Verify a physical NIC is connected and enabled."
            throw "No eligible adapters."
        }

        if ($AdapterName) {
            $selectedAdapter = $eligibleAdapters | Where-Object { $_.Name -eq $AdapterName } | Select-Object -First 1
            if (-not $selectedAdapter) {
                throw "Requested -AdapterName '$AdapterName' is not among the eligible adapters: $($eligibleAdapters.Name -join ', ')."
            }
            Write-LogInfo "Using adapter (by -AdapterName): $($selectedAdapter.Name) -- $($selectedAdapter.InterfaceDescription)"
        } elseif ($eligibleAdapters.Count -eq 1) {
            $selectedAdapter = $eligibleAdapters[0]
            Write-LogInfo "Using adapter: $($selectedAdapter.Name) -- $($selectedAdapter.InterfaceDescription)"
        } elseif ($NonInteractive) {
            throw "Multiple eligible adapters detected ($($eligibleAdapters.Name -join ', ')). Re-run with -AdapterName to select one -- -NonInteractive cannot prompt for a choice."
        } else {
            Write-LogWarn "Multiple eligible adapters detected:"
            for ($i = 0; $i -lt $eligibleAdapters.Count; $i++) {
                Write-Host "  [$i] $($eligibleAdapters[$i].Name) -- $($eligibleAdapters[$i].InterfaceDescription)"
            }
            $selection = Read-Host "Enter the index of the adapter to use"
            if ($selection -notmatch '^\d+$' -or [int]$selection -ge $eligibleAdapters.Count) {
                throw "Invalid adapter selection: '$selection'."
            }
            $selectedAdapter = $eligibleAdapters[[int]$selection]
        }

        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $($selectedAdapter.InterfaceIndex)

        $currentOrigin = ($ipConfig.IPv4Address | Select-Object -First 1).PrefixOrigin
        if ($currentOrigin -eq 'Dhcp') {
            Write-LogWarn "DHCP is active on '$($selectedAdapter.Name)'. A domain controller requires a static IP."
            if ($NonInteractive) {
                if (-not $StaticIpAddress -or $PrefixLength -le 0 -or -not $DefaultGateway) {
                    throw "Non-interactive network configuration requires -StaticIpAddress, -PrefixLength, and -DefaultGateway when the adapter is on DHCP. Received: StaticIpAddress='$StaticIpAddress', PrefixLength='$PrefixLength', DefaultGateway='$DefaultGateway'. (This DHCP state usually means the unattended specialize pass fell back to DHCP -- see New-VMwareWorkstationVM.ps1 vmxnet3 note.)"
                }
                $staticIP     = $StaticIpAddress
                $prefixLength = $PrefixLength
                $gateway      = $DefaultGateway
                Write-LogInfo "Applying supplied static configuration non-interactively (repairs a DHCP fallback from the unattended specialize pass)."
            } else {
                $staticIP     = Read-Host "Static IP address"
                $prefixLength = Read-Host "Subnet prefix length (e.g. 24)"
                $gateway      = Read-Host "Default gateway"
            }

            $null = Remove-NetIPAddress -InterfaceIndex $($selectedAdapter.InterfaceIndex) -Confirm:$false -ErrorAction SilentlyContinue
            $null = Remove-NetRoute    -InterfaceIndex $($selectedAdapter.InterfaceIndex) -Confirm:$false -ErrorAction SilentlyContinue

            $null = New-NetIPAddress -InterfaceIndex $($selectedAdapter.InterfaceIndex) `
                        -IPAddress $staticIP -PrefixLength $prefixLength -DefaultGateway $gateway

            $null = Set-DnsClientServerAddress -InterfaceIndex $($selectedAdapter.InterfaceIndex) `
                        -ServerAddresses @("127.0.0.1", $staticIP)

            Write-LogSuccess "Static IP $staticIP/$prefixLength applied to '$($selectedAdapter.Name)'."
        } else {
            $firstIPEntry = $ipConfig.IPv4Address | Select-Object -First 1
            if ($null -eq $firstIPEntry) {
                Write-LogError "Adapter '$($selectedAdapter.Name)' has no IPv4 address configured. Assign a static IP before re-running."
                throw "No IPv4 address found on selected adapter '$($selectedAdapter.Name)'."
            }
            Write-LogInfo "Adapter '$($selectedAdapter.Name)' already has a static IP. No changes made."
            $existingIP = $firstIPEntry.IPAddress
            $null = Set-DnsClientServerAddress -InterfaceIndex $($selectedAdapter.InterfaceIndex) `
                        -ServerAddresses @("127.0.0.1", $existingIP)
            Write-LogInfo "DNS client set to loopback + $existingIP."
        }
    } catch {
        Write-LogError "Network configuration failed: $_"
        throw
    }
}

function Install-RequiredFeatures {
    try {
        # ADCS-Cert-Authority/RSAT-ADCS are intentionally NOT installed here -- Install-ADDSForest refuses to
        # promote a server with Certificate Server present. The CA feature and configuration both happen
        # post-promotion in Initialize-ADDirectory.ps1's Install-EnterpriseRootCA.
        $featureList = @(
            'AD-Domain-Services',
            'DNS',
            'RSAT-AD-AdminCenter',
            'GPMC'
        )
        Write-LogInfo "Installing features: $($featureList -join ', ')"
        $result = Install-WindowsFeature -Name $featureList -IncludeManagementTools
        if ($result.RestartNeeded -eq 'Yes') {
            Write-LogWarn "Feature installation flagged a restart requirement. Continuing -- the promotion reboot will satisfy this."
        }
        if (-not $result.Success) {
            throw "Feature installation reported failure. Review output above."
        }
        Write-LogSuccess "Feature installation completed."
    } catch {
        Write-LogError "Feature installation failed: $_"
        throw
    }
}

function Get-FunctionalLevelParameterType {
    # Reads the type of one of Install-ADDSForest's mode parameters (ForestMode or
    # DomainMode). Returns the type, or the reason it could not be read. Never throws.
    param(
        [Parameter(Mandatory)][string]$ParameterNameParam
    )
    try {
        $installForestCommand = Get-Command -Name Install-ADDSForest -ErrorAction Stop
        if (-not $installForestCommand.Parameters.ContainsKey($ParameterNameParam)) {
            throw "Install-ADDSForest has no $ParameterNameParam parameter"
        }
        return [pscustomobject]@{ ParameterType = $installForestCommand.Parameters[$ParameterNameParam].ParameterType; ReadError = $null }
    } catch {
        return [pscustomobject]@{ ParameterType = $null; ReadError = (($_.Exception.Message -replace '\s*\r?\n\s*', ' ').Trim().TrimEnd('.')) }
    }
}

function Test-FunctionalLevelName {
    # Compares a functional level name with the names the installed Install-ADDSForest
    # parameter accepts. Returns $false only when the parameter is an enum that does not
    # hold the name. A type that is not an enum, or one that could not be read, logs a
    # WARN and leaves the check to Install-ADDSForest itself.
    param(
        [Parameter(Mandatory)][string]$ParameterNameParam,
        [Parameter(Mandatory)][string]$VariableNameParam,
        [Parameter(Mandatory)][string]$LevelNameParam,
        [AllowNull()][type]$ParameterTypeParam,
        [AllowNull()][string]$ReadErrorParam
    )
    if ($null -eq $ParameterTypeParam) {
        Write-LogWarn "Functional level check: couldn't read Install-ADDSForest's $ParameterNameParam parameter: $ReadErrorParam. Leaving the check of '$LevelNameParam' to Install-ADDSForest."
        return $true
    }
    if (-not $ParameterTypeParam.IsEnum) {
        Write-LogWarn "Functional level check: Install-ADDSForest's $ParameterNameParam parameter is of type $($ParameterTypeParam.FullName), not an enum, so its accepted names can't be read here. Leaving the check of '$LevelNameParam' to Install-ADDSForest."
        return $true
    }
    $acceptedNames = @([Enum]::GetNames($ParameterTypeParam))
    if ($acceptedNames -contains $LevelNameParam) {
        Write-LogInfo "Functional level check: Install-ADDSForest accepts $ParameterNameParam '$LevelNameParam'."
        return $true
    }
    Write-LogError "Functional level check: Install-ADDSForest on this server does not accept $ParameterNameParam '$LevelNameParam'. It accepts: $($acceptedNames -join ', '). Set $ParameterNameParam in the build profile, or `$$VariableNameParam in global-config.ps1, to a level this server accepts. The AD DS role is already installed and this script's pre-flight refuses a server that has it, so start again from a clean server."
    return $false
}

function Install-NewForest {
    param(
        [string]$DomainNameParam,
        [string]$ForestNameParam,
        [string]$NetBIOSNameParam,
        [SecureString]$DSRMPasswordParam,
        [string]$ForestModeParam,
        [string]$DomainModeParam
    )
    try {
        Import-Module ADDSDeployment -ErrorAction Stop
        Write-LogInfo "Promoting server as forest root DC for '$ForestNameParam'..."

        # -NoRebootOnCompletion defers reboot so the finally block can optionally register the scheduled task first.
        # -Force suppresses the interactive confirmation dialog for unattended runs.
        Install-ADDSForest `
            -DomainName                    $DomainNameParam `
            -ForestMode                    $ForestModeParam `
            -DomainMode                    $DomainModeParam `
            -DomainNetBIOSName             $NetBIOSNameParam `
            -InstallDns `
            -SafeModeAdministratorPassword $DSRMPasswordParam `
            -NoRebootOnCompletion `
            -Force

        Write-LogSuccess "AD forest deployment completed. Reboot pending."
    } catch {
        Write-LogError "AD forest promotion failed: $_"
        throw
    }
}

function Register-PopulateScheduledTask {
    param(
        [string]$Script2PathParam,
        [string]$TaskNameParam
    )
    try {
        if (-not (Test-Path $Script2PathParam)) {
            Write-LogError "Initialize-ADDirectory.ps1 not found at '$Script2PathParam'. Scheduled task cannot be created."
            throw "Script 2 path not found."
        }

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                         -Argument "-NoProfile -ExecutionPolicy Bypass -NonInteractive -File `"$Script2PathParam`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4)

        $null = Register-ScheduledTask -TaskName $TaskNameParam `
                    -Action $action -Trigger $trigger `
                    -Principal $principal -Settings $settings -Force

        # Register-ScheduledTask can write a non-terminating CIM error and still return without
        # throwing, leaving the task missing or partially configured. Confirm it actually exists.
        $null = Get-ScheduledTask -TaskName $TaskNameParam -ErrorAction Stop

        Write-LogSuccess "Scheduled task '$TaskNameParam' registered. Initialize-ADDirectory.ps1 will auto-run at next Administrator logon."
    } catch {
        Write-LogError "Failed to register scheduled task '$TaskNameParam': $_"
        throw
    }
}

function Show-PostPromotionManualStepNotice {
    # Prints an unmissable red console banner reminding the operator that directory
    # population has NOT run yet. The scheduled task uses an -AtLogOn trigger with a
    # BUILTIN\Administrators group principal, so Initialize-ADDirectory.ps1 does not
    # run until an Administrator logs into this server after the reboot. Console-only
    # by design (a visual prompt); the caller also writes the same instruction through
    # Write-LogWarn so the transcript/CSV records it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Deliberate red console banner so the operator cannot miss the required manual logon step; the same instruction is also persisted via Write-LogWarn by the caller.')]
    param ()
    $bannerLines = @(
        '',
        '================================================================================',
        ' ACTION REQUIRED: DIRECTORY POPULATION HAS NOT RUN YET',
        '',
        ' AD forest promotion succeeded, but Initialize-ADDirectory.ps1 (OUs, users,',
        ' groups, Enterprise CA, GPOs, etc.) runs via a scheduled task that triggers',
        ' ONLY at the next Administrator logon.',
        '',
        ' Log into this server as Administrator after the reboot to start directory',
        ' population. It removes its own scheduled task and reboots when finished.',
        '================================================================================',
        ''
    )
    foreach ($bannerLine in $bannerLines) {
        Write-Host $bannerLine -ForegroundColor Red
    }
}

#endregion

#region Main Execution Block
try {
    Initialize-Logging `
        -LogPathParam    $logPath `
        -ScriptNameParam "New-ADForestDeployment.ps1" `
        -CsvLogPathParam $csvErrorLogPath
    Start-Transcript -Path $transcriptPath

    Write-LogInfo "New-ADForestDeployment.ps1 started."

    # Build profile results from include\global-config.ps1, logged now that logging has started.
    $buildProfileFailed = Write-BuildProfileResult `
        -SummaryParam  $buildProfileSummary `
        -InfoParam     $buildProfileInfo `
        -WarningsParam $buildProfileWarnings `
        -ErrorParam    $buildProfileError
    if ($buildProfileFailed) {
        throw "Stopping before any change: the build profile check failed (error above). Fix it and run this script again."
    }

    if ($forestName -ne $domainName) {
        throw "For a new forest root domain, `$forestName must equal `$domainName in global-config.ps1. Found: domainName='$domainName', forestName='$forestName'."
    }

    if (-not (Test-Prerequisites -DomainNameParam $domainName -RequiredOSBuild $requiredOSBuild -RequiredPS $requiredPSVersion)) {
        throw "Pre-flight checks failed. Review errors above before re-running."
    }

    Set-StaticNetworkConfiguration `
        -NonInteractive:$NonInteractive `
        -StaticIpAddress $StaticIpAddress `
        -PrefixLength    $PrefixLength `
        -DefaultGateway  $DefaultGateway `
        -AdapterName     $AdapterName
    Install-RequiredFeatures

    # The Install-ADDSForest reference lists mode values only up to WinThreshold, so the
    # names are checked against the installed cmdlet before promoting.
    foreach ($levelCheck in @(
            @{ ParameterName = 'ForestMode'; VariableName = 'forestMode'; LevelName = $forestMode },
            @{ ParameterName = 'DomainMode'; VariableName = 'domainMode'; LevelName = $domainMode })) {
        $levelTypeRead = Get-FunctionalLevelParameterType -ParameterNameParam $levelCheck.ParameterName
        $levelAccepted = Test-FunctionalLevelName `
            -ParameterNameParam $levelCheck.ParameterName `
            -VariableNameParam  $levelCheck.VariableName `
            -LevelNameParam     $levelCheck.LevelName `
            -ParameterTypeParam $levelTypeRead.ParameterType `
            -ReadErrorParam     $levelTypeRead.ReadError
        if (-not $levelAccepted) {
            throw "Functional level check failed for $($levelCheck.ParameterName) '$($levelCheck.LevelName)'. Review the error above."
        }
    }

    Install-NewForest `
        -DomainNameParam   $domainName `
        -ForestNameParam   $forestName `
        -NetBIOSNameParam  $netBIOSName `
        -DSRMPasswordParam (ConvertTo-SecureString $dsrmPwDontDoThisInProd -AsPlainText -Force) `
        -ForestModeParam   $forestMode `
        -DomainModeParam   $domainMode

    $rebootRequired = $true

    if ($CreateScheduledTask) {
        Register-PopulateScheduledTask -Script2PathParam $script2Path -TaskNameParam $scheduledTaskName
        Write-LogWarn "Directory population has NOT run yet. Initialize-ADDirectory.ps1 runs only at the next Administrator logon. Log into this server as Administrator after the reboot to start it."
        Show-PostPromotionManualStepNotice
    } else {
        Write-LogInfo "Scheduled task not requested. Run Initialize-ADDirectory.ps1 manually after reboot."
    }

    Write-LogSuccess "New-ADForestDeployment.ps1 complete. Rebooting now."
} catch {
    Write-LogError "New-ADForestDeployment.ps1 terminated with fatal error: $_"
} finally {
    try { Stop-Transcript } catch { } # Intentional: suppress error if Start-Transcript was never reached
    if ($rebootRequired) {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO]    Reboot initiated."
        Restart-Computer -Force
    } else {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO]    Reboot skipped -- promotion did not complete successfully."
    }
}
#endregion
