# CodexGauge

An open-source macOS menu-bar app that **monitors official announcements for extra Codex resets and shows a live countdown** alongside your ChatGPT plan’s Codex usage. The countdown automatically uses the earlier of your normal reset and a confirmed extra reset.

<p align="center">
  <img src="menu-bar-current.png" alt="CodexGauge menu showing usage, reset countdown, and announcement settings" width="420">
</p>




- **Extra-reset monitoring:** checks configured official news sources hourly by default. When a verified future extra reset is found, the countdown includes it automatically.
- **Next Extra Reset News:** opens the announcement for the next confirmed extra reset, even when your normal reset comes first. When no upcoming extra reset exists, it links to the last timed extra reset announcement retained by the app, if available.
- Compact ChatGPT logo with a filled semicircular usage gauge.
- Optional percentage remaining, reset countdown, and Codex credit balance, rotating every four seconds by default. Rotation speed is configurable; the icon stays in place.
- Countdown uses the earlier normal reset or verified future extra automatic reset.
- Independent official-announcement checks: 5 minutes, 15 minutes, 1 hour (default), 2 hours, 6 hours, or daily.
- Plan heading resolved from the live account plan code and the installed ChatGPT Usage & billing page's label definitions.
- Plan heading opens https://chatgpt.com/settings/billing?mweb_fallback=1; usage opens https://chatgpt.com/settings/usage.
- The menu shows the last reset the app detected while monitoring usage. A decrease in weekly usage to below 10% is treated as a reset; its recorded time is when the decrease is detected, which can be up to one refresh interval later. Corrections to reported usage may also trigger it.
- Optional launch at login.

## Build and test

Requires macOS 13+, Python 3, and Xcode Command Line Tools. Usage requires an existing ChatGPT sign-in and an installed official Codex helper (bundled ChatGPT/Codex app or Codex CLI).

```sh
python3 build.py --test
python3 build.py
```

The built app is `build/CodexGauge.app`. Quit any previous copy before copying it to your Applications folder and opening it. The bundle identifier remains `local.codex.usagebar` to preserve existing settings. If moving an existing installation, toggle Launch at Login off before moving and on afterward to refresh its path.

The build copies the ChatGPT logo from a locally installed ChatGPT app when available. Vendor logo assets and application code are not included in this repository. CodexGauge is an independent project and is not affiliated with or endorsed by OpenAI.

## Data and limits

Usage refreshes every five minutes through the official helper's read-only `account/rateLimits/read` operation. No model turns or credit purchases are requested. Settings and announcement cache stay on the Mac; the app has no dependency on a cloud scheduled task or Google Drive.

Default announcement sources include OpenAI News RSS, the Codex changelog RSS, and a third-party public RSS mirror of Tibo’s X account (@thsottiaux). The mirror discovers candidate posts; the app checks their original content using X’s public embed service before using them for a countdown. No user X login is required. The mirror can be stale, incomplete, or unavailable; X embed responses can also be delayed or truncated. The parser requires an explicit future time, date/year, timezone, and eligible automatic reset announcement. It rejects vague announcements, banked-reset claim deadlines, completed resets, and unsupported eligibility conditions. Coverage is limited to configured accessible sources: X-only announcements may still be missed. Failed checks preserve previous valid data, which expires after 48 hours without verification.

Plan labels are read as data from the installed ChatGPT app without executing its JavaScript. Changes to its packaging or the helper protocol may require an update; a generic account-plan label is used when the richer label is unavailable.

## Source

The Swift files contain the Cocoa app, gauge rendering, plan labels, and announcement checker. `AnnouncementTests.swift` contains parser checks; display/countdown checks are also available in the app's test entry points. Build products, credentials, local usage caches, and extracted vendor resources are excluded.

## License

CodexGauge is licensed under the [MIT License](LICENSE), which permits personal and commercial use, modification, and distribution. Contributions are welcome under the same license. OpenAI and ChatGPT names and logos belong to their respective owners.
