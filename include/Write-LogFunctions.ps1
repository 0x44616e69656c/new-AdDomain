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

    Write-CsvLogEntry is an internal helper and should not be called directly by
    consuming scripts. The CSV is written as UTF-8 with a byte order mark on both
    Windows PowerShell 5.1 and PowerShell 7.
.EXAMPLE
    . .\Write-LogFunctions.ps1
    Initialize-Logging -LogPathParam $logPath -ScriptNameParam "New-ADForestDeployment.ps1" -CsvLogPathParam $csvErrorLogPath
    Write-LogInfo "Starting deployment."
.NOTES
    Version:      2.0.0
    Author:       Daniel Owen
    Release Date: 2026-11-05
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
