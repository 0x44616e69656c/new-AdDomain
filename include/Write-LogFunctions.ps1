<#
.SYNOPSIS
    Shared logging functions for the AD deployment script set.
.DESCRIPTION
    Dot-sourced by New-ADForestDeployment.ps1 and Initialize-ADDirectory.ps1.

    Provides:
      - Initialize-Logging  : call once at script startup to set the log directory,
                              script name, and CSV error log path; creates the log
                              directory if absent.
      - Write-LogInfo/Warn/Error/Success/Debug : write timestamped, color-coded
                              messages to the console (captured by Start-Transcript).
      - Write-LogError and Write-LogWarn also append a structured row to the CSV
                              error log so that failures survive across transcript runs
                              and can be queried without parsing free-form text.
      - Write-BuildProfileResult : logs the build profile results global-config.ps1
                              set (summary, INFO lines, WARN lines, then each error
                              line) and returns $true when there was an error.
      - Test-GlobalConfigVersion : checks the loaded global-config.ps1 is at least the
                              release a script needs, and logs an ERROR when it isn't.
      - Write-OverrideChangedDefault : logs one INFO line per setting whose shipped
                              default changed since the previous release, when this
                              run left it at that default.

    Write-CsvLogEntry is an internal helper and should not be called directly by
    consuming scripts. The CSV is written as UTF-8 with a byte order mark on both
    Windows PowerShell 5.1 and PowerShell 7.
.EXAMPLE
    . .\Write-LogFunctions.ps1
    Initialize-Logging -LogPathParam $logPath -ScriptNameParam "New-ADForestDeployment.ps1" -CsvLogPathParam $csvErrorLogPath
    Write-LogInfo "Starting deployment."
.NOTES
    Version:      2.1.0
    Author:       Daniel Owen
    Release Date: 2026-11-12
    Requirements: PowerShell 5.1+
#>

#region Module-Level Logging State
# Set by Initialize-Logging. Nil-checked before every CSV write so that the
# log functions degrade gracefully if called before initialization.
$script:csvLogPath    = $null
$script:logScriptName = $null
#endregion

#region Logging Initializer
function Initialize-Logging {
    <#
    .SYNOPSIS
        Initializes the logging subsystem for a script run.
    .DESCRIPTION
        Creates the log directory if absent, then stores the CSV error log path
        and script name in module-level state used by Write-LogError and
        Write-LogWarn. Must be called before Start-Transcript so the log
        directory exists when the transcript file is created.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPathParam,
        [Parameter(Mandatory)][string]$ScriptNameParam,
        [Parameter(Mandatory)][string]$CsvLogPathParam
    )
    $null = New-Item -ItemType Directory -Path $LogPathParam -Force
    $script:logScriptName = $ScriptNameParam
    $script:csvLogPath    = $CsvLogPathParam
}
#endregion

#region CSV Log Writer
function Write-CsvLogEntry {
    param(
        [string]$Level,
        [string]$Message
    )
    if ($null -eq $script:csvLogPath) { return }
    # Windows PowerShell 5.1 writes ASCII by default, which turns every non-ASCII
    # character into '?'. 'UTF8' there and 'utf8BOM' on PowerShell 6 and later both
    # write UTF-8 with a byte order mark.
    $csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    try {
        [pscustomobject]@{
            Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Level      = $Level
            Script     = $script:logScriptName
            Message    = $Message
        } | Export-Csv -Path $script:csvLogPath -Append -NoTypeInformation -Encoding $csvEncoding
    } catch {
        # Log directory or path problem -- write a warning to screen but do not
        # throw, as a CSV write failure must never abort the main operation.
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN]    CSV log write failed: $_" -ForegroundColor Yellow
    }
}
#endregion

#region Logging Functions
function Write-LogInfo {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO]    $Message"
}

function Write-LogWarn {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN]    $Message" -ForegroundColor Yellow
    Write-CsvLogEntry -Level 'WARN' -Message $Message
}

function Write-LogError {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR]   $Message" -ForegroundColor Red
    Write-CsvLogEntry -Level 'ERROR' -Message $Message
}

function Write-LogSuccess {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [SUCCESS] $Message" -ForegroundColor Green
}

function Write-LogDebug {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [DEBUG]   $Message" -ForegroundColor Cyan
}
#endregion

#region Build Profile Results
function Write-BuildProfileResult {
    <#
    .SYNOPSIS
        Logs the build profile results that global-config.ps1 set, in order.
    .DESCRIPTION
        The summary as INFO (when set), each INFO line, each warning as WARN, then each
        line of the error as ERROR, so every logged line starts with its timestamp and
        its source. Returns $true when there was an error, so the caller can stop.
    #>
    param(
        [AllowNull()][string]$SummaryParam,
        [AllowNull()][string[]]$InfoParam,
        [AllowNull()][string[]]$WarningsParam,
        [AllowNull()][string]$ErrorParam
    )
    if ($SummaryParam) { Write-LogInfo $SummaryParam }
    foreach ($infoLine in @($InfoParam)) { if ($infoLine) { Write-LogInfo $infoLine } }
    foreach ($warningLine in @($WarningsParam)) { if ($warningLine) { Write-LogWarn $warningLine } }
    if ($ErrorParam) {
        foreach ($errorLine in ($ErrorParam -split '\r?\n')) { if ($errorLine) { Write-LogError $errorLine } }
        return $true
    }
    return $false
}
#endregion

#region Global Config Version
function Test-GlobalConfigVersion {
    <#
    .SYNOPSIS
        Checks that the loaded global-config.ps1 is at least the release a script needs.
    .DESCRIPTION
        An older global-config.ps1 put back over this release's has no
        $globalConfigVersion, or a lower one, and would run this release's scripts
        without the override file. Versions compare as [version], so a newer
        global-config.ps1, as between releases, passes. Logs one ERROR naming both
        versions and returns $false when the check fails, and returns $true otherwise.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$FoundVersionParam,
        [Parameter(Mandatory)][string]$RequiredVersionParam,
        [Parameter(Mandatory)][string]$ScriptNameParam
    )
    $foundVersion = $null
    if ($FoundVersionParam) { $foundVersion = $FoundVersionParam -as [version] }
    if ($null -ne $foundVersion -and $foundVersion -ge [version]$RequiredVersionParam) { return $true }
    $foundText = if (-not $FoundVersionParam) {
        'has no version, so it comes from an older release'
    } elseif ($null -eq $foundVersion) {
        "has the version '$FoundVersionParam', which isn't a version number"
    } else {
        "is version $foundVersion"
    }
    Write-LogError "$ScriptNameParam needs include\global-config.ps1 $RequiredVersionParam or later, and the one loaded $foundText. An older copy was probably put back over this release's. Restore this release's include\global-config.ps1 and keep your settings in overrides\overrides.psd1. UPGRADE.md shows how to move them there with Export-OverrideFile.ps1."
    return $false
}
#endregion

#region Changed Defaults
function Write-OverrideChangedDefault {
    <#
    .SYNOPSIS
        Logs one INFO line for each setting whose shipped default changed since the
        previous release, when this run left that setting at its shipped default.
    .DESCRIPTION
        Reads the override catalog and the release table and hands them to
        Get-OverrideChangedDefault, from include\OverrideFile.ps1, which global-config.ps1
        loads. Each line names the setting, its old and new default, and the override
        key that keeps the old one. A key this run set, from the command line, the build
        profile or the override file, gets no line. A problem reading either file, or an
        error from the comparison, is logged as a WARN and never stops the run. Logs
        nothing when the reader isn't loaded, which global-config.ps1 has already
        reported.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$CatalogPathParam,
        [AllowNull()][AllowEmptyString()][string]$ReleaseTablePathParam,
        [AllowNull()][AllowEmptyString()][string]$CurrentVersionParam,
        [AllowNull()][AllowEmptyCollection()][string[]]$SetKeyParam,
        [AllowNull()][AllowEmptyCollection()][string[]]$BoundParameterNameParam
    )
    if (-not $CatalogPathParam -or -not (Get-Command -Name 'Get-OverrideChangedDefault' -CommandType Function -ErrorAction SilentlyContinue)) { return }
    try {
        $catalogData = Import-PowerShellDataFile -LiteralPath $CatalogPathParam -ErrorAction Stop
        $releaseData = $null
        if ($ReleaseTablePathParam -and (Test-Path -LiteralPath $ReleaseTablePathParam -PathType Leaf)) {
            $releaseData = Import-PowerShellDataFile -LiteralPath $ReleaseTablePathParam -ErrorAction Stop
        }
    } catch {
        Write-LogWarn "Changed default: the override catalog or the release table couldn't be read ($($_.Exception.GetType().FullName)), so changed defaults aren't reported for this run."
        return
    }
    # A parameter given on the command line is set too. Its key is the catalog key whose
    # Name is that parameter.
    $setKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($setKey in @($SetKeyParam)) { if ($setKey) { $setKeys.Add($setKey) } }
    if ($catalogData -is [hashtable] -and $catalogData['Settings'] -is [hashtable]) {
        foreach ($catalogKey in @($catalogData['Settings'].get_Keys())) {
            $catalogEntry = $catalogData['Settings'][$catalogKey]
            if ($catalogEntry -is [hashtable] -and $catalogEntry['Target'] -ceq 'Parameter' -and @($BoundParameterNameParam) -contains $catalogEntry['Name']) { $setKeys.Add([string]$catalogKey) }
        }
    }
    $changedResult = Get-OverrideChangedDefault -Catalog $catalogData -ReleaseTable $releaseData -CurrentVersion $CurrentVersionParam -SetKey ([string[]]$setKeys.ToArray())
    foreach ($changedLine in @($changedResult.Info)) { if ($changedLine) { Write-LogInfo $changedLine } }
    foreach ($changedLine in @($changedResult.Warnings)) { if ($changedLine) { Write-LogWarn $changedLine } }
    if ($changedResult.Error) {
        foreach ($changedLine in ($changedResult.Error -split '\r?\n')) { if ($changedLine) { Write-LogWarn $changedLine } }
    }
}
#endregion
