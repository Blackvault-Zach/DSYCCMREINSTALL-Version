# DSYCCMREINSTALL-Version

Public update-check and distribution repo for the internal CCM Reinstall
Tool. This repo does not contain the ccmsetup files, CMClientInstall, or
anything site-specific - just the script itself and the metadata needed
to check for and pull updates.

## Structure

- `version.txt` (root, fixed location - never moves)
  - Line 1: current version number (e.g. `1.1.0`)
  - Line 2: `NORMAL` or `CRITICAL`
  - Line 3: `ON` or `OFF`

- `latest/` (contents get fully replaced every release)
  - `CHANGELOG.txt` - shown to the user when an update is available
  - `UPDATELIST.txt` - list of files the updater needs to pull for this
    release, one relative path per line
  - The actual file(s) listed in `UPDATELIST.txt` (e.g. the current
    `Reinstall-CCMClient-vX.X.ps1`)

## version.txt fields explained

**Severity**
- `NORMAL` - update available, optional. User is shown the changelog and
  can choose to update now or keep running the current version.
- `CRITICAL` - update available, not optional. User is shown the
  changelog and the tool updates automatically.

**Status**
- `ON` - update distribution is active, the tool will check and pull
  normally.
- `OFF` - update distribution is paused (e.g. mid-release while files are
  being swapped in `latest/`). The tool skips the update process entirely
  and continues on whatever version is already installed, silently.

## Publishing a new release

1. Drop the new script version into `latest/`, remove the old one
2. Update `latest/CHANGELOG.txt` with what changed
3. Update `latest/UPDATELIST.txt` if the set of files changed
4. Set `version.txt` line 3 to `OFF` while doing the above if it takes more
   than a moment, so nobody pulls a half-updated release
5. Update `version.txt` lines 1 and 2 (version number, severity)
6. Set `version.txt` line 3 back to `ON`
