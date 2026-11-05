# Upgrading new-AdDomain from 1.0 to 2.0

## Do you need to upgrade?

2.0 is a feature release, not a bug fix. If you don't need build profiles, `Win2025` functional levels or the DC's own site, you may do better staying on 1.0 until the next version. That one is planned to keep every setting you might change in a separate override file that upgrades leave alone, with a small script that moves the edits you have already made into it. Upgrading will be a lot less fiddly then.

If you do want 2.0 now, the steps below get you there without losing your settings.

## What an upgrade touches

new-AdDomain builds a new forest on a clean server. It never changes a forest it already built, and 2.0 cannot upgrade one either. A forest you built with 1.0 stays exactly as it is. Upgrading only changes what your next build does.

So the whole job is replacing one folder and carrying your settings across. The settings are the hard part. 1.0 kept them in tracked files that 2.0 changed, mainly [include/global-config.ps1](include/global-config.ps1) and [config/serviceaccounts.csv](config/serviceaccounts.csv). If you cloned the repository and never edited a file, `git pull` in its folder is all it takes, and you can skip to step 4.

For what changed and why, see [What's Changed Since 1.0](README.md#whats-changed-since-10) in the README.

## Step 1. Find what you changed

If you cloned the repository, run these two commands in the folder that holds `new-AdDomain`. They list every file you edited and show what you changed in each.

```powershell
git -C .\new-AdDomain status
git -C .\new-AdDomain diff
```

If you downloaded a zip, compare your folder against a fresh 1.0 download. The files people usually edit are `include\global-config.ps1` and the CSV files in `config\`.

Write down each value you changed. You'll put them back by hand in step 3, so a list beats a copy of the old file.

## Step 2. Get 2.0 into a fresh folder

Keep your 1.0 folder for reference and put 2.0 next to it. Run these in the folder that holds `new-AdDomain`.

```powershell
Rename-Item -Path .\new-AdDomain -NewName new-AdDomain-1.0
git clone https://github.com/0x44616e69656c/new-AdDomain.git
```

A fresh folder means no merge conflicts and nothing half-applied. If you use build-lab, the new folder keeps the name build-lab expects.

## Step 3. Put your settings back

**Domain identity goes in a build profile.** Seven settings can now live in a build profile. If you changed any of them, put them in `include\build-profile.psd1` instead of editing global-config.ps1. Each key is the 1.0 variable name with a capital first letter.

| 1.0 variable in global-config.ps1 | 2.0 profile key |
|---|---|
| `$domainName` | `DomainName` |
| `$netBIOSName` | `NetBIOSName` |
| `$forestMode` | `ForestMode` |
| `$domainMode` | `DomainMode` |
| `$requiredOSBuild` | `RequiredOSBuild` |
| `$primarySiteName` | `PrimarySiteName` |
| `$primarySubnet` | `PrimarySubnet` |

Leave `$forestName` out. It follows `DomainName` now. Leave `PrimarySubnet` out too unless you picked a subnet on purpose. 1.0 shipped a fixed `10.0.0.0/24`, and 2.0 ships `Auto`, which uses the subnet the DC's own address sits in. A profile is never tracked by git, so it survives this upgrade and every later one. See [Build Profiles](README.md#build-profiles) for the valid values.

**Everything else goes into the new global-config.ps1 by hand.** Password policy, OU names and the rest stay in global-config.ps1. Edit 2.0's file one value at a time.

Do not copy your 1.0 global-config.ps1 over 2.0's. The 2.0 file is what loads the build profile and runs its checks, and the 1.0 file does neither. From reading the code, here is what happens if you do (I have not run it). Script one promotes the DC on the old values, never reads your profile, and says nothing about it. After the reboot, script two then stops at its CSV check, so you end up with a promoted DC and an empty directory. build-lab 2.1 refuses such a copy before building anything, but its message tells you to update new-AdDomain, which you already did.

**CSV files.** Only `config\serviceaccounts.csv` changed between 1.0 and 2.0. Copy any other CSV you edited from your 1.0 folder over the 2.0 one.

For `serviceaccounts.csv`, add your rows to the 2.0 file instead. 2.0 writes SPN hosts as `host.{DomainName}`, so a 1.0 row like `MSSQLSvc/sql01.lab.local:1433` becomes `MSSQLSvc/sql01.{DomainName}:1433`. An SPN with the domain typed out still passes every check. It just names `lab.local` hosts inside whatever domain you actually built, and nothing warns you. See [Service account SPNs](README.md#service-account-spns).

## Step 4. Build on a clean server

Run script one on a clean server, or on a fresh snapshot of one. A misspelled profile key, a functional level other than `WinThreshold` and `Win2025`, or a global-config.ps1 value the build can't use stops script one before it changes anything. The ERROR lines name the file and the setting, so the first run doubles as the check.

Expect two changes in the results, even with your settings carried over. The DC ends up in its own renamed site, not in `Default-First-Site-Name`. The test results file also has fifteen rows instead of nine.

## A lab still on lab.local

The default domain is now `lab.test`. To keep building `lab.local`, use this profile. Expect a warning that `.local` is reserved for multicast DNS.

```powershell
@{ DomainName = 'lab.local'; NetBIOSName = 'LAB' }
```

If build-lab drives your builds, its [UPGRADE.md](https://github.com/0x44616e69656c/build-lab/blob/main/UPGRADE.md) covers adding member servers to a DC you built before.

## What has been tested

2.0 was run end to end on Windows Server 2025 (build 26100), on fresh servers. The upgrade itself was not. Nobody has carried a modified 1.0 setup through these steps on a live VM. The steps come from comparing the 1.0 and 2.0 files line by line, so treat them as a careful reading rather than a proven path, and tell me where they're wrong.
