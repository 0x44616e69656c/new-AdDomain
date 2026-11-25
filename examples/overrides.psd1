# Example override file for new-AdDomain. Each release generates it from
# include\override-catalog.psd1 and replaces it, so don't edit it here.
#
# No run reads this file. To use it, copy the lines you need into the @{ } of
# overrides\overrides.psd1 in the project folder, or copy this whole file there.
# Then remove the # in front of each setting you want to change and set your value.
# Leave the others commented out, because a setting you uncomment counts as one you
# chose, even at its shipped value. A setting left commented out keeps its shipped
# value, and follows that value when a later release changes it.
#
# Every value shown is the shipped one, so a copy left as it is changes nothing.
# A setting shown with no value has no default that can be written here. Give it
# a value before you remove its #, or the run stops.
#
# OVERRIDE.md lists the values each setting accepts, why it ships as it does, and
# what else can set it. Save the file as UTF-8 with a BOM if you add non-ASCII text.

@{
    # The common name of the Enterprise Root CA.
    # CaCommonName = 'Lab-Root-CA'

    # The folder the CA database goes in.
    # CaDatabasePath = 'C:\Windows\system32\CertLog'

    # The hash algorithm the CA signs with.
    # CaHashAlgorithm = 'SHA256'

    # The CA key length, in bits.
    # CaKeyLength = 2048

    # The folder the CA log goes in.
    # CaLogPath = 'C:\Windows\system32\CertLog'

    # How many years the CA certificate is valid.
    # CaValidityYears = 5

    # How many computer objects script two creates.
    # ComputerCount = 0

    # The DNS forwarders set on the DC.
    # DnsForwarders = @('1.1.1.1', '8.8.8.8')

    # How many generated users are added to Domain Admins.
    # Shipped default, in words. Random, a count from MinDA to MaxDA.
    # DomainAdminCount =

    # The domain functional level.
    # DomainMode = 'WinThreshold'

    # The DNS name of the forest root domain the build creates.
    # DomainName = 'lab.test'

    # The Directory Services Restore Mode password set when the DC is promoted.
    # Secret. Its shipped value is never shown.
    # DsrmPassword =

    # The forest functional level.
    # ForestMode = 'WinThreshold'

    # How many groups script two creates before nesting them.
    # GroupCount = 50

    # The name prefix of generated laptop computer objects.
    # LaptopPrefix = 'LAP'

    # How many minutes a locked account stays locked.
    # LockoutDurationMinutes = 30

    # Failed logons before an account locks, also used to lock the generated locked users.
    # LockoutThreshold = 5

    # The most companies chosen for a run, never more than config\companies.csv holds.
    # MaxCompanyCount = 5

    # The most generated users added to Domain Admins.
    # MaxDA = 10

    # The most members each generated group gets.
    # MaxGroupMembers = 10

    # The deepest group-in-group nesting.
    # MaxGroupNestingDepth = 3

    # The maximum password age in the domain password policy, in days.
    # MaxPasswordAgeDays = 90

    # The fewest companies chosen for a run. Every generated user works for one of them.
    # MinCompanyCount = 1

    # The fewest generated users added to Domain Admins.
    # MinDA = 2

    # The fewest members each generated group gets.
    # MinGroupMembers = 2

    # The minimum password length in the domain password policy, capped at 14.
    # MinPasswordLength = 14

    # The NetBIOS name of the domain.
    # NetBIOSName = 'LAB'

    # The time servers the DC syncs from.
    # NtpServers = @('time.windows.com')

    # How many old passwords the domain password policy remembers.
    # PasswordHistoryCount = 24

    # The length of each generated password.
    # PasswordLength = 20

    # The percentage of generated users that are disabled and moved to the DisabledUsers OU.
    # PctDisabled = 5

    # The percentage of generated users that are locked out.
    # PctLocked = 2

    # The percentage of generated users that must change their password at the next logon.
    # PctPwExpired = 5

    # The percentage of generated users whose password never expires.
    # PctPwNeverExpires = 10

    # The percentage of generated users given a random city of their own. The rest share one city picked for the run.
    # PctRemoteUsers = 30

    # The percentage of generated users that need a smart card to log on.
    # PctSmartcard = 3

    # How much lab data script two creates.
    # Population = 'Full'

    # The name of the AD site the DC is put in.
    # PrimarySiteName = 'Lab-HQ'

    # The subnet given to the DC's site.
    # PrimarySubnet = 'Auto'

    # The seed for the random draws, so a population can be repeated.
    # RandomSeed = 0

    # The oldest Windows build script one runs on.
    # RequiredOSBuild = 26100

    # The name prefix of generated server computer objects.
    # ServerPrefix = 'SRV'

    # The form of each generated user's UPN.
    # UpnPattern = 'firstlast'

    # How many users script two creates.
    # UserCount = 1000

    # The name prefix of generated workstation computer objects.
    # WorkstationPrefix = 'WK'
}
