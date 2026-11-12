<#
.SYNOPSIS
    Build profile support for the AD deployment script set.
.DESCRIPTION
    Dot-sourced by include\global-config.ps1, on the guest by both deployment scripts
    and on the host by build-lab.ps1. It only defines functions. Loading it writes
    nothing to the output, the console or the disk.

    A build profile is a .psd1 file, include\build-profile.psd1, that overrides some of
    the base values in global-config.ps1 for one build. Get-BuildProfile reads it,
    applies it over the global-config.ps1 values, falls back to a safe value where a
    value is empty or clashes, validates every effective value whatever its source,
    and returns the effective values with the INFO, WARN and error lines to log. Every
    line starts with its source: "Build profile '<path>':" for a profile value,
    "Override file '<path>':" for a value from overrides\overrides.psd1, or
    "global-config.ps1:" for a value from that file.

    Functions:
      - Get-BuildProfileBuiltInValue         : the shipped base values, used when a
                                               global-config.ps1 value is empty
      - Get-BuildProfile                     : reads, merges and validates
      - Resolve-ServicePrincipalName         : replaces {DomainName} in an SPN
      - Test-ServicePrincipalNamePlaceholder : lists CSV rows whose SPN still holds
                                               a brace after substitution
      - Test-ServicePrincipalNameDomain      : lists CSV rows whose literal SPN names
                                               a host outside the build's domain
      - Resolve-UserStatePercentage          : keeps the five user-state percentages
                                               at a sum of 100 or less
      - Resolve-MinMaxPair                   : keeps a minimum no higher than its
                                               maximum
      - Get-IPv4NetworkAddress               : the network address of an address and
                                               prefix, in CIDR form
      - Test-IPv4AddressInSubnet             : whether an address is inside a subnet

    The file is dot-sourced, so it sets no strict mode or error preference of its own,
    which would change its caller's. Each function sets its error preference locally.
.EXAMPLE
    . "$PSScriptRoot\BuildProfile.ps1"
    $buildProfileResult = Get-BuildProfile -DomainName 'lab.test' -NetBIOSName 'LAB' `
        -ForestMode 'WinThreshold' -DomainMode 'WinThreshold' -RequiredOSBuild 26100 `
        -PrimarySiteName 'Lab-HQ' -PrimarySubnet 'Auto' `
        -ProfilePath "$PSScriptRoot\build-profile.psd1"
.EXAMPLE
    Resolve-ServicePrincipalName -ServicePrincipalName 'MSSQLSvc/sql01.{DomainName}:1433' -DomainName 'lab.test'
    # MSSQLSvc/sql01.lab.test:1433
.OUTPUTS
    None when dot-sourced. Get-BuildProfile returns one PSCustomObject. See each function.
.NOTES
    Version:           2.1.0
    Author:            Daniel Owen
    Release Date:      2026-11-12
    Requirements:      PowerShell 5.1+
    Target Set Source: N/A
    Event Log Source:  N/A
    Setup:             N/A
#>


#region Built-in Values
function Get-BuildProfileBuiltInValue {
    <#
    .SYNOPSIS
        Returns the shipped base values, keyed by global-config.ps1 variable name.
    .DESCRIPTION
        An empty or missing value in global-config.ps1 takes its built-in value here,
        with a WARN. $netBIOSName has no entry, because an empty one is derived from the
        domain's first label. These must equal the assignments in global-config.ps1.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param ()
    return [ordered]@{
        domainName      = 'lab.test'
        forestMode      = 'WinThreshold'
        domainMode      = 'WinThreshold'
        requiredOSBuild = 26100
        primarySiteName = 'Lab-HQ'
        primarySubnet   = 'Auto'
    }
}
#endregion

#region IPv4 Helpers
function ConvertTo-BuildProfileIPv4Number {
    # Converts a dotted-decimal IPv4 address to its 32-bit value, held in a [long] so the
    # top bit does not turn it negative. Throws on anything but four decimal octets.
    [CmdletBinding()]
    [OutputType([long])]
    param (
        [Parameter(Mandatory)]
        [string]$IPAddress
    )
    $ErrorActionPreference = 'Stop'
    $octetPattern = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    if ($IPAddress -notmatch "\A$octetPattern\.$octetPattern\.$octetPattern\.$octetPattern\z") {
        throw "'$IPAddress' is not an IPv4 address in dotted-decimal form."
    }
    return ([long]$Matches[1] * 16777216) + ([long]$Matches[2] * 65536) + ([long]$Matches[3] * 256) + [long]$Matches[4]
}

function ConvertFrom-BuildProfileIPv4Number {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [long]$IPv4Number
    )
    return (@(24, 16, 8, 0) | ForEach-Object { ($IPv4Number -shr $_) -band 255 }) -join '.'
}

function Get-BuildProfileIPv4Mask {
    [CmdletBinding()]
    [OutputType([long])]
    param (
        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )
    if ($PrefixLength -eq 0) { return [long]0 }
    return ([long]4294967295 -shl (32 - $PrefixLength)) -band [long]4294967295
}

function Get-IPv4NetworkAddress {
    <#
    .SYNOPSIS
        Returns the network address of an IPv4 address and prefix, in CIDR form.
    .EXAMPLE
        Get-IPv4NetworkAddress -IPAddress '192.168.159.100' -PrefixLength 24
        # 192.168.159.0/24
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$IPAddress,

        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )
    $ErrorActionPreference = 'Stop'
    $addressNumber = ConvertTo-BuildProfileIPv4Number -IPAddress $IPAddress
    $networkNumber = $addressNumber -band (Get-BuildProfileIPv4Mask -PrefixLength $PrefixLength)
    return "$(ConvertFrom-BuildProfileIPv4Number -IPv4Number $networkNumber)/$PrefixLength"
}

function Test-IPv4AddressInSubnet {
    <#
    .SYNOPSIS
        Returns $true when an IPv4 address is inside a subnet given in CIDR form.
    .DESCRIPTION
        Throws when either value is not in the expected form, so a caller never
        mistakes a typo for "not in the subnet".
    .EXAMPLE
        Test-IPv4AddressInSubnet -IPAddress '192.168.159.90' -Subnet '10.99.0.0/24'
        # False
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$IPAddress,

        [Parameter(Mandatory)]
        [string]$Subnet
    )
    $ErrorActionPreference = 'Stop'
    if ($Subnet -notmatch '\A([0-9.]+)/([0-9]{1,2})\z' -or [int]$Matches[2] -gt 32) {
        throw "'$Subnet' is not an IPv4 subnet in CIDR form."
    }
    $subnetPrefixLength = [int]$Matches[2]
    $subnetNumber       = ConvertTo-BuildProfileIPv4Number -IPAddress $Matches[1]
    $addressNumber      = ConvertTo-BuildProfileIPv4Number -IPAddress $IPAddress
    $mask               = Get-BuildProfileIPv4Mask -PrefixLength $subnetPrefixLength
    return (($addressNumber -band $mask) -eq ($subnetNumber -band $mask))
}
#endregion

#region Value Helpers
function Test-BuildProfileEmptyValue {
    # Empty means $null, a string of only whitespace, or an empty list or table.
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [AllowNull()]
        [object]$Value
    )
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrWhiteSpace($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return ($Value.get_Count() -eq 0) }
    if ($Value -is [System.Array]) { return ($Value.Count -eq 0) }
    return $false
}

function Get-BuildProfileSingleLine {
    # Folds an exception message onto one line without a trailing full stop, so each stop
    # stays one line in the joined error.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [string]$Text
    )
    if ($null -eq $Text) { return '' }
    return (($Text -replace '\s*\r?\n\s*', ' ').Trim()).TrimEnd('.')
}

function Test-BuildProfileNetBIOSName {
    # Returns $null when the name is valid, otherwise the reason it is not.
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )
    $reservedWords = @(
        'ANONYMOUS', 'AUTHENTICATED USER', 'BATCH', 'BUILTIN', 'CREATOR GROUP',
        'CREATOR GROUP SERVER', 'CREATOR OWNER', 'CREATOR OWNER SERVER', 'DIALUP',
        'DIGEST AUTH', 'DOMAIN', 'ENTERPRISE', 'INTERACTIVE', 'INTERNET', 'LOCAL',
        'LOCAL SYSTEM', 'NETWORK', 'NETWORK SERVICE', 'NT AUTHORITY', 'NT DOMAIN',
        'NTLM AUTH', 'NULL', 'PROXY', 'REMOTE INTERACTIVE', 'RESTRICTED', 'SCHANNEL AUTH',
        'SELF', 'SERVER', 'SERVICE', 'SYSTEM', 'TERMINAL SERVER', 'THIS ORGANIZATION',
        'USERS', 'WORLD'
    )
    if ($Name.Length -gt 15) { return 'longer than 15 characters' }
    if ($Name -notmatch '\A[A-Za-z0-9-]{1,15}\z') { return 'not only letters, digits or hyphens' }
    if ($Name -match '\A[0-9]+\z') { return 'digits only' }
    if ($reservedWords -contains $Name) { return 'a reserved word' }
    return $null
}

function ConvertTo-BuildProfileSetting {
    <#
    .SYNOPSIS
        Validates one effective value and returns it in canonical form.
    .DESCRIPTION
        Returns a PSCustomObject with Valid, Value (the canonical value) and Problem (the
        text after "<source> <name> " when the value is malformed). The caller has
        already replaced empty values.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )
    $labelPattern  = '[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    $octetPattern  = '(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    $result = [pscustomobject]@{ Valid = $false; Value = $null; Problem = $null }

    if ($Value -is [System.Array] -or $Value -is [System.Collections.IDictionary]) {
        $result.Problem = 'must be a single value, not a list or a table.'
        return $result
    }
    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim() }
    $isString = $Value -is [string]

    switch ($Key) {
        'DomainName' {
            if ($isString -and $text -match "\A(?=.{1,64}\z)$labelPattern(?:\.$labelPattern)+\z") {
                $result.Valid = $true; $result.Value = $text
            } else {
                $result.Problem = "'$text' is not a valid domain name. It needs at least two labels separated by dots, each 1 to 63 letters, digits or hyphens that doesn't start or end with a hyphen, and at most 64 characters in all."
            }
        }
        'NetBIOSName' {
            if ($isString -and $null -eq (Test-BuildProfileNetBIOSName -Name $text)) {
                $result.Valid = $true; $result.Value = $text
            } else {
                $result.Problem = "'$text' is not a valid NetBIOS name. It must be 1 to 15 letters, digits or hyphens, not digits only, and not a reserved word."
            }
        }
        { $_ -in @('ForestMode', 'DomainMode') } {
            $canonicalMode = @('WinThreshold', 'Win2025') | Where-Object { $isString -and $_ -eq $text }
            if ($canonicalMode) {
                $result.Valid = $true; $result.Value = [string]$canonicalMode
            } else {
                $result.Problem = "'$text' is not supported. Use WinThreshold or Win2025."
            }
        }
        'RequiredOSBuild' {
            $isWholeNumber = ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) -or
                             ($isString -and $text -match '\A[0-9]{1,10}\z')
            if ($isWholeNumber -and [long]$text -ge 0 -and [long]$text -le [int]::MaxValue) {
                $result.Valid = $true; $result.Value = [int]$text
            } else {
                $result.Problem = "'$text' is not a valid build number. Use a whole number of 17763 or higher, such as 26100."
            }
        }
        'PrimarySiteName' {
            if ($isString -and $text -match '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z') {
                $result.Valid = $true; $result.Value = $text
            } else {
                $result.Problem = "'$text' is not a valid site name. It must be 1 to 63 letters, digits or hyphens, starting with a letter or digit and not ending with a hyphen."
            }
        }
        'PrimarySubnet' {
            if ($isString -and $text -eq 'Auto') {
                $result.Valid = $true; $result.Value = 'Auto'
            } elseif ($isString -and $text -match "\A$octetPattern(?:\.$octetPattern){3}/(?:[89]|[12][0-9]|30)\z") {
                $result.Valid = $true; $result.Value = $text
            } else {
                $result.Problem = "'$text' is not valid. Use Auto, or an IPv4 subnet in CIDR form with a prefix of 8 to 30, such as 192.168.159.0/24."
            }
        }
    }
    return $result
}
#endregion

#region Get-BuildProfile
function Get-BuildProfile {
    <#
    .SYNOPSIS
        Applies a build profile over the global-config.ps1 values and validates the result.
    .DESCRIPTION
        Takes the seven global-config.ps1 base values as they are ($null, an empty string,
        a string or an integer) and, when a profile exists, its path. Never throws.

        Precedence, per key: a profile value; an empty profile key takes the
        global-config.ps1 value; an empty global-config.ps1 value takes the built-in
        value. The global-config.ps1 value is the effective one, which the override file
        may have set, as FileSources says. NetBIOSName is derived from the domain's first
        label when the profile sets DomainName and leaves NetBIOSName out or empty, when
        the override file sets DomainName and neither the override file nor the profile
        sets NetBIOSName, or when $netBIOSName is empty.
    .PARAMETER DomainName
        $domainName from global-config.ps1.
    .PARAMETER NetBIOSName
        $netBIOSName from global-config.ps1.
    .PARAMETER ForestMode
        $forestMode from global-config.ps1.
    .PARAMETER DomainMode
        $domainMode from global-config.ps1.
    .PARAMETER RequiredOSBuild
        $requiredOSBuild from global-config.ps1.
    .PARAMETER PrimarySiteName
        $primarySiteName from global-config.ps1.
    .PARAMETER PrimarySubnet
        $primarySubnet from global-config.ps1.
    .PARAMETER ProfilePath
        The build profile to read. Omit it when there is none.
    .PARAMETER FileSources
        Key to source label, such as "Override file '<path>'", for each of the seven
        values that came from the override file rather than global-config.ps1. A line
        about such a value starts with that label and names the key. Omit it, or pass an
        empty table, when no value came from the override file, and every line is as
        it was before override files.
    .OUTPUTS
        PSCustomObject with DomainName, NetBIOSName, ForestMode, DomainMode,
        RequiredOSBuild, PrimarySiteName, PrimarySubnet (all $null when Error is set),
        DomainNameSource (Profile, OverrideFile, GlobalConfigEdited or Shipped, $null
        when Error is set), ProfileKeys (the keys whose value came from the profile,
        a NetBIOS name derived from its DomainName included, empty when Error is set),
        ProfilePath, Summary ($null when Error is set), Info and
        Warnings (string arrays) and Error ($null, or one stop per line).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()][object]$DomainName,
        [AllowNull()][object]$NetBIOSName,
        [AllowNull()][object]$ForestMode,
        [AllowNull()][object]$DomainMode,
        [AllowNull()][object]$RequiredOSBuild,
        [AllowNull()][object]$PrimarySiteName,
        [AllowNull()][object]$PrimarySubnet,
        [string]$ProfilePath,
        [AllowNull()][hashtable]$FileSources
    )
    $ErrorActionPreference = 'Stop'

    $infoLines    = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()
    $errorLines   = [System.Collections.Generic.List[string]]::new()
    $effective    = [ordered]@{}
    $keyNames     = @('DomainName', 'NetBIOSName', 'ForestMode', 'DomainMode', 'RequiredOSBuild', 'PrimarySiteName', 'PrimarySubnet')

    try {
        $fileValues = @{
            DomainName      = $DomainName
            NetBIOSName     = $NetBIOSName
            ForestMode      = $ForestMode
            DomainMode      = $DomainMode
            RequiredOSBuild = $RequiredOSBuild
            PrimarySiteName = $PrimarySiteName
            PrimarySubnet   = $PrimarySubnet
        }
        $builtInValues = Get-BuildProfileBuiltInValue
        $laterItemKeys = [ordered]@{
            BuildName            = 'plan item 4'
            RandomSeed           = 'plan item 3'
            Population           = 'plan item 3'
            DomainAdminCount     = 'plan item 3'
            CertificateAuthority = $null
            VirtualNetwork       = 'plan item 10'
            Machines             = 'plan item 8'
            Trusts               = 'plan item 9'
        }
        $derivedKeys = @('DomainDN', 'ForestName', 'UsersOU', 'GroupsOU', 'ServersOU', 'WorkstationsOU', 'AdminsOU', 'ServiceAccountsOU', 'DisabledUsersOU', 'QuarantineOU')
        $draftKeyHints = @{
            DomainDnsName = 'DomainName'
            ForestDnsName = 'DomainName'
            SiteName      = 'PrimarySiteName'
            SiteSubnet    = 'PrimarySubnet'
        }
        $profilePrefix = $null
        $filePrefix    = 'global-config.ps1:'

        # The override file's label for a value that came from it, else $null.
        $overrideLabelOf = @{}
        foreach ($keyName in $keyNames) {
            $overrideLabelOf[$keyName] = $null
            if ($null -ne $FileSources -and $FileSources.ContainsKey($keyName) -and $FileSources[$keyName]) { $overrideLabelOf[$keyName] = [string]$FileSources[$keyName] }
        }

        # A value's name in a line: the key for a profile value, the variable for a file value.
        $variableNameOf = @{}
        foreach ($keyName in $keyNames) { $variableNameOf[$keyName] = $keyName.Substring(0, 1).ToLowerInvariant() + $keyName.Substring(1) }

        #region Read the profile
        $profileData = $null
        if ($ProfilePath) {
            $profilePrefix = "Build profile '$ProfilePath':"
            if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
                $errorLines.Add("$profilePrefix the file does not exist.")
            } else {
                try {
                    $profileData = Import-PowerShellDataFile -LiteralPath $ProfilePath -ErrorAction Stop
                } catch {
                    $errorLines.Add("$profilePrefix can't be read as a PowerShell data file: $(Get-BuildProfileSingleLine -Text $_.Exception.Message). It must hold one hashtable of constant values.")
                }
            }
        }

        # Per key: 'Missing', 'Empty' or 'Value'. Without a profile every key is 'Missing'.
        $profileState = @{}
        $profileValue = @{}
        foreach ($keyName in $keyNames) { $profileState[$keyName] = 'Missing' }
        if ($null -ne $profileData) {
            foreach ($rawKey in @($profileData.get_Keys() | Sort-Object)) {
                $rawValue     = $profileData[$rawKey]
                $canonicalKey = $keyNames | Where-Object { $_ -eq $rawKey } | Select-Object -First 1
                $laterKey     = @($laterItemKeys.get_Keys()) | Where-Object { $_ -eq $rawKey } | Select-Object -First 1
                if ($canonicalKey) {
                    if (Test-BuildProfileEmptyValue -Value $rawValue) {
                        $profileState[$canonicalKey] = 'Empty'
                    } else {
                        $profileState[$canonicalKey] = 'Value'
                        $profileValue[$canonicalKey] = $rawValue
                    }
                } elseif ($laterKey) {
                    $laterItem = $laterItemKeys[$laterKey]
                    if (Test-BuildProfileEmptyValue -Value $rawValue) {
                        if ($laterItem) {
                            $warningLines.Add("$profilePrefix $laterKey is empty and is ignored until $laterItem ships.")
                        } else {
                            $warningLines.Add("$profilePrefix $laterKey is empty and is ignored until a plan item supports it.")
                        }
                    } elseif ($laterItem) {
                        $errorLines.Add("$profilePrefix $laterKey is not supported yet ($laterItem). Remove it, or leave it empty.")
                    } else {
                        $errorLines.Add("$profilePrefix $laterKey is not supported yet (no plan item yet). Remove it, or leave it empty.")
                    }
                } elseif ($derivedKeys -contains $rawKey) {
                    $errorLines.Add("$profilePrefix $rawKey can't be set. It is derived from DomainName.")
                } else {
                    $unknownKeyLine = "$profilePrefix unknown key '$rawKey'. Valid keys: $($keyNames -join ', ')."
                    $hintKey = @($draftKeyHints.get_Keys()) | Where-Object { $_ -eq $rawKey } | Select-Object -First 1
                    if ($hintKey) {
                        $unknownKeyLine += " Did you mean $($draftKeyHints[$hintKey])? The plan's draft key names were renamed."
                    }
                    $errorLines.Add($unknownKeyLine)
                }
            }
        }
        #endregion

        #region Effective raw values, with the empty-value fallbacks
        $deriveNetBIOSFromProfile = ($profileState['DomainName'] -eq 'Value') -and ($profileState['NetBIOSName'] -ne 'Value')
        $deriveNetBIOSFromOverride = (-not $deriveNetBIOSFromProfile) -and ($profileState['NetBIOSName'] -eq 'Missing') -and
                                     ($null -ne $overrideLabelOf['DomainName']) -and ($null -eq $overrideLabelOf['NetBIOSName'])
        $rawEffective   = @{}
        $sourceOf       = @{}
        $deriveNetBIOS  = $false
        $derivedNetBIOS = $null
        $leftOutKeys    = [System.Collections.Generic.List[string]]::new()

        # Derives NetBIOSName from the effective domain's first label, in place, so its WARN
        # follows the lines about NetBIOSName. DomainName comes first in $keyNames, so its
        # effective value is known here. An invalid domain is reported by its own check.
        $deriveNetBIOSName = {
            $domainSetting = ConvertTo-BuildProfileSetting -Key 'DomainName' -Value $rawEffective['DomainName']
            if (-not $domainSetting.Valid) { return }
            $derivedDomain = $domainSetting.Value
            $firstLabel    = $derivedDomain.Split('.')[0].ToUpperInvariant()
            $labelProblem  = Test-BuildProfileNetBIOSName -Name $firstLabel
            if ($sourceOf['NetBIOSName'] -eq 'Profile') {
                $profileNetBIOSState = if ($profileState['NetBIOSName'] -eq 'Empty') { 'empty' } else { 'not set' }
                if ($labelProblem) {
                    $errorLines.Add("$profilePrefix NetBIOSName is $profileNetBIOSState, and the name derived from DomainName '$derivedDomain', '$firstLabel', is not a valid NetBIOS name ($labelProblem). Set NetBIOSName in the profile.")
                } else {
                    $warningLines.Add("$profilePrefix NetBIOSName is $profileNetBIOSState; using '$firstLabel', the first label of DomainName '$derivedDomain', upper-cased.")
                    $firstLabel
                }
            } elseif ($deriveNetBIOSFromOverride) {
                $overridePrefix = "$($overrideLabelOf['DomainName']):"
                if ($labelProblem) {
                    $errorLines.Add("$overridePrefix NetBIOSName is not set, and the name derived from DomainName '$derivedDomain', '$firstLabel', is not a valid NetBIOS name ($labelProblem). Set NetBIOSName in the override file.")
                } else {
                    $warningLines.Add("$overridePrefix NetBIOSName is not set; using '$firstLabel', the first label of DomainName '$derivedDomain', upper-cased.")
                    $firstLabel
                }
            } else {
                if ($labelProblem) {
                    $errorLines.Add("$filePrefix `$netBIOSName is empty or missing, and the name derived from the domain '$derivedDomain', '$firstLabel', is not a valid NetBIOS name ($labelProblem). Set `$netBIOSName in global-config.ps1.")
                } else {
                    $warningLines.Add("$filePrefix `$netBIOSName is empty or missing; using '$firstLabel', the first label of the domain '$derivedDomain', upper-cased.")
                    $firstLabel
                }
            }
        }

        foreach ($keyName in $keyNames) {
            $variableName = $variableNameOf[$keyName]
            if ($keyName -eq 'NetBIOSName' -and $deriveNetBIOSFromProfile) {
                $sourceOf[$keyName] = 'Profile'
                $deriveNetBIOS      = $true
                $derivedNetBIOS     = . $deriveNetBIOSName
                continue
            }
            if ($keyName -eq 'NetBIOSName' -and $deriveNetBIOSFromOverride) {
                $sourceOf[$keyName] = 'File'
                $deriveNetBIOS      = $true
                $derivedNetBIOS     = . $deriveNetBIOSName
                if ($null -ne $profileData) { $leftOutKeys.Add($keyName) }
                continue
            }
            if ($profileState[$keyName] -eq 'Value') {
                $rawEffective[$keyName] = $profileValue[$keyName]
                $sourceOf[$keyName]     = 'Profile'
                continue
            }

            $fileValue     = $fileValues[$keyName]
            $fileValueText = if ($null -eq $fileValue) { '' } else { ([string]$fileValue).Trim() }
            $fileIsEmpty   = Test-BuildProfileEmptyValue -Value $fileValue
            if ($profileState[$keyName] -eq 'Empty' -and $null -ne $overrideLabelOf[$keyName]) {
                $warningLines.Add("$profilePrefix $keyName is empty; using $keyName from $($overrideLabelOf[$keyName]), '$fileValueText'.")
            } elseif ($profileState[$keyName] -eq 'Empty') {
                if ($fileIsEmpty) {
                    $warningLines.Add("$profilePrefix $keyName is empty; using `$$variableName from global-config.ps1, which is also empty (see the next line).")
                } else {
                    $warningLines.Add("$profilePrefix $keyName is empty; using `$$variableName from global-config.ps1, '$fileValueText'.")
                }
            } elseif ($null -ne $profileData) {
                $leftOutKeys.Add($keyName)
            }

            $sourceOf[$keyName] = 'File'
            if (-not $fileIsEmpty) {
                $rawEffective[$keyName] = $fileValue
            } elseif ($keyName -eq 'NetBIOSName') {
                $deriveNetBIOS  = $true
                $derivedNetBIOS = . $deriveNetBIOSName
            } else {
                $builtInValue           = $builtInValues[$variableName]
                $rawEffective[$keyName] = $builtInValue
                $warningLines.Add("$filePrefix `$$variableName is empty or missing; using the built-in value '$builtInValue'.")
            }
        }
        #endregion

        #region Validate each effective value
        $prefixOf = @{}
        $nameOf   = @{}
        foreach ($keyName in $keyNames) {
            if ($sourceOf[$keyName] -eq 'Profile') {
                $prefixOf[$keyName] = $profilePrefix
                $nameOf[$keyName]   = $keyName
            } elseif ($null -ne $overrideLabelOf[$keyName]) {
                $prefixOf[$keyName] = "$($overrideLabelOf[$keyName]):"
                $nameOf[$keyName]   = $keyName
            } else {
                $prefixOf[$keyName] = $filePrefix
                $nameOf[$keyName]   = "`$$($variableNameOf[$keyName])"
            }
        }
        $validValue = @{}
        foreach ($keyName in $keyNames) {
            if ($keyName -eq 'NetBIOSName' -and $deriveNetBIOS) { continue }
            $setting = ConvertTo-BuildProfileSetting -Key $keyName -Value $rawEffective[$keyName]
            if ($setting.Valid) {
                $validValue[$keyName] = $setting.Value
            } else {
                $errorLines.Add("$($prefixOf[$keyName]) $($nameOf[$keyName]) $($setting.Problem)")
            }
        }

        if ($deriveNetBIOS -and $null -ne $derivedNetBIOS) { $validValue['NetBIOSName'] = [string]$derivedNetBIOS }

        if ($leftOutKeys.Count -gt 0) {
            $leftOutPairs = foreach ($leftOutKey in $leftOutKeys) {
                if ($validValue.ContainsKey($leftOutKey)) { "$leftOutKey=$($validValue[$leftOutKey])" }
            }
            if (@($leftOutPairs).Count -gt 0) {
                $leftOutFromOverride = @($leftOutKeys | Where-Object { $null -ne $overrideLabelOf[$_] -or ($_ -eq 'NetBIOSName' -and $deriveNetBIOSFromOverride) }).Count -gt 0
                $leftOutSourceText   = if ($leftOutFromOverride) { 'the override file and global-config.ps1 values apply' } else { 'the global-config.ps1 values apply' }
                $infoLines.Add("$profilePrefix not set in the profile, so $($leftOutSourceText): $(@($leftOutPairs) -join ', ')")
            }
        }
        #endregion

        #region Fallbacks that combine values
        # The second source is named only when it differs from the first.
        $originOf = @{}
        foreach ($keyName in $keyNames) {
            if ($sourceOf[$keyName] -eq 'Profile') { $originOf[$keyName] = 'Profile' }
            elseif ($null -ne $overrideLabelOf[$keyName]) { $originOf[$keyName] = $overrideLabelOf[$keyName] }
            else { $originOf[$keyName] = 'File' }
        }
        $fromOther = {
            param ([string]$OwnKey, [string]$OtherKey)
            if ($originOf[$OwnKey] -eq $originOf[$OtherKey]) { return '' }
            if ($originOf[$OtherKey] -eq 'Profile') { return ", from build profile '$ProfilePath'" }
            if ($originOf[$OtherKey] -ne 'File') { return ", from $($originOf[$OtherKey])" }
            return ', from global-config.ps1'
        }

        if ($validValue.ContainsKey('DomainName') -and $validValue['DomainName'] -match '\.local\z') {
            $warningLines.Add("$($prefixOf['DomainName']) $($nameOf['DomainName']) '$($validValue['DomainName'])' ends in .local, which RFC 6762 reserves for multicast DNS; using it as given.")
        }

        if ($validValue.ContainsKey('ForestMode') -and $validValue.ContainsKey('DomainMode') -and
            $validValue['ForestMode'] -eq 'Win2025' -and $validValue['DomainMode'] -eq 'WinThreshold') {
            $warningLines.Add("$($prefixOf['DomainMode']) $($nameOf['DomainMode']) WinThreshold is lower than $($nameOf['ForestMode']) Win2025$(& $fromOther 'DomainMode' 'ForestMode'); raising $($nameOf['DomainMode']) to Win2025.")
            $validValue['DomainMode'] = 'Win2025'
        }

        if ($validValue.ContainsKey('RequiredOSBuild')) {
            if ($validValue['RequiredOSBuild'] -lt 17763) {
                $warningLines.Add("$($prefixOf['RequiredOSBuild']) $($nameOf['RequiredOSBuild']) $($validValue['RequiredOSBuild']) is below the lab's floor; using 17763")
                $validValue['RequiredOSBuild'] = 17763
            }
            $win2025ModeKey = $null
            if ($validValue.ContainsKey('ForestMode') -and $validValue['ForestMode'] -eq 'Win2025') {
                $win2025ModeKey = 'ForestMode'
            } elseif ($validValue.ContainsKey('DomainMode') -and $validValue['DomainMode'] -eq 'Win2025') {
                $win2025ModeKey = 'DomainMode'
            }
            if ($win2025ModeKey -and $validValue['RequiredOSBuild'] -lt 26100) {
                $warningLines.Add("$($prefixOf['RequiredOSBuild']) $($nameOf['RequiredOSBuild']) $($validValue['RequiredOSBuild']) is below 26100, which $($nameOf[$win2025ModeKey]) Win2025$(& $fromOther 'RequiredOSBuild' $win2025ModeKey) needs; using 26100.")
                $validValue['RequiredOSBuild'] = 26100
            }
        }

        if ($validValue.ContainsKey('PrimarySubnet') -and $validValue['PrimarySubnet'] -ne 'Auto') {
            $subnetParts    = $validValue['PrimarySubnet'].Split('/')
            $networkAddress = Get-IPv4NetworkAddress -IPAddress $subnetParts[0] -PrefixLength ([int]$subnetParts[1])
            if ($networkAddress -ne $validValue['PrimarySubnet']) {
                $warningLines.Add("$($prefixOf['PrimarySubnet']) $($nameOf['PrimarySubnet']) $($validValue['PrimarySubnet']) has host bits set; using the network address $networkAddress.")
                $validValue['PrimarySubnet'] = $networkAddress
            }
        }
        #endregion

        if ($errorLines.Count -eq 0) {
            foreach ($keyName in $keyNames) { $effective[$keyName] = $validValue[$keyName] }
        }
    } catch {
        $errorLines.Add("BuildProfile.ps1: Get-BuildProfile failed unexpectedly: $(Get-BuildProfileSingleLine -Text $_.Exception.Message).")
    }

    $summaryText      = $null
    $domainNameSource = $null
    $profileKeys      = [string[]]@()
    if ($errorLines.Count -eq 0) {
        $profileKeys = [string[]]@($keyNames | Where-Object { $sourceOf[$_] -eq 'Profile' })
        $valuePairs  = ($keyNames | ForEach-Object { "$_=$($effective[$_])" }) -join ', '
        $anyOverride = @($keyNames | Where-Object { $null -ne $overrideLabelOf[$_] }).Count -gt 0
        if ($ProfilePath) {
            $summaryText = "Build profile: $valuePairs, from '$ProfilePath'"
        } elseif ($anyOverride) {
            $summaryText = "No build profile; override file and global-config.ps1 values: $valuePairs"
        } else {
            $summaryText = "No build profile; global-config.ps1 values: $valuePairs"
        }
        # Who named the domain. Shipped means nobody did: the built-in domain from an
        # unedited or empty global-config.ps1 value.
        $builtInDomainName = [string](Get-BuildProfileBuiltInValue)['domainName']
        if ($sourceOf['DomainName'] -eq 'Profile') { $domainNameSource = 'Profile' }
        elseif ($null -ne $overrideLabelOf['DomainName']) { $domainNameSource = 'OverrideFile' }
        elseif ([string]::Equals([string]$effective['DomainName'], $builtInDomainName, [System.StringComparison]::OrdinalIgnoreCase)) { $domainNameSource = 'Shipped' }
        else { $domainNameSource = 'GlobalConfigEdited' }
    }

    $errorText = $null
    if ($errorLines.Count -gt 0) { $errorText = $errorLines -join [Environment]::NewLine }

    $profilePathValue = $null
    if ($ProfilePath) { $profilePathValue = $ProfilePath }

    return [pscustomobject]@{
        DomainName      = $(if ($errorText) { $null } else { [string]$effective['DomainName'] })
        NetBIOSName     = $(if ($errorText) { $null } else { [string]$effective['NetBIOSName'] })
        ForestMode      = $(if ($errorText) { $null } else { [string]$effective['ForestMode'] })
        DomainMode      = $(if ($errorText) { $null } else { [string]$effective['DomainMode'] })
        RequiredOSBuild = $(if ($errorText) { $null } else { [int]$effective['RequiredOSBuild'] })
        PrimarySiteName = $(if ($errorText) { $null } else { [string]$effective['PrimarySiteName'] })
        PrimarySubnet   = $(if ($errorText) { $null } else { [string]$effective['PrimarySubnet'] })
        DomainNameSource = $(if ($errorText) { $null } else { $domainNameSource })
        ProfileKeys     = $(if ($errorText) { [string[]]@() } else { $profileKeys })
        ProfilePath     = $profilePathValue
        Summary         = $summaryText
        Info            = [string[]]$infoLines.ToArray()
        Warnings        = [string[]]$warningLines.ToArray()
        Error           = $errorText
    }
}
#endregion

#region Cross-Key Checks
function Resolve-UserStatePercentage {
    <#
    .SYNOPSIS
        Keeps the five user-state percentages at a sum of 100 or less, lowering the
        shipped ones nobody set before it ever stops.
    .DESCRIPTION
        Takes the five effective percentages in roll order (PctDisabled, PctPwExpired,
        PctPwNeverExpires, PctSmartcard, PctLocked) and, for each one somebody set, the
        label of where it was set. A percentage with no label is inherited, the shipped
        value. When the sum is above 100 and the ones set alone stay at 100 or less, the
        inherited ones are lowered, the last roll range first, none below 0, until the
        sum is 100, with one WARN. When the ones set alone sum above 100, nothing gives
        way and the result is a stop. Never throws.
    .PARAMETER Value
        Key to whole number, the five percentages.
    .PARAMETER Source
        Key to label, such as "Override file '<path>'" or "global-config.ps1", for each
        percentage somebody set. Leave an inherited one out.
    .OUTPUTS
        PSCustomObject with Values (key to whole number, after any lowering), Warning
        ($null or one line) and Error ($null or one line).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Source
    )
    $rollOrder = @('PctDisabled', 'PctPwExpired', 'PctPwNeverExpires', 'PctSmartcard', 'PctLocked')
    $resolved  = [ordered]@{}
    foreach ($percentageKey in $rollOrder) { $resolved[$percentageKey] = [int]$Value[$percentageKey] }
    $result = [pscustomobject]@{ Values = $resolved; Warning = $null; Error = $null }

    $percentageSum = 0
    foreach ($percentageKey in $rollOrder) { $percentageSum += $resolved[$percentageKey] }
    if ($percentageSum -le 100) { return $result }

    $setKeys = @($rollOrder | Where-Object { $Source.Contains($_) -and $Source[$_] })
    $setSum  = 0
    foreach ($setKey in $setKeys) { $setSum += $resolved[$setKey] }
    $labels  = @($setKeys | ForEach-Object { [string]$Source[$_] } | Select-Object -Unique)
    $prefix  = if ($labels.Count -gt 0) { (@($labels) -join ' and ') + ':' } else { 'global-config.ps1:' }
    $setText = (@($setKeys | ForEach-Object { "$_=$($resolved[$_])" }) -join ', ')

    if ($setSum -gt 100 -or $setKeys.Count -eq $rollOrder.Count) {
        $result.Error = "$prefix the user-state percentages set, $setText, sum to $percentageSum, above 100, so none can give way. Lower them so the five sum to 100 or less."
        return $result
    }

    $excess   = $percentageSum - 100
    $lowered  = [System.Collections.Generic.List[string]]::new()
    for ($rollIndex = $rollOrder.Count - 1; $rollIndex -ge 0 -and $excess -gt 0; $rollIndex--) {
        $percentageKey = $rollOrder[$rollIndex]
        if ($setKeys -contains $percentageKey) { continue }
        $oldValue = $resolved[$percentageKey]
        $cut      = [math]::Min($oldValue, $excess)
        if ($cut -le 0) { continue }
        $resolved[$percentageKey] = $oldValue - $cut
        $excess -= $cut
        $lowered.Add("$percentageKey $oldValue to $($resolved[$percentageKey])")
    }
    $loweredText = if ($lowered.Count -gt 1) { (@($lowered[0..($lowered.Count - 2)]) -join ', ') + ' and ' + $lowered[-1] } else { $lowered[0] }
    $result.Warning = "$prefix $setText brings the user-state percentages to $percentageSum, above 100; lowering the shipped $loweredText, so they sum to 100."
    return $result
}

function Resolve-MinMaxPair {
    <#
    .SYNOPSIS
        Keeps a minimum no higher than its maximum, moving the shipped one when only one
        was set.
    .DESCRIPTION
        For a pair such as MinDA and MaxDA. When the minimum is above the maximum and one
        of the two is inherited (the shipped value, no label), the inherited one moves
        to the other's value, with one WARN. When both were set, nothing gives way and
        the result is a stop. Never throws.
    .PARAMETER MinKey
        The minimum's key, such as MinDA.
    .PARAMETER MaxKey
        The maximum's key, such as MaxDA.
    .PARAMETER MinValue
        The effective minimum.
    .PARAMETER MaxValue
        The effective maximum.
    .PARAMETER MinSource
        Where the minimum was set, such as "Override file '<path>'" or "Command line".
        Empty when it is the shipped value.
    .PARAMETER MaxSource
        Where the maximum was set, as MinSource.
    .OUTPUTS
        PSCustomObject with Min, Max, Warning ($null or one line) and Error ($null or one
        line).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)][string]$MinKey,
        [Parameter(Mandatory)][string]$MaxKey,
        [Parameter(Mandatory)][int]$MinValue,
        [Parameter(Mandatory)][int]$MaxValue,
        [AllowNull()][AllowEmptyString()][string]$MinSource,
        [AllowNull()][AllowEmptyString()][string]$MaxSource
    )
    $result = [pscustomobject]@{ Min = $MinValue; Max = $MaxValue; Warning = $null; Error = $null }
    if ($MinValue -le $MaxValue) { return $result }
    $minIsSet = -not [string]::IsNullOrEmpty($MinSource)
    $maxIsSet = -not [string]::IsNullOrEmpty($MaxSource)
    if ($minIsSet -and $maxIsSet) {
        $maxPlace = if ($MaxSource -ceq $MinSource) { '' } else { " ($MaxSource)" }
        $result.Error = "$($MinSource): $MinKey=$MinValue is above $MaxKey=$MaxValue$maxPlace. Both were set, so neither gives way. Set $MinKey no higher than $MaxKey."
    } elseif ($minIsSet) {
        $result.Max     = $MinValue
        $result.Warning = "$($MinSource): $MinKey=$MinValue is above the shipped $MaxKey $MaxValue; raising $MaxKey to $MinValue."
    } elseif ($maxIsSet) {
        $result.Min     = $MaxValue
        $result.Warning = "$($MaxSource): $MaxKey=$MaxValue is below the shipped $MinKey $MinValue; lowering $MinKey to $MaxValue."
    } else {
        $result.Error = "$MinKey=$MinValue is above $MaxKey=$MaxValue in the shipped values. Set $MinKey no higher than $MaxKey."
    }
    return $result
}
#endregion

#region SPN Functions
function Resolve-ServicePrincipalName {
    <#
    .SYNOPSIS
        Replaces every {DomainName} placeholder in an SPN with the build's domain.
    .DESCRIPTION
        The placeholder is matched without regard to case, so {domainname} works too. An
        SPN with no placeholder comes back exactly as given, and a $null or empty SPN
        comes back unchanged (no SPN is written for it).
    .PARAMETER ServicePrincipalName
        The SPN as the CSV holds it.
    .PARAMETER DomainName
        The build's domain.
    .EXAMPLE
        Resolve-ServicePrincipalName -ServicePrincipalName 'HTTP/web01.{DomainName}' -DomainName 'lab.test'
        # HTTP/web01.lab.test
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$ServicePrincipalName,

        [Parameter(Mandatory, Position = 1)]
        [string]$DomainName
    )
    $ErrorActionPreference = 'Stop'
    if ($null -eq $ServicePrincipalName -or [string]::IsNullOrEmpty([string]$ServicePrincipalName)) {
        return $ServicePrincipalName
    }
    $replacementDomain = $DomainName
    $matchEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { param ($placeholderMatch) $replacementDomain }.GetNewClosure()
    return [regex]::Replace([string]$ServicePrincipalName, '\{DomainName\}', $matchEvaluator,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Test-ServicePrincipalNamePlaceholder {
    <#
    .SYNOPSIS
        Returns the service account CSV rows whose SPN still holds a brace after
        {DomainName} substitution.
    .DESCRIPTION
        A brace left after substitution means a misspelled placeholder, such as {Domain}.
        Each row returned is a PSCustomObject with RowNumber (1 for the first row under
        the header), Name, ServicePrincipalName (as in the file) and
        ResolvedServicePrincipalName. No row returned means no misspelled placeholder.
        A CSV with no SPN column returns nothing. The rows are written to the pipeline one
        by one, so wrap the call in @() to count them.
        Throws when the file is missing or can't be read.
    .PARAMETER CsvPath
        The service account CSV file.
    .PARAMETER DomainName
        The build's domain.
    .EXAMPLE
        $badRows = @(Test-ServicePrincipalNamePlaceholder -CsvPath "$csvPath\serviceaccounts.csv" -DomainName $domainName)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$CsvPath,

        [Parameter(Mandatory, Position = 1)]
        [string]$DomainName
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Service account CSV not found at '$CsvPath'. Restore config\serviceaccounts.csv, or point the check at the right file."
    }
    try {
        $csvRows = @(Import-Csv -LiteralPath $CsvPath)
    } catch {
        throw "Service account CSV '$CsvPath' can't be read: $(Get-BuildProfileSingleLine -Text $_.Exception.Message)."
    }

    $rowNumber = 0
    foreach ($csvRow in $csvRows) {
        $rowNumber++
        $propertyNames = @($csvRow.PSObject.Properties.Name)
        if ($propertyNames -notcontains 'SPN') { continue }
        $servicePrincipalName = $csvRow.SPN
        if ([string]::IsNullOrWhiteSpace($servicePrincipalName)) { continue }
        $resolvedName = Resolve-ServicePrincipalName -ServicePrincipalName $servicePrincipalName -DomainName $DomainName
        if ($resolvedName -match '[{}]') {
            [pscustomobject]@{
                RowNumber                    = $rowNumber
                Name                         = $(if ($propertyNames -contains 'Name') { [string]$csvRow.Name } else { $null })
                ServicePrincipalName         = [string]$servicePrincipalName
                ResolvedServicePrincipalName = [string]$resolvedName
            }
        }
    }
}

function Test-ServicePrincipalNameDomain {
    <#
    .SYNOPSIS
        Returns the service account CSV rows whose literal SPN names a host in another
        domain.
    .DESCRIPTION
        An SPN with no {DomainName} placeholder is kept as written, which is right for a
        host outside the lab. A 1.0 CSV kept that way names lab.local hosts in whatever
        domain is built, so each row whose host is a DNS name of two or more labels that
        is neither the build's domain nor under it is returned, to WARN on. The host is
        the part after the service class and before any port or service name. A NetBIOS
        host, an IPv4 address and an SPN with a placeholder are never returned. Each row
        is a PSCustomObject with RowNumber (1 for the first row under the header), Name,
        ServicePrincipalName, HostName and SuggestedServicePrincipalName, the same SPN
        with the host's domain part written as {DomainName}. The rows are written to the
        pipeline one by one, so wrap the call in @() to count them.
        Throws when the file is missing or can't be read.
    .PARAMETER CsvPath
        The service account CSV file.
    .PARAMETER DomainName
        The build's domain.
    .EXAMPLE
        $otherDomainRows = @(Test-ServicePrincipalNameDomain -CsvPath $serviceAccountCsvPath -DomainName 'lab.test')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$CsvPath,

        [Parameter(Mandatory, Position = 1)]
        [string]$DomainName
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "Service account CSV not found at '$CsvPath'. Restore config\serviceaccounts.csv, or point the check at the right file."
    }
    try {
        $csvRows = @(Import-Csv -LiteralPath $CsvPath)
    } catch {
        throw "Service account CSV '$CsvPath' can't be read: $(Get-BuildProfileSingleLine -Text $_.Exception.Message)."
    }

    $ipv4Pattern = '\A(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\z'
    $rowNumber = 0
    foreach ($csvRow in $csvRows) {
        $rowNumber++
        $propertyNames = @($csvRow.PSObject.Properties.Name)
        if ($propertyNames -notcontains 'SPN') { continue }
        $servicePrincipalName = [string]$csvRow.SPN
        if ([string]::IsNullOrWhiteSpace($servicePrincipalName) -or $servicePrincipalName -match '[{}]') { continue }
        $spnMatch = [regex]::Match($servicePrincipalName, '\A([^/]+)/([^:/]+)(.*)\z')
        if (-not $spnMatch.Success) { continue }
        $hostName = $spnMatch.Groups[2].Value
        if ($hostName -match $ipv4Pattern) { continue }
        $hostLabels = $hostName.Split('.')
        if ($hostLabels.Count -lt 2) { continue }
        if ([string]::Equals($hostName, $DomainName, [System.StringComparison]::OrdinalIgnoreCase) -or
            $hostName.EndsWith(".$DomainName", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        [pscustomobject]@{
            RowNumber                    = $rowNumber
            Name                         = $(if ($propertyNames -contains 'Name') { [string]$csvRow.Name } else { $null })
            ServicePrincipalName         = $servicePrincipalName
            HostName                     = $hostName
            SuggestedServicePrincipalName = "$($spnMatch.Groups[1].Value)/$($hostLabels[0]).{DomainName}$($spnMatch.Groups[3].Value)"
        }
    }
}
#endregion
