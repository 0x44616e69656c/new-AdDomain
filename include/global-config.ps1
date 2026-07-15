<#
.SYNOPSIS
    Shared configuration variables for the AD deployment script set.
.DESCRIPTION
    Dot-sourced by New-ADForestDeployment.ps1 and Initialize-ADDirectory.ps1.
    All operational values are defined here. No hardcoded values should appear
    inside logic blocks in either script. $deployRoot is computed as the parent
    of this include\ folder, so logs, config CSVs, and artifacts always live
    alongside the deployment scripts, wherever this project folder is run from.
.EXAMPLE
    . .\global-config.ps1
.NOTES
    Version:      1.0.0
    Author:       Daniel Owen
    Release Date: 2026-07-13
    Requirements: PowerShell 5.1+
#>

#region Deployment Root
# This file lives in <project root>\include\, so the parent of $PSScriptRoot is the project root.
$deployRoot              = Split-Path -Path $PSScriptRoot -Parent
#endregion

#region Domain Identity
# Single source of truth for domain identity, shared by New-ADForestDeployment.ps1 (forest creation)
# and Initialize-ADDirectory.ps1 (post-promotion population). Edit these values to deploy a different domain.
$domainName              = "lab.local"
$forestName              = "lab.local"    # Must equal $domainName for a new forest root domain.
$netBIOSName             = "LAB"

# Derived domain distinguished name. Update automatically when $domainName changes.
$domainDN                = ($domainName.Split('.') | ForEach-Object { "DC=$_" }) -join ','
#endregion

#region Forest and Domain Functional Level
$forestMode              = "WinThreshold"
$domainMode              = "WinThreshold"
#endregion

#region Minimum OS Requirement
# Lowest Windows Server build New-ADForestDeployment.ps1 will promote. Its pre-flight
# check refuses to run on anything below this. Build reference:
#   14393 = Server 2016   17763 = Server 2019   20348 = Server 2022   26100 = Server 2025
# Do not set below 14393: the WinThreshold functional level above requires the DC to be
# Server 2016 or newer, so Install-ADDSForest would fail on an older build regardless.
$requiredOSBuild         = 26100
#endregion

#region Network
$dnsForwarders           = @("1.1.1.1", "8.8.8.8")
$ntpServers              = @("time.windows.com")
#endregion

#region OU Structure
# All OU paths are derived from $domainDN. Changing $domainName above updates these automatically.
$usersOU                 = "OU=Employees,$domainDN"  # Not "Users" -- collides with the built-in CN=Users container at the domain root (see gotchas.md)
$groupsOU                = "OU=Groups,$domainDN"
$serversOU               = "OU=Servers,$domainDN"
$workstationsOU          = "OU=Workstations,$domainDN"
$adminsOU                = "OU=Admins,$domainDN"          # OU created; reserved for future use as an object target
$serviceAccountsOU       = "OU=ServiceAccounts,$domainDN"
$disabledUsersOU         = "OU=DisabledUsers,$domainDN"
$quarantineOU            = "OU=Quarantine,$domainDN"      # OU created; reserved for future use as an object target
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

#region AD Sites
$primarySiteName         = "Lab-HQ"
$primarySubnet           = "10.0.0.0/24"
#endregion

#region User Population
# UPN format applied to all created users.
# Options: "firstlast" (john.smith@lab.local), "f_last" (j_smith@lab.local), or any other value (uses sam@domain, e.g. jsmith@lab.local)
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
