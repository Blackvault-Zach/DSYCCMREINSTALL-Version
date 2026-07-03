# DSYCCMREINSTALL-Version

This repo exists purely as a public version-check endpoint for the internal
CCM Reinstall Tool. It does not contain the actual script or any of the
install files - just the current version number.

## Files

- `version.txt` - plain text, single line, current released version number
  (e.g. `1.1.0`). This is what the script checks against on launch.

## Why this is separate from the real tool

The actual script, ccmsetup files, and everything else stay private/internal
since they reference internal site codes and hostnames. This repo is public
only so any machine running the tool can check for updates without needing
GitHub credentials or access to the internal package.

## Updating the version

When a new version of the tool is released, update `version.txt` with the
new version number and commit. That's the only step needed - the script
compares its own version against this file on every launch.
