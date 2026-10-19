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
- Validate Mainnet Go/No-Go release gate: `npm run gate:check`
- Assert no E2E wallet bypass in production build: `npm run test:security-build`
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

## 9. Release Governance & Authority: Approval, Pause, and Rollback

This section defines the operational authority matrix, decision thresholds, and escalation protocols
governing public network releases, fulfilling the requirements of Issue #305 and the Mainnet Go/No-Go Gate.

### 9.1 Approval Authority (Who Can Approve a Release)

A public mainnet release or promotion cannot proceed without formal, auditable sign-off from designated
gatekeepers representing the core operational domains in [`docs/MAINNET_READINESS.md`](./MAINNET_READINESS.md).

#### Named Approval Gatekeepers

| Domain | Designated Gatekeeper | Functional Role | Contact / Handle |
| :--- | :--- | :--- | :--- |
| **Release Commander** | Morgan Reed | Infrastructure & Release Lead | `@release-mgmt` |
| **Security Lead** | Alex Chen | Principal Security Architect | `@security-lead` |
| **Contract Lead** | Dev Sharma | Principal Soroban Smart Contract Engineer | `@contracts-lead` |
| **Treasury & Finance** | Elena Rostova | Head of Treasury & Financial Operations | `@treasury-lead` |
| **Support & Ops** | Marcus Vance | Operations & Customer Support Lead | `@support-ops` |
| **Legal & Privacy** | Sarah Jenkins | Legal Counsel & Compliance Lead | `@legal-counsel` |
| **SRE & Monitoring** | Jordan Taylor | Staff SRE / Observability Lead | `@sre-lead` |

#### Approval Requirements & Protocol

1. **Unanimous P0 Sign-Off**: All required P0 checklist items in `docs/MAINNET_READINESS.md` must be marked `APPROVED` with active, unexpired review dates (within 30 days of release date).
2. **Automated CI Release Gate Passing**: The automated CI gate check (`npm run gate:check`) and security build verification (`npm run test:security-build`) must pass with zero errors in `.github/workflows/production-check.yml`.
3. **Quorum for Final Promotion**: Final sign-off requires unanimous authorization from the **Release Commander**, **Security Lead**, **Contract Lead**, and **Treasury Lead**.
4. **Explicit Approval Record**: Approvals must be recorded in the `Go/No-Go Approval Record` table in `docs/MAINNET_READINESS.md` before deploying to production.

---

### 9.2 Pause Authority (Who Can Pause a Release)

Stellar-star adheres to the **"Stop-the-Line" (Andon Cord)** principle: any team member observing a potential
security, financial, or integrity issue has the authority and responsibility to immediately pause a release.

#### Who Can Unilaterally Pause
- **Release Commander** (`@release-mgmt`)
- **On-Call Engineer / SRE** (`@sre-lead`)
- **Security Team Member** (`@security-lead`)
- **Smart Contract Engineer** (`@contracts-lead`)
- **Support Team Lead** (`@support-ops`)

#### Mandatory Pause Triggers
A release in progress or canary deployment must be paused immediately upon encountering any of the following:

- **Error Spikes**: Error rate exceeding 0.5% of requests or sudden surge in `/api/error-report` telemetry.
- **Money-Path Discrepancy**: Any report of on-chain debit without corresponding settlement contract record.
- **Surge Pricing Rejections**: Multiple `tx_insufficient_fee` or transaction submission timeouts from Horizon.
- **Network Mismatch Warnings**: Live reports of `NetworkMismatchBanner` activations or wrong-network signing attempts.
- **RPC Desynchronization**: Soroban RPC or Horizon endpoint returning stale ledger sequences (> 10 ledgers behind).

#### Immediate Pause Action Steps
1. **Halt Deployment Pipeline**: Cancel any in-progress GitHub Action or Vercel production deployment.
2. **Display Diagnostic Screen**: If client misconfiguration is suspected, trigger the fail-closed network block screen.
3. **Notify Response Channel**: Broadcast a priority alert to `#incident-sev1` / `#release-alerts` stating release pause, timestamp, and triggering symptom.

---

### 9.3 Rollback Authority & Execution (Who Can Roll Back a Release)

When an issue cannot be safely mitigated or hotfixed within 15 minutes of release pause, a rollback must be declared.

#### Rollback Decision Authority
- **Release Commander** (`Morgan Reed`)
- **Incident Commander** (`Jordan Taylor` / active on-call lead)
- **Security Lead** (`Alex Chen`)

Any of the above individuals has the unilateral authority to order an immediate rollback without convening an emergency committee.

#### Step-by-Step Rollback Procedure

1. **Step 1: Frontend Application Rollback (< 2 minutes)**
   - Open Vercel / hosting console.
   - Select the last verified, stable production deployment SHA.
   - Click **Instant Rollback** to redirect traffic immediately to the previous immutable release bundle.
   - Purge edge caches / CDN distributions.

2. **Step 2: Environment Configuration Safety**
   - If the issue stems from an erroneous environment override, revert `.env` production variables.
   - Verify `assertValidNetworkConfig()` passes for the rolled-back configuration.

3. **Step 3: On-Chain & Contract State Isolation**
   - Stellar blockchain ledger entries are permanent and non-custodial; on-chain transactions cannot be deleted.
   - If a deployed contract address is invalid, update `NEXT_PUBLIC_CONTRACT_ID` back to the stable contract instance.
   - Check the Settlement Pool balances to ensure no pending or locked balances were affected.

4. **Step 4: Database Hygiene & State Audit**
   - Check Supabase migration status via `npm run db:status`.
   - If a migration caused backwards-incompatible schema drift, execute the documented down-migration or initiate Supabase Point-in-Time Recovery (PITR).
   - Re-verify RLS policies remain intact with `npm test -- __tests__/database`.

5. **Step 5: Post-Rollback Communication & Retrospective**
   - Update user status page / broadcast resolution message.
   - Log the rollback in the operational incident register.
   - Convene a blameless post-mortem within 24 hours to review root cause and update test coverage before re-attempting the Go/No-Go gate evaluation.
