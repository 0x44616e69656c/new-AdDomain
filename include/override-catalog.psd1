# new-AdDomain's override catalog: every setting overrides\overrides.psd1 can hold.
# include\OverrideFile.ps1 reads it, and OVERRIDE.md is generated from it, so a change
# here needs OVERRIDE.md generated again.
@{
    Project  = 'new-AdDomain'
    Settings = @{
        DomainName = @{
            Target        = 'Variable'
            Name          = 'domainName'
            Shipped       = 'lab.test'
            Rule          = @{ Type = 'External'; Description = 'Two or more labels of letters, digits and hyphens, 64 characters at most' }
            Summary       = 'The DNS name of the forest root domain the build creates'
            ShippedReason = 'RFC 2606 reserves .test for testing. Release 1.0 used lab.local, and RFC 6762 reserves .local for multicast DNS'
        }
        NetBIOSName = @{
            Target        = 'Variable'
            Name          = 'netBIOSName'
            Shipped       = 'LAB'
            Rule          = @{ Type = 'External'; Description = '1 to 15 letters, digits or hyphens, not digits only and not a reserved word. With DomainName set and NetBIOSName left out, the first label of DomainName, upper-cased, is used with a WARN' }
            Summary       = 'The NetBIOS name of the domain'
            ShippedReason = 'The first label of the shipped domain, upper-cased'
        }
        ForestMode = @{
            Target        = 'Variable'
            Name          = 'forestMode'
            Shipped       = 'WinThreshold'
            Rule          = @{ Type = 'External'; Description = 'WinThreshold or Win2025. Win2025 needs Server 2025 domain controllers' }
            Summary       = 'The forest functional level'
            ShippedReason = 'The highest level every supported Windows Server release can run'
        }
        DomainMode = @{
            Target        = 'Variable'
            Name          = 'domainMode'
            Shipped       = 'WinThreshold'
            Rule          = @{ Type = 'External'; Description = 'WinThreshold or Win2025, never lower than ForestMode. A lower one is raised with a WARN' }
            Summary       = 'The domain functional level'
            ShippedReason = 'The highest level every supported Windows Server release can run'
        }
        RequiredOSBuild = @{
            Target        = 'Variable'
            Name          = 'requiredOSBuild'
            Shipped       = 26100
            Rule          = @{ Type = 'External'; Description = 'A whole number. Below 17763 is raised to 17763, and below 26100 to 26100 when either level is Win2025, each with a WARN' }
            Summary       = 'The oldest Windows build script one runs on'
            ShippedReason = 'Server 2025 (build 26100) is the only tested release'
        }
        PrimarySiteName = @{
            Target        = 'Variable'
            Name          = 'primarySiteName'
            Shipped       = 'Lab-HQ'
            Rule          = @{ Type = 'External'; Description = '1 to 63 letters, digits or hyphens, starting with a letter or digit and not ending with a hyphen' }
            Summary       = 'The name of the AD site the DC is put in'
            ShippedReason = 'The shipped value since 1.0'
        }
        PrimarySubnet = @{
            Target        = 'Variable'
            Name          = 'primarySubnet'
            Shipped       = 'Auto'
            Rule          = @{ Type = 'External'; Description = 'Auto, or an IPv4 subnet in CIDR form with a prefix of 8 to 30, such as 192.168.159.0/24' }
            Summary       = 'The subnet given to the DC''s site'
            ShippedReason = 'Auto uses the subnet the DC''s own address sits in, the only value that is right on every host'
        }
        DnsForwarders = @{
            Target        = 'Variable'
            Name          = 'dnsForwarders'
            Shipped       = @('1.1.1.1', '8.8.8.8')
            Rule          = @{ Type = 'List'; ItemRule = @{ Type = 'String'; Pattern = '\A(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\z'; Description = 'an IPv4 address' } }
            Summary       = 'The DNS forwarders set on the DC'
            ValuesNote    = 'A single address is taken as a list of one'
            ShippedReason = 'Two public resolvers, Cloudflare''s and Google''s, the shipped value since 1.0'
        }
        NtpServers = @{
            Target        = 'Variable'
            Name          = 'ntpServers'
            Shipped       = @('time.windows.com')
            Rule          = @{ Type = 'List'; ItemRule = @{ Type = 'String'; Pattern = '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z'; Description = 'a host name or an IPv4 address' } }
            Summary       = 'The time servers the DC syncs from'
            ValuesNote    = 'A single name is taken as a list of one'
            ShippedReason = 'Microsoft''s public time server, the shipped value since 1.0'
        }
        WorkstationPrefix = @{
            Target        = 'Variable'
            Name          = 'workstationPrefix'
            Shipped       = 'WK'
            Rule          = @{ Type = 'String'; Pattern = '\A[A-Za-z0-9]{1,6}\z'; Description = '1 to 6 letters or digits' }
            Summary       = 'The name prefix of generated workstation computer objects'
            ShippedReason = 'The shipped value since 1.0'
        }
        ServerPrefix = @{
            Target        = 'Variable'
            Name          = 'serverPrefix'
            Shipped       = 'SRV'
            Rule          = @{ Type = 'String'; Pattern = '\A[A-Za-z0-9]{1,6}\z'; Description = '1 to 6 letters or digits' }
            Summary       = 'The name prefix of generated server computer objects'
            ShippedReason = 'The shipped value since 1.0'
        }
        LaptopPrefix = @{
            Target        = 'Variable'
            Name          = 'laptopPrefix'
            Shipped       = 'LAP'
            Rule          = @{ Type = 'String'; Pattern = '\A[A-Za-z0-9]{1,6}\z'; Description = '1 to 6 letters or digits' }
            Summary       = 'The name prefix of generated laptop computer objects'
            ShippedReason = 'The shipped value since 1.0'
        }
        CaCommonName = @{
            Target        = 'Variable'
            Name          = 'caCommonName'
            Shipped       = 'Lab-Root-CA'
            Rule          = @{ Type = 'String'; MinLength = 1; MaxLength = 64; Pattern = '\A[^"]*\z'; Description = '1 to 64 characters with no double quote' }
            Summary       = 'The common name of the Enterprise Root CA'
            ShippedReason = 'The shipped value since 1.0'
        }
        CaKeyLength = @{
            Target        = 'Variable'
            Name          = 'caKeyLength'
            Shipped       = 2048
            Rule          = @{ Type = 'Integer'; Allowed = @(2048, 3072, 4096) }
            Summary       = 'The CA key length, in bits'
            ShippedReason = 'The shipped value since 1.0'
        }
        CaHashAlgorithm = @{
            Target        = 'Variable'
            Name          = 'caHashAlgorithm'
            Shipped       = 'SHA256'
            Rule          = @{ Type = 'String'; Allowed = @('SHA256', 'SHA384', 'SHA512') }
            Summary       = 'The hash algorithm the CA signs with'
            ShippedReason = 'The shipped value since 1.0'
        }
        CaValidityYears = @{
            Target        = 'Variable'
            Name          = 'caValidityYears'
            Shipped       = 5
            Rule          = @{ Type = 'Integer'; Minimum = 1; Maximum = 20 }
            Summary       = 'How many years the CA certificate is valid'
            ShippedReason = 'The shipped value since 1.0'
        }
        CaDatabasePath = @{
            Target        = 'Variable'
            Name          = 'caDatabasePath'
            Shipped       = 'C:\Windows\system32\CertLog'
            Rule          = @{ Type = 'String'; Pattern = '\A[A-Za-z]:\\[^"<>|?*]*\z'; Description = 'an absolute local folder path, such as C:\Windows\system32\CertLog' }
            Summary       = 'The folder the CA database goes in'
            ShippedReason = 'The shipped value since 1.0'
        }
        CaLogPath = @{
            Target        = 'Variable'
            Name          = 'caLogPath'
            Shipped       = 'C:\Windows\system32\CertLog'
            Rule          = @{ Type = 'String'; Pattern = '\A[A-Za-z]:\\[^"<>|?*]*\z'; Description = 'an absolute local folder path, such as C:\Windows\system32\CertLog' }
            Summary       = 'The folder the CA log goes in'
            ShippedReason = 'The same folder as the CA database, which is fine for a lab'
        }
        MinPasswordLength = @{
            Target        = 'Variable'
            Name          = 'minPasswordLength'
            Shipped       = 14
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 128 }
            Summary       = 'The minimum password length in the domain password policy'
            ValuesNote    = '15 to 128 builds with 14 and a WARN, because the domain enforces at most 14 unless Relax minimum password length limits is enabled on every DC'
            ShippedReason = 'The most the domain enforces without that setting. Releases 1.0 and 2.0 shipped 15, which the domain enforced as 14'
        }
        PasswordHistoryCount = @{
            Target        = 'Variable'
            Name          = 'passwordHistoryCount'
            Shipped       = 24
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 24 }
            Summary       = 'How many old passwords the domain password policy remembers'
            ShippedReason = 'The shipped value since 1.0'
        }
        LockoutThreshold = @{
            Target        = 'Variable'
            Name          = 'lockoutThreshold'
            Shipped       = 5
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 999 }
            Summary       = 'Failed logons before an account locks, also used to lock the generated locked users'
            ShippedReason = 'The shipped value since 1.0'
        }
        LockoutDurationMinutes = @{
            Target        = 'Variable'
            Name          = 'lockoutDurationMinutes'
            Shipped       = 30
            Rule          = @{ Type = 'Integer'; Minimum = 1; Maximum = 99999 }
            Summary       = 'How many minutes a locked account stays locked'
            ShippedReason = 'The shipped value since 1.0'
        }
        MaxPasswordAgeDays = @{
            Target        = 'Variable'
            Name          = 'maxPasswordAgeDays'
            Shipped       = 90
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 999 }
            Summary       = 'The maximum password age in the domain password policy, in days'
            ShippedReason = 'The shipped value since 1.0'
        }
        UpnPattern = @{
            Target        = 'Variable'
            Name          = 'upnPattern'
            Shipped       = 'firstlast'
            Rule          = @{ Type = 'String'; MinLength = 1; Description = 'Any text. firstlast gives first.last, f_last gives f_last, and anything else gives the account name, each at the domain' }
            Summary       = 'The form of each generated user''s UPN'
            ShippedReason = 'firstlast can''t collide, because the generated display names are unique'
        }
        PctDisabled = @{
            Target        = 'Variable'
            Name          = 'pctDisabled'
            Shipped       = 5
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 100 }
            Summary       = 'The percentage of generated users that are disabled and moved to the DisabledUsers OU'
            ValuesNote    = 'The five user-state percentages must sum to 100 or less. Above that, the shipped ones you left alone are lowered with a WARN, and the run stops only when the ones you set sum above 100'
            ShippedReason = 'The shipped value since 1.0'
        }
        PctPwExpired = @{
            Target        = 'Variable'
            Name          = 'pctPwExpired'
            Shipped       = 5
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 100 }
            Summary       = 'The percentage of generated users that must change their password at the next logon'
            ValuesNote    = 'One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says'
            ShippedReason = 'The shipped value since 1.0'
        }
        PctPwNeverExpires = @{
            Target        = 'Variable'
            Name          = 'pctPwNeverExpires'
            Shipped       = 10
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 100 }
            Summary       = 'The percentage of generated users whose password never expires'
            ValuesNote    = 'One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says'
            ShippedReason = 'The shipped value since 1.0'
        }
        PctSmartcard = @{
            Target        = 'Variable'
            Name          = 'pctSmartcard'
            Shipped       = 3
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 100 }
            Summary       = 'The percentage of generated users that need a smart card to log on'
            ValuesNote    = 'One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says'
            ShippedReason = 'The shipped value since 1.0'
        }
        PctLocked = @{
            Target        = 'Variable'
            Name          = 'pctLocked'
            Shipped       = 2
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 100 }
            Summary       = 'The percentage of generated users that are locked out'
            ValuesNote    = 'One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says'
            ShippedReason = 'The shipped value since 1.0'
        }
        PctRemoteUsers = @{
            Target        = 'Variable'
            Name          = 'pctRemoteUsers'
            Shipped       = 30
            Rule          = @{ Type = 'Integer'; Minimum = 0; Maximum = 100 }
            Summary       = 'The percentage of generated users given a random city of their own. The rest share one city picked for the run'
            ShippedReason = 'The shipped value since 1.0'
        }
        MinCompanyCount = @{
            Target        = 'Variable'
            Name          = 'minCompanyCount'
            Shipped       = 1
            Rule          = @{ Type = 'Integer'; Minimum = 1; Maximum = 100 }
            Summary       = 'The fewest companies chosen for a run. Every generated user works for one of them'
            ValuesNote    = 'A value above MaxCompanyCount is used as MaxCompanyCount'
            ShippedReason = 'The shipped value since 1.0'
        }
        MaxCompanyCount = @{
            Target        = 'Variable'
            Name          = 'maxCompanyCount'
            Shipped       = 5
            Rule          = @{ Type = 'Integer'; Minimum = 1; Maximum = 100 }
            Summary       = 'The most companies chosen for a run, never more than config\companies.csv holds'
            ShippedReason = 'The shipped value since 1.0'
        }
        UserCount = @{
            Target        = 'Parameter'
            Name          = 'UserCount'
            Shipped       = 1000
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ShippedReason = 'The parameter''s default since 1.0'
        }
        GroupCount = @{
            Target        = 'Parameter'
            Name          = 'GroupCount'
            Shipped       = 50
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ShippedReason = 'The parameter''s default since 1.0'
        }
        ComputerCount = @{
            Target        = 'Parameter'
            Name          = 'ComputerCount'
            Shipped       = 0
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ShippedReason = 'The parameter''s default since 1.0, which creates no computer objects'
        }
        PasswordLength = @{
            Target        = 'Parameter'
            Name          = 'PasswordLength'
            Shipped       = 20
            ValuesNote    = 'A length below MinPasswordLength gives a WARN that generated passwords are shorter than the policy, and the build carries on'
            ShippedReason = 'The parameter''s default since 1.0'
        }
        MinGroupMembers = @{
            Target        = 'Parameter'
            Name          = 'MinGroupMembers'
            Shipped       = 2
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ValuesNote    = 'A value above MaxGroupMembers moves the one you didn''t set to the other''s value with a WARN, and stops the run only when you set both'
            ShippedReason = 'The parameter''s default since 1.0'
        }
        MaxGroupMembers = @{
            Target        = 'Parameter'
            Name          = 'MaxGroupMembers'
            Shipped       = 10
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ValuesNote    = 'A value below MinGroupMembers is handled as MinGroupMembers says'
            ShippedReason = 'The parameter''s default since 1.0'
        }
        MinDA = @{
            Target        = 'Parameter'
            Name          = 'MinDA'
            Shipped       = 2
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ValuesNote    = 'A value above MaxDA moves the one you didn''t set to the other''s value with a WARN, and stops the run only when you set both'
            ShippedReason = 'The parameter''s default since 1.0'
        }
        MaxDA = @{
            Target        = 'Parameter'
            Name          = 'MaxDA'
            Shipped       = 10
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ValuesNote    = 'A value below MinDA is handled as MinDA says'
            ShippedReason = 'The parameter''s default since 1.0'
        }
        MaxGroupNestingDepth = @{
            Target        = 'Parameter'
            Name          = 'MaxGroupNestingDepth'
            Shipped       = 3
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ShippedReason = 'The parameter''s default since 1.0'
        }
        RandomSeed = @{
            Target        = 'Parameter'
            Name          = 'RandomSeed'
            Shipped       = 0
            Rule          = @{ Type = 'Integer'; Minimum = 0 }
            ShippedReason = 'The parameter''s default since 1.0. 0 sets no seed, so each run differs'
        }
        DsrmPassword = @{
            Target        = 'Constant'
            Name          = 'dsrmPwDontDoThisInProd'
            Secret        = $true
            Rule          = @{ Type = 'String'; MinLength = 8; MaxLength = 127 }
            Summary       = 'The Directory Services Restore Mode password set when the DC is promoted'
            ValuesNote    = 'Install-ADDSForest''s own password rules apply on top'
            ShippedText   = 'the lab password set in New-ADForestDeployment.ps1'
            ShippedReason = 'A fixed lab password, so a build needs no input. Never use it outside a lab'
        }
    }
    Siblings = @{
        'build-lab'               = @('VmName', 'ComputerName', 'RamMB', 'CpuCount', 'DiskGB', 'NetworkType', 'SubnetMask', 'DefaultGateway', 'DnsServer', 'TimeoutMinutes', 'GuestReadyTimeoutMinutes', 'DeploymentTimeoutMinutes', 'MemberServerCount', 'MemberRamMB', 'MemberCpuCount', 'MemberDiskGB', 'DomainJoinTimeoutMinutes', 'VmBuilderScriptPath', 'AdDomainSourcePath', 'EnableEventLogging', 'MaxMemberServerCount')
        'New-VMwareWorkstationVM' = @('VmName', 'RamMB', 'CpuCount', 'DiskGB', 'ComputerName', 'TimeZone', 'Edition', 'NetworkType', 'SubnetMask', 'DefaultGateway', 'DnsServer', 'TimeoutMinutes', 'PostSetupDelayMinutes', 'ShutdownTimeoutMinutes', 'RestartTimeoutMinutes', 'LogPath', 'TempPath', 'ShowConsole', 'ProductKey', 'ImageNameStandard', 'ImageNameDatacenter', 'GuestOS', 'InputLocale', 'SystemLocale', 'UserLocale', 'Organization')
    }
    Document = @{
        NotCovered      = @(
            @{ Name = 'deployRoot'; Reason = 'The project folder, worked out from where global-config.ps1 sits' }
            @{ Name = 'logPath'; Reason = 'Derived from the project folder. A folder outside the project wouldn''t exist in the guest' }
            @{ Name = 'csvPath'; Reason = 'Derived from the project folder. Replace a CSV through overrides\config instead' }
            @{ Name = 'artifactsPath'; Reason = 'Derived from the project folder. A folder outside the project wouldn''t exist in the guest' }
            @{ Name = 'csvErrorLogPath'; Reason = 'Derived from the log folder' }
            @{ Name = 'forestName'; Reason = 'Always equal to DomainName, because the build creates a new forest root domain' }
            @{ Name = 'domainDN'; Reason = 'Derived from DomainName' }
            @{ Name = 'usersOU'; Reason = 'Derived from DomainName. It is OU=Employees, because an OU named Users collides with the built-in CN=Users container' }
            @{ Name = 'groupsOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'serversOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'workstationsOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'adminsOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'serviceAccountsOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'disabledUsersOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'quarantineOU'; Reason = 'Derived from DomainName' }
            @{ Name = 'scheduledTaskName'; Reason = 'Script two removes its logon task by this name, so a change between the two scripts would leave the old task behind' }
            @{ Name = 'globalConfigVersion'; Reason = 'Names the release of global-config.ps1 for the scripts'' version check. It isn''t a setting' }
            @{ Name = 'requiredPSVersion'; Reason = 'What script one needs to run. It isn''t a setting' }
            @{ Name = 'CreateScheduledTask'; Reason = 'A parameter of script one, chosen for each run' }
            @{ Name = 'NonInteractive'; Reason = 'A parameter of script one, chosen for each run' }
            @{ Name = 'StaticIpAddress'; Reason = 'A parameter of script one, given for each server' }
            @{ Name = 'PrefixLength'; Reason = 'A parameter of script one, given for each server' }
            @{ Name = 'DefaultGateway'; Reason = 'A parameter of script one, given for each server' }
            @{ Name = 'AdapterName'; Reason = 'A parameter of script one, given for each server' }
        )
        CsvReplacements = @(
            @{ File = 'first.csv'; Holds = 'The first names users are built from'; Headers = @('FirstName') }
            @{ File = 'last.csv'; Holds = 'The last names users are built from'; Headers = @('LastName') }
            @{ File = 'words.csv'; Holds = 'The words group names are built from'; Headers = @('Word') }
            @{ File = 'departments.csv'; Holds = 'The departments users are given'; Headers = @('Department') }
            @{ File = 'titles.csv'; Holds = 'The job titles users are given'; Headers = @('Title') }
            @{ File = 'offices.csv'; Holds = 'The offices users are given'; Headers = @('Office') }
            @{ File = 'cities.csv'; Holds = 'The cities and states users are given'; Headers = @('City', 'State') }
            @{ File = 'companies.csv'; Holds = 'The companies a run chooses from'; Headers = @('Company') }
            @{ File = 'streets.csv'; Holds = 'The street names in user addresses'; Headers = @('Street') }
            @{ File = 'computers.csv'; Holds = 'The seeds computer object names are built from'; Headers = @('Seed') }
            @{ File = 'serviceaccounts.csv'; Holds = 'The service accounts and their SPNs. Write an SPN host as host.{DomainName} so it follows the domain'; Headers = @('Name', 'Description', 'SPN') }
        )
        Security        = @(
            'In a build-lab run the whole project folder, the overrides folder and DsrmPassword included, is copied into the guest and stays at `C:\temp\new-AdDomain` on the DC after the build'
            'A standalone run reads the file where it is, on the server you run the scripts on'
        )
        BuildProfile    = @{ Script = 'include\BuildProfile.ps1' }
    }
}
