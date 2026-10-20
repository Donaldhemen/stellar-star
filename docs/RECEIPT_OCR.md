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

Implementation and validation evidence, processing review and rollout procedure
are recorded below as the feature is completed.
