# Overrides

This file is generated from `include\override-catalog.psd1`. Don't edit it. A change goes in the catalog, and this file is generated again.

## Where the file goes

Put your settings in `overrides\overrides.psd1` in the project folder. Git ignores that folder, so an upgrade never touches it. The file is a PowerShell data file holding one hashtable of constant values. Each value is a quoted string, a number, `$true`, `$false` or a list of those. Save it as UTF-8 with a BOM when it holds non-ASCII text. A key you leave out takes its shipped value.

For example, with settings at their shipped values:

```powershell
@{
    CaCommonName = 'Lab-Root-CA'
    CaDatabasePath = 'C:\Windows\system32\CertLog'
}
```

To make the file from an older copy of the project, see [UPGRADE.md](UPGRADE.md).

## Precedence

A value given on the command line wins. Without one, a build profile's value applies, for the keys whose row says a profile sets them. Without that, the override file's value applies, and without that, the shipped value. A command-line value that differs from the override file's is logged as INFO.

## What a run logs

With no override file, a run logs one INFO line saying so, and the shipped settings apply. With one, it logs one INFO line naming the file, its SHA-256 and each setting it applied, with secret values shown as `<set>`. A key left empty gives a WARN, and its shipped value applies. A run stops when the file can't be read, holds a value that isn't a constant, holds an unknown key, or holds a value outside a key's permitted values.

## Settings

| Key | What it changes | How to override | Default | Permitted values | Why this default | Secret |
|---|---|---|---|---|---|---|
| `CaCommonName` | The common name of the Enterprise Root CA. | `overrides\overrides.psd1`, key `CaCommonName`. | `Lab-Root-CA` | 1 to 64 characters with no double quote. | The shipped value since 1.0. | no |
| `CaDatabasePath` | The folder the CA database goes in. | `overrides\overrides.psd1`, key `CaDatabasePath`. | `C:\Windows\system32\CertLog` | An absolute local folder path, such as C:\Windows\system32\CertLog. | The shipped value since 1.0. | no |
| `CaHashAlgorithm` | The hash algorithm the CA signs with. | `overrides\overrides.psd1`, key `CaHashAlgorithm`. | `SHA256` | One of SHA256, SHA384, SHA512. | The shipped value since 1.0. | no |
| `CaKeyLength` | The CA key length, in bits. | `overrides\overrides.psd1`, key `CaKeyLength`. | 2048 | One of 2048, 3072, 4096. | The shipped value since 1.0. | no |
| `CaLogPath` | The folder the CA log goes in. | `overrides\overrides.psd1`, key `CaLogPath`. | `C:\Windows\system32\CertLog` | An absolute local folder path, such as C:\Windows\system32\CertLog. | The same folder as the CA database, which is fine for a lab. | no |
| `CaValidityYears` | How many years the CA certificate is valid. | `overrides\overrides.psd1`, key `CaValidityYears`. | 5 | A whole number from 1 to 20. | The shipped value since 1.0. | no |
| `ComputerCount` | The default of `-ComputerCount`, described in the README and the script's help. | `overrides\overrides.psd1`, key `ComputerCount`. `-ComputerCount` on the command line also sets it, and the command line wins. | 0 | A whole number of 0 or more. | The parameter's default since 1.0, which creates no computer objects. | no |
| `DnsForwarders` | The DNS forwarders set on the DC. | `overrides\overrides.psd1`, key `DnsForwarders`. | `1.1.1.1`, `8.8.8.8` | A list of 1 or more items, each an IPv4 address. A single address is taken as a list of one. | Two public resolvers, Cloudflare's and Google's, the shipped value since 1.0. | no |
| `DomainMode` | The domain functional level. | `overrides\overrides.psd1`, key `DomainMode`. A build profile also sets it, and the profile wins. | `WinThreshold` | WinThreshold or Win2025, never lower than ForestMode. A lower one is raised with a WARN. | The highest level every supported Windows Server release can run. | no |
| `DomainName` | The DNS name of the forest root domain the build creates. | `overrides\overrides.psd1`, key `DomainName`. A build profile also sets it, and the profile wins. | `lab.test` | Two or more labels of letters, digits and hyphens, 64 characters at most. | RFC 2606 reserves .test for testing. Release 1.0 used lab.local, and RFC 6762 reserves .local for multicast DNS. | no |
| `DsrmPassword` | The Directory Services Restore Mode password set when the DC is promoted. | `overrides\overrides.psd1`, key `DsrmPassword`. | the lab password set in New-ADForestDeployment.ps1 | Text of 8 to 127 characters. Install-ADDSForest's own password rules apply on top. | A fixed lab password, so a build needs no input. Never use it outside a lab. | yes |
| `ForestMode` | The forest functional level. | `overrides\overrides.psd1`, key `ForestMode`. A build profile also sets it, and the profile wins. | `WinThreshold` | WinThreshold or Win2025. Win2025 needs Server 2025 domain controllers. | The highest level every supported Windows Server release can run. | no |
| `GroupCount` | The default of `-GroupCount`, described in the README and the script's help. | `overrides\overrides.psd1`, key `GroupCount`. `-GroupCount` on the command line also sets it, and the command line wins. | 50 | A whole number of 0 or more. | The parameter's default since 1.0. | no |
| `LaptopPrefix` | The name prefix of generated laptop computer objects. | `overrides\overrides.psd1`, key `LaptopPrefix`. | `LAP` | 1 to 6 letters or digits. | The shipped value since 1.0. | no |
| `LockoutDurationMinutes` | How many minutes a locked account stays locked. | `overrides\overrides.psd1`, key `LockoutDurationMinutes`. | 30 | A whole number from 1 to 99999. | The shipped value since 1.0. | no |
| `LockoutThreshold` | Failed logons before an account locks, also used to lock the generated locked users. | `overrides\overrides.psd1`, key `LockoutThreshold`. | 5 | A whole number from 0 to 999. | The shipped value since 1.0. | no |
| `MaxCompanyCount` | The most companies chosen for a run, never more than config\companies.csv holds. | `overrides\overrides.psd1`, key `MaxCompanyCount`. | 5 | A whole number from 1 to 100. | The shipped value since 1.0. | no |
| `MaxDA` | The default of `-MaxDA`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MaxDA`. `-MaxDA` on the command line also sets it, and the command line wins. | 10 | A whole number of 0 or more. A value below MinDA is handled as MinDA says. | The parameter's default since 1.0. | no |
| `MaxGroupMembers` | The default of `-MaxGroupMembers`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MaxGroupMembers`. `-MaxGroupMembers` on the command line also sets it, and the command line wins. | 10 | A whole number of 0 or more. A value below MinGroupMembers is handled as MinGroupMembers says. | The parameter's default since 1.0. | no |
| `MaxGroupNestingDepth` | The default of `-MaxGroupNestingDepth`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MaxGroupNestingDepth`. `-MaxGroupNestingDepth` on the command line also sets it, and the command line wins. | 3 | A whole number of 0 or more. | The parameter's default since 1.0. | no |
| `MaxPasswordAgeDays` | The maximum password age in the domain password policy, in days. | `overrides\overrides.psd1`, key `MaxPasswordAgeDays`. | 90 | A whole number from 0 to 999. | The shipped value since 1.0. | no |
| `MinCompanyCount` | The fewest companies chosen for a run. Every generated user works for one of them. | `overrides\overrides.psd1`, key `MinCompanyCount`. | 1 | A whole number from 1 to 100. A value above MaxCompanyCount is used as MaxCompanyCount. | The shipped value since 1.0. | no |
| `MinDA` | The default of `-MinDA`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MinDA`. `-MinDA` on the command line also sets it, and the command line wins. | 2 | A whole number of 0 or more. A value above MaxDA moves the one you didn't set to the other's value with a WARN, and stops the run only when you set both. | The parameter's default since 1.0. | no |
| `MinGroupMembers` | The default of `-MinGroupMembers`, described in the README and the script's help. | `overrides\overrides.psd1`, key `MinGroupMembers`. `-MinGroupMembers` on the command line also sets it, and the command line wins. | 2 | A whole number of 0 or more. A value above MaxGroupMembers moves the one you didn't set to the other's value with a WARN, and stops the run only when you set both. | The parameter's default since 1.0. | no |
| `MinPasswordLength` | The minimum password length in the domain password policy. | `overrides\overrides.psd1`, key `MinPasswordLength`. | 14 | A whole number from 0 to 128. 15 to 128 builds with 14 and a WARN, because the domain enforces at most 14 unless Relax minimum password length limits is enabled on every DC. | The most the domain enforces without that setting. Releases 1.0 and 2.0 shipped 15, which the domain enforced as 14. | no |
| `NetBIOSName` | The NetBIOS name of the domain. | `overrides\overrides.psd1`, key `NetBIOSName`. A build profile also sets it, and the profile wins. | `LAB` | 1 to 15 letters, digits or hyphens, not digits only and not a reserved word. With DomainName set and NetBIOSName left out, the first label of DomainName, upper-cased, is used with a WARN. | The first label of the shipped domain, upper-cased. | no |
| `NtpServers` | The time servers the DC syncs from. | `overrides\overrides.psd1`, key `NtpServers`. | `time.windows.com` | A list of 1 or more items, each a host name or an IPv4 address. A single name is taken as a list of one. | Microsoft's public time server, the shipped value since 1.0. | no |
| `PasswordHistoryCount` | How many old passwords the domain password policy remembers. | `overrides\overrides.psd1`, key `PasswordHistoryCount`. | 24 | A whole number from 0 to 24. | The shipped value since 1.0. | no |
| `PasswordLength` | The default of `-PasswordLength`, described in the README and the script's help. | `overrides\overrides.psd1`, key `PasswordLength`. `-PasswordLength` on the command line also sets it, and the command line wins. | 20 | A whole number from 4 to 94. A length below MinPasswordLength gives a WARN that generated passwords are shorter than the policy, and the build carries on. | The parameter's default since 1.0. | no |
| `PctDisabled` | The percentage of generated users that are disabled and moved to the DisabledUsers OU. | `overrides\overrides.psd1`, key `PctDisabled`. | 5 | A whole number from 0 to 100. The five user-state percentages must sum to 100 or less. Above that, the shipped ones you left alone are lowered with a WARN, and the run stops only when the ones you set sum above 100. | The shipped value since 1.0. | no |
| `PctLocked` | The percentage of generated users that are locked out. | `overrides\overrides.psd1`, key `PctLocked`. | 2 | A whole number from 0 to 100. One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says. | The shipped value since 1.0. | no |
| `PctPwExpired` | The percentage of generated users that must change their password at the next logon. | `overrides\overrides.psd1`, key `PctPwExpired`. | 5 | A whole number from 0 to 100. One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says. | The shipped value since 1.0. | no |
| `PctPwNeverExpires` | The percentage of generated users whose password never expires. | `overrides\overrides.psd1`, key `PctPwNeverExpires`. | 10 | A whole number from 0 to 100. One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says. | The shipped value since 1.0. | no |
| `PctRemoteUsers` | The percentage of generated users given a random city of their own. The rest share one city picked for the run. | `overrides\overrides.psd1`, key `PctRemoteUsers`. | 30 | A whole number from 0 to 100. | The shipped value since 1.0. | no |
| `PctSmartcard` | The percentage of generated users that need a smart card to log on. | `overrides\overrides.psd1`, key `PctSmartcard`. | 3 | A whole number from 0 to 100. One of the five user-state percentages, which must sum to 100 or less, as PctDisabled says. | The shipped value since 1.0. | no |
| `PrimarySiteName` | The name of the AD site the DC is put in. | `overrides\overrides.psd1`, key `PrimarySiteName`. A build profile also sets it, and the profile wins. | `Lab-HQ` | 1 to 63 letters, digits or hyphens, starting with a letter or digit and not ending with a hyphen. | The shipped value since 1.0. | no |
| `PrimarySubnet` | The subnet given to the DC's site. | `overrides\overrides.psd1`, key `PrimarySubnet`. A build profile also sets it, and the profile wins. | `Auto` | Auto, or an IPv4 subnet in CIDR form with a prefix of 8 to 30, such as 192.168.159.0/24. | Auto uses the subnet the DC's own address sits in, the only value that is right on every host. | no |
| `RandomSeed` | The default of `-RandomSeed`, described in the README and the script's help. | `overrides\overrides.psd1`, key `RandomSeed`. `-RandomSeed` on the command line also sets it, and the command line wins. | 0 | A whole number of 0 or more. | The parameter's default since 1.0. 0 sets no seed, so each run differs. | no |
| `RequiredOSBuild` | The oldest Windows build script one runs on. | `overrides\overrides.psd1`, key `RequiredOSBuild`. A build profile also sets it, and the profile wins. | 26100 | A whole number. Below 17763 is raised to 17763, and below 26100 to 26100 when either level is Win2025, each with a WARN. | Server 2025 (build 26100) is the only tested release. | no |
| `ServerPrefix` | The name prefix of generated server computer objects. | `overrides\overrides.psd1`, key `ServerPrefix`. | `SRV` | 1 to 6 letters or digits. | The shipped value since 1.0. | no |
| `UpnPattern` | The form of each generated user's UPN. | `overrides\overrides.psd1`, key `UpnPattern`. | `firstlast` | Any text. firstlast gives first.last, f_last gives f_last, and anything else gives the account name, each at the domain. | firstlast can't collide, because the generated display names are unique. | no |
| `UserCount` | The default of `-UserCount`, described in the README and the script's help. | `overrides\overrides.psd1`, key `UserCount`. `-UserCount` on the command line also sets it, and the command line wins. | 1000 | A whole number of 0 or more. | The parameter's default since 1.0. | no |
| `WorkstationPrefix` | The name prefix of generated workstation computer objects. | `overrides\overrides.psd1`, key `WorkstationPrefix`. | `WK` | 1 to 6 letters or digits. | The shipped value since 1.0. | no |

## Build profile

A build profile, `include\build-profile.psd1`, sets the keys below for one build, and wins over the override file. How to use one is in the README. A key the profile leaves out takes the override file's value, then the shipped value, with one INFO line. An empty key falls back the same way, with a WARN.

The keys a build profile takes, each with its permitted values under [Settings](#settings):

- [`DomainMode`](#settings)
- [`DomainName`](#settings)
- [`ForestMode`](#settings)
- [`NetBIOSName`](#settings)
- [`PrimarySiteName`](#settings)
- [`PrimarySubnet`](#settings)
- [`RequiredOSBuild`](#settings)

A build profile refuses these keys until their feature exists, so that a profile never looks as if it did something the build didn't:

- `BuildName`
- `CertificateAuthority`
- `DomainAdminCount`
- `Machines`
- `Population`
- `RandomSeed`
- `Trusts`
- `VirtualNetwork`

## Retired keys

None.

## CSV replacements

A file at `overrides\config\<name>.csv` replaces `config\<name>.csv` whole, for every script that reads it. A replaced file no longer receives later shipped changes to that file.

| File | What it holds | Required headers |
|---|---|---|
| `cities.csv` | The cities and states users are given. | `City`, `State` |
| `companies.csv` | The companies a run chooses from. | `Company` |
| `computers.csv` | The seeds computer object names are built from. | `Seed` |
| `departments.csv` | The departments users are given. | `Department` |
| `first.csv` | The first names users are built from. | `FirstName` |
| `last.csv` | The last names users are built from. | `LastName` |
| `offices.csv` | The offices users are given. | `Office` |
| `serviceaccounts.csv` | The service accounts and their SPNs. Write an SPN host as host.{DomainName} so it follows the domain. | `Name`, `Description`, `SPN` |
| `streets.csv` | The street names in user addresses. | `Street` |
| `titles.csv` | The job titles users are given. | `Title` |
| `words.csv` | The words group names are built from. | `Word` |

## Not covered

These can't be set in the override file.

| Setting | Why it isn't covered |
|---|---|
| `AdapterName` | A parameter of script one, given for each server. |
| `CreateScheduledTask` | A parameter of script one, chosen for each run. |
| `DefaultGateway` | A parameter of script one, given for each server. |
| `NonInteractive` | A parameter of script one, chosen for each run. |
| `PrefixLength` | A parameter of script one, given for each server. |
| `StaticIpAddress` | A parameter of script one, given for each server. |
| `adminsOU` | Derived from DomainName. |
| `artifactsPath` | Derived from the project folder. A folder outside the project wouldn't exist in the guest. |
| `csvErrorLogPath` | Derived from the log folder. |
| `csvPath` | Derived from the project folder. Replace a CSV through overrides\config instead. |
| `deployRoot` | The project folder, worked out from where global-config.ps1 sits. |
| `disabledUsersOU` | Derived from DomainName. |
| `domainDN` | Derived from DomainName. |
| `forestName` | Always equal to DomainName, because the build creates a new forest root domain. |
| `globalConfigVersion` | Names the release of global-config.ps1 for the scripts' version check. It isn't a setting. |
| `groupsOU` | Derived from DomainName. |
| `logPath` | Derived from the project folder. A folder outside the project wouldn't exist in the guest. |
| `quarantineOU` | Derived from DomainName. |
| `requiredPSVersion` | What script one needs to run. It isn't a setting. |
| `scheduledTaskName` | Script two removes its logon task by this name, so a change between the two scripts would leave the old task behind. |
| `serversOU` | Derived from DomainName. |
| `serviceAccountsOU` | Derived from DomainName. |
| `usersOU` | Derived from DomainName. It is OU=Employees, because an OU named Users collides with the built-in CN=Users container. |
| `workstationsOU` | Derived from DomainName. |

## Security

Secret values sit in plain text in `overrides\overrides.psd1` on disk, and are masked only in logs. In a build-lab run the whole project folder, the overrides folder and DsrmPassword included, is copied into the guest and stays at `C:\temp\new-AdDomain` on the DC after the build. A standalone run reads the file where it is, on the server you run the scripts on.

## Other projects

Each lab project documents its own overrides:

- [New-VMwareWorkstationVM](https://github.com/0x44616e69656c/New-VMwareWorkstationVM/blob/main/OVERRIDE.md)
- [build-lab](https://github.com/0x44616e69656c/build-lab/blob/main/OVERRIDE.md)
