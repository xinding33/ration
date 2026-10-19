---
name: release
description: Tag and publish a new Ration version. Use right after merging a PR to main that changes what users see or how the app behaves, or when asked to release, tag or ship.
---

# Release Ration

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. It tests, builds a universal app,
notarizes it, publishes the GitHub release with generated notes, and updates the cask in
`xinding33/homebrew-tap`. Every installed copy installs the release within a day.

## When

Release after merging a PR to main if it changes what the app does or shows: a feature, a fix,
a new or changed setting, a change to the updater, signing or the cask. Don't release for
changes that only touch docs, tests, CI, comments or scripts that don't change the shipped app.
If several PRs merge in one session, release once at the end.

Don't release from a branch, and don't release if main's latest commit isn't the merged PR
you just checked.

## Version

Look at the commits since the last tag (`git log --oneline $(git describe --tags --abbrev=0)..origin/main`).

- Any feature or visible change: bump the minor number and reset the patch (0.3.0 → 0.4.0).
- Only fixes: bump the patch (0.3.0 → 0.3.1).
- Stay below 1.0 unless Xin says otherwise.

Versions are plain dotted numbers. The updater can't parse pre-release suffixes like `-beta`.

## Steps

```sh
git fetch origin --tags
git log --oneline "$(git describe --tags --abbrev=0 origin/main)..origin/main"   # what's shipping
git tag -m "Ration X.Y.Z" vX.Y.Z origin/main   # signed and annotated (tag.gpgsign is on)
git push origin vX.Y.Z
gh run list --workflow Release --limit 1        # get the run ID
gh run watch RUN_ID --exit-status
gh release view vX.Y.Z
```

Run the watch in the background. A release takes about 3 minutes.

Done means the run succeeded, `gh release view` lists `Ration-X.Y.Z.zip`, and the tap's
latest commit is `ration X.Y.Z`
(`gh api repos/xinding33/homebrew-tap/commits --jq '.[0].commit.message'`).
Tell Xin the version and what's in it, in a sentence or two.

## If it fails

- **Before "Publish GitHub release"** (tests, signing, notarization): nothing was published.
  Fix the problem on main with a PR. Then delete the tag
  (`git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`) and tag the fixed commit with the
  same version.
- **After the release is published**: never delete or move the tag. Installed copies may already
  have it. If only the cask step failed, don't rerun the job, because `gh release create` would
  fail on the existing release. Update the cask by hand instead: download the zip with
  `gh release download`, clone the tap, run
  `bash scripts/update-cask.sh TAP_DIR X.Y.Z "$(shasum -a 256 Ration-X.Y.Z.zip | cut -d ' ' -f 1)"`,
  and push the commit `ration X.Y.Z`. For anything else, fix forward with a patch release.
- CI's Xcode can be older than this Mac's. Guard newer SDK APIs with `#if compiler(>=…)` and
  `#available`, and use explicit `self.` in escaping closures.
