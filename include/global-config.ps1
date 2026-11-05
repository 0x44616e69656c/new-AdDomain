<#
.SYNOPSIS
    Shared configuration variables for the AD deployment script set.
.DESCRIPTION
    Dot-sourced by New-ADForestDeployment.ps1 and Initialize-ADDirectory.ps1, and by
    build-lab.ps1 on the host. All operational values are defined here. No hardcoded
    values should appear inside logic blocks in either script. $deployRoot is computed as
    the parent of this include\ folder, so logs, config CSVs, and artifacts always live
    alongside the deployment scripts, wherever this project folder is run from.

    The file runs in three parts:
      1. The base values: the domain, the functional levels, the minimum OS build and
         the AD site. Each is first set to $null, so a deleted assignment reads as empty
         rather than picking up a same-named variable from the caller.
      2. Load and validate: dot-sources include\BuildProfile.ps1 and calls
         Get-BuildProfile, which applies include\build-profile.psd1 when it exists,
         replaces empty values, validates every value and returns the effective ones.
      3. The derived values: $forestName, $domainDN and the OU paths. Skipped when part
         2 found an error.

    It never throws for a profile or validation problem. It sets $buildProfileSummary,
    $buildProfileInfo, $buildProfileWarnings and $buildProfileError for the scripts to
    log once logging has started. Loading it writes nothing to the output, the console
    or the disk.
.EXAMPLE
    . .\global-config.ps1
.NOTES
    Version:      2.0.0
    Author:       Daniel Owen
    Release Date: 2026-11-05
    Requirements: PowerShell 5.1+
#>

#region Deployment Root
# This file lives in <project root>\include\, so the parent of $PSScriptRoot is the project root.
$deployRoot              = Split-Path -Path $PSScriptRoot -Parent
#endregion

#region Part 1: Base Values
# A build profile (include\build-profile.psd1) overrides any of these for one build. Each
# key is the variable name with a capital first letter, for example DomainName overrides
# $domainName. An empty value here takes the shipped value, with a warning.
$domainName              = $null
$netBIOSName             = $null
$forestMode              = $null
$domainMode              = $null
$requiredOSBuild         = $null
$primarySiteName         = $null
$primarySubnet           = $null

#region Domain Identity
# Single source of truth for domain identity, shared by New-ADForestDeployment.ps1 (forest creation)
# and Initialize-ADDirectory.ps1 (post-promotion population). $forestName always equals $domainName
# (part 3), because the scripts build a new forest root domain only.
$domainName              = "lab.test"
$netBIOSName             = "LAB"
#endregion

#region Forest and Domain Functional Level
# WinThreshold or Win2025. Win2025 needs Server 2025 domain controllers.
$forestMode              = "WinThreshold"
$domainMode              = "WinThreshold"
#endregion

#region Minimum OS Requirement
# Lowest Windows Server build New-ADForestDeployment.ps1 will promote. Its pre-flight
# check refuses to run on anything below this. Build reference:
#   17763 = Server 2019   20348 = Server 2022   26100 = Server 2025
# Do not set below 17763. The lab covers Server 2019, 2022 and 2025 only, so a lower value
# is raised to 17763, and to 26100 when either functional level is Win2025. Server 2025 is
# the only tested release, so the shipped value is 26100.
$requiredOSBuild         = 26100
#endregion

#region AD Sites
# 'Auto' creates the subnet the domain controller's own address sits in. An explicit
# IPv4 subnet in CIDR form is used when it contains the DC's address.
$primarySiteName         = "Lab-HQ"
$primarySubnet           = 'Auto'
#endregion
#endregion

#region Network
$dnsForwarders           = @("1.1.1.1", "8.8.8.8")
$ntpServers              = @("time.windows.com")
#endregion

#region Computer Naming Prefixes
$workstationPrefix       = "WK"
$serverPrefix            = "SRV"
$laptopPrefix            = "LAP"
#endregion

#region File Paths
$logPath                 = "$deployRoot\logs"
$csvPath                 = "$deployRoot\config"
$artifactsPath           = "$deployRoot\artifacts"
$csvErrorLogPath         = "$logPath\ad-deploy-errors.csv"
#endregion

#region Certificate Authority
$caCommonName            = "Lab-Root-CA"
$caKeyLength             = 2048
$caHashAlgorithm         = "SHA256"
$caValidityYears         = 5
$caDatabasePath          = "C:\Windows\system32\CertLog"
$caLogPath               = "C:\Windows\system32\CertLog"    # Lab: same directory for CA database and logs is intentional
#endregion

#region Scheduled Task
$scheduledTaskName       = "AD-Populate-PostPromotion"
#endregion

#region Password Policy
$minPasswordLength       = 15
$passwordHistoryCount    = 24
$lockoutThreshold        = 5
$lockoutDurationMinutes  = 30
$maxPasswordAgeDays      = 90
#endregion

#region User Population
# UPN format applied to all created users.
# Options: "firstlast" (john.smith@lab.test), "f_last" (j_smith@lab.test), or any other value (uses sam@domain, e.g. jsmith@lab.test)
# "firstlast" is safe from UPN collisions because New-LabUsers guarantees unique display names
# (unique "First Last" implies unique first.last). "f_last" can still collide (e.g. John/Jane Smith).
$upnPattern              = "firstlast"

# Percentage of users to receive each non-normal state. Remaining users are left as standard enabled accounts.
# These are applied cumulatively: roll 1-5 = disabled, 6-10 = pw expired, 11-20 = pw never expires,
# 21-23 = smartcard required, 24-25 = locked. 26-100 = normal.
$pctDisabled             = 5
$pctPwExpired            = 5
$pctPwNeverExpires       = 10
$pctSmartcard            = 3
$pctLocked               = 2

# Companies randomly selected per run; all users are assigned to one of the chosen companies.
$minCompanyCount         = 1
$maxCompanyCount         = 5

# Remote workers receive a random city each; all other users share a single city picked once per run.
$pctRemoteUsers          = 30
#endregion

#region Part 2: Load and Validate the Build Profile
# Every variable this part adds starts with $buildProfile, so none can overwrite a
# same-named parameter of the script that dot-sources this file.
$buildProfileSummary     = $null
$buildProfileInfo        = [string[]]@()
$buildProfileWarnings    = [string[]]@()
$buildProfileError       = $null
$buildProfileScriptPath  = Join-Path -Path $PSScriptRoot -ChildPath 'BuildProfile.ps1'
$buildProfileDataPath    = Join-Path -Path $PSScriptRoot -ChildPath 'build-profile.psd1'

if (-not (Test-Path -LiteralPath $buildProfileScriptPath -PathType Leaf)) {
    $buildProfileError = "BuildProfile.ps1 not found at '$buildProfileScriptPath'. Restore include\BuildProfile.ps1 from the new-AdDomain repository. Without it the build profile can't be checked and service account SPNs can't be resolved."
} else {
    try {
        . $buildProfileScriptPath
    } catch {
        $buildProfileError = "BuildProfile.ps1 at '$buildProfileScriptPath' failed to load: $(($_.Exception.Message -replace '\s*\r?\n\s*', ' ').Trim().TrimEnd('.')). Restore include\BuildProfile.ps1 from the new-AdDomain repository."
    }
}

if (-not $buildProfileError) {
    $buildProfileArguments = @{
        DomainName      = $domainName
        NetBIOSName     = $netBIOSName
        ForestMode      = $forestMode
        DomainMode      = $domainMode
        RequiredOSBuild = $requiredOSBuild
        PrimarySiteName = $primarySiteName
        PrimarySubnet   = $primarySubnet
    }
    if (Test-Path -LiteralPath $buildProfileDataPath -PathType Leaf) {
        $buildProfileArguments['ProfilePath'] = $buildProfileDataPath
    }
    $buildProfileResult   = Get-BuildProfile @buildProfileArguments
    $buildProfileSummary  = $buildProfileResult.Summary
    $buildProfileInfo     = [string[]]@($buildProfileResult.Info)
    $buildProfileWarnings = [string[]]@($buildProfileResult.Warnings)
    $buildProfileError    = $buildProfileResult.Error

    if (-not $buildProfileError) {
        $domainName      = $buildProfileResult.DomainName
        $netBIOSName     = $buildProfileResult.NetBIOSName
        $forestMode      = $buildProfileResult.ForestMode
        $domainMode      = $buildProfileResult.DomainMode
        $requiredOSBuild = $buildProfileResult.RequiredOSBuild
        $primarySiteName = $buildProfileResult.PrimarySiteName
        $primarySubnet   = $buildProfileResult.PrimarySubnet
    }
}
#endregion

#region Part 3: Derived Values
# Skipped when part 2 found an error. Both scripts log that error and stop, and their log
# paths come from $deployRoot, not from the domain.
if (-not $buildProfileError) {
    $forestName          = $domainName

    # Derived domain distinguished name, from the effective $domainName.
    $domainDN            = ($domainName.Split('.') | ForEach-Object { "DC=$_" }) -join ','

    # All OU paths are derived from $domainDN.
    $usersOU             = "OU=Employees,$domainDN"  # Not "Users", which collides with the built-in CN=Users container at the domain root
    $groupsOU            = "OU=Groups,$domainDN"
    $serversOU           = "OU=Servers,$domainDN"
    $workstationsOU      = "OU=Workstations,$domainDN"
    $adminsOU            = "OU=Admins,$domainDN"          # OU created; reserved for future use as an object target
    $serviceAccountsOU   = "OU=ServiceAccounts,$domainDN"
    $disabledUsersOU     = "OU=DisabledUsers,$domainDN"
    $quarantineOU        = "OU=Quarantine,$domainDN"      # OU created; reserved for future use as an object target
}
#endregion
