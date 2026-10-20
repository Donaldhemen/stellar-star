# Receipt capture and reviewed drafts (#340)

OCR suggestions are never expense records. A user selects or captures a photo,
starts extraction, edits and confirms every field, then explicitly submits the
normal expense form. No total is computed from line items.

## Implementation boundaries

- Process images on the user's device with a self-hosted Tesseract worker,
  WebAssembly core and English model; no receipt is sent to an OCR service.
- Keep the original file and draft in component memory, never browser storage,
  analytics, logs, source control or the blockchain.
- After expense creation, attach the unchanged original through the existing
  issue 014 upload API. Its sniffing, quarantine, authorization, private bucket,
  signed links and retention remain authoritative.
- If attachment fails, retain a retry screen for the existing expense. Retrying
  must not create a second expense.
- Keep ambiguous dates, currencies and amounts blank for manual entry. Mark
  uncertain suggestions and require individual confirmation even at high confidence.

## Processing and cost review (2026-10-20)

| Topic | Engineering decision and release constraint |
|---|---|
| Provider | Tesseract.js 7.0.0, Tesseract.js-core 7.0.0 and `@tesseract.js-data/eng` 1.0.0, pinned by npm lockfile. Local open-source software; no hosted OCR account or API key. |
| Regions | OCR pixels and raw OCR text stay on the user's device. Worker/core/model are fetched from the application's own origin. Original upload uses the existing Supabase project region only after explicit expense submission. Operators must verify their deployment/CDN and Supabase regions and existing storage terms before release. |
| Processing terms | No receipt is transferred to a new OCR processor, so no external OCR DPA is introduced by this implementation. Existing application hosting and Supabase processing terms still apply to original storage. Replacing local OCR with a service requires a fresh provider, region, retention, subprocessors and data-use review. |
| Software terms | Tesseract engine/core and underlying English model use Apache 2.0; the language npm package declares MIT. Generated assets include engine/core licenses, embedded worker notices and `NOTICE.txt`; see `RECEIPT_OCR_NOTICES.txt`. |
| Cost limit | External OCR API spend: zero, with no per-page billing. At most one extraction per capture screen; 4 MiB original, 25 megapixel decode limit, 2400 px OCR derivative, 60 s operation timeout, 40 suggested items. Hosting/storage bandwidth remains part of the operator's existing budget and alerts; no new paid service is enabled. |
| Retention | Drafts/photos live only in component memory and are discarded on close. Tesseract cache is disabled. Saved originals use issue 014's private bucket, uploader/checksum metadata, quarantine, removal and configured retention (default 730 days). The existing authenticated retention cron must be configured. Reviewed date/items become ordinary expense description text and follow expense retention; removing the original does not erase expense text. |
| Consent | Selection does not start OCR. The user chooses extraction or manual entry, confirms every field and item, applies the draft, then explicitly creates the expense. |

This records the implementation assessment, not an assertion of organization-level
legal or production approval. The entry point is disabled by default with
`NEXT_PUBLIC_RECEIPT_OCR_ENABLED=false` until the deployment owner completes the
region, hosting budget, existing storage terms and device checks below.

Primary references reviewed:

- [Tesseract local installation](https://github.com/naptha/tesseract.js/blob/master/docs/local-installation.md): explicit worker, core and language paths avoid default CDN requests.
- [Worker API](https://github.com/naptha/tesseract.js/blob/master/docs/api.md): worker lifetime, recognition and cache options.
- [Engine license](https://github.com/naptha/tesseract.js/blob/master/LICENSE.md), [underlying model license](https://github.com/tesseract-ocr/tessdata_best/blob/main/LICENSE), and installed npm package license metadata.

## Behavior and supported input

The existing expense form offers rear-camera capture and photo selection when
enabled. JPEG, PNG and WebP up to 4 MiB are accepted; the unchanged original is
kept. PDFs and HEIC remain supported by ordinary receipt attachments after manual
expense creation, but are not OCR inputs. English OCR can miss non-English text;
manual entry is always available for a selected supported photo.

Only an explicit total label is parsed. Multiple totals, ambiguous separators,
locale dates and ambiguous currency symbols require manual entry. ISO dates and
explicit currency codes use the existing FX whitelist. Merchant and item matches
are heuristic and always marked low confidence. Higher confidence never skips a
confirmation. Unsupported currencies must not be relabelled to force conversion;
use the normal manual expense flow with an explicitly chosen supported amount.

Changing a field clears its confirmation; changing the item list also clears its
completeness confirmation. The form blocks expense submission while capture or
review is open, including Enter-key submission. Date and reviewed line details
are copied into an editable expense description. They never affect split math;
the reviewed total continues through the existing FX quote and split flow.

After expense save, the screen uploads the exact original with the existing
authenticated API. Failure retains the file and expense ID for retry. A 409 only
counts as success if the existing receipt's SHA-256 matches; quota conflicts do
not. Quarantined originals are stored but cannot be downloaded, as in issue 014.
Do not close the screen before attachment completes: this flow does not provide
a durable offline queue or background upload.

## Deployment procedure

1. Run `npm ci` and `npm run ocr:assets` (also invoked by `npm run dev` and
   `npm run build`). Generated `/public/ocr` is ignored by Git; ship it with the
   application's public assets. No real receipts or OCR fixtures are generated.
2. Confirm `/ocr/worker.min.js`, `/ocr/core/*.wasm.js`, `/ocr/core/*.wasm`,
   `/ocr/eng.traineddata.gz` and license notices are served from this origin.
   A custom CSP must permit same-origin workers/scripts and WebAssembly. Do not
   redirect these requests to a third-party CDN.
3. Verify existing wallet authentication, receipt service-role configuration,
   private bucket, migration 0009 and authenticated retention scheduler. Align
   `RECEIPT_MAX_BYTES` with the 4 MiB capture cap (a stricter server limit will
   reject the original). Confirm Supabase region and storage terms in the
   deployment record, with the responsible owner's name and date.
4. Review asset bandwidth/storage budgets and alerts in the hosting account.
   There is no OCR-provider billing configuration. Record owner/date and the
   approved hosting budget outside this source-controlled engineering assessment.
5. Verify capture on iOS Safari and Android Chrome, file selection on desktop,
   blurry/rotated photos, missing totals, decimal commas, denied membership,
   original removal/expiry and failed upload recovery. Real device/deployed
   storage checks require the operator's deployment and are not claimed here.
6. Set `NEXT_PUBLIC_RECEIPT_OCR_ENABLED=true` and rebuild only after those checks.
   Roll back by setting it to false and rebuilding. Existing saved receipts keep
   their normal access and retention behavior.

## Verification commands

- OCR tests: `npm test -- --runInBand ocr ReceiptDraftReview ReceiptPhotoPicker ReceiptAttachmentStep ReceiptCapture ExpenseReceiptDraft useReceiptCapture`.
- Existing receipt/form regressions: `npm test -- --runInBand __tests__/receipts __tests__/components/expenses/ExpenseForm.test.tsx __tests__/hooks/useExpenseFormCurrency.test.tsx`.
- Real worker/network smoke: install Chromium with `npx playwright install chromium`, then `npm run test:ocr:browser`. It recognizes a synthetic receipt and blocks/reports requests outside the local origin.
- Full gates: `npm run lint`, `npx tsc --noEmit`, `npm run build`, `npm test -- --runInBand`.

Repository-wide gates and final issue-specific results are recorded in
`RECEIPT_OCR_VALIDATION.md`.
