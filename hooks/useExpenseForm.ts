"use client";

import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useToast } from "@/components/ui/Toast";
import { useExpense } from "@/hooks/useExpense";
import {
  calculateSplit,
  findDuplicateWalletErrors,
  isValidStellarAddress,
} from "@/lib/split/calculator";
import { validateAmount } from "@/lib/expense/validation";
import type { Expense, Member, SplitMode } from "@/types/expense";
import { fetchExchangeRate, describeAge } from "@/lib/fx/quote";
import { convertAssetAmount, toLedgerAmount } from "@/lib/money/assetPrecision";
import { Money } from "@/lib/money";
import { isExpenseCategory, type ExpenseCategory } from "@/lib/expense/categories";
import { parseTagInput, validateTags } from "@/lib/expense/tags";

/** Prefill for the form, e.g. from a trip's recurring expense rule. */
export interface ExpenseFormInitialValues {
  title?: string;
  totalAmount?: string;
  splitMode?: SplitMode;
  paidByMemberId?: string;
}

export interface UseExpenseFormOptions {
  onSuccess?: (expenseId?: string) => void;
  currentUserPublicKey?: string | null;
  currentUserName?: string | null;
  defaultMembers?: Member[];
  /** Pre-fill, e.g. from a recurring draft. The user still reviews and submits. */
  initialValues?: ExpenseFormInitialValues;
}

export interface ExpenseFormInitialValues {
  title?: string;
  description?: string | null;
  totalAmount?: string;
  currency?: string;
  splitMode?: SplitMode;
  paidByMemberId?: string;
  category?: ExpenseCategory | null;
  tags?: string[];
}

interface ExpenseFormValidationInput {
  title: string;
  totalAmount: string;
  currency: string;
  members: Member[];
  /** Normalized tags; optional so existing callers keep validating as before. */
  tags?: string[];
}

export function blankExpenseMember(): Member {
  return { id: crypto.randomUUID(), name: "", walletAddress: "", weight: 1 };
}

export function validateExpenseFormFields({
  title,
  totalAmount,
  currency,
  members,
  tags = [],
}: ExpenseFormValidationInput): Record<string, string> {
  const errors: Record<string, string> = {};

  if (!title.trim()) errors.title = "Title is required.";

  const tagError = validateTags(tags);
  if (tagError) errors.tags = tagError;

  const amountError = validateAmount(totalAmount, currency);
  if (amountError) {
    errors.totalAmount = amountError;
  }

  members.forEach((member, index) => {
    if (!member.name.trim()) {
      errors[`member_name_${index}`] = "Name is required.";
    }

    const raw = member.walletAddress?.trim() ?? "";
    if (raw && !isValidStellarAddress(raw)) {
      errors[`member_addr_${index}`] = "Invalid Stellar address (must start with G, 56 chars).";
    }
  });

  const duplicateErrors = findDuplicateWalletErrors(members.map((member) => member.walletAddress));
  Object.entries(duplicateErrors).forEach(([index, message]) => {
    errors[`member_addr_${index}`] = message;
  });

  if (members.filter((member) => member.name.trim()).length < 2) {
    errors.members = "Add at least 2 members.";
  }

  return errors;
}



export function useExpenseForm({
  onSuccess,
  currentUserPublicKey,
  currentUserName,
  defaultMembers,
  initialValues,
}: UseExpenseFormOptions) {
  const { addExpense } = useExpense();
  const { success: toastSuccess, error: toastError, info: toastInfo } = useToast();
  const initialMembersRef = useRef<Member[] | null>(null);

  if (!initialMembersRef.current) {
    initialMembersRef.current = resolveInitialMembers(defaultMembers, currentUserName, currentUserPublicKey);
  }

  const [title, setTitle] = useState(initialValues?.title ?? "");
  const [description, setDescription] = useState(initialValues?.description ?? "");
  const [totalAmount, setTotalAmount] = useState(initialValues?.totalAmount ?? "");
  const [currency, setCurrency] = useState(initialValues?.currency ?? "XLM");
  const [category, setCategoryState] = useState<ExpenseCategory | "">(initialValues?.category ?? "");
  const [tagsInput, setTagsInput] = useState((initialValues?.tags ?? []).join(", "));
  const [splitMode, setSplitMode] = useState<SplitMode>(initialValues?.splitMode ?? "equal");
  const [members, setMembers] = useState<Member[]>(initialMembersRef.current!);
  const [paidByMemberId, setPaidByMemberId] = useState(
    initialMembersRef.current!.some((member) => member.id === initialValues?.paidByMemberId)
      ? initialValues!.paidByMemberId!
      : initialMembersRef.current![0]?.id ?? "",
  );
  const [submitting, setSubmitting] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  /**
   * True when the FX service could not price the chosen currency at submit
   * time. The form stays filled in so the user can switch to XLM and retry —
   * an outage at a third party must not discard what they typed.
   */
  const [rateUnavailable, setRateUnavailable] = useState(false);

  const namedMembers = useMemo(() => members.filter((member) => member.name.trim()), [members]);
  const shares = useMemo(() => {
    const amount = Money.tryParse(totalAmount);
    if (!amount || !amount.isPositive() || namedMembers.length < 2) return [];
    return calculateSplit(amount, namedMembers, paidByMemberId, splitMode);
  }, [totalAmount, namedMembers, paidByMemberId, splitMode]);
  const payerName = members.find((member) => member.id === paidByMemberId)?.name || "Payer";
  const tags = useMemo(() => parseTagInput(tagsInput), [tagsInput]);
  const setCategory = useCallback((value: string) => {
    setCategoryState(isExpenseCategory(value) ? value : "");
  }, []);

  useEffect(() => {
    if (!members.find((member) => member.id === paidByMemberId)) {
      setPaidByMemberId(members[0]?.id ?? "");
    }
  }, [members, paidByMemberId]);

  const addMember = () => setMembers((previous) => [...previous, blankExpenseMember()]);

  const removeMember = (id: string) => {
    if (members.length <= 2) return;
    setMembers((previous) => previous.filter((member) => member.id !== id));
  };

  const updateMember = (id: string, patch: Partial<Member>) => {
    setMembers((previous) =>
      previous.map((member) => (member.id === id ? { ...member, ...patch } : member))
    );
  };

  const validate = useCallback(() => {
    const nextErrors = validateExpenseFormFields({ title, totalAmount, currency, members, tags });
    setErrors(nextErrors);
    return Object.keys(nextErrors).length === 0;
  }, [title, totalAmount, currency, members, tags]);

  const handleSubmit = useCallback(
    async (event: FormEvent) => {
      event.preventDefault();
      if (!validate()) return;

      setSubmitting(true);
      setRateUnavailable(false);
      try {
        const cleanMembers = members.map((member) => ({
          ...member,
          name: member.name.trim(),
          walletAddress: member.walletAddress ? member.walletAddress.trim().toUpperCase() : undefined,
        }));
        let finalSettlementAmount = toLedgerAmount(totalAmount, "XLM");
        let exchangeRate: string | undefined = undefined;
        let exchangeRateTimestamp: string | undefined = undefined;

        if (currency !== "XLM") {
          const quote = await fetchExchangeRate(currency);

          if (quote === null) {
            // Invariant: rate unavailability never blocks expense creation.
            // The degraded path is a designed state, so we stop converting and
            // record the expense in the currency the user typed, rather than
            // failing the submit or — worse — multiplying by NaN and persisting
            // "NaN" as the amount.
            setSubmitting(false);
            setRateUnavailable(true);
            toastError(
              `Cannot price ${currency} right now`,
              "Exchange rates are temporarily unavailable. Enter the amount in XLM to continue — nothing you typed has been lost.",
            );
            return;
          }

          exchangeRate = quote.rate;
          exchangeRateTimestamp = quote.fetchedAtIso;
          finalSettlementAmount = convertAssetAmount(
            totalAmount,
            currency,
            "XLM",
            quote.rate,
          );

          if (quote.stale) {
            // Served from cache past its TTL. The expense is still created —
            // a slightly old rate beats no expense — but the user is told,
            // because a silently stale rate is the worst failure mode.
            toastInfo(
              "Using a recent exchange rate",
              `The live rate is unavailable, so a rate from ${describeAge(quote.rateAgeMs)} ago was used.`,
            );
          }
        }

        const calculatedShares = calculateSplit(
          finalSettlementAmount,
          cleanMembers,
          paidByMemberId,
          splitMode,
        );

        const expense: Expense = {
          id: crypto.randomUUID(),
          title: title.trim(),
          description: description.trim() || undefined,
          totalAmount: finalSettlementAmount,
          currency,
          exchangeRate,
          exchangeRateTimestamp,
          category: category || null,
          tags,
          splitMode,
          paidByMemberId,
          members: cleanMembers,
          shares: calculatedShares,
          createdAt: new Date().toISOString(),
          settled: false,
        };

        await addExpense(expense);
        toastSuccess("Expense created!", `"${expense.title}" split among ${cleanMembers.length} members.`);
        onSuccess?.(expense.id);
      } catch (err: unknown) {
        const raw = err instanceof Error ? err.message : "Failed to create expense.";
        if (raw.includes("policy") || raw.includes("permission") || raw.includes("uuid") || raw.includes("syntax")) {
          toastError("Save failed", "Database error. Please check your setup or try again.");
        } else if (raw.includes("fetch") || raw.includes("network") || raw.includes("Network")) {
          toastError("No connection", "Cannot reach server. Check your connection (WARP on?).");
        } else {
          toastError("Error", raw);
        }
      } finally {
        setSubmitting(false);
      }
    },
    // `currency` and `toastInfo` are both read in the body above and belong
    // here. Omitting `currency` was a live bug, not just a lint gap: the
    // callback closed over "XLM" from the first render, so switching the
    // dropdown to USD or INR and submitting skipped the conversion branch
    // entirely and persisted the typed amount tagged XLM.
    [
      addExpense,
      category,
      currency,
      description,
      members,
      onSuccess,
      paidByMemberId,
      splitMode,
      tags,
      title,
      toastError,
      toastInfo,
      toastSuccess,
      totalAmount,
      validate,
    ],
  );

  return {
    title,
    setTitle,
    description,
    setDescription,
    totalAmount,
    setTotalAmount,
    currency,
    setCurrency,
    category,
    setCategory,
    tagsInput,
    setTagsInput,
    tags,
    splitMode,
    setSplitMode,
    members,
    paidByMemberId,
    setPaidByMemberId,
    submitting,
    errors,
    /** True when the last submit could not be priced; the form is still filled in. */
    rateUnavailable,
    namedMembers,
    shares,
    payerName,
    addMember,
    removeMember,
    updateMember,
    handleSubmit,
  };
}

function resolveInitialMembers(
  defaultMembers?: Member[],
  currentUserName?: string | null,
  currentUserPublicKey?: string | null,
) {
  if (defaultMembers && defaultMembers.length >= 2) return defaultMembers;

  return [
    {
      id: crypto.randomUUID(),
      name: currentUserName ?? "",
      walletAddress: currentUserPublicKey ?? "",
      weight: 1,
    },
    blankExpenseMember(),
  ];
}
