---
layout: default
title: Troubleshooting
---

# Troubleshooting (development)

In-app problems for testers: [User help](../user/help.md).

## Apple Intelligence on the Simulator

The iOS Simulator **does not** run the on-device Foundation Model. Ask / `makeSession` will fail there.

**Fix:** Run the **iOS app on this Mac** (Apple silicon): Xcode destination **My Mac (Designed for iPhone)** — scheme **FinanceWizard**. Same binary as iPhone, iPhone-sized window. Apple Intelligence must be on in **System Settings** on the Mac (same as iPhone). This is not Mac Catalyst and not a Mac-native target.

If that destination is missing: App target → Build Settings → **Supports Mac Designed for iPhone** = Yes (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`). **Supports Mac Catalyst** stays No.

## Build errors

### Multiple commands produce `Info.plist`

**Cause:** `Info.plist` is both processed as the app plist and copied as a resource (folder-synced Xcode projects).

**Fix:** Keep `Info.plist` in membership exceptions (not copied as a resource), or use only `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_*` without a conflicting copy phase.

### `Cannot find type Transaction` in widget

**Cause:** `Shared/` not in WidgetExtension target membership.

**Fix:** Select `Transaction.swift` / `SharedStore.swift` → File inspector → check **WidgetExtension**. (Folder-sync should already do this.)

### `Failed to open ModelContainer` at launch

**Cause:** App Group missing, wrong id, or signing/capability not applied.

**Fix:** Both targets have `group.net.roberth.FinanceWizard`, same Team, then Clean + delete the app + reinstall.

## Xcode console noise (usually ignore)

### `CFPrefsPlistSource` / `group.net.roberth.FinanceWizard` / `kCFPreferencesAnyUser with a container`

App Group prefs warning, common on Simulator. SwiftData still uses the group for the store; logo **files** use the group folder. We avoid `UserDefaults(suiteName:)` for logo metadata. If widgets can’t see data, re-check entitlements + signing—not this log alone.

### `non-launching port is incompatible with service identifier "com.apple.PointerUI…"`

Simulator pointer UI. Unrelated. Ignore.

### `UIContextMenuInteraction updateVisibleMenuWithBlock: while no context menu is visible`

SwiftUI refreshing a toolbar menu that isn’t open. Harmless.

## Plaid (contributor)

### “webview integration mode for link is deprecated”

Current builds use **Hosted Link** + `ASWebAuthenticationSession`. Rebuild/reinstall.

### Link finishes but “no public_token”

Race after Hosted Link. The app polls `/link/token/get`. Retry or check Plaid Dashboard logs.

### Link failed: “closed without linking a bank (or the session timed out)”

The poll used to give up after **30s** while the bank sheet was still open (easy to hit on Sandbox: search bank → `user_good` / `pass_good` → pick accounts). It now polls until the `ASWebAuthenticationSession` closes, then waits a short grace period for `/link/token/get`.

Still failing: confirm Sandbox secret, `hosted_link.is_mobile_app` + `financewizard://hosted-link-complete`, and that **First Platypus Bank** completed (not cancelled). Plaid Dashboard → Logs for that `link_token`.

### OAuth bank never returns (Production)

May need an **https Universal Link** in Settings + Plaid Dashboard allowlist.

### Duplicates

Should not happen if upsert by `transactionId` works. Re-linking can mint new Plaid ids → new rows.

## Classification and card rates

### A merchant bill is being filed as a credit-card payment

`PlaidCategoryMapper.looksLikeCardPaymentTitle(_:allowWeakSignals:)` splits its needles. Strong ones (“payment thank you”, “credit card payment”, “payment to <issuer>”, `looksLikeIssuerBillPayTitle`) always count. Weak ones — `autopay`, `automatic payment`, `ach pmt`, `payment received` — are ordinary merchant-descriptor words and only count when `allowWeakSignals` is true, which `isCreditCardPayment` passes **only** for money-in on a credit account. Do not move a needle back into the unconditional set without checking it against real utility / phone / insurance descriptors.

### Where did rewards go?

Removed. `CardBenefitsStore`, `CardProductCatalog` and `RewardCategory` are deleted, along
with `Transaction.multiplier` / `multiplierLocked` / `rewardCategoryOverride`,
`BankAccount.debitRewardMultiplier` / `achRewardMultiplier`, and `VendorRule.multiplier`.
The app tracks spending, income, budgets and card debt — not earn rates.

SwiftData drops the removed columns by lightweight migration; this was verified against a
real 3,268-transaction store with no row loss. Older `.fwbackup` files still restore: the
extra JSON keys are ignored on decode. Vendor learn-rules likewise keep working, since the
stored `multiplier` key is simply no longer read.

### Card payments turned into "Loan" rows / Total paid collapsed

`PlaidCategoryMapper.classify` must test `isCreditCardPayment` **before**
`looksLikeLoanDisbursement`. The loan check has a PFC shortcut that fires on any
`LOAN_DISBURSEMENTS*` tag, and Plaid applies that tag to the card side of ordinary bill
payments — so payments were stored as positive `Loan` adjustments and their
`CreditCardPayment` rows deleted. A strong payment title outranks a PFC guess.
`isCreditCardPayment` already refuses titles naming a real card-line loan
("My Chase Loan TO 1234"), so genuine disbursements still fall through.

`cleanLegacyMisclassifiedRows` repairs rows an older build corrupted this way: an
`overrideSource == "adjustment"` row categorised `Loan` whose title reads as a card payment
is converted back, sign normalised, and its payment row recreated.

### A real bill payment disappeared from Total paid

`cleanLegacyMisclassifiedRows` has a branch that rescues purchases Plaid mis-tagged as
`CREDIT_CARD_PAYMENT` — it re-files them and deletes the mirrored `CreditCardPayment` row.
Its test used to be only "the title doesn't look like a payment", which is not the same as
"this is a purchase". A checking-side bill pay worded as a transfer
("Ach Deposit Internet Transfer From Account E") matched no payment needle, so its payment
row was deleted and the transaction re-filed as Shopping — then removed altogether by the
transfer rule on the next pass. The branch now also requires
`!looksLikeNonSpendTitle(row.title)`.

Rows already destroyed this way cannot be recovered from Plaid if they came from the Apple
Card CSV (ids prefixed `applecard:`) — re-import the CSV to restore them.

### A charge shows up in Total paid after editing its category

`TransactionDetailView.syncCreditPaymentRecord` mirrors a `CreditCardPayment` row when the
chosen category is excluded from spend. `isExcludedFromSpendCategory` covers **Loan, Refund
and Installment** as well as Credit Card Payment, so re-filing a charge as Loan created a
bill-payment row for it — re-inflating Total paid by the charge amount. The guard is now
`isCreditCardPaymentCategory`. Same distinction applies in `OnDeviceAITools`, where the
"card payments" total counted all four categories.

`cleanLegacyMisclassifiedRows` drops payment rows left behind by the old behaviour: a
transaction excluded from spend but *not* categorised Credit Card Payment must not have one.

### Transaction detail: Save must not rewrite what it did not change

`saveEdits` used to set every field, lock category and rail, and stamp
`overrideSource = "user"` unconditionally. Two consequences: opening a row and pressing Save
with no edits froze it against all future Sync corrections, and it erased provenance markers —
a My Chase Loan charge adopted by the payoff editor (`"my-loan"`) became `"user"`. It now
compares against the model and only touches fields that actually moved.

Presenting the payoff editor uses `.sheet(item:)`, not `.sheet(isPresented:)` plus a companion
`@State` for the kind. The old pair was set in one button action and SwiftUI could build the
sheet before the kind landed, so a My Chase Loan opened the editor as **Pay Over Time** — a
flat-fee plan instead of an APR one, with the wrong principal/interest split every cycle. Keep
any value the sheet needs inside the `item`.

### Everything is dated a day early / lands in the wrong month

Plaid sends calendar days ("2026-09-01"), not instants. `PlaidSyncEngine.dayFormatter` and
`ContentView.parseExportDate` must parse them in `TimeZone.current`, because every consumer
(`TransactionAnalytics.dateInterval`, `StatementCycle.group`, `daysUntilDue`, `Text(style:.date)`)
reads them with `Calendar.current`. Parsing at UTC midnight put every row on the previous local
day west of Greenwich: September spend counted in August, due dates shown a day early, statement
close days one short.

Rows written before that fix sit at UTC midnight. `reanchorStoredDays` re-stamps them to local
midnight of their intended day, gated on `dayAnchorVersion`. It only touches values sitting
exactly on a UTC midnight, so real timestamps are safe and re-running is a no-op.

### Two things must agree about "the same" payment

`CreditAnalytics.isSamePayment` collapses the checking-side and card-side rows of one bill
pay. It now *requires* the two rows to be on opposite sides — mask and issuer only confirm the
pair. Without that guard two genuinely separate payments of equal amount inside the 3-day
window merged, and Total paid under-counted.

`TransactionDetailView.syncCreditPaymentRecord` must resolve `cardName` to the **card**, not
the funding account — `AccountsBoard.paymentsMatching` and `paymentIdentities` treat it as the
card's identity.

### `expenseCategory` must never return the Credit Card Payment category

It only runs for rows `classify()` already decided are spend. Returning that category filed a
real purchase (an in-store swipe Plaid tags `LOAN_PAYMENTS_CREDIT_CARD_PAYMENT`) under a
category excluded from spend, with no payment row either — a ledger entry nothing summed.
Genuine payments get their category from `upsertCreditPaymentExpense`.

### Card financing fees

`PLAN FEE - <merchant>` (My Chase Plan) and `ANNUAL MEMBERSHIP FEE` map to **Fees**, not
Installment. Installment is excluded from spend because it re-bills a purchase already in
the list; a plan fee is a new cost and must stay visible next to `PURCHASE INTEREST CHARGE`.

### Statement periods look off

`StatementCycle.clampedDate` must clamp the close day to the month’s length **before** building the date. `Calendar.date(from:)` is lenient and never returns nil for an out-of-range day — it rolls over (2026-02-31 → 2026-03-03), which silently produced February windows stamped in March. `statementStart(end:closeDay:)` derives the window start from the previous close for the same reason. `group(_:closeDay:lastStatement:)` takes the issuer’s last statement date so `isOpen` means “not yet billed” rather than “ends on or after today”; `currentGroup(in:)` is the single source of truth for which cycle the Accounts row and the card screen summarise.

## Onboarding / Welcome

### Welcome never appears

Flag is `settings.onboardingCompleted`. **Settings → Developer → Debug → Replay onboarding**. `OnboardingGate` sits under splash in the live app.

### Splash logo does not match Welcome

Both use **`AppIconImage`**. `Image("AppIcon")` does not load an `.appiconset`. The old `SplashLogo` imageset was removed.

### Get Started title is the wrong color

`AccentColor` is ink (dark in Light, light in Dark). `.borderedProminent` often keeps a **light** label in both schemes, so Light looks fine and Dark vanishes (white on white). `.colorInvert()` on the title only “fixes” Dark and breaks Light.

Set the button’s `.foregroundStyle` to `Color(.systemBackground)` (canvas color) after the prominent style.

## Widget empty (simulator)

1. Run the **app**, Sync, then add the widget.
2. Confirm App Group id on both targets.
3. Delete and re-add the widget after major model changes.
