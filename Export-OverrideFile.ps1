<#
.SYNOPSIS
    Moves the settings you changed in an older copy of new-AdDomain into an override
    file, overrides\overrides.psd1, that upgrades leave alone.
.DESCRIPTION
    Reads an older new-AdDomain folder without running any of it: include\global-config.ps1,
    Initialize-ADDirectory.ps1 and New-ADForestDeployment.ps1 are parsed, and each value
    is read only when it is a constant. The CSV files in its config folder are compared
    by their text, so a change of line endings alone isn't an edit.

    Each setting in this release's include\override-catalog.psd1 is compared with the
    value the old copy's release shipped, taken from include\release-values.psd1 (or from
    a clean copy of that release, with -ReferencePath). The release is the one whose
    script headers carry the old copy's Version line. When no release matches, or more
    than one does, every release counts, and a value equal to any of them is unchanged.

    For each setting:
      - unchanged: not written
      - changed by you: written
      - a shipped default that has changed since your release, which you never edited:
        reported, and written only with -KeepPreviousDefaults
      - not a constant (built from other values): not written, with a WARN to set it by
        hand
      - a value this release refuses, or can't check: written commented out, with the
        reason and a WARN, so the file still loads
    A CSV you edited is copied to overrides\config. An SPN in it that names a host
    outside the domain is reported with the {DomainName} form to use.

    Nothing already in overrides\ is overwritten. When overrides.psd1, or a CSV this run
    would write, is already there, the whole output goes to a new folder,
    overrides\migrated-<yyyyMMdd-HHmmss>, which no script reads, with a WARN for each
    file in the way. Merge it by hand. The file it writes is read back with the same
    checks the scripts use, and a problem there stops the run.

    Intake answers for this script:
      - CSV run log: on, every level, one file per run in -LogPath, kept and never pruned
      - Windows event logging: none
      - Strict mode: on
      - Write mode and scope cap: no directory writes. It writes one data file and copies
        CSVs, behind -WhatIf and -Confirm
      - Retry: none
      - Shared code: include\OverrideFile.ps1, include\Logging.ps1 and
        include\Sanitization.ps1, copies of shared files, and include\BuildProfile.ps1
      - Credentials: none. A secret setting such as DsrmPassword is written to the
        override file, and never to the log or the console
.PARAMETER SourcePath
    The older new-AdDomain folder to read, for example ..\new-AdDomain-old. It is only
    read. It may be this folder, for settings you edited in this release's own files.
.PARAMETER ReferencePath
    Optional. A clean, unedited copy of the release the old folder came from. Its values
    are used in place of include\release-values.psd1.
.PARAMETER KeepPreviousDefaults
    Also write each setting whose shipped default changed since your release and which
    you never edited, so the next build matches the old one.
.PARAMETER LogPath
    The folder for the run log. Defaults to the logs folder beside this script.
.EXAMPLE
    .\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old
.EXAMPLE
    .\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old -KeepPreviousDefaults -WhatIf
.OUTPUTS
    None on the pipeline. overrides\overrides.psd1 and overrides\config\<name>.csv, or
    the same under overrides\migrated-<yyyyMMdd-HHmmss>. Console lines, and the run log
    Export-OverrideFile_<yyyyMMdd-HHmmss>.csv in -LogPath, one row per setting. Exit code
    0 on success or after -WhatIf, 1 when the run stops.
.NOTES
    Version: 2.1.0
    Author: Daniel Owen
    Release Date: 2026-11-12
    Requirements: Windows PowerShell 5.1. The include folder beside this script, with
        OverrideFile.ps1, Logging.ps1, Sanitization.ps1, BuildProfile.ps1,
        override-catalog.psd1 and release-values.psd1. Run logs are kept, never pruned.
    Target Set Source: the old folder's scripts and config\*.csv, against
        include\override-catalog.psd1
    Event Log Source: N/A
    Setup: N/A
#>

#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The summary and next step are console output for the person running the migration.')]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [string]$ReferencePath,

    [switch]$KeepPreviousDefaults,

    [string]$LogPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

#region Include
# Sanitization.ps1 loads before Logging.ps1, which calls it for every CSV row.
foreach ($includeFileName in @('Sanitization.ps1', 'Logging.ps1', 'OverrideFile.ps1', 'BuildProfile.ps1')) {
    $includeFilePath = Join-Path -Path $PSScriptRoot -ChildPath "include\$includeFileName"
    if (-not (Test-Path -LiteralPath $includeFilePath -PathType Leaf)) {
        throw ('Required include file not found: {0}. Restore the include folder from the new-AdDomain repository.' -f $includeFilePath)
    }
    . $includeFilePath
}
#endregion Include

#region Functions

function Write-MigrationLog {
    # One log row, written in a -WhatIf run too, since logging changes nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG', 'FATAL')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    Write-Log -Message $Message -Level $Level -Context $Context
}

function Get-TreeSetting {
    # The settings of one new-AdDomain folder, read by parsing: each catalog key's value
    # from the script that holds it (a Variable from global-config.ps1, a Parameter from
    # Initialize-ADDirectory.ps1, a Constant from New-ADForestDeployment.ps1), the header
    # version, and each config\*.csv's hash. A key the folder doesn't hold is left out.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TreePath,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$CatalogSettings
    )
    $scriptPaths = @{
        Variable  = Join-Path -Path $TreePath -ChildPath 'include\global-config.ps1'
        Parameter = Join-Path -Path $TreePath -ChildPath 'Initialize-ADDirectory.ps1'
        Constant  = Join-Path -Path $TreePath -ChildPath 'New-ADForestDeployment.ps1'
    }
    $readings = @{}
    $problems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($targetName in @($scriptPaths.get_Keys())) {
        if (Test-Path -LiteralPath $scriptPaths[$targetName] -PathType Leaf) {
            $reading = Read-ScriptSetting -Path $scriptPaths[$targetName]
            if ($reading.Error) { $problems.Add($reading.Error) } else { $readings[$targetName] = $reading }
        }
    }
    $settings = @{}
    foreach ($keyName in @($CatalogSettings.get_Keys())) {
        $entry = $CatalogSettings[$keyName]
        if (-not $readings.ContainsKey($entry.Target)) { continue }
        $reading = $readings[$entry.Target]
        $candidates = if ($entry.Target -ceq 'Parameter') { @($reading.Parameters) } else { @($reading.Assignments) }
        $matching = @($candidates | Where-Object { $null -ne $_ -and [string]::Equals($_.Name, $entry.Name, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($matching.Count -gt 0) { $settings[$keyName] = $matching[$matching.Count - 1] }
    }
    $csvHashes = @{}
    $csvFiles  = @{}
    $configFolder = Join-Path -Path $TreePath -ChildPath 'config'
    if (Test-Path -LiteralPath $configFolder -PathType Container) {
        foreach ($csvFile in @(Get-ChildItem -LiteralPath $configFolder -Filter '*.csv' -File)) {
            $csvHash = Get-OverrideCsvHash -Bytes ([System.IO.File]::ReadAllBytes($csvFile.FullName))
            $csvHashes[$csvFile.Name] = $csvHash.Sha256
            $csvFiles[$csvFile.Name]  = $csvFile.FullName
        }
    }
    $version = $null
    if ($readings.ContainsKey('Variable')) { $version = $readings['Variable'].Version }
    $topNames = @()
    if ($readings.ContainsKey('Variable')) { $topNames = @($readings['Variable'].Assignments) }
    return [pscustomobject]@{
        Settings    = $settings
        Csv         = $csvHashes
        CsvFiles    = $csvFiles
        Version     = $version
        Assignments = $topNames
        Problems    = [string[]]$problems.ToArray()
    }
}

function ConvertFrom-TreeSetting {
    # A folder's settings in the release table's terms: Constant, Expression, NoDefault
    # or, for a secret, Sha256 of its text.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Setting,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$CatalogSettings
    )
    $converted = @{}
    foreach ($keyName in @($Setting.get_Keys())) {
        $treeValue = $Setting[$keyName]
        switch ([string]$treeValue.State) {
            'Value' {
                if ($CatalogSettings[$keyName].Secret) { $converted[$keyName] = @{ Sha256 = (Get-TextSha256 -Text ([string]$treeValue.Value)) } }
                else { $converted[$keyName] = @{ Constant = $treeValue.Value } }
            }
            'NoDefault' { $converted[$keyName] = @{ NoDefault = $true } }
            'Dynamic' {
                if (($treeValue.PSObject.Properties.Name -contains 'SourceText') -and $treeValue.SourceText) { $converted[$keyName] = @{ Expression = [string]$treeValue.SourceText } }
            }
        }
    }
    return $converted
}

function Get-TextSha256 {
    # The SHA-256 of a text's UTF-8 bytes, as 64 lower-case hex digits.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hashAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $hashAlgorithm.Dispose()
    }
}

function Test-ShippedMatch {
    # Whether an old value equals a release's shipped value for one key, in any of the
    # release table's forms.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$OldSetting,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Shipped
    )
    switch ([string]$OldSetting.State) {
        'Value' {
            if ($Shipped.Contains('Constant')) { return (Test-OverrideValueEqual -First $OldSetting.Value -Second $Shipped['Constant']) }
            if ($Shipped.Contains('Sha256')) { return ((Get-TextSha256 -Text ([string]$OldSetting.Value)) -ceq [string]$Shipped['Sha256']) }
            return $false
        }
        'NoDefault' { return $Shipped.Contains('NoDefault') }
        'Dynamic' {
            $sourceText = $null
            if ($OldSetting.PSObject.Properties.Name -contains 'SourceText') { $sourceText = $OldSetting.SourceText }
            return ($Shipped.Contains('Expression') -and $sourceText -and [string]::Equals([string]$sourceText, [string]$Shipped['Expression'], [System.StringComparison]::Ordinal))
        }
    }
    return $false
}

function ConvertTo-MigrationLiteral {
    # A value as PowerShell data file text: a string in single quotes, escaped by
    # PowerShell's own CodeGeneration API, which also doubles the curly single quotes
    # PowerShell reads as quote marks, a whole number, $true, $false, or a list of
    # those. $null for anything else.
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [System.Collections.IDictionary]) { return $null }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [string]) { return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value) + "'" }
    if ($Value -is [System.Array]) {
        $itemTexts = foreach ($item in $Value) {
            if ($item -is [System.Array]) { return $null }
            $itemText = ConvertTo-MigrationLiteral -Value $item
            if ($null -eq $itemText) { return $null }
            $itemText
        }
        return '@(' + (@($itemTexts) -join ', ') + ')'
    }
    foreach ($numberType in @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])) {
        if ($Value -is $numberType) { return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    return $null
}

function Get-ValueCheck {
    # Checks a value to write with this release's own rules: a catalog rule, Get-BuildProfile's
    # check for a profile key, and for a parameter its own attributes, read from the script
    # beside this one. Returns State (Valid, Refused or Uncheckable) and Reason.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][object]$CatalogEntry,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$ParameterScriptPath
    )
    if ($null -ne $CatalogEntry.Rule) {
        if ([string]$CatalogEntry.Rule['Type'] -ceq 'External') {
            $profileCheck = ConvertTo-BuildProfileSetting -Key $Key -Value $Value
            if (-not $profileCheck.Valid) { return [pscustomobject]@{ State = 'Refused'; Reason = "this release refuses it: $Key $($profileCheck.Problem)" } }
        } else {
            $ruleCheck = Test-OverrideRuleValue -Rule $CatalogEntry.Rule -Value $Value
            if (-not $ruleCheck.Valid) { return [pscustomobject]@{ State = 'Refused'; Reason = "this release refuses it. It must be $((Get-OverrideRuleText -Rule $CatalogEntry.Rule).TrimEnd('.'))." } }
        }
    }
    if ($CatalogEntry.Target -ceq 'Parameter') {
        $parameterCheck = Test-ParameterValueByAst -ScriptPath $ParameterScriptPath -ParameterName $CatalogEntry.Name -Value $Value
        if ($parameterCheck.State -ceq 'Refused') { return [pscustomobject]@{ State = 'Refused'; Reason = "the parameter's $($parameterCheck.Attribute) refuses it: $($parameterCheck.Reason)" } }
        if ($parameterCheck.State -ceq 'Uncheckable') { return [pscustomobject]@{ State = 'Uncheckable'; Reason = "it can't be checked: $($parameterCheck.Reason)" } }
    }
    return [pscustomobject]@{ State = 'Valid'; Reason = $null }
}

function Write-MigrationFile {
    # Writes the override file as UTF-8 with a byte order mark, or copies a CSV, behind
    # -WhatIf and -Confirm. Returns $true when it wrote.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Text,
        [string]$CopyFrom
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write the migrated file')) { return $false }
    $null = New-Item -ItemType Directory -Path (Split-Path -Path $Path -Parent) -Force
    if ($CopyFrom) { Copy-Item -LiteralPath $CopyFrom -Destination $Path -Force }
    else { [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true))) }
    return $true
}

#endregion Functions

#region Variables

$scriptName = 'Export-OverrideFile.ps1'
$scriptVersion = '2.1.0'
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $LogPath) { $LogPath = Join-Path -Path $PSScriptRoot -ChildPath 'logs' }
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
$logFilePath = Join-Path -Path $LogPath -ChildPath ('Export-OverrideFile_{0}.csv' -f $runStamp)
$csvLevels = [string[]]@('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG', 'FATAL')
$catalogPath = Join-Path -Path $PSScriptRoot -ChildPath 'include\override-catalog.psd1'
$releaseTablePath = Join-Path -Path $PSScriptRoot -ChildPath 'include\release-values.psd1'
$overridesPath = Join-Path -Path $PSScriptRoot -ChildPath 'overrides'
$parameterScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Initialize-ADDirectory.ps1'
$runOutcome = 'stopped'
$exitCode = 1

#endregion Variables

#region Main

$logContext = $null
try {
    $WhatIfPreferenceSaved = $WhatIfPreference
    $WhatIfPreference = $false
    $null = New-Item -ItemType Directory -Path $LogPath -Force
    $logContext = New-LogContext -ScriptName $scriptName -CsvLogPath $logFilePath -CsvLevels $csvLevels
    $WhatIfPreference = $WhatIfPreferenceSaved
    Write-MigrationLog -Context $logContext -Level INFO -Message ('Run start | {0} {1} | source {2}, reference {3}, KeepPreviousDefaults {4}, WhatIf {5}' -f $scriptName, $scriptVersion, $SourcePath, $(if ($ReferencePath) { $ReferencePath } else { 'none' }), [bool]$KeepPreviousDefaults, [bool]$WhatIfPreference)

    #region Read
    $sourceFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath).TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path -Path $sourceFullPath -ChildPath 'include\global-config.ps1') -PathType Leaf)) {
        throw ('-SourcePath {0} holds no include\global-config.ps1, so it is not a new-AdDomain folder. Pass the folder of your older copy.' -f $sourceFullPath)
    }
    $catalog = Read-OverrideCatalog -CatalogPath $catalogPath
    if ($catalog.Error) { throw ('This release''s catalog {0} failed its check: {1}' -f $catalogPath, ($catalog.Error -replace '\r?\n', ' ')) }
    $oldTree = Get-TreeSetting -TreePath $sourceFullPath -CatalogSettings $catalog.Settings
    foreach ($problem in $oldTree.Problems) { Write-MigrationLog -Context $logContext -Level WARN -Message "Read | $problem | the settings in that script are not migrated" }
    $currentTree = Get-TreeSetting -TreePath $PSScriptRoot -CatalogSettings $catalog.Settings
    $currentShipped = ConvertFrom-TreeSetting -Setting $currentTree.Settings -CatalogSettings $catalog.Settings
    Write-MigrationLog -Context $logContext -Level INFO -Message ('Read | {0} | header Version {1}, {2} settings found, {3} CSV files' -f $sourceFullPath, $(if ($oldTree.Version) { $oldTree.Version } else { 'none' }), $oldTree.Settings.get_Count(), $oldTree.Csv.get_Count())
    #endregion Read

    #region The release the old copy came from
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    if ($ReferencePath) {
        $referenceFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReferencePath).TrimEnd('\')
        if (-not (Test-Path -LiteralPath (Join-Path -Path $referenceFullPath -ChildPath 'include\global-config.ps1') -PathType Leaf)) {
            throw ('-ReferencePath {0} holds no include\global-config.ps1. Pass a clean copy of your release.' -f $referenceFullPath)
        }
        $referenceTree = Get-TreeSetting -TreePath $referenceFullPath -CatalogSettings $catalog.Settings
        $candidates.Add([pscustomobject]@{ Name = "the clean copy at $referenceFullPath"; Settings = (ConvertFrom-TreeSetting -Setting $referenceTree.Settings -CatalogSettings $catalog.Settings); Csv = $referenceTree.Csv })
        Write-MigrationLog -Context $logContext -Level INFO -Message "Release | $referenceFullPath | compared with the clean copy, not the release table"
    } else {
        if (-not (Test-Path -LiteralPath $releaseTablePath -PathType Leaf)) { throw ('The release table {0} is missing. Restore it from the new-AdDomain repository.' -f $releaseTablePath) }
        $releaseTable = Import-PowerShellDataFile -LiteralPath $releaseTablePath
        $releases = $releaseTable['Releases']
        $releaseNames = @($releases.get_Keys() | Sort-Object { [version]$_ })
        $matchingNames = @($releaseNames | Where-Object { $oldTree.Version -and [string]$releases[$_]['HeaderVersion'] -ceq $oldTree.Version })
        if ($matchingNames.Count -eq 1) {
            Write-MigrationLog -Context $logContext -Level INFO -Message "Release | $($matchingNames[0]) | identified from the header Version $($oldTree.Version)"
        } else {
            $why = if ($matchingNames.Count -gt 1) { "the header Version $($oldTree.Version) fits $($matchingNames.Count) releases" } elseif ($oldTree.Version) { "no release has the header Version $($oldTree.Version)" } else { 'the old global-config.ps1 has no Version line' }
            Write-MigrationLog -Context $logContext -Level INFO -Message "Release | $($releaseNames -join ', ') | $why, so every release counts and a value equal to any of them is unchanged"
            if ($matchingNames.Count -eq 0) { $matchingNames = $releaseNames }
        }
        foreach ($releaseName in $matchingNames) {
            $candidates.Add([pscustomobject]@{ Name = "release $releaseName"; Settings = $releases[$releaseName]['Settings']; Csv = $releases[$releaseName]['Csv'] })
        }
    }
    #endregion

    #region Each setting
    $outputLines  = New-Object 'System.Collections.Generic.List[string]'
    $summary      = [ordered]@{ Written = 0; Unchanged = 0; ChangedDefault = 0; Dynamic = 0; CommentedOut = 0; CsvCopied = 0 }
    $writtenValues = @{}
    foreach ($keyName in @($catalog.Settings.get_Keys() | Sort-Object)) {
        $entry = $catalog.Settings[$keyName]
        if (-not $oldTree.Settings.ContainsKey($keyName)) { continue }
        $oldSetting = $oldTree.Settings[$keyName]
        $oldText = if ($oldSetting.State -ceq 'Value') { ConvertTo-OverrideDisplayText -Value $oldSetting.Value -Secret:$entry.Secret } else { "<$($oldSetting.State)>" }
        $sourceFile = switch ([string]$entry.Target) { 'Variable' { 'include\global-config.ps1' } 'Parameter' { 'Initialize-ADDirectory.ps1' } default { 'New-ADForestDeployment.ps1' } }
        $currentText = '<none>'
        if ($currentTree.Settings.ContainsKey($keyName) -and $currentTree.Settings[$keyName].State -ceq 'Value') { $currentText = ConvertTo-OverrideDisplayText -Value $currentTree.Settings[$keyName].Value -Secret:$entry.Secret }

        # A key no candidate release holds wasn't in that release, so a value for it in the
        # old copy is yours.
        $matchedRelease = $null
        $candidatesWithKey = @($candidates | Where-Object { $_.Settings.Contains($keyName) })
        foreach ($candidate in $candidatesWithKey) {
            if (Test-ShippedMatch -OldSetting $oldSetting -Shipped $candidate.Settings[$keyName]) { $matchedRelease = $candidate; break }
        }

        $action = $null
        $reason = $null
        $writeIt = $false
        if ($null -ne $matchedRelease) {
            $sameAsNow = $currentShipped.ContainsKey($keyName) -and (Test-ShippedMatch -OldSetting $oldSetting -Shipped $currentShipped[$keyName])
            if ($sameAsNow) {
                $summary['Unchanged']++
                Write-MigrationLog -Context $logContext -Level INFO -Message "Setting $keyName | old $oldText | shipped $oldText | unchanged | equals $($matchedRelease.Name)"
                continue
            }
            $summary['ChangedDefault']++
            if ($KeepPreviousDefaults) {
                $writeIt = $true
                $action  = 'written, a previous default kept'
                $reason  = "you never changed it, and its shipped default changed since $($matchedRelease.Name). Kept with -KeepPreviousDefaults"
            } else {
                Write-MigrationLog -Context $logContext -Level INFO -Message "Setting $keyName | old $oldText | shipped now $currentText | changed default, not written | you never changed it, and its shipped default changed since $($matchedRelease.Name). Run with -KeepPreviousDefaults to keep $oldText"
                continue
            }
        } elseif ($oldSetting.State -cne 'Value') {
            $summary['Dynamic']++
            Write-MigrationLog -Context $logContext -Level WARN -Message "Setting $keyName | old $oldText at $sourceFile line $($oldSetting.Line) | shipped $currentText | not written | it isn't a constant, so it can't be read without running the file. Set $keyName in overrides\overrides.psd1 by hand if you need it"
            continue
        } else {
            $writeIt = $true
            $action  = 'written'
        }

        if ($writeIt) {
            $literal = ConvertTo-MigrationLiteral -Value $oldSetting.Value
            $check = if ($null -eq $literal) { [pscustomobject]@{ State = 'Uncheckable'; Reason = 'it isn''t a string, a whole number, $true, $false or a list of those' } } else { Get-ValueCheck -Key $keyName -CatalogEntry $entry -Value $oldSetting.Value -ParameterScriptPath $parameterScriptPath }
            $comment = "From $sourceFile line $($oldSetting.Line)"
            if ($candidatesWithKey.Count -gt 0) { $comment += ", shipped in $(@($candidates | ForEach-Object { $_.Name }) -join ' or ')" }
            if ($check.State -ceq 'Valid') {
                $outputLines.Add("    # $($comment -replace '[\r\n]+', ' ').")
                $outputLines.Add("    $keyName = $literal")
                $writtenValues[$keyName] = $oldSetting.Value
                $summary['Written']++
                Write-MigrationLog -Context $logContext -Level INFO -Message "Setting $keyName | old $oldText | shipped $currentText | $action | $(if ($reason) { $reason } else { 'you changed it' })"
            } else {
                # Every physical line of a refused value is a comment, so a value that spans
                # lines can't leave text active. PowerShell ends a line at CRLF, at LF and
                # at a lone CR, so the value is split at all three. The comment and the
                # reason are kept to one line.
                $outputLines.Add("    # $($comment -replace '[\r\n]+', ' '). Not active: $($check.Reason -replace '[\r\n]+', ' ')")
                $commentedText = if ($null -ne $literal) { "$keyName = $literal" } else { "$keyName = <not a constant this file can hold>" }
                foreach ($commentedLine in ($commentedText -split '\r\n|\r|\n')) { $outputLines.Add("    # $commentedLine") }
                $summary['CommentedOut']++
                Write-MigrationLog -Context $logContext -Level WARN -Message "Setting $keyName | old $oldText | shipped $currentText | written commented out | $($check.Reason) Fix it in the file, then remove the # to use it"
            }
        }
    }

    # Old top-level settings that aren't override keys.
    $currentTopNames = @($currentTree.Assignments | ForEach-Object { $_.Name })
    $catalogNames = @($catalog.Settings.get_Values() | ForEach-Object { $_.Name })
    foreach ($oldAssignment in @($oldTree.Assignments | Where-Object { $_.State -ceq 'Value' })) {
        if ($catalogNames -contains $oldAssignment.Name) { continue }
        $currentAssignment = @($currentTree.Assignments | Where-Object { [string]::Equals($_.Name, $oldAssignment.Name, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -Last 1
        if ($currentTopNames -notcontains $oldAssignment.Name) {
            Write-MigrationLog -Context $logContext -Level INFO -Message "Variable `$$($oldAssignment.Name) | old $(ConvertTo-OverrideDisplayText -Value $oldAssignment.Value) | none | not migrated | it isn't a setting in this release. OVERRIDE.md says what replaced it"
        } elseif ($null -ne $currentAssignment -and $currentAssignment.State -ceq 'Value' -and -not (Test-OverrideValueEqual -First $oldAssignment.Value -Second $currentAssignment.Value)) {
            Write-MigrationLog -Context $logContext -Level WARN -Message "Variable `$$($oldAssignment.Name) | old $(ConvertTo-OverrideDisplayText -Value $oldAssignment.Value) | shipped $(ConvertTo-OverrideDisplayText -Value $currentAssignment.Value) | not migrated | it differs from this release's value, and the override file can't set it. OVERRIDE.md lists it under Not covered"
        }
    }
    #endregion

    #region CSVs
    $csvToCopy = [ordered]@{}
    foreach ($csvName in @($oldTree.Csv.get_Keys() | Sort-Object)) {
        $shippedNames = @($currentTree.Csv.get_Keys())
        if ($shippedNames -notcontains $csvName) {
            Write-MigrationLog -Context $logContext -Level WARN -Message "CSV $csvName | old copy | none | not copied | it isn't one of this release's CSV files, so nothing would read it"
            continue
        }
        $oldHash = $oldTree.Csv[$csvName]
        $isUnchanged = @($candidates | Where-Object { $_.Csv -and $_.Csv.Contains($csvName) -and [string]$_.Csv[$csvName] -ceq $oldHash }).Count -gt 0
        if ($isUnchanged) {
            Write-MigrationLog -Context $logContext -Level INFO -Message "CSV $csvName | $oldHash | shipped | unchanged | equals the shipped file, line endings aside"
            continue
        }
        $csvToCopy[$csvName] = $oldTree.CsvFiles[$csvName]
        $summary['CsvCopied']++
        Write-MigrationLog -Context $logContext -Level INFO -Message "CSV $csvName | $oldHash | shipped differs | copied | you changed it. A replaced file no longer gets later shipped changes"
        if ($csvName -ceq 'serviceaccounts.csv') {
            $checkDomain = if ($writtenValues.ContainsKey('DomainName')) { [string]$writtenValues['DomainName'] } elseif ($currentTree.Settings.ContainsKey('DomainName')) { [string]$currentTree.Settings['DomainName'].Value } else { 'lab.test' }
            foreach ($otherDomainRow in @(Test-ServicePrincipalNameDomain -CsvPath $oldTree.CsvFiles[$csvName] -DomainName $checkDomain)) {
                Write-MigrationLog -Context $logContext -Level WARN -Message "CSV serviceaccounts.csv row $($otherDomainRow.RowNumber) | SPN $($otherDomainRow.ServicePrincipalName) | domain $checkDomain | copied as written | it names host $($otherDomainRow.HostName), outside the domain. If it should follow the domain, write it as $($otherDomainRow.SuggestedServicePrincipalName)"
            }
        }
    }
    #endregion

    #region Write
    $activeOverridePath = Join-Path -Path $overridesPath -ChildPath 'overrides.psd1'
    $hasSettings = ($summary['Written'] + $summary['CommentedOut']) -gt 0
    $targetFolder = $overridesPath
    $collisions = New-Object 'System.Collections.Generic.List[string]'
    if ($hasSettings -and (Test-Path -LiteralPath $activeOverridePath)) { $collisions.Add($activeOverridePath) }
    foreach ($csvName in @($csvToCopy.get_Keys())) {
        $activeCsvPath = Join-Path -Path $overridesPath -ChildPath "config\$csvName"
        if (Test-Path -LiteralPath $activeCsvPath) { $collisions.Add($activeCsvPath) }
    }
    if ($collisions.Count -gt 0) {
        $targetFolder = Join-Path -Path $overridesPath -ChildPath "migrated-$runStamp"
        foreach ($collision in $collisions) {
            Write-MigrationLog -Context $logContext -Level WARN -Message "Write | $collision | already there, so nothing under overrides is changed | the whole output goes to $targetFolder instead. Merge it by hand"
        }
    }

    $writtenPaths = New-Object 'System.Collections.Generic.List[string]'
    $overrideFileText = $null
    if ($hasSettings) {
        $fileLines = New-Object 'System.Collections.Generic.List[string]'
        $fileLines.Add("# Written by Export-OverrideFile.ps1 $scriptVersion from $($sourceFullPath -replace '[\r\n]+', ' ') on $(Get-Date -Format 'yyyy-MM-dd').")
        $fileLines.Add('# OVERRIDE.md lists every setting this file can hold.')
        $fileLines.Add('@{')
        foreach ($outputLine in $outputLines) { $fileLines.Add($outputLine) }
        $fileLines.Add('}')
        $overrideFileText = ($fileLines -join "`r`n") + "`r`n"
        # The file is parsed before anything is written, so a file that doesn't parse is
        # never left behind. The text itself is never logged, since it can hold a secret.
        $assembledErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($overrideFileText, [ref]$null, [ref]$assembledErrors)
        if (@($assembledErrors).Count -gt 0) {
            throw ('The override file this run assembled doesn''t parse (line {0}), so nothing was written. This is a defect in Export-OverrideFile.ps1.' -f $assembledErrors[0].Extent.StartLineNumber)
        }
        $targetOverridePath = Join-Path -Path $targetFolder -ChildPath 'overrides.psd1'
        if (Write-MigrationFile -Path $targetOverridePath -Text $overrideFileText) { $writtenPaths.Add($targetOverridePath) }
    }
    foreach ($csvName in @($csvToCopy.get_Keys())) {
        $targetCsvPath = Join-Path -Path $targetFolder -ChildPath "config\$csvName"
        if (Write-MigrationFile -Path $targetCsvPath -CopyFrom $csvToCopy[$csvName]) { $writtenPaths.Add($targetCsvPath) }
    }
    foreach ($writtenPath in $writtenPaths) { Write-MigrationLog -Context $logContext -Level SUCCESS -Message "Write | $writtenPath | written" }
    #endregion

    #region Read back
    $writtenOverridePath = @($writtenPaths | Where-Object { $_ -like '*\overrides.psd1' }) | Select-Object -First 1
    if ($writtenOverridePath) {
        $readBack = Get-OverrideFile -Path $writtenOverridePath -CatalogPath $catalogPath
        if ($readBack.Error) {
            foreach ($readBackLine in ($readBack.Error -split '\r?\n')) { Write-MigrationLog -Context $logContext -Level ERROR -Message "Read back | $writtenOverridePath | $readBackLine" }
            throw ('The file this run wrote, {0}, fails the check the scripts use (errors above). This is a defect in Export-OverrideFile.ps1. Fix the file by hand, or remove it.' -f $writtenOverridePath)
        }
        foreach ($readBackKey in @($readBack.Values.get_Keys())) {
            $readBackEntry = $catalog.Settings[$readBackKey]
            if ($readBackEntry.Target -cne 'Parameter') { continue }
            $parameterCheck = Test-ParameterValueByAst -ScriptPath $parameterScriptPath -ParameterName $readBackEntry.Name -Value $readBack.Values[$readBackKey]
            if ($parameterCheck.State -cne 'Valid') { throw ('The file this run wrote, {0}, holds {1}, which -{2} refuses: {3}' -f $writtenOverridePath, $readBackKey, $readBackEntry.Name, $parameterCheck.Reason) }
        }
        Write-MigrationLog -Context $logContext -Level SUCCESS -Message "Read back | $writtenOverridePath | passes the scripts' check"
    }
    #endregion

    #region Summary
    $whereText = if ($writtenPaths.Count -gt 0) { $targetFolder } elseif ($WhatIfPreference -and ($hasSettings -or $csvToCopy.get_Count() -gt 0)) { "$targetFolder (not written, -WhatIf)" } else { 'nothing written' }
    $summaryText = 'Settings written {0}, unchanged {1}, changed defaults {2}{3}, not constants {4}, written commented out {5}. CSV files copied {6}. Output: {7}.' -f $summary['Written'], $summary['Unchanged'], $summary['ChangedDefault'], $(if ($KeepPreviousDefaults) { ' (kept)' } else { ' (not kept, see -KeepPreviousDefaults)' }), $summary['Dynamic'], $summary['CommentedOut'], $summary['CsvCopied'], $whereText
    Write-MigrationLog -Context $logContext -Level INFO -Message "Summary | $sourceFullPath | $summaryText"
    Write-Host $summaryText
    if ($writtenPaths.Count -gt 0) {
        Write-Host 'Next: put back the shipped files you edited, with git checkout -- <file> in a clone or a fresh copy of the release, so your settings live only in the override file. The run log lists each setting.'
    }
    $runOutcome = 'done'
    $exitCode = 0
    #endregion
}
catch {
    if ($null -ne $logContext) { Write-MigrationLog -Context $logContext -Level FATAL -Message "Run stopped | $SourcePath | $($_.Exception.Message)" }
    else { Write-Host "Export-OverrideFile.ps1 stopped: $($_.Exception.Message)" }
}
finally {
    if ($null -ne $logContext) { Write-MigrationLog -Context $logContext -Level INFO -Message "Run end | $SourcePath | $runOutcome; log $logFilePath" }
}
exit $exitCode

#endregion Main
