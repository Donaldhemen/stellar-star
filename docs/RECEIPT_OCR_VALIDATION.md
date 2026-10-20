# Issue #340 validation record

Date: 2026-10-20. Base: `main` at `bf17401`.
Branch: `feat/340-receipt-ocr-drafts`.

## Acceptance coverage

| Requirement | Implementation and evidence |
|---|---|
| Explicit capture/selection and review before creation | `ReceiptPhotoPicker`, `useReceiptCapture`, `ReceiptDraftReview`, and `ExpenseForm` enforce separate selection, extraction, per-field/item confirmation, draft application and expense submission. New capture and form integration tests exercise the complete review handoff. |
| Original follows issue 014 | The exact selected `File` is passed to the existing authenticated receipt upload API. No re-encoding. Upload recovery uses the saved expense ID and verifies checksum for duplicate conflicts. Existing inspection/access/store tests pass; live deployment still needs migration 0009 and the retention scheduler. |
| Low-confidence indicators; no inferred total | Merchant/items are conservatively marked uncertain. Missing/ambiguous totals stay blank; no item summation exists in the parser. Field edits invalidate confirmation. Tests cover locale ambiguity, missing totals, duplicate totals, invalid amounts and confidence metadata. |
| Provider, regions, costs and terms reviewed before launch | Technical processing assessment, primary references, license notices, hosting constraints and deployment-owner checklist are in `RECEIPT_OCR.md`. The build-time feature switch defaults to false. No organization-level or deployed-region approval is asserted. |

## Completed checks

- **70 new tests passed**, including real capture/review UI orchestration,
  original identity, upload retries, stale extraction, worker timeout/cancellation,
  local asset paths, parsing and mandatory review.
- **76 existing receipt and expense-form regression tests passed.**
- The existing receipt schema test's **4 migration assertions passed**. Its
  **4 setup-file assertions failed**: `supabase-setup.sql` lacks the receipt
  section already absent at the base commit. That file and test were not changed.
  Do not provision a deployment from that setup file alone; apply migration 0009.
- Real Chromium 149 / Playwright recognition smoke **passed** against a generated
  synthetic receipt: merchant, date and total were recognized with all third-party
  requests blocked and none observed. No real receipt was saved to a fixture.
- `npm run ocr:assets` **passed**, including all shipped core variants, English
  model and software notices.
- ESLint over changed source/tests/scripts **passed with zero errors**; one
  existing hook dependency warning remains in `useExpenseForm` (`category/tags`).
- `git diff --check` **passed**.

The final combined targeted run executed 20 suites: **19 passed**, 1 failed
(the pre-existing setup schema mismatch); **150 tests passed, 4 failed**.

## Repository-wide blockers present in the base

These are not release approvals and must not be bypassed:

- `npx tsc --noEmit` and `npm run build` fail on existing syntax errors in
  `components/trips/InviteMemberModal.tsx:68` and
  `lib/stellar/accountState.ts:91` (`2n/;`). `git show main:<path>` confirms both
  errors at the base commit; neither file was modified for this issue.
- Full `npm run lint` reports 8 errors in existing invitation/account syntax,
  missing trip-page component imports, and an unavailable rule referenced by an
  export test. Changed OCR code has no lint errors.
- An initial broad Jest run reported 26 failing suites, 107 passing, 1 skipped
  (68 failed tests, 1101 passed, 1 skipped). Failures include existing trip form
  imports, onboarding syntax, payment expectations, schema/setup and governance
  records. The final focused results above supersede that run for this feature.
- `npm audit` reports 44 repository dependency advisories (8 moderate, 35 high,
  1 critical). No blind dependency upgrade or forced audit fix was applied.

## Remaining release checks

The default feature flag remains off. Before production enablement, the deployment
owner must resolve the repository build blockers, confirm existing storage region
and processing terms, approve hosting budgets, apply storage migrations, verify
the retention cron, and run the documented iOS/Android and deployed authorization
checks. Those checks require a real deployment and organizational decisions and
were not fabricated or replaced by mocked tests.
