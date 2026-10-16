# Ration

A small, free native macOS menu bar app that shows how much of your Claude and ChatGPT
subscription limits you've used. Built for Apple silicon and macOS 14 or newer.

The menu bar icon is two rings: the outer one is Claude, the inner one ChatGPT. Each fills with
that service's fullest limit and turns orange at 80%. Click it for every limit, how much of it is
used, and when it resets.

Weekly limits also show where you're headed. Stripes past the fill show how much you'll have used
when the week resets if you keep going at the same rate: orange if you'd leave a good part of it
unused, green if you'd use most of it, and gray with a mark past the end if you'd run out first.
Hover over the row to see it in words. The stripes appear once a tenth of the week has passed, and
orange waits for a quarter.

## Install

Requires macOS 14+ on Apple silicon. Releases are signed with a Developer ID and notarized by Apple.

```sh
brew install --cask xinding33/tap/ration
```

Or download `Ration-x.y.z.zip` from the [latest release](https://github.com/xinding33/ration/releases/latest),
unzip it, and move `Ration.app` to Applications.

Open Ration, then choose **Settings…** from its menu bar icon to sign in and turn on **Open at Login**.

To uninstall, turn off **Open at Login** and quit Ration, then run `brew uninstall --cask ration`
(or delete `Ration.app`). `brew uninstall --zap --cask ration` also removes its settings. To remove
its Claude login too, choose **Sign Out** under Settings › Accounts first.

### Updating

Ration updates itself: once a day it checks for a new [release](https://github.com/xinding33/ration/releases),
checks that it is signed by the same developer, replaces itself and restarts. To turn that off,
uncheck **Install Updates Automatically** under Settings › General, and use **Check for Updates…**
there instead.

## Accounts

**Claude.** Choose **Sign In…** under Settings › Accounts. Ration runs Claude Code's own
`claude auth login` in a private, empty profile, so you sign in on Claude's usual page in your
browser. It then moves that login into its own Keychain item (`io.github.xinding33.ration.claude`)
and deletes the profile, so from then on only Ration uses or renews it. That keeps it independent of
Claude Code's own login: Claude Code can be signed in another way, such as with a
`claude setup-token` token, which can't read usage. Signing in needs Claude Code installed; Ration
looks for it in the usual places, or set `CLAUDE_EXECUTABLE` to its path.

**ChatGPT.** Ration reads Codex's ChatGPT login from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`)
and never changes or renews it; Codex does that. Sign in to Codex with your ChatGPT account. If
Codex's login expires, opening Codex renews it.

Either service can be turned off under Settings › Accounts, which leaves a single ring.

## How it checks

Every five minutes, and when you open the menu if the numbers are more than a minute old, Ration
asks each service:

| Service | Request |
|---|---|
| Claude | `GET https://api.anthropic.com/api/oauth/usage` |
| ChatGPT | `GET https://chatgpt.com/backend-api/wham/usage` |

These are the endpoints Claude Code and Codex use for their own usage displays. They aren't
documented public APIs and may change. When a service rate-limits the check, Ration waits as long
as it's asked, up to an hour, and says so in the menu. Other failures back off from five minutes
to an hour.

The only other network access is looking up the Claude account's email once after signing in
(`GET https://api.anthropic.com/api/oauth/profile`), renewing the Claude login
(`POST https://platform.claude.com/v1/oauth/token`), and the daily update check against GitHub.
Nothing is sent anywhere else.

## Build

Requires Xcode or the Swift command-line tools. No packages.

```sh
swift test
bash scripts/build.sh
open dist/Ration.app
```

The build creates an ad-hoc signed Apple silicon app and ZIP for your own Mac. Builds you make
yourself can't install releases, since they aren't signed by the same developer; pull and build
again to update.

Read-only diagnostics, which check both services once and print what they found, without tokens.
They never renew the Claude login, which belongs to the running app, so they report an expired
access token instead of renewing it:

```sh
dist/Ration.app/Contents/MacOS/Ration --diagnose
```

`--snapshot DIR` draws the menu bar icon and the menu's rows with sample numbers to PNGs, in light
and dark.

### Release

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, signs with the hardened
runtime, notarizes and staples the app, publishes `Ration-x.y.z.zip` to a GitHub Release, and
updates the cask in [xinding33/homebrew-tap](https://github.com/xinding33/homebrew-tap). It needs
these secrets in a `release` environment restricted to `v*` tags: `DEVELOPER_ID_P12` and
`DEVELOPER_ID_P12_PASSWORD` (the base64-encoded Developer ID Application certificate and its
password), `NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` (a base64-encoded App Store Connect
API key), and `TAP_DEPLOY_KEY` (a deploy key with write access to the tap).

To produce the same notarized ZIP locally, save notary credentials once with
`xcrun notarytool store-credentials ration-notary`, then run `bash scripts/release.sh`.

## Development

Ration's implementation, tests, and documentation were developed with AI assistance. Ration is not
affiliated with Anthropic or OpenAI.

## License

Copyright 2026 Xin Ding. Licensed under the [Apache License, Version 2.0](LICENSE).
