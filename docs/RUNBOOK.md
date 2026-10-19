# Stellar-star Production Runbook

## 1. Prerequisites

- Node.js 18+
- npm 9+
- Rust toolchain (for contract work)
- Stellar CLI (for deployment operations)
- Funded Stellar testnet account
- Supabase project with schema from `supabase-setup.sql`

## 2. Environment Setup

Copy `.env.local.example` to `.env.local`:

```bash
cp .env.local.example .env.local
```

Ensure the following variables are configured:

- `NEXT_PUBLIC_STELLAR_NETWORK=TESTNET`
- `NEXT_PUBLIC_HORIZON_URL` (Horizon API URL)
- `NEXT_PUBLIC_STELLAR_EXPLORER` (Stellar Expert/Explorer URL)
- `NEXT_PUBLIC_SOROBAN_RPC_URL` (Soroban RPC URL)
- `NEXT_PUBLIC_CONTRACT_ID` (Deployed Soroban contract ID)
- `NEXT_PUBLIC_SUPABASE_URL` (Supabase Project URL)
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` (Supabase Anonymous Client Key)
- `SUPABASE_JWT_SECRET` (or `JWT_SECRET` matching the Supabase JWT signing secret)
- `NEXT_PUBLIC_APP_NAME` (App metadata name)
- `NEXT_PUBLIC_APP_VERSION` (App version)
- `NEXT_PUBLIC_SITE_URL` (Deployment or localhost URL)

## 3. Local Validation

Run in project root:

- `npm run lint`
- `npm test -- --runInBand`
- `npm run build`

Run contract tests:

- `cd contract && cargo test`

### 3.1 End-to-End Tests (Playwright)

Browser-level coverage for the main user journeys (landing, auth prompt,
dashboard, expenses, trips, trip detail, plus mobile viewports) lives in
`e2e/e2e.spec.ts`. Playwright starts the Next.js dev server itself, so no
manual `npm run dev` step is needed first.

- `npm run test:e2e` - headless run across all configured projects (desktop
  Chrome/Firefox/Safari plus Mobile Chrome/Mobile Safari device emulation)
- `npm run test:e2e:ui` - interactive UI mode for debugging a single test
- `npx playwright test --project=chromium` - fastest single-browser run
  (what CI runs)
- `npm run test:e2e:report` - open the HTML report from the last run

No real Supabase project or wallet extension is required to run this suite:
it only asserts unauthenticated-state UI (wallet-connect prompts, auth
guards, page structure) and responsive layout, using the placeholder
Supabase env vars already set in `playwright.config.ts`'s `webServer`.

## 4. Contract Deployment (Testnet)

Run the automated contract deployment script:

```bash
bash scripts/deploy-contract.sh <secret-key-or-stellar-cli-alias> <token-contract-id>
```

This script will:
1. Build the WASM contract package (`settlex_contract.wasm`).
2. Resolve the deployer's public key address (`G...`).
3. Deploy the Settlement Pool contract instance and get its `POOL_CONTRACT_ID`.
4. Deploy the Settlement contract instance and get its `SETTLEMENT_CONTRACT_ID`.
5. Cross-initialize both contracts by calling `init_pool` with the settlement and token contract IDs, then `init` on the settlement contract (referencing the pool contract).
6. Print the contract IDs and Stellar Expert explorer links.

After deployment:
1. Update `NEXT_PUBLIC_CONTRACT_ID` and `NEXT_PUBLIC_SETTLEMENT_CONTRACT_ID` with the printed settlement contract ID.
2. Update `NEXT_PUBLIC_POOL_CONTRACT_ID` and `NEXT_PUBLIC_POOL_TOKEN_ID` with the printed values.
3. Save the printed explorer links in `README.md` and documentation if needed.

## 5. CI/CD Verification

- Ensure workflow files exist and are valid:
  - `.github/workflows/ci.yml`
  - `.github/workflows/production-check.yml`
- Validate network configuration:
  - Development / Testnet validation: `npm run config:validate`
  - Mandatory production deployment gate: `npm run config:validate -- --production`
    - Validates selected network, Horizon, Soroban RPC, explorer, contract IDs, asset issuer values, and public app URL without printing secrets.
    - Rejects testnet endpoints or placeholder contract IDs before production deployment.
- Confirm CI badge resolves in README.
- Confirm repo settings enforce checks on PRs (manual GitHub setting).

## 6. Release Documentation Pack

Before submission or mainnet promotion, verify:

- README is up to date
- `docs/MAINNET_READINESS.md` signed off and Go/No-Go gate evaluated
- `docs/RELEASE_CHECKLIST.md` current
- `docs/REQUIREMENT_PROOF_MATRIX.md` current
- `docs/ARCHITECTURE_AND_LIMITATIONS.md` current
- `docs/RUNBOOK.md` (specifically Section 9 Release Governance) reviewed

## 7. Incident / Rollback Basics

If a production or production-like issue occurs:

1. **Pause immediately**: Exercise pause authority (Section 9.2) to halt active releases or traffic.
2. Stop deployment changes and freeze configuration.
3. Re-run lint/test/build and contract tests.
4. Validate `.env.local` contract ID and network configuration consistency.
5. Compare README proof IDs/tx hashes against Stellar Expert explorer.
6. If contract ID is wrong or unrecoverable, follow the formal rollback procedure in Section 9.3.

## 8. Settlement Pool Credit Model

To prevent recording settlements without a valid proof on-chain, the Stellar-star contract interfaces with a `SettlementPoolContract`.
Before a payment record is accepted:
1. The user's share amount is checked against their balance in the pool contract.
2. If the user's pool balance is insufficient (shortfall > 0), they must deposit credits first using the "Deposit Shortfall" flow in their row. This invokes `deposit(member, amount)` on the pool contract with their signature.
3. When the payment is recorded via `record_payment`, the settlement contract performs an inter-contract call to the pool contract to `withdraw` the amount from the payer's pool balance.

## 9. Alert Investigation Runbook: From Correlation ID to On-Chain Transaction and Database Record

This runbook specifies the step-by-step procedure for on-call engineers investigating payment-path alerts generated by Stellar-star (Issue #307).

### 9.1 Alert Classification & Severity

| Alert Type | Severity | Condition | Impact |
|------------|----------|-----------|--------|
| `PARTIAL_SUCCESS_SPIKE` | **SEV-1** | Any transaction where funds moved on Horizon but Soroban contract recording failed (`onchain-proof-failed` / `partial_success`). | User's wallet was debited, but app/contract lacks on-chain proof. Risk of user uncertainty or double-spend if retried blindly. |
| `CRITICAL_SERVICE_UNAVAILABLE` | **SEV-1** | Outage of Horizon Gateway, Soroban RPC, Supabase Database, or Attestation Oracle. | All or part of the money path is halted. Users cannot submit or verify payments. |
| `REPEATED_FAILURES` | **SEV-2** | 3 or more payment-path failures within a 5-minute rolling window. | Systemic degradation (e.g. surge fees, wallet provider failure, bad network config). |

### 9.2 Log Shape & Invariants

Every payment operation propagates a correlation ID (`requestId` / `x-request-id`) through headers, error reports, and database records.
- **Log Sink**: Server-side logs emit structured lines with the prefix `[StellarStar:client-error]` and `[StellarStar:oncall-alert]`.
- **Zero-Secret Invariant**: Error reports are scrubbed before emission:
  - Stellar secret keys (`S...`) -> `[REDACTED_STELLAR_SECRET]`
  - JWT tokens (`ey...`) -> `[REDACTED_JWT]`
  - Transaction XDR payloads -> `[REDACTED_XDR_PAYLOAD]`
  - Sensitive keys (`secret`, `token`, `xdr`, `private`, `auth`, `password`, `seed`) -> `[REDACTED]`

### 9.3 Investigation Procedure: Step-by-Step

#### Step 1: Extract Correlation ID (`requestId`)
Extract the correlation ID from the alert notification or query server logs:
```bash
# Filter server logs for the specific request ID
grep "[StellarStar:client-error]" /var/log/stellar-star.log | grep "<requestId>"

# Or inspect the on-call alert entry
grep "[StellarStar:oncall-alert]" /var/log/stellar-star.log | grep "<requestId>"
```
The log payload contains `name`, `message`, and `context` (e.g. `tripId`, `expenseId`, `hash` / `txHash`, `amount`).

#### Step 2: Query the Database Record in Supabase
Using the correlation ID (`requestId`), inspect the durable settlement intent in Supabase:
```sql
SELECT
  id,
  request_id,
  trip_id,
  expense_id,
  member_id,
  payer_wallet,
  member_wallet,
  amount,
  currency,
  status,
  tx_hash,
  ledger,
  on_chain,
  error_message,
  created_at,
  updated_at
FROM settlement_intents
WHERE request_id = '<requestId>';
```
Analyze the state:
- **`status = 'submitted'` with `on_chain = false`**: Funds were submitted to Horizon (`tx_hash` populated), but on-chain contract recording failed or is pending.
- **`status = 'pending'`**: Client initiated settlement intent acquisition but failed before or during Horizon submission.
- **`status = 'recorded'`**: Both Horizon payment and contract recording completed.

Also inspect the associated expense record:
```sql
SELECT id, trip_id, title, amount, currency, is_settled, paid_shares
FROM expenses
WHERE id = '<expense_id>';
```

#### Step 3: Verify the Stellar Horizon Transaction (`txHash`)
If a transaction hash (`tx_hash` or `hash`) exists in the intent or log context, verify whether value actually moved on the Stellar ledger:

1. **Horizon REST API**:
   ```bash
   curl -s -H "x-request-id: <requestId>" "$NEXT_PUBLIC_HORIZON_URL/transactions/<txHash>"
   ```
2. **Stellar Expert Block Explorer**:
   - Testnet: `https://stellar.expert/explorer/testnet/tx/<txHash>`
   - Public / Mainnet: `https://stellar.expert/explorer/public/tx/<txHash>`

**Verification Outcomes**:
- **HTTP 200 with `"successful": true`**: **Value moved on-chain.** The user's wallet was debited. **DO NOT** ask the user to pay again.
- **HTTP 200 with `"successful": false`**: Transaction was submitted but failed consensus (check `result_codes` in response, e.g. `op_underfunded`, `tx_insufficient_fee`).
- **HTTP 404 Not Found**: The transaction never reached or was dropped by Stellar Core. Funds did not move.

#### Step 4: Verify Soroban Contract State
If the Horizon transaction was successful, verify whether the Soroban settlement contract recorded the payment:

Using Stellar CLI:
```bash
stellar contract invoke \
  --id "$NEXT_PUBLIC_CONTRACT_ID" \
  --network "$NEXT_PUBLIC_STELLAR_NETWORK" \
  -- \
  is_paid \
  --expense_id "<expense_id>" \
  --member "<member_wallet>"
```

- If `is_paid` returns `true`: The contract record is intact. App state can be synchronized.
- If `is_paid` returns `false`: This confirms a **Partial Success** event. Funds moved on Horizon, but contract proof is missing.

#### Step 5: Remediation Actions

1. **Remediating Partial Success (`txHash` confirmed, contract unrecorded)**:
   - Run the automated reconciliation script or trigger `/api/settlement/reconcile`:
     ```bash
     curl -X POST "$NEXT_PUBLIC_SITE_URL/api/settlement/reconcile" \
       -H "Content-Type: application/json" \
       -H "x-request-id: <requestId>" \
       -d '{"walletAddress": "<member_wallet>"}'
     ```
   - Alternatively, advise the user to click **"Retry On-Chain Proof"** in the UI. Because the transaction hash is preserved, the retry flow only submits the contract attestation, preventing double payment.

2. **Remediating Critical Service Outage**:
   - Check Horizon status (`$NEXT_PUBLIC_HORIZON_URL/fee_stats`).
   - Check Soroban RPC health via `getHealth` method.
   - Check Supabase status page and connection pooler.
   - If prolonged (>15 minutes), engage the Release Authority to post a maintenance notice or pause new payment actions.

3. **Remediating Repeated Failures**:
   - Review recent error reports grouped by `message`.
   - Common causes:
     - Fee surge on Stellar network: Update base fee configuration.
     - Out-of-sync sequence numbers: Instruct affected users to wait 30 seconds for pending ledger closure.
     - Invalid destination trustlines: Confirm recipient account has required asset trustline.

