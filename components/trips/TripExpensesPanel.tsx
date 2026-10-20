"use client";

import { AnimatePresence, motion } from "framer-motion";
import { Plus, ReceiptText } from "lucide-react";
import { ExpenseCard } from "@/components/expenses/ExpenseCard";
import type { Expense } from "@/types/expense";

interface TripExpensesPanelProps {
  expenses: Expense[];
  tripId: string;
  currentUserPublicKey?: string | null;
  /** Omitted when the trip's permissions do not let this viewer add expenses. */
  onAddExpense?: () => void;
}

export function TripExpensesPanel({
  expenses,
  tripId,
  currentUserPublicKey,
  onAddExpense,
}: TripExpensesPanelProps) {
  return (
    <motion.div
      key="expenses"
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.15 }}
    >
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-sm font-bold text-[#0F0F14]">Expenses ({expenses.length})</h2>
        {onAddExpense ? (
          <button
            onClick={onAddExpense}
            className="flex items-center gap-1.5 text-xs font-bold px-3 py-2 rounded-xl bg-[#0F0F14] text-[#2DD4BF] hover:bg-[#1A1A22] transition-all"
          >
            <Plus size={12} />
            Add Expense
          </button>
        ) : (
          <span className="text-[11px] text-[#AAA]">Only the trip creator can add expenses</span>
        )}
      </div>
      {expenses.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-10 px-4 text-center rounded-xl border border-dashed border-[#E5E5E5]">
          <ReceiptText size={20} className="text-[#CCC] mb-2" />
          <p className="text-sm text-[#AAA]">No expenses in this trip yet.</p>
        </div>
      ) : (
        <div className="space-y-3">
          <AnimatePresence mode="popLayout">
            {expenses.map((expense) => (
              <ExpenseCard
                key={expense.id}
                expense={expense}
                currentUserPublicKey={currentUserPublicKey}
                tripId={tripId}
              />
            ))}
          </AnimatePresence>
        </div>
      )}
    </motion.div>
  );
}
