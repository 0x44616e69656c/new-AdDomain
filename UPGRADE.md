# Upgrading new-AdDomain to 2.1

**Not tested yet.** These steps come from reading the code and from offline tests that run the migration against copies of 1.0 and 2.0. Nobody has carried a modified 1.0 or 2.0 setup through them and built a DC on a live VM. Until that run passes, treat this as a careful reading rather than a proven path, and tell me where it's wrong.

## What an upgrade touches

new-AdDomain builds a new forest on a clean server. It never changes a forest it already built, and 2.1 can't upgrade one either. A forest you built with 1.0 or 2.0 stays exactly as it is. Upgrading only changes what your next build does.

So the job is replacing one folder and carrying your settings across. Up to 2.0 your settings lived in tracked files, mainly `include\global-config.ps1` and the CSV files in `config\`. From 2.1 they live in an `overrides` folder that git ignores and no upgrade touches, and `Export-OverrideFile.ps1` moves them there for you. This is the last upgrade that needs them moved.

Never edited a file? Then there is nothing to move. Run `git pull` in the folder of a clone, or swap in a fresh copy, and skip to step 5.

For what changed, see [What's New in 2.1](README.md#whats-new-in-21) in the README. [OVERRIDE.md](OVERRIDE.md) lists every setting the override file can hold.

## Step 1. Keep your old folder and get 2.1 next to it

Run these in the folder that holds `new-AdDomain`.

```powershell
Rename-Item -Path .\new-AdDomain -NewName new-AdDomain-old
git clone https://github.com/0x44616e69656c/new-AdDomain.git
```

Downloaded a zip instead? Extract it to a folder named `new-AdDomain` next to `new-AdDomain-old`, look the files over, then unblock them:

```powershell
Get-ChildItem -Path .\new-AdDomain -Recurse -File | Unblock-File
```

A fresh folder means no merge conflicts and nothing half applied, and the new folder keeps the name build-lab expects.

## Step 2. See what the migration would do

The script reads `new-AdDomain-old` and never runs anything in it. With `-WhatIf` it writes nothing except its log.

```powershell
cd .\new-AdDomain
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old -WhatIf
```

The last line counts the settings it would write, the ones that are unchanged, and the changed defaults. Its log, `logs\Export-OverrideFile_<timestamp>.csv`, has one row per setting with what it found and why. A secret such as the DSRM password shows there as `<set>`.

**Changed defaults.** A setting you never edited, whose shipped default has changed since your release, isn't written unless you ask, so a build on 2.1 gets 2.1's default. From 1.0 that's three:
- the domain, `lab.local` then and `lab.test` now
- the site subnet, `10.0.0.0/24` then and `Auto` now
- the minimum password length, 15 then and 14 now, which is what the domain enforced anyway

From 2.0 it's only the password length. To keep the old values, so the next build matches the last one, add `-KeepPreviousDefaults` in step 3. If you still run a lab on `lab.local`, you want that.

## Step 3. Run it

```powershell
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old
```

Or, to keep the old defaults:

```powershell
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old -KeepPreviousDefaults
```

It writes `overrides\overrides.psd1`, with a comment above each setting naming the old file and line it came from, and copies each CSV you edited to `overrides\config\`. A CSV whose only difference is its line endings isn't copied. Read the WARN lines it prints. Each one is something it couldn't carry across on its own:
- a value built from other values, which it can't read without running the file. Set that one by hand in `overrides\overrides.psd1`
- a value 2.1 refuses, which it writes commented out with the reason. Fix it and remove the `#`
- an SPN in `serviceaccounts.csv` that names a host outside the domain, such as `MSSQLSvc/sql01.lab.local:1433`. It is copied as written, and the WARN shows the `{DomainName}` form to use if it should follow the domain

If `overrides\` already holds a file it would write, it changes nothing there and writes everything to `overrides\migrated-<timestamp>\` instead. Merge that by hand.

## Step 4. Bring your build profile

A build profile was never tracked by git, so copy it across if you have one.

```powershell
Copy-Item -Path ..\new-AdDomain-old\include\build-profile.psd1 -Destination .\include\build-profile.psd1
```

Skip this if `..\new-AdDomain-old\include\build-profile.psd1` doesn't exist.

Don't copy your old `include\global-config.ps1` over the new one. 2.1's is what reads the override file. Both scripts check its version first and stop before any change when it's older, so a copied one won't promote a DC on the wrong settings, but your build won't start either.

## Step 5. Build on a clean server

Run script one on a clean server, or a fresh snapshot of one. Its log starts with its version, and near the top one INFO line names the override file, its SHA-256 and every setting it applied, so the first run doubles as the check. A misspelled key, a value outside what a setting takes, or an older `global-config.ps1` stops script one before it changes anything, and the ERROR line names the file and the setting.

If you left the minimum password length at its default, both scripts also log one INFO line saying it went from 15 in 2.0.0 to 14 in this release, and how to keep 15. That line is expected. It shows up only on 2.1 and goes away at the next release.

If build-lab drives your builds, its [UPGRADE.md](https://github.com/0x44616e69656c/build-lab/blob/main/UPGRADE.md) covers the build-lab and New-VMwareWorkstationVM folders, which have their own override files and migration scripts.

## Later upgrades

From 2.1 on, keep every change in `overrides\` and `include\build-profile.psd1`. A clone then upgrades with `git pull`. From a zip, get the new release and copy those two across into it. Nothing else carries over.

## What has been tested

The migration was run offline against unedited copies of 1.0 and 2.0 taken from their release tags, and against copies with every setting edited, CSVs edited, values it should refuse and files already in `overrides\`. None of that has been followed by a live build. 2.0 itself was run end to end on Windows Server 2025 (build 26100). 2.1's own live run is still to come.
