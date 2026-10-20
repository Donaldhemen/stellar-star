"use client";

import React, { createContext, useContext, useState, useEffect, useCallback, useMemo } from "react";
import {
  type Locale,
  type LocaleInfo,
  SUPPORTED_LOCALES,
  DEFAULT_LOCALE,
  isRTL as checkIsRTL,
  getDirection,
  translate,
  parseLocaleAmount,
  type ParseAmountResult,
  formatLocaleDate,
  formatLocaleDateTime,
  type DateFormatStyle,
} from "@/lib/i18n";

export type { Locale, LocaleInfo };
export { SUPPORTED_LOCALES };

interface LocaleContextType {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  isRTL: boolean;
  dir: "rtl" | "ltr";
  t: (key: string, params?: Record<string, string | number>) => string;
  formatDate: (
    date: Date | string | number,
    options?: Intl.DateTimeFormatOptions | DateFormatStyle
  ) => string;
  formatDateTime: (date: Date | string | number) => string;
  parseAmount: (input: string) => ParseAmountResult;
}

const LocaleContext = createContext<LocaleContextType | undefined>(undefined);

const VALID_LOCALES: Locale[] = ["en-US", "de-DE", "hi-IN", "ja-JP", "ar-SA", "qps-ploc"];

export function LocaleProvider({ children }: { children: React.ReactNode }) {
  const [locale, setLocale] = useState<Locale>(DEFAULT_LOCALE);

  useEffect(() => {
    const saved = localStorage.getItem("stellar-star-locale") as Locale;
    if (saved && VALID_LOCALES.includes(saved)) {
      setLocale(saved);
    } else if (typeof window !== "undefined" && window.navigator) {
      const browserLang = window.navigator.language?.toLowerCase() ?? "";
      if (browserLang.startsWith("de")) {
        setLocale("de-DE");
      } else if (browserLang.startsWith("hi")) {
        setLocale("hi-IN");
      } else if (browserLang.startsWith("ja")) {
        setLocale("ja-JP");
      } else if (browserLang.startsWith("ar")) {
        setLocale("ar-SA");
      } else {
        setLocale("en-US");
      }
    }
  }, []);

  const isRTL = useMemo(() => checkIsRTL(locale), [locale]);
  const dir = useMemo(() => getDirection(locale), [locale]);

  // Synchronize document attributes for accessibility and layout direction
  useEffect(() => {
    if (typeof document !== "undefined") {
      const langCode = locale === "qps-ploc" ? "en" : locale.split("-")[0];
      document.documentElement.lang = langCode;
      document.documentElement.dir = dir;
    }
  }, [locale, dir]);

  const handleSetLocale = useCallback((newLocale: Locale) => {
    setLocale(newLocale);
    try {
      localStorage.setItem("stellar-star-locale", newLocale);
    } catch {
      // Ignore localStorage errors in restricted environments
    }
  }, []);

  const t = useCallback(
    (key: string, params?: Record<string, string | number>) => {
      return translate(locale, key, params);
    },
    [locale]
  );

  const formatDate = useCallback(
    (
      date: Date | string | number,
      options?: Intl.DateTimeFormatOptions | DateFormatStyle
    ) => {
      return formatLocaleDate(date, locale, options);
    },
    [locale]
  );

  const formatDateTime = useCallback(
    (date: Date | string | number) => {
      return formatLocaleDateTime(date, locale);
    },
    [locale]
  );

  const parseAmount = useCallback(
    (input: string) => {
      return parseLocaleAmount(input, locale);
    },
    [locale]
  );

  const contextValue = useMemo<LocaleContextType>(
    () => ({
      locale,
      setLocale: handleSetLocale,
      isRTL,
      dir,
      t,
      formatDate,
      formatDateTime,
      parseAmount,
    }),
    [locale, handleSetLocale, isRTL, dir, t, formatDate, formatDateTime, parseAmount]
  );

  return <LocaleContext.Provider value={contextValue}>{children}</LocaleContext.Provider>;
}

export function useLocale(): LocaleContextType {
  const context = useContext(LocaleContext);
  if (!context) {
    // Safe default fallback for tests, SSR or static generation
    return {
      locale: DEFAULT_LOCALE,
      setLocale: () => {},
      isRTL: false,
      dir: "ltr",
      t: (key: string, params?: Record<string, string | number>) =>
        translate(DEFAULT_LOCALE, key, params),
      formatDate: (
        date: Date | string | number,
        options?: Intl.DateTimeFormatOptions | DateFormatStyle
      ) => formatLocaleDate(date, DEFAULT_LOCALE, options),
      formatDateTime: (date: Date | string | number) =>
        formatLocaleDateTime(date, DEFAULT_LOCALE),
      parseAmount: (input: string) => parseLocaleAmount(input, DEFAULT_LOCALE),
    };
  }
  return context;
}
