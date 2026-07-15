# new-AdDomain

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE.svg)](https://learn.microsoft.com/powershell/)
[![Platform: Windows Server 2025](https://img.shields.io/badge/Platform-Windows%20Server%202025-0078D6.svg)](https://www.microsoft.com/windows-server)

Stands up a fresh Windows Server 2025 Active Directory forest and fills it with realistic-looking users, groups, computers, service accounts, GPOs, and a certificate authority. Built for labs, demos, red-team ranges, and SIEM testing, not for production.

This came out of a need to build a domain that looks lived-in for testing, and I did not want to click through the promotion wizard and then build users, groups, computers, etc. I wanted a solution that did not have any requirements not already built into Windows (Ansible etc.) This does all that and more with PowerShell 5.1.

## What It Does

Two scripts run in sequence, split by the promotion reboot. Everything that has to happen before the box is a domain controller lives in script one. Everything that needs a running DC lives in script two.

1. **`New-ADForestDeployment.ps1`** (run as local Administrator, pre-domain). Runs pre-flight checks, sets a static IP on the wired NIC, installs AD DS / DNS / management tools, promotes the server as a new forest root DC, optionally registers a scheduled task to auto-run script two, then reboots.
2. **`Initialize-ADDirectory.ps1`** (run as Domain Administrator, post-promotion). Enables the AD Recycle Bin, deploys an Enterprise Root CA, sets DNS forwarders and time sync, validates the firewall, builds the OU tree, then populates users, groups (with nesting), computers, service accounts, GPOs, password policy, and a site topology. Finishes with functional tests and CSV/JSON artifacts.

Script two does not run on its own. The scheduled task uses an **at-logon** trigger, so directory population starts the next time an Administrator logs into the DC after the reboot. Script one prints a red banner reminding you of exactly that. If you skip `-CreateScheduledTask`, you will need to run script two by hand after the reboot.

Domain identity (`lab.local` / `LAB` out of the box) lives in one place: [include/global-config.ps1](include/global-config.ps1). Both scripts read it. Edit it there to build a different domain. More configuration notes are found in the Configuration Notes section of this document.

## Screenshots

### Script one -- `New-ADForestDeployment.ps1`

1. **Feature installation.** Installing AD DS, DNS, and management tools before promotion.

![Console output showing Windows feature installation progress](images/s1_1.jpg)

2. **Forest promotion begins.** `Install-ADDSForest` validating prerequisites for the new forest root domain.

![Console output showing Install-ADDSForest validating environment and user input](images/s1_2.jpg)

3. **Promotion in progress.** The DNS delegation warning is expected for a new forest root with no parent zone; no action needed.

![Console output showing forest installation starting, with an expected DNS delegation warning](images/s1_3.jpg)

### Script two -- `Initialize-ADDirectory.ps1`

4. **Post-promotion pre-flight.** Confirms core AD services are running, saves the dcdiag/repadmin reports, and enables the Recycle Bin.

![Console output showing service readiness checks and AD Recycle Bin being enabled](images/s2_1.jpg)

5. **CA, firewall check, and OU structure.** Enterprise Root CA deployed, then `Test-FirewallRules` validates DC/CA ports -- the WARN lines are informational, since the function only validates and does not create rules. CSV validation and OU creation follow.

![Console output showing Enterprise Root CA deployment, firewall rule verification, and OU creation](images/s2_2.jpg)

6. **Populating the directory.** Group creation finishes at 50, then user creation runs toward the configured count.

![Console output showing group creation complete and user creation progress](images/s2_3.jpg)

7. **Wrap-up and functional tests.** Service accounts, GPOs, password policy, and site topology configured; functional tests confirm the build.

![Console output showing service account creation, GPO deployment, and functional test results](images/s2_4.jpg)

### Result, in Active Directory Users and Computers

8. **Employees OU.** Users created by script two.

![Active Directory Users and Computers showing the Employees OU populated with generated users](images/ad_1.jpg)

9. **Groups OU.** A mix of security and distribution groups.

![Active Directory Users and Computers showing the Groups OU populated with generated groups](images/ad_2.jpg)

10. **Nested group membership.** A group nested inside another group, alongside individual user members.

![Group properties dialog showing another group and two users as members](images/ad_3.jpg)

11. **DisabledUsers OU.** Users moved here by the user-state randomization pass.

![Active Directory Users and Computers showing the DisabledUsers OU populated with disabled accounts](images/ad_4.jpg)

### Artifacts

12. **Functional test results.** `test-results-<timestamp>.csv`, one PASS/FAIL row per check -- LDAP query, DNS resolution, Domain Admins membership, CA status, and more.

![Functional test results CSV opened in a text editor, showing PASS rows for each check](images/log_1.jpg)

13. **User export.** `users-<timestamp>.csv`. As noted below, this file carries the beautiful plaintext password generated for each user. This is a lab, so this should be OK, but treat it accordingly.

![Users CSV opened in a text editor, showing generated user attributes and plaintext passwords](images/log_2.jpg)

## Requirements

- **Windows Server 2025** (build 26100 or later). Script one refuses to run on anything older. All PowerShell modules used should be available as far back as Windows 2016. Domain Level is 2016. If you want to use an earlier version, change `$requiredOSBuild` in the config file. I have only tested on Server 2025.
- **PowerShell 5.1.** PowerShell 7 is not supported or tested. Without extra work it will not run, because both scripts depend on Windows PowerShell only modules. The scheduled task and both scripts assume `powershell.exe`.
- **Local Administrator** rights for script one; **Domain Administrator** rights for script two.
- **A clean server.** No existing AD DS role, no AD CS role, not already domain-joined, and the target domain name must not already resolve in DNS. Script one checks all of this and stops if any of it is true.

AD CS is deliberately left out of script one. `Install-ADDSForest` will not promote a server that already has Certificate Server installed, so the CA role goes in post-promotion inside script two.

The RSAT AD tools and GPMC that script two needs are installed by script one during the feature step, so you do not have to add them yourself.

## Tested On

- **Windows Server 2025 (build 26100).** Promotion through full directory population, run end to end on a live VM.

The unattended path (`-NonInteractive` with supplied network parameters) exists so an outside orchestrator can drive script one over VMware guest operations without a console to prompt at. That orchestration script is not part of this repo. I have another project that does this.

## Quick Start

Clone the repository:

```powershell
git clone https://github.com/0x44616e69656c/new-AdDomain.git
cd new-AdDomain
```

Edit [include/global-config.ps1](include/global-config.ps1) if you want something other than `lab.local` / `LAB`, then run script one from an elevated prompt on a clean Server 2025 box:

```powershell
.\New-ADForestDeployment.ps1 -CreateScheduledTask
```

It promotes the DC and reboots. After the reboot, log in as Administrator. The scheduled task fires and script two builds out the directory. Expect a few minutes for promotion and a bit longer for AD object population.

Prefer to keep the two steps separate? Drop `-CreateScheduledTask`, let the box reboot, then run script two yourself:

```powershell
.\Initialize-ADDirectory.ps1
```

## Full Example

Unattended promotion where the adapter came up on DHCP and you want to pin a static address without any prompts:

```powershell
.\New-ADForestDeployment.ps1 -CreateScheduledTask -NonInteractive `
    -StaticIpAddress '192.168.1.50' -PrefixLength 24 -DefaultGateway '192.168.1.1'
```

A smaller, reproducible population with computer objects included:

```powershell
.\Initialize-ADDirectory.ps1 -UserCount 500 -GroupCount 25 -ComputerCount 100 -RandomSeed 42
```

`-RandomSeed` fixes the randomness so two runs produce the same directory. Handy when you need a lab that rebuilds identically.

## Parameters

### `New-ADForestDeployment.ps1`

| Parameter | Default | Notes |
|---|---|---|
| `-CreateScheduledTask` | switch | Registers the at-logon task so script two auto-runs after the reboot. |
| `-NonInteractive` | switch | Never prompts. Any code path that would call `Read-Host` throws a clear error instead. For console-less unattended runs. |
| `-StaticIpAddress` | none | Static IP to apply when the selected adapter is found on DHCP. Required with `-NonInteractive` in that case. |
| `-PrefixLength` | none | Subnet prefix length, 1-32. Required alongside `-StaticIpAddress` under `-NonInteractive`. |
| `-DefaultGateway` | none | Default gateway. Required alongside `-StaticIpAddress` under `-NonInteractive`. |
| `-AdapterName` | none | Selects the wired NIC by name when more than one eligible adapter is present. Required under `-NonInteractive` when the choice is ambiguous. |

### `Initialize-ADDirectory.ps1`

| Parameter | Default | Notes |
|---|---|---|
| `-UserCount` | `1000` | Number of users to create. |
| `-GroupCount` | `50` | Number of groups to create before nesting. |
| `-ComputerCount` | `0` | Computer objects to create. `0` skips computer creation. |
| `-PasswordLength` | `20` | Generated password length, 4-94. |
| `-MinGroupMembers` | `2` | Minimum members assigned to each group. |
| `-MaxGroupMembers` | `10` | Maximum members assigned to each group. |
| `-MinDA` | `2` | Minimum users added to Domain Admins (random within range). |
| `-MaxDA` | `10` | Maximum users added to Domain Admins. |
| `-MaxGroupNestingDepth` | `3` | Deepest group-in-group nesting. |
| `-RandomSeed` | `0` | Seeds the RNG for a reproducible run. `0` means no seed (fresh randomness each run). |

Domain name, NetBIOS name, OU layout, CA settings, password policy, and the user-state percentages are configuration, not parameters. They live in [include/global-config.ps1](include/global-config.ps1).

## Logs

Logs go to `logs\` under the project folder.

Both scripts produce:

- `<ScriptName>-<timestamp>.log` -- the full PowerShell transcript for after-the-fact diagnosis.
- `ad-deploy-errors.csv` -- structured `WARN`/`ERROR` rows shared by both scripts, so failures survive across runs and can be queried without grepping transcripts. Columns: `Timestamp,Level,Script,Message`. Import with `Import-Csv`.

Script two also writes two post-promotion diagnostic reports:

- `dcdiag-<timestamp>.txt` -- output of `dcdiag /v`.
- `repadmin-<timestamp>.txt` -- output of `repadmin /replsummary`.

If you file a bug, include these.

## Artifacts

Script two writes a snapshot of what it built to `artifacts\`:

- `users-<timestamp>.csv` and `users-<timestamp>.json` -- every user created, with a subset of attributes. **This includes passwords for users.**
- `test-results-<timestamp>.csv` -- pass/fail rows from the functional test pass.

## Configuration Notes

Configuration defaults are found in [include/global-config.ps1](include/global-config.ps1).
Text configuration files (names, departments, etc.) are found in the [config](config) directory.

A few choices in [include/global-config.ps1](include/global-config.ps1) are deliberate. Do not "fix" them unless you understand what you are doing and don't report bugs if changes break things:

- **`$usersOU` is `OU=Employees`, not `OU=Users`.** An OU named `Users` collides with the built-in `CN=Users` container at the domain root.
- **`$forestName` must equal `$domainName`.** This builds a new forest root domain, so the two are the same. Script one refuses to run if they differ.
- **The DSRM password is hardcoded in script one.** It is a lab tool. The variable is named `$dsrmPwDontDoThisInProd` so nobody mistakes the intent. Technically I guess you can change this one, but it's a lab.
- **Enterprise CA database and log share one directory.** Fine for a lab, not what you would do in production.

## Known Limitations

- **Lab and demo only.** Hardcoded DSRM credential, a self-signed-style Enterprise CA, and a wide-open functional model. This is not a hardened build and is not meant to be.
- **New forest root only.** It does not join an existing forest, add a child domain, or add a replica DC.
- **Single DC, single site.** One site and one subnet are created. No replication topology beyond that.
- **Population is only partly idempotent.** OUs, service accounts, computer objects, GPOs, and sites are skipped if they already exist, but re-running script two adds a fresh batch of randomly generated users and groups and re-rolls their memberships. Start from a clean promotion for a predictable result.

## Troubleshooting

**"ADCS-Cert-Authority is already installed."** -- `Install-ADDSForest` will not promote a server with the CA role present. Remove AD CS, then re-run script one. The CA is installed later by script two.

**"DNS name '...' already resolves."** -- The target domain name already answers in DNS, which usually means a conflicting zone or a prior half-built attempt. Clear it before re-running.

**Directory never populated after the reboot.** -- The scheduled task triggers at Administrator logon, not at boot. Log into the DC as Administrator. If you never passed `-CreateScheduledTask`, run `Initialize-ADDirectory.ps1` by hand.

**Script one hangs with no output on an unattended VM.** -- A prompt is waiting on a console that is not there. Re-run with `-NonInteractive` and supply `-StaticIpAddress`, `-PrefixLength`, `-DefaultGateway`, and `-AdapterName` as needed.

**"For a new forest root domain, $forestName must equal $domainName."** -- Set both to the same value in [include/global-config.ps1](include/global-config.ps1).

## Contact

- Mastodon: @daniel@infosec.exchange
- Email: 0x44616e69656c {AT} [not-this]danielowen[.]com
- LinkedIn: https://www.linkedin.com/in/danielowen/
- Web: https://danielowen.com

## Contributing

Bug reports and pull requests are welcome. This project accepts code changes through the fork and pull request model. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to file a bug and the pull request requirements.

## License

Released under the [MIT License](LICENSE). You are free to use, copy, modify, and distribute this software, including for commercial purposes, provided the copyright notice and license text are retained. The software is provided "as is", without warranty of any kind.
