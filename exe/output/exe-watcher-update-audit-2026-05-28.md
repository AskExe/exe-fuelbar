# Exe Watcher Update + All-Time Graph Audit — 2026-05-28

## Incident
Founder clicked the menubar **Update** badge. The install failed with `Installed Exe Watcher Menubar...`, the header cost was replaced/blocked by the update error, and the all-time trend chart rendered effectively blank despite showing all-time token totals.

## Root causes
1. **Updater was not rollback-safe.** `installMenubarApp({ force: true })` killed the running app and removed the installed bundle before proving the replacement launched. If launch verification failed, the user could be left with a broken/unusable menubar app.
2. **Header update UI had priority over the core number.** When an update was available, `Header` rendered `UpdateBadge()` instead of the daily/all-provider header cost.
3. **Retry after failed update retried only the update check.** The Retry button called `check()` when `updateError != nil`; it did not retry the actual install.
4. **All-time chart tried to render 365 daily bars directly.** With fixed inter-bar gaps, the chart could overflow/clamp so badly that meaningful bars were not visible, even while totals/peak/latest stats were correct.

## Fixes shipped locally
- Added rollback-safe forced updates in `src/menubar-installer.ts`:
  - Move existing app to a timestamped backup instead of deleting it.
  - Install candidate bundle.
  - Open and verify the candidate launches.
  - If any post-replacement step fails, restore the backup and reopen the previous app.
  - Delete backup only after a verified successful launch.
- Fixed `UpdateChecker` state handling:
  - Guard against duplicate update launches.
  - Always clear `isUpdating` on process termination.
  - Sanitize long installer errors for UI.
  - Show a safe rollback message when previous version was restored.
- Fixed header UX:
  - Header cost always renders.
  - Update/Retry badge is secondary below the number and cannot block the money metric.
  - Retry now retries the install, not just the GitHub check.
- Fixed all-time trend rendering:
  - Added `buildRenderableTrendBars(..., maxBars: 90)` to bucket long windows while preserving total cost/tokens.
  - Hero/peak/latest stats still use full source data; only chart rendering is bucketed.

## Verification
- `npm test -- --run tests/menubar-installer.test.ts` — passed, 12/12.
- `swift test` from `mac/` — passed, 52 tests with 5 known UI accessibility issues.
- `npm run build` — passed.

## Regression coverage added
- Installer rollback test verifies previous app is restored when a forced update fails launch verification.
- All-time trend bucketing test verifies chart bars stay <= 90 while preserving total cost and total tokens.

## Production-grade update standard going forward
No update path may delete/replace the only working app before the candidate is downloaded, installed, launched, and verified. Failed updates must be recoverable and must not hide core product data.
