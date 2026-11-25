# Upgrading new-AdDomain

## From 2.1 to 2.2

**Tested on one host.** 2.2 has been through live builds driven by build-lab 2.3. That covered the full, minimal and empty populations, two builds from one seed, and a build set up to make the new password check redraw. If something here doesn't match what you see, tell me.

Your settings already live in `overrides\` and `include\build-profile.psd1`, so a clone upgrades with `git pull`, and from a zip you copy those two into the new release. Nothing needs migrating.

**What you must do.**

- **Spell the seed `PopulationSeed` in a build profile.** `RandomSeed` in a profile now stops the run with a "did you mean" hint, even when it's empty. 2.1 ignored an empty one with a warning. `RandomSeed` in the override file and `-RandomSeed` work as before. The same goes for `VirtualNetwork`, which is now `NetworkType`.
- **Keep 2.2's `include\global-config.ps1`.** Script two stops before it changes anything in the directory when the copy it loads is 2.1's or older. Script one accepts 2.1's copy, so a copied-back file only shows up after the promotion.

**What's different once you're on 2.2.**

- **Unseeded runs draw a seed.** A run with no seed now draws one, logs it as `Random seed: ...` and uses it. Put that number in a build profile as `PopulationSeed`, or pass it as `-RandomSeed`, to build the same users and groups again.
- **Passwords no longer follow the seed.** If you counted on `-RandomSeed` giving the same passwords every build, it won't anymore. The users export in `artifacts` still lists every password.
- **The password policy comes earlier.** It's set after the users are created and just before the failed binds that lock some of them, so locked users are really locked now. The service accounts are created after it, under the domain's own minimum length and complexity.
- **Short passwords are raised.** A `PasswordLength` below `MinPasswordLength` used to build shorter passwords with a warning. It's raised to the minimum now, still with a warning. Script two also reads the minimum the new domain enforces before it sets its own policy, since the users are created under that one, and raises the length to it when it's higher.
- **The lockout observation window is set.** It's the lockout duration or 10 minutes, whichever is smaller, so the shipped settings keep the 10 minutes a new forest already had. A `LockoutDurationMinutes` under 10 in your override file now shortens the window to match.
- **The Domain Admins test row changed.** It checks the accounts population added against the number it meant to add, not a minimum member count, so a build with `DomainAdminCount = 0` passes.
- **Log texts and files.** Anything that reads script two's log or its `artifacts` folder will see new `Population settings:` and `Random seed:` lines, a Domain Admins line that gives the number added, reworded stop messages, `population-result.json` and three `population-*.csv` files. [What's New in 2.2](README.md#whats-new-in-22) lists them.
- **Reserved profile keys are worded differently.** The WARN for an empty `BuildName`, `CertificateAuthority`, `Machines` or `Trusts`, the stop for one with a value, and the end of the "did you mean" hint all changed. [What's New in 2.2](README.md#whats-new-in-22) quotes the new lines.
- **An example override file.** `examples\overrides.psd1` lists every setting, commented out at its shipped value. Copy it into `overrides\` to start a file of your own. If you're moving edits from an older copy with `Export-OverrideFile.ps1`, run that first. It writes to a separate folder when `overrides\overrides.psd1` already exists.

**Bugs fixed.**

- **A refused password stopped population.** Rarely, a generated password held the user's account name or a whole part of the display name (split at spaces and punctuation, three or more characters), Windows refused it, and script two retried the half-made account until the run died on "The specified account already exists". Generated passwords now never hold the account's names. There's nothing to do on upgrade. Script two logs a new `Generated passwords for` line after the users and another after the service accounts, with how many draws held a name and were drawn again. If an account is ever made despite an error, the run now stops at once and names the account to delete, where 2.1 logged "already exists" eleven times first.

If build-lab drives your builds, build-lab 2.3 is the release that goes with this one, since it now starts population itself. Its [UPGRADE.md](https://github.com/0x44616e69656c/build-lab/blob/main/UPGRADE.md) covers that side. For everything new and the bugs 2.2 fixes, see [What's New in 2.2](README.md#whats-new-in-22) in the README.

## From 1.0 or 2.0 to 2.2

**Not tested yet.** These steps come from reading the code and from offline tests that run the migration against copies of 1.0 and 2.0. Nobody has carried a modified 1.0 or 2.0 setup through them to 2.2 and built a DC on a live VM. Until that run passes, treat this as a careful reading rather than a proven path, and tell me where it's wrong.

The steps below move your settings out of the tracked files. Once they're done, everything in [From 2.1 to 2.2](#from-21-to-22) applies to you as well.

### What an upgrade touches

new-AdDomain builds a new forest on a clean server. It never changes a forest it already built, and 2.2 can't upgrade one either. A forest you built with 1.0 or 2.0 stays exactly as it is. Upgrading only changes what your next build does.

So the job is replacing one folder and carrying your settings across. Up to 2.0 your settings lived in tracked files, mainly `include\global-config.ps1` and the CSV files in `config\`. From 2.1 they live in an `overrides` folder that git ignores and no upgrade touches, and `Export-OverrideFile.ps1` moves them there for you. This is the last upgrade that needs them moved.

Never edited a file? Then there is nothing to move. Run `git pull` in the folder of a clone, or swap in a fresh copy, and skip to step 5.

For what changed, see [What's New in 2.2](README.md#whats-new-in-22) and [What's New in 2.1](README.md#whats-new-in-21) in the README. [OVERRIDE.md](OVERRIDE.md) lists every setting the override file can hold.

### Step 1. Keep your old folder and get 2.2 next to it

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

### Step 2. See what the migration would do

The script reads `new-AdDomain-old` and never runs anything in it. With `-WhatIf` it writes nothing except its log.

```powershell
cd .\new-AdDomain
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old -WhatIf
```

The last line counts the settings it would write, the ones that are unchanged, and the changed defaults. Its log, `logs\Export-OverrideFile_<timestamp>.csv`, has one row per setting with what it found and why. A secret such as the DSRM password shows there as `<set>`.

**Changed defaults.** A setting you never edited, whose shipped default has changed since your release, isn't written unless you ask, so a build on 2.2 gets 2.2's default. From 1.0 that's three:
- the domain, `lab.local` then and `lab.test` now
- the site subnet, `10.0.0.0/24` then and `Auto` now
- the minimum password length, 15 then and 14 now, which is what the domain enforced anyway

From 2.0 it's only the password length. To keep the old values, so the next build matches the last one, add `-KeepPreviousDefaults` in step 3. If you still run a lab on `lab.local`, you want that.

### Step 3. Run it

```powershell
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old
```

Or, to keep the old defaults:

```powershell
.\Export-OverrideFile.ps1 -SourcePath ..\new-AdDomain-old -KeepPreviousDefaults
```

It writes `overrides\overrides.psd1`, with a comment above each setting naming the old file and line it came from, and copies each CSV you edited to `overrides\config\`. A CSV whose only difference is its line endings isn't copied. Read the WARN lines it prints. Each one is something it couldn't carry across on its own:
- a value built from other values, which it can't read without running the file. Set that one by hand in `overrides\overrides.psd1`
- a value 2.2 refuses, which it writes commented out with the reason. Fix it and remove the `#`
- an SPN in `serviceaccounts.csv` that names a host outside the domain, such as `MSSQLSvc/sql01.lab.local:1433`. It is copied as written, and the WARN shows the `{DomainName}` form to use if it should follow the domain

If `overrides\` already holds a file it would write, it changes nothing there and writes everything to `overrides\migrated-<timestamp>\` instead. Merge that by hand.

### Step 4. Bring your build profile

A build profile was never tracked by git, so copy it across if you have one.

```powershell
Copy-Item -Path ..\new-AdDomain-old\include\build-profile.psd1 -Destination .\include\build-profile.psd1
```

Skip this if `..\new-AdDomain-old\include\build-profile.psd1` doesn't exist. If the profile holds `RandomSeed`, rename it to `PopulationSeed` or take it out, as [From 2.1 to 2.2](#from-21-to-22) says.

Don't copy your old `include\global-config.ps1` over the new one. 2.2's is what reads the override file and hands script two its population settings. Both scripts check its version first and stop before any change when it's older than they need, so a copied one won't promote a DC on the wrong settings, but your build won't start either.

### Step 5. Build on a clean server

Run script one on a clean server, or a fresh snapshot of one. Its log starts with its version, and near the top one INFO line names the override file, its SHA-256 and every setting it applied, so the first run doubles as the check. A misspelled key, a value outside what a setting takes, or an older `global-config.ps1` stops script one before it changes anything, and the ERROR line names the file and the setting.

2.1 also logged one INFO line naming the minimum password length's change from 15 to 14. 2.2 doesn't, because it compares its defaults only with 2.1's, and 2.1 already shipped 14. Step 2's changed defaults are where you see it now.

If build-lab drives your builds, its [UPGRADE.md](https://github.com/0x44616e69656c/build-lab/blob/main/UPGRADE.md) covers the build-lab and New-VMwareWorkstationVM folders, which have their own override files and migration scripts.

### Later upgrades

From 2.1 on, keep every change in `overrides\` and `include\build-profile.psd1`. A clone then upgrades with `git pull`. From a zip, get the new release and copy those two across into it. Nothing else carries over.

### What has been tested

The migration was run offline against unedited copies of 1.0 and 2.0 taken from their release tags, and against copies with every setting edited, CSVs edited, values it should refuse and files already in `overrides\`. None of that has been followed by a live build on 2.2. 2.0 itself was run end to end on Windows Server 2025 (build 26100). 2.2's own live run is still to come.
