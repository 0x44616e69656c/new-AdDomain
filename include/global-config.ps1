<#
.SYNOPSIS
    Shared configuration variables for the AD deployment script set.
.DESCRIPTION
    Dot-sourced by New-ADForestDeployment.ps1 and Initialize-ADDirectory.ps1, and by
    build-lab.ps1 on the host. All operational values are defined here. No hardcoded
    values should appear inside logic blocks in either script. $deployRoot is computed as
    the parent of this include\ folder, so logs, config CSVs, and artifacts always live
    alongside the deployment scripts, wherever this project folder is run from.

    The file runs in four parts:
      1. The base values: the domain, the functional levels, the minimum OS build and
         the AD site, then the rest. The first seven are first set to $null, so a
         deleted assignment reads as empty rather than picking up a same-named variable
         from the caller.
      1b. The override file: dot-sources include\OverrideFile.ps1, which reads
         overrides\overrides.psd1 against include\override-catalog.psd1. A value it
         holds for one of this file's variables replaces the base value. Its values for
         the scripts' parameters and constants are kept in $overrideFileValues. A CSV
         under overrides\config replaces the shipped one, and $overrideFileCsvPaths
         names the file each script reads.
      2. Load and validate: dot-sources include\BuildProfile.ps1, keeps the user-state
         percentages and the count pairs consistent, and calls Get-BuildProfile, which
         applies include\build-profile.psd1 when it exists, replaces empty values,
         validates every value and returns the effective ones.
      3. The derived values: $forestName, $domainDN and the OU paths. Skipped when part
         1b or part 2 found an error.

    It never throws for an override, profile or validation problem. It sets
    $buildProfileSummary, $buildProfileInfo, $buildProfileWarnings and
    $buildProfileError for the scripts to log once logging has started, with the
    override file's lines first. Loading it writes nothing to the output, the console
    or the disk. $globalConfigVersion names this file's release, so each script can
    refuse a global-config.ps1 older than the one it needs.
.EXAMPLE
    . .\global-config.ps1
.NOTES
    Version:      2.1.0
    Author:       Daniel Owen
    Release Date: 2026-11-12
    Requirements: PowerShell 5.1+
#>

#region Deployment Root
# This file lives in <project root>\include\, so the parent of $PSScriptRoot is the project root.
$deployRoot              = Split-Path -Path $PSScriptRoot -Parent
#endregion

#region Version
# Equal to the Version line above. Each script stops when this is missing or older than
# the global-config.ps1 it needs, which catches an older copy of this file put back over
# this one.
$globalConfigVersion     = '2.1.0'
#endregion

#region Part 1: Base Values
# Change a value in overrides\overrides.psd1, not here, so an upgrade keeps it. OVERRIDE.md
# lists every setting. A build profile (include\build-profile.psd1) overrides the first
# seven for one build. Each key is the variable name with a capital first letter, for
# example DomainName overrides $domainName. An empty value here takes the shipped value,
# with a warning.
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
# 14 is the most the domain policy enforces unless "Relax minimum password length limits"
# is enabled on every DC, which needs Windows Server version 2004 or later. Above 14, the
# DC logs event 16979 and enforces 14 anyway.
$minPasswordLength       = 14
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

#region Part 1b: Apply the Override File
# overrides\overrides.psd1 holds the user's standing settings. include\OverrideFile.ps1
# reads it and checks it against include\override-catalog.psd1. A value for one of this
# file's variables replaces the base value above, and a build profile in part 2 still
# wins over it. Values for the scripts' parameters and constants wait in
# $overrideFileValues. Every variable this part adds starts with $overrideFile, so none
# can overwrite a same-named parameter of the script that dot-sources this file. A
# problem is left in $overrideFileError, never thrown.
$overrideFileInfo         = [string[]]@()
$overrideFileWarnings     = [string[]]@()
$overrideFileError        = $null
$overrideFilePairWarnings = [string[]]@()
$overrideFilePairError    = $null
$overrideFileResult       = $null
$overrideFileCatalog      = $null
$overrideFileSources      = @{}
$overrideFileValues       = @{}
$overrideFileCsvPaths     = [ordered]@{}
$overrideFileInfoList     = [System.Collections.Generic.List[string]]::new()
$overrideFileWarningList  = [System.Collections.Generic.List[string]]::new()
$overrideFileErrorList    = [System.Collections.Generic.List[string]]::new()
$overrideFilePairWarnList = [System.Collections.Generic.List[string]]::new()
$overrideFilePairErrList  = [System.Collections.Generic.List[string]]::new()
$overrideFilePath         = Join-Path -Path $deployRoot -ChildPath 'overrides\overrides.psd1'
$overrideFileCsvFolder    = Join-Path -Path $deployRoot -ChildPath 'overrides\config'
$overrideFileReaderPath   = Join-Path -Path $PSScriptRoot -ChildPath 'OverrideFile.ps1'
$overrideFileCatalogPath  = Join-Path -Path $PSScriptRoot -ChildPath 'override-catalog.psd1'
$overrideFileReleaseTablePath = Join-Path -Path $PSScriptRoot -ChildPath 'release-values.psd1'
$overrideFileSetKeys      = [string[]]@()
$overrideFileLabel        = "Override file '$overrideFilePath'"
$overrideFileCsvNames     = @('first.csv', 'last.csv', 'words.csv', 'departments.csv', 'titles.csv', 'offices.csv', 'cities.csv', 'companies.csv', 'streets.csv', 'computers.csv', 'serviceaccounts.csv')

$overrideFileReaderLoaded  = $false
$overrideFileReaderProblem = "OverrideFile.ps1 not found at '$overrideFileReaderPath'"
if (Test-Path -LiteralPath $overrideFileReaderPath -PathType Leaf) {
    try {
        . $overrideFileReaderPath
        $overrideFileReaderLoaded = $true
    } catch {
        $overrideFileReaderProblem = "OverrideFile.ps1 at '$overrideFileReaderPath' failed to load"
    }
}

if (-not $overrideFileReaderLoaded) {
    # With no override file the shipped values are what a run would use anyway, so a
    # missing reader is a WARN. With one, the user's settings can't be applied.
    if (Test-Path -LiteralPath $overrideFilePath) {
        $overrideFileErrorList.Add("$overrideFileReaderProblem, so the override file '$overrideFilePath' can't be applied. Restore include\OverrideFile.ps1 from the new-AdDomain repository.")
    } else {
        $overrideFileWarningList.Add("$overrideFileReaderProblem. There is no override file, so the shipped settings apply. Restore include\OverrideFile.ps1 from the new-AdDomain repository.")
    }
} else {
    try {
        $overrideFileResult = Get-OverrideFile -Path $overrideFilePath -CatalogPath $overrideFileCatalogPath
        foreach ($overrideFileLine in @($overrideFileResult.Info)) { $overrideFileInfoList.Add($overrideFileLine) }
        foreach ($overrideFileLine in @($overrideFileResult.Warnings)) { $overrideFileWarningList.Add($overrideFileLine) }
        if ($overrideFileResult.Error) {
            foreach ($overrideFileLine in ($overrideFileResult.Error -split '\r?\n')) { $overrideFileErrorList.Add($overrideFileLine) }
        }
        $overrideFileCatalog = Read-OverrideCatalog -CatalogPath $overrideFileCatalogPath
        if ($overrideFileCatalog.Error) { $overrideFileCatalog = $null }
        if ($overrideFileResult.Found -and -not $overrideFileResult.Error -and $null -ne $overrideFileCatalog) {
            foreach ($overrideFileKey in @($overrideFileResult.Values.get_Keys() | Sort-Object)) {
                $overrideFileEntry = $overrideFileCatalog.Settings[$overrideFileKey]
                if ($overrideFileEntry.Target -ceq 'Variable') {
                    Set-Variable -Name $overrideFileEntry.Name -Value $overrideFileResult.Values[$overrideFileKey]
                    $overrideFileSources[$overrideFileKey] = $overrideFileLabel
                } else {
                    $overrideFileValues[$overrideFileKey] = $overrideFileResult.Values[$overrideFileKey]
                }
            }
        }
    } catch {
        $overrideFileErrorList.Add("$($overrideFileLabel): the override file couldn't be applied ($($_.Exception.GetType().FullName)), so the run stops before any change. Check the file against OVERRIDE.md.")
    }
}

# 14 is the most the domain enforces unless "Relax minimum password length limits" is
# enabled on every DC, so a longer minimum builds with 14 and says so. Above 128 is more
# than Windows allows even with that setting, so it stops, as the override file's own
# check does for the same value.
if (($minPasswordLength -is [int] -or $minPasswordLength -is [long]) -and $minPasswordLength -ge 15 -and $minPasswordLength -le 128) {
    $overrideFileMinLengthName = if ($overrideFileSources.ContainsKey('MinPasswordLength')) { "$($overrideFileLabel): MinPasswordLength" } else { 'global-config.ps1: $minPasswordLength' }
    $overrideFileWarningList.Add("$overrideFileMinLengthName $minPasswordLength is above 14, the most the domain enforces unless Relax minimum password length limits is enabled on every DC; using 14.")
    Set-Variable -Name 'minPasswordLength' -Value 14
} elseif (($minPasswordLength -is [int] -or $minPasswordLength -is [long]) -and $minPasswordLength -gt 128) {
    $overrideFileErrorList.Add('global-config.ps1: $minPasswordLength isn''t valid. It must be a whole number from 0 to 128, and above 14 the build uses 14.')
}

# Each CSV is read from overrides\config when a file of that name is there.
foreach ($overrideFileCsvName in $overrideFileCsvNames) {
    $overrideFileCsvReplacement = Join-Path -Path $overrideFileCsvFolder -ChildPath $overrideFileCsvName
    if (Test-Path -LiteralPath $overrideFileCsvReplacement -PathType Leaf) {
        $overrideFileCsvPaths[$overrideFileCsvName] = $overrideFileCsvReplacement
        $overrideFileCsvHash = 'unreadable'
        try { $overrideFileCsvHash = (Get-FileHash -LiteralPath $overrideFileCsvReplacement -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $overrideFileCsvHash = 'unreadable' }
        $overrideFileInfoList.Add("Override CSV '$overrideFileCsvReplacement' (SHA-256 $overrideFileCsvHash): replaces config\$overrideFileCsvName.")
    } else {
        $overrideFileCsvPaths[$overrideFileCsvName] = Join-Path -Path $csvPath -ChildPath $overrideFileCsvName
    }
}
if (Test-Path -LiteralPath $overrideFileCsvFolder -PathType Container) {
    try {
        foreach ($overrideFileCsvItem in @(Get-ChildItem -LiteralPath $overrideFileCsvFolder -File -ErrorAction Stop)) {
            if ($overrideFileCsvNames -notcontains $overrideFileCsvItem.Name) {
                $overrideFileWarningList.Add("Override CSV '$($overrideFileCsvItem.FullName)': $($overrideFileCsvItem.Name) isn't one of the shipped CSV files, so it is ignored. OVERRIDE.md lists the files a replacement can have.")
            }
        }
    } catch {
        $overrideFileWarningList.Add("Override CSV folder '$overrideFileCsvFolder' couldn't be listed ($($_.Exception.GetType().FullName)), so a misnamed file in it wouldn't be reported.")
    }
}
#endregion

#region Part 2: Load and Validate the Build Profile
# Every variable this part adds starts with $buildProfile, so none can overwrite a
# same-named parameter of the script that dot-sources this file.
$buildProfileSummary     = $null
$buildProfileInfo        = [string[]]@()
$buildProfileWarnings    = [string[]]@()
$buildProfileError       = $null
$buildProfileDomainSource = $null
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
    # The five user-state percentages must sum to 100 or less. A shipped one nobody set
    # gives way with a WARN, and only the user's own values clashing stop the run, here
    # before anything is created rather than part way through population.
    $overrideFilePercentValues  = [ordered]@{ PctDisabled = $pctDisabled; PctPwExpired = $pctPwExpired; PctPwNeverExpires = $pctPwNeverExpires; PctSmartcard = $pctSmartcard; PctLocked = $pctLocked }
    $overrideFilePercentSources = @{}
    $overrideFilePercentReady   = $true
    foreach ($overrideFileKey in @($overrideFilePercentValues.get_Keys())) {
        $overrideFileNumber = $overrideFilePercentValues[$overrideFileKey] -as [int]
        if ($null -eq $overrideFileNumber) { $overrideFilePercentReady = $false; continue }
        $overrideFilePercentValues[$overrideFileKey] = $overrideFileNumber
        if ($overrideFileSources.ContainsKey($overrideFileKey)) {
            $overrideFilePercentSources[$overrideFileKey] = $overrideFileLabel
        } elseif ($null -eq $overrideFileCatalog -or [int]$overrideFileCatalog.Settings[$overrideFileKey].Shipped -ne $overrideFileNumber) {
            $overrideFilePercentSources[$overrideFileKey] = 'global-config.ps1'
        }
    }
    if ($overrideFilePercentReady) {
        $overrideFilePercentResult = Resolve-UserStatePercentage -Value $overrideFilePercentValues -Source $overrideFilePercentSources
        if ($overrideFilePercentResult.Error) {
            $overrideFileErrorList.Add($overrideFilePercentResult.Error)
        } elseif ($overrideFilePercentResult.Warning) {
            $overrideFileWarningList.Add($overrideFilePercentResult.Warning)
            foreach ($overrideFileKey in @($overrideFilePercentResult.Values.get_Keys())) {
                Set-Variable -Name ($overrideFileKey.Substring(0, 1).ToLowerInvariant() + $overrideFileKey.Substring(1)) -Value $overrideFilePercentResult.Values[$overrideFileKey]
            }
        }
    }

    # The count pairs are Initialize-ADDirectory.ps1's parameters, which it checks with
    # its command line. This pre-check sees the override file and the shipped values,
    # which is all a logon-task run or build-lab on the host has. Its lines are kept apart
    # from the build profile's, so script two doesn't log them twice.
    if ($null -ne $overrideFileCatalog) {
        foreach ($overrideFilePair in @(@('MinGroupMembers', 'MaxGroupMembers'), @('MinDA', 'MaxDA'))) {
            $overrideFileMinKey = $overrideFilePair[0]
            $overrideFileMaxKey = $overrideFilePair[1]
            if (-not ($overrideFileValues.ContainsKey($overrideFileMinKey) -or $overrideFileValues.ContainsKey($overrideFileMaxKey))) { continue }
            $overrideFilePairArguments = @{ MinKey = $overrideFileMinKey; MaxKey = $overrideFileMaxKey; MinSource = ''; MaxSource = '' }
            foreach ($overrideFileSide in @(@('Min', $overrideFileMinKey), @('Max', $overrideFileMaxKey))) {
                if ($overrideFileValues.ContainsKey($overrideFileSide[1])) {
                    $overrideFilePairArguments["$($overrideFileSide[0])Value"]  = [int]$overrideFileValues[$overrideFileSide[1]]
                    $overrideFilePairArguments["$($overrideFileSide[0])Source"] = $overrideFileLabel
                } else {
                    $overrideFilePairArguments["$($overrideFileSide[0])Value"]  = [int]$overrideFileCatalog.Settings[$overrideFileSide[1]].Shipped
                }
            }
            $overrideFilePairResult = Resolve-MinMaxPair @overrideFilePairArguments
            if ($overrideFilePairResult.Error) { $overrideFilePairErrList.Add($overrideFilePairResult.Error) }
            elseif ($overrideFilePairResult.Warning) { $overrideFilePairWarnList.Add($overrideFilePairResult.Warning) }
        }
    }

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
    if ($overrideFileSources.get_Count() -gt 0) {
        $buildProfileArguments['FileSources'] = $overrideFileSources
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
        $buildProfileDomainSource = $buildProfileResult.DomainNameSource
    }
}

# The keys whose value this run took from the override file or the build profile, so a
# changed shipped default isn't reported for them. A script adds its command line's.
$overrideFileSetKeyList = [System.Collections.Generic.List[string]]::new()
if ($null -ne $overrideFileResult -and -not $overrideFileResult.Error) {
    foreach ($overrideFileKey in @($overrideFileResult.Values.get_Keys())) { $overrideFileSetKeyList.Add([string]$overrideFileKey) }
}
if ((Get-Variable -Name 'buildProfileResult' -ErrorAction SilentlyContinue) -and $null -ne $buildProfileResult -and ($buildProfileResult.PSObject.Properties.Name -contains 'ProfileKeys')) {
    foreach ($overrideFileKey in @($buildProfileResult.ProfileKeys)) { if ($overrideFileSetKeyList -notcontains $overrideFileKey) { $overrideFileSetKeyList.Add([string]$overrideFileKey) } }
}
$overrideFileSetKeys = [string[]]$overrideFileSetKeyList.ToArray()

# The override file's lines go first, so each script logs them with the build profile's
# and stops on either's error with no change of its own.
$overrideFileInfo         = [string[]]$overrideFileInfoList.ToArray()
$overrideFileWarnings     = [string[]]$overrideFileWarningList.ToArray()
$overrideFilePairWarnings = [string[]]$overrideFilePairWarnList.ToArray()
if ($overrideFileErrorList.Count -gt 0) { $overrideFileError = $overrideFileErrorList -join [Environment]::NewLine }
if ($overrideFilePairErrList.Count -gt 0) { $overrideFilePairError = $overrideFilePairErrList -join [Environment]::NewLine }
$buildProfileInfo         = [string[]](@($overrideFileInfo) + @($buildProfileInfo))
$buildProfileWarnings     = [string[]](@($overrideFileWarnings) + @($buildProfileWarnings))
if ($overrideFileError) {
    if ($buildProfileError) { $buildProfileError = $overrideFileError + [Environment]::NewLine + $buildProfileError }
    else { $buildProfileError = $overrideFileError }
}
#endregion

#region Part 3: Derived Values
# Skipped when part 1b or part 2 found an error. Both scripts log that error and stop,
# and their log paths come from $deployRoot, not from the domain.
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
