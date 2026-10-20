export type SplitMode = "equal" | "custom";

export interface Member {
  id: string;
  name: string;
  walletAddress?: string;
  weight?: number;
}

export interface SplitShare {
  memberId: string;
  name: string;
  walletAddress?: string;
  amount: string;
  paid: boolean;
  txHash?: string;
}

export interface Expense {
  id: string;
  title: string;
  description?: string;
  /** Amount denominated in the settlement asset (see `settlementAsset`). */
  totalAmount: string;
  /**
   * The fiat currency the user typed in (EUR, USD, …) — a display and
   * provenance fact only.
   *
   * NOT a Stellar asset and never a payment denomination: `totalAmount` was
   * already converted out of it at creation time via `exchangeRate`. Use
   * `settlementAssetOf()` from lib/settlement/expenseAsset.ts to ask what this
   * expense actually settles in.
   */
  currency: string;
  /**
   * Rate used to convert `currency` into the settlement asset at creation time,
   * as a decimal string. Absent when the expense was entered directly in the
   * settlement asset (no conversion happened).
   */
  exchangeRate?: string;
  /** ISO timestamp of the `exchangeRate` quote, for provenance. */
  exchangeRateTimestamp?: string;
  /** Provider that produced `exchangeRate` (e.g. "coingecko"). */
  exchangeRateSource?: string;
  /**
   * The amount exactly as the user typed it, in `currency`. `totalAmount` is
   * this converted at `exchangeRate`. Absent on rows created before #323.
   */
  enteredAmount?: string;
  /**
   * Canonical Stellar asset this expense settles in ("native", "USDC:GA5Z…").
   * Absent on rows created before multi-asset support, which all settle native.
   */
  settlementAsset?: string | null;
  splitMode: SplitMode;
  paidByMemberId: string;
  members: Member[];
  shares: SplitShare[];
  createdAt: string;
  settled: boolean;
  version?: number;
  updatedAt?: string;
}

export type ExpenseFormData = {
  title: string;
  description: string;
  totalAmount: string;
  splitMode: SplitMode;
  paidByMemberId: string;
  members: Member[];
};
