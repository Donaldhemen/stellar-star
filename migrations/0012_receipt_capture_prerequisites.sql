-- Issue #340: replay receipt/form prerequisites under a unique migration version.
-- Historical branches reused 0008/0009/0010; do not renumber applied history.
-- Every operation below is idempotent. FX freeze is restored last to preserve provenance.

-- ============================================================================
-- Stellar-star Migration 0008: Expense categories, tags & filterable history
-- (issue #317)
-- ============================================================================
-- Lightweight organization for long trips. Nothing here changes how much
-- anyone owes: category and tags are labels, and settlement_asset only makes
-- the asset an expense already settles in queryable (NULL = native XLM, which
-- is what every existing row settles in).
--
-- Search and filtering run server-side in public.search_expenses(), a
-- SECURITY INVOKER function, so the caller's existing RLS policies decide
-- visibility exactly as they do for a plain SELECT.

-- â”€â”€â”€ Columns â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS settlement_asset TEXT,
  ADD COLUMN IF NOT EXISTS category TEXT,
  ADD COLUMN IF NOT EXISTS tags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];

-- Keep in step with EXPENSE_CATEGORIES in lib/expense/categories.ts.
DO $constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'expenses_category_check') THEN
    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_category_check CHECK (
        category IS NULL OR category IN (
          'food', 'groceries', 'lodging', 'transport', 'activities', 'shopping',
          'utilities', 'rent', 'subscriptions', 'health', 'other'
        )
      );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'expenses_tags_limit_check') THEN
    ALTER TABLE public.expenses
      ADD CONSTRAINT expenses_tags_limit_check CHECK (cardinality(tags) <= 10);
  END IF;
END
$constraints$;

-- â”€â”€â”€ Tag normalization â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Mirrors normalizeTag() in lib/expense/tags.ts: lowercase, strip a leading
-- '#', collapse non-alphanumeric runs to '-', trim '-', cap at 32 characters,
-- de-duplicate keeping first-seen order. Enforced here so a client that skips
-- the TypeScript helper still cannot store "Beach" and "beach" as two tags.
CREATE OR REPLACE FUNCTION public.normalize_expense_tags(p_tags TEXT[])
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT COALESCE(array_agg(tag ORDER BY first_pos), ARRAY[]::TEXT[])
  FROM (
    SELECT tag, MIN(pos) AS first_pos
    FROM (
      SELECT
        btrim(left(btrim(regexp_replace(
          regexp_replace(lower(btrim(raw)), '^#+', ''),
          '[^[:alnum:]]+', '-', 'g'
        ), '-'), 32), '-') AS tag,
        pos
      FROM unnest(COALESCE(p_tags, ARRAY[]::TEXT[])) WITH ORDINALITY AS t(raw, pos)
    ) cleaned
    WHERE tag <> ''
    GROUP BY tag
  ) deduped;
$fn$;

CREATE OR REPLACE FUNCTION public.normalize_expense_labels()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.tags := public.normalize_expense_tags(NEW.tags);
  NEW.category := NULLIF(lower(btrim(NEW.category)), '');
  RETURN NEW;
END;
$fn$;

-- Runs after the 01â€“04 integrity pipeline (triggers fire alphabetically).
DROP TRIGGER IF EXISTS trg_05_expenses_normalize_labels ON public.expenses;
CREATE TRIGGER trg_05_expenses_normalize_labels
  BEFORE INSERT OR UPDATE ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.normalize_expense_labels();

-- â”€â”€â”€ Freeze the settlement asset â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- The asset is part of the debt, exactly like the amount: a member relabelling
-- an expense must not be able to change what it settles in. Same function as
-- migration 0005, plus settlement_asset.
CREATE OR REPLACE FUNCTION public.freeze_row_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
  old_json JSONB;
  new_json JSONB;
BEGIN
  old_json := to_jsonb(OLD);
  new_json := to_jsonb(NEW);

  new_json := new_json
    || jsonb_build_object('id', old_json -> 'id')
    || jsonb_build_object('created_at', old_json -> 'created_at')
    || jsonb_build_object('created_by_wallet', old_json -> 'created_by_wallet')
    || jsonb_build_object('total_amount', old_json -> 'total_amount')
    || jsonb_build_object('currency', old_json -> 'currency')
    || jsonb_build_object('exchange_rate', old_json -> 'exchange_rate')
    || jsonb_build_object('exchange_rate_timestamp', old_json -> 'exchange_rate_timestamp')
    || jsonb_build_object('settlement_asset', old_json -> 'settlement_asset');

  RETURN jsonb_populate_record(NEW, new_json);
END;
$fn$;

-- â”€â”€â”€ Search â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Everything free-text search looks at, lowercased. Mirrors
-- expenseSearchDocument() in lib/expense/historyFilters.ts. Computed on read
-- rather than stored, so existing rows need no backfill (a backfill UPDATE
-- would re-run the share validation and bump updated_at on every expense).
CREATE OR REPLACE FUNCTION public.expense_search_document(p_expense public.expenses)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
  SELECT lower(concat_ws(' ',
    p_expense.title,
    p_expense.description,
    p_expense.category,
    array_to_string(p_expense.tags, ' '),
    (SELECT string_agg(concat_ws(' ', m ->> 'name', m ->> 'walletAddress'), ' ')
       FROM jsonb_array_elements(
         CASE WHEN jsonb_typeof(p_expense.members) = 'array' THEN p_expense.members ELSE '[]'::jsonb END
       ) AS m),
    (SELECT string_agg(s ->> 'txHash', ' ')
       FROM jsonb_array_elements(
         CASE WHEN jsonb_typeof(p_expense.shares) = 'array' THEN p_expense.shares ELSE '[]'::jsonb END
       ) AS s
      WHERE s ? 'txHash')
  ));
$fn$;

-- Filtered, searched, keyset-paginated history. Every filter is optional (NULL
-- = not applied). Semantics match matchesExpenseHistoryFilters() in
-- lib/expense/historyFilters.ts:
--   p_trip_id   only expenses linked from that trip's expense_ids
--   p_terms     lowercased terms; ALL must appear in the search document
--   p_category  a category, or 'uncategorized' for NULL
--   p_tags      the expense must carry ALL of them
--   p_payer     paid_by_member_id, or the payer member's wallet address
--   p_status    'open' (not settled) | 'unpaid' | 'partial' | 'settled'
--   p_asset     canonical asset key; 'native' also matches NULL
--   p_from/p_to half-open [from, to) instant range on created_at
--   p_cursor_*  keyset position from the previous page (created_at, id)
CREATE OR REPLACE FUNCTION public.search_expenses(
  p_trip_id           UUID        DEFAULT NULL,
  p_terms             TEXT[]      DEFAULT NULL,
  p_category          TEXT        DEFAULT NULL,
  p_tags              TEXT[]      DEFAULT NULL,
  p_payer             TEXT        DEFAULT NULL,
  p_status            TEXT        DEFAULT NULL,
  p_asset             TEXT        DEFAULT NULL,
  p_from              TIMESTAMPTZ DEFAULT NULL,
  p_to                TIMESTAMPTZ DEFAULT NULL,
  p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id         UUID        DEFAULT NULL,
  p_limit             INT         DEFAULT 21
)
RETURNS SETOF public.expenses
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  SELECT e.*
  FROM public.expenses e
  WHERE (p_trip_id IS NULL OR e.id::text IN (
          SELECT unnest(t.expense_ids) FROM public.trips t WHERE t.id = p_trip_id))
    AND (p_category IS NULL
         OR (p_category = 'uncategorized' AND e.category IS NULL)
         OR e.category = p_category)
    AND (p_tags IS NULL OR cardinality(p_tags) = 0 OR e.tags @> p_tags)
    AND (p_payer IS NULL
         OR e.paid_by_member_id = p_payer
         OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(e.members) = 'array' THEN e.members ELSE '[]'::jsonb END
           ) AS m
           WHERE m ->> 'id' = e.paid_by_member_id
             AND upper(m ->> 'walletAddress') = upper(p_payer)))
    AND (p_status IS NULL
         OR (p_status = 'settled' AND e.settled)
         OR (p_status = 'open' AND NOT e.settled)
         OR (p_status IN ('unpaid', 'partial') AND NOT e.settled AND (
               EXISTS (
                 SELECT 1
                 FROM jsonb_array_elements(
                   CASE WHEN jsonb_typeof(e.shares) = 'array' THEN e.shares ELSE '[]'::jsonb END
                 ) AS s
                 WHERE (s ->> 'paid')::boolean IS TRUE)
             ) = (p_status = 'partial')))
    AND (p_asset IS NULL
         OR COALESCE(NULLIF(e.settlement_asset, ''), 'native') = p_asset)
    AND (p_from IS NULL OR e.created_at >= p_from)
    AND (p_to IS NULL OR e.created_at < p_to)
    AND (p_cursor_created_at IS NULL
         OR e.created_at < p_cursor_created_at
         OR (p_cursor_id IS NOT NULL AND e.created_at = p_cursor_created_at AND e.id < p_cursor_id))
    AND (p_terms IS NULL OR NOT EXISTS (
          SELECT 1 FROM unnest(p_terms) AS term
          WHERE strpos(public.expense_search_document(e), lower(term)) = 0))
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 21), 1), 101);
$fn$;

GRANT EXECUTE ON FUNCTION public.search_expenses(
  UUID, TEXT[], TEXT, TEXT[], TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, UUID, INT
) TO authenticated;

-- â”€â”€â”€ Indexes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

-- Keyset pagination: ORDER BY created_at DESC, id DESC with a (created_at, id) bound.
CREATE INDEX IF NOT EXISTS idx_expenses_created_at_id
  ON public.expenses (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_expenses_category_created_at
  ON public.expenses (category, created_at DESC);

-- Containment (tags @> ARRAY[...]) is what the tag filter uses.
CREATE INDEX IF NOT EXISTS idx_expenses_tags
  ON public.expenses USING GIN (tags);

NOTIFY pgrst, 'reload schema';

INSERT INTO public.schema_migrations (version, name, checksum)
VALUES ('0008', '0008_expense_categories_tags_search', 'expense_categories_tags_search_v1')
ON CONFLICT (version) DO NOTHING;

-- ============================================================================
-- Stellar-star Migration 0008: Trip templates & duplicate-from-history (#321)
-- ============================================================================
-- Repeated groups (flatmates, teams, annual trips) can save a trip's structure
-- as a template, or start a new trip from a template or a past trip.
--
-- Guarantees enforced here rather than trusted from the client:
--   1. A copy never carries history. create_trip_from_copy writes
--      expense_ids = '{}' and settled = FALSE whatever the payload says.
--   2. Copies are idempotent. The caller supplies an idempotency key; a retry
--      with the same key returns the row the first call created.
--   3. Copies are audited. Every successful copy appends one immutable row to
--      trip_copy_events in the same transaction as the write it describes.
--   4. A caller can only copy what RLS already lets them read.
-- See docs/DESIGN_TRIP_TEMPLATES.md.

-- â”€â”€ Trip structure columns â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS starts_on           DATE,
  ADD COLUMN IF NOT EXISTS ends_on             DATE,
  ADD COLUMN IF NOT EXISTS recurring_rules     JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS permissions         JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS source_template_id  TEXT,
  ADD COLUMN IF NOT EXISTS copied_from_trip_id TEXT;

-- â”€â”€ Templates â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Private to the wallet that saved them. No balances, shares or payments: the
-- columns that would hold them do not exist.
CREATE TABLE IF NOT EXISTS public.trip_templates (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_wallet     TEXT        NOT NULL,
  name             TEXT        NOT NULL CHECK (length(btrim(name)) > 0),
  description      TEXT,
  members          JSONB       NOT NULL DEFAULT '[]'::jsonb,
  recurring_rules  JSONB       NOT NULL DEFAULT '[]'::jsonb,
  permissions      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  duration_days    INT         CHECK (duration_days IS NULL OR duration_days > 0),
  source_trip_id   TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trip_templates_owner_created_at
  ON public.trip_templates (owner_wallet, created_at DESC);

DROP TRIGGER IF EXISTS trip_templates_set_updated_at ON public.trip_templates;
CREATE TRIGGER trip_templates_set_updated_at
  BEFORE UPDATE ON public.trip_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.trip_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trip_templates_select_owner ON public.trip_templates;
CREATE POLICY trip_templates_select_owner ON public.trip_templates
  FOR SELECT USING (owner_wallet = public.current_wallet());

DROP POLICY IF EXISTS trip_templates_insert_owner ON public.trip_templates;
CREATE POLICY trip_templates_insert_owner ON public.trip_templates
  FOR INSERT WITH CHECK (owner_wallet = public.current_wallet());

DROP POLICY IF EXISTS trip_templates_update_owner ON public.trip_templates;
CREATE POLICY trip_templates_update_owner ON public.trip_templates
  FOR UPDATE USING      (owner_wallet = public.current_wallet())
             WITH CHECK (owner_wallet = public.current_wallet());

DROP POLICY IF EXISTS trip_templates_delete_owner ON public.trip_templates;
CREATE POLICY trip_templates_delete_owner ON public.trip_templates
  FOR DELETE USING (owner_wallet = public.current_wallet());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.trip_templates TO authenticated;

-- â”€â”€ Copy audit log â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Append-only: there is no UPDATE or DELETE policy, so under RLS a row can be
-- written once (by the function below, as the caller) and never rewritten.
CREATE TABLE IF NOT EXISTS public.trip_copy_events (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key  TEXT        NOT NULL,
  operation        TEXT        NOT NULL
                   CHECK (operation IN ('trip_to_template', 'template_to_trip', 'trip_to_trip')),
  actor_wallet     TEXT        NOT NULL,
  source_kind      TEXT        NOT NULL CHECK (source_kind IN ('template', 'trip')),
  source_id        TEXT        NOT NULL,
  target_kind      TEXT        NOT NULL CHECK (target_kind IN ('template', 'trip')),
  target_id        TEXT        NOT NULL,
  -- Counts of what was copied, for the audit trail. Never balances or amounts.
  summary          JSONB       NOT NULL DEFAULT '{}'::jsonb,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT trip_copy_events_idempotency_key_unique UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_trip_copy_events_actor_created_at
  ON public.trip_copy_events (actor_wallet, created_at DESC);

ALTER TABLE public.trip_copy_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trip_copy_events_select_actor ON public.trip_copy_events;
CREATE POLICY trip_copy_events_select_actor ON public.trip_copy_events
  FOR SELECT USING (actor_wallet = public.current_wallet());

DROP POLICY IF EXISTS trip_copy_events_insert_actor ON public.trip_copy_events;
CREATE POLICY trip_copy_events_insert_actor ON public.trip_copy_events
  FOR INSERT WITH CHECK (actor_wallet = public.current_wallet());

GRANT SELECT, INSERT ON public.trip_copy_events TO authenticated;

-- â”€â”€ create_trip_from_copy â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- SECURITY INVOKER on purpose: every read and write below runs under the
-- caller's RLS, so a source the caller cannot see is reported as not found.
CREATE OR REPLACE FUNCTION public.create_trip_from_copy(
  p_idempotency_key TEXT,
  p_source_kind     TEXT,
  p_source_id       TEXT,
  p_trip            JSONB
)
RETURNS SETOF public.trips
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  v_wallet   TEXT := public.current_wallet();
  v_event    public.trip_copy_events%ROWTYPE;
  v_trip_id  UUID;
  v_name     TEXT := btrim(COALESCE(p_trip ->> 'name', ''));
  v_members  JSONB := COALESCE(p_trip -> 'members', '[]'::jsonb);
  v_rules    JSONB := COALESCE(p_trip -> 'recurring_rules', '[]'::jsonb);
  v_starts   DATE := NULLIF(p_trip ->> 'starts_on', '')::DATE;
  v_ends     DATE := NULLIF(p_trip ->> 'ends_on', '')::DATE;
BEGIN
  IF v_wallet IS NULL THEN
    RAISE EXCEPTION 'COPY_UNAUTHENTICATED' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 16 THEN
    RAISE EXCEPTION 'COPY_INVALID_KEY';
  END IF;
  IF p_source_kind NOT IN ('template', 'trip') THEN
    RAISE EXCEPTION 'COPY_INVALID_SOURCE';
  END IF;

  -- Replay: the same key always resolves to the trip it first created.
  SELECT * INTO v_event FROM public.trip_copy_events WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_event.actor_wallet <> v_wallet THEN
      RAISE EXCEPTION 'COPY_KEY_CONFLICT';
    END IF;
    RETURN QUERY SELECT * FROM public.trips WHERE id::TEXT = v_event.target_id;
    RETURN;
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'COPY_INVALID_TRIP: name is required';
  END IF;
  IF jsonb_typeof(v_members) <> 'array' OR jsonb_array_length(v_members) < 2 THEN
    RAISE EXCEPTION 'COPY_INVALID_TRIP: at least two members are required';
  END IF;
  IF jsonb_typeof(v_rules) <> 'array' THEN
    RAISE EXCEPTION 'COPY_INVALID_TRIP: recurring_rules must be an array';
  END IF;
  IF v_starts IS NOT NULL AND v_ends IS NOT NULL AND v_ends < v_starts THEN
    RAISE EXCEPTION 'COPY_INVALID_TRIP: end date precedes start date';
  END IF;

  IF p_source_kind = 'template' THEN
    PERFORM 1 FROM public.trip_templates WHERE id::TEXT = p_source_id;
  ELSE
    PERFORM 1 FROM public.trips WHERE id::TEXT = p_source_id;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COPY_SOURCE_NOT_FOUND';
  END IF;

  v_trip_id := COALESCE(NULLIF(p_trip ->> 'id', '')::UUID, gen_random_uuid());

  -- Claim the key before writing. A concurrent call with the same key blocks
  -- on the unique index, then sees the conflict and returns the winner's row.
  INSERT INTO public.trip_copy_events (
    idempotency_key, operation, actor_wallet,
    source_kind, source_id, target_kind, target_id, summary
  ) VALUES (
    p_idempotency_key,
    CASE WHEN p_source_kind = 'template' THEN 'template_to_trip' ELSE 'trip_to_trip' END,
    v_wallet,
    p_source_kind, p_source_id, 'trip', v_trip_id::TEXT,
    jsonb_build_object(
      'member_count', jsonb_array_length(v_members),
      'recurring_rule_count', jsonb_array_length(v_rules),
      'has_dates', v_starts IS NOT NULL OR v_ends IS NOT NULL,
      'excluded', jsonb_build_array('expenses', 'shares', 'payments', 'balances', 'settled')
    )
  )
  ON CONFLICT (idempotency_key) DO NOTHING;

  IF NOT FOUND THEN
    SELECT * INTO v_event FROM public.trip_copy_events WHERE idempotency_key = p_idempotency_key;
    IF v_event.actor_wallet <> v_wallet THEN
      RAISE EXCEPTION 'COPY_KEY_CONFLICT';
    END IF;
    RETURN QUERY SELECT * FROM public.trips WHERE id::TEXT = v_event.target_id;
    RETURN;
  END IF;

  INSERT INTO public.trips (
    id, name, description, members, expense_ids, settled, created_by_wallet,
    starts_on, ends_on, recurring_rules, permissions,
    source_template_id, copied_from_trip_id
  ) VALUES (
    v_trip_id,
    v_name,
    NULLIF(btrim(COALESCE(p_trip ->> 'description', '')), ''),
    v_members,
    ARRAY[]::TEXT[],          -- history is never copied
    FALSE,
    v_wallet,
    v_starts,
    v_ends,
    v_rules,
    COALESCE(p_trip -> 'permissions', '{}'::jsonb),
    CASE WHEN p_source_kind = 'template' THEN p_source_id END,
    CASE WHEN p_source_kind = 'trip' THEN p_source_id END
  );

  RETURN QUERY SELECT * FROM public.trips WHERE id = v_trip_id;
END;
$fn$;

-- â”€â”€ save_trip_template â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.save_trip_template(
  p_idempotency_key TEXT,
  p_source_trip_id  TEXT,
  p_template        JSONB
)
RETURNS SETOF public.trip_templates
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $fn$
DECLARE
  v_wallet      TEXT := public.current_wallet();
  v_event       public.trip_copy_events%ROWTYPE;
  v_template_id UUID := gen_random_uuid();
  v_name        TEXT := btrim(COALESCE(p_template ->> 'name', ''));
  v_members     JSONB := COALESCE(p_template -> 'members', '[]'::jsonb);
  v_rules       JSONB := COALESCE(p_template -> 'recurring_rules', '[]'::jsonb);
BEGIN
  IF v_wallet IS NULL THEN
    RAISE EXCEPTION 'COPY_UNAUTHENTICATED' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 16 THEN
    RAISE EXCEPTION 'COPY_INVALID_KEY';
  END IF;

  SELECT * INTO v_event FROM public.trip_copy_events WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_event.actor_wallet <> v_wallet THEN
      RAISE EXCEPTION 'COPY_KEY_CONFLICT';
    END IF;
    RETURN QUERY SELECT * FROM public.trip_templates WHERE id::TEXT = v_event.target_id;
    RETURN;
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'COPY_INVALID_TEMPLATE: name is required';
  END IF;
  IF jsonb_typeof(v_members) <> 'array' OR jsonb_typeof(v_rules) <> 'array' THEN
    RAISE EXCEPTION 'COPY_INVALID_TEMPLATE: members and recurring_rules must be arrays';
  END IF;

  PERFORM 1 FROM public.trips WHERE id::TEXT = p_source_trip_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COPY_SOURCE_NOT_FOUND';
  END IF;

  INSERT INTO public.trip_copy_events (
    idempotency_key, operation, actor_wallet,
    source_kind, source_id, target_kind, target_id, summary
  ) VALUES (
    p_idempotency_key, 'trip_to_template', v_wallet,
    'trip', p_source_trip_id, 'template', v_template_id::TEXT,
    jsonb_build_object(
      'member_count', jsonb_array_length(v_members),
      'recurring_rule_count', jsonb_array_length(v_rules),
      'excluded', jsonb_build_array('expenses', 'shares', 'payments', 'balances', 'settled')
    )
  )
  ON CONFLICT (idempotency_key) DO NOTHING;

  IF NOT FOUND THEN
    SELECT * INTO v_event FROM public.trip_copy_events WHERE idempotency_key = p_idempotency_key;
    IF v_event.actor_wallet <> v_wallet THEN
      RAISE EXCEPTION 'COPY_KEY_CONFLICT';
    END IF;
    RETURN QUERY SELECT * FROM public.trip_templates WHERE id::TEXT = v_event.target_id;
    RETURN;
  END IF;

  INSERT INTO public.trip_templates (
    id, owner_wallet, name, description, members, recurring_rules,
    permissions, duration_days, source_trip_id
  ) VALUES (
    v_template_id,
    v_wallet,
    v_name,
    NULLIF(btrim(COALESCE(p_template ->> 'description', '')), ''),
    v_members,
    v_rules,
    COALESCE(p_template -> 'permissions', '{}'::jsonb),
    NULLIF(p_template ->> 'duration_days', '')::INT,
    p_source_trip_id
  );

  RETURN QUERY SELECT * FROM public.trip_templates WHERE id = v_template_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.create_trip_from_copy(TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_trip_template(TEXT, TEXT, JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.schema_migrations (version, name, checksum)
VALUES ('0008', '0008_trip_templates', 'trip_templates_v1')
ON CONFLICT (version) DO NOTHING;

-- ============================================================================
-- Stellar-star Migration 0009: Reusable contacts & member profiles (#322)
-- ============================================================================
-- A private address book so names and wallets are not retyped for every trip.
--
-- Guarantees enforced by the database, not trusted from the client:
--   1. Contacts are private: every policy is owner_wallet = current_wallet().
--   2. Duplicates are detected by canonical wallet address, never by name:
--      UNIQUE (owner_wallet, wallet_address) on the upper-cased address.
--   3. Only the wallet's owner can verify it. wallet_verified/claimed_by_wallet
--      are writable solely by claim_contact_profile, which requires a session
--      signed by that very wallet.
--   4. A wallet already on a contact is never swapped in place. The change is
--      recorded in contact_wallet_changes, visible to every member of the
--      affected active trips, and applies only after the notice period.
--      Historic shares and payments are never rewritten.
-- See docs/DESIGN_CONTACTS.md.

-- â”€â”€ Contacts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE TABLE IF NOT EXISTS public.contacts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_wallet        TEXT        NOT NULL,
  display_name        TEXT        NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 80),
  wallet_address      TEXT        CHECK (wallet_address IS NULL OR wallet_address ~ '^G[A-Z2-7]{55}$'),
  wallet_verified     BOOLEAN     NOT NULL DEFAULT FALSE,
  claimed_by_wallet   TEXT,
  verified_at         TIMESTAMPTZ,
  invite_destination  TEXT        CHECK (invite_destination IS NULL OR length(invite_destination) <= 254),
  invite_channel      TEXT        CHECK (invite_channel IS NULL OR invite_channel IN ('email', 'phone', 'other')),
  -- SHA-256 of a one-time claim token; the token itself is never stored.
  claim_token_hash    TEXT,
  claim_expires_at    TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS contacts_owner_wallet_unique_idx
  ON public.contacts (owner_wallet, wallet_address)
  WHERE wallet_address IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS contacts_claim_token_hash_idx
  ON public.contacts (claim_token_hash)
  WHERE claim_token_hash IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_contacts_owner_name
  ON public.contacts (owner_wallet, display_name);

-- Canonicalises input and protects the verification columns. Functions below
-- that are allowed to touch them set stellar_star.contact_privileged for the
-- current transaction only.
CREATE OR REPLACE FUNCTION public.guard_contact_row()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
  privileged BOOLEAN := COALESCE(current_setting('stellar_star.contact_privileged', true), '') = 'on';
BEGIN
  NEW.display_name := btrim(NEW.display_name);
  NEW.wallet_address := NULLIF(upper(btrim(COALESCE(NEW.wallet_address, ''))), '');
  NEW.invite_destination := NULLIF(btrim(COALESCE(NEW.invite_destination, '')), '');

  IF privileged THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.wallet_verified := FALSE;
    NEW.claimed_by_wallet := NULL;
    NEW.verified_at := NULL;
    RETURN NEW;
  END IF;

  -- UPDATE by the owner.
  NEW.owner_wallet := OLD.owner_wallet;
  NEW.wallet_verified := OLD.wallet_verified;
  NEW.claimed_by_wallet := OLD.claimed_by_wallet;
  NEW.verified_at := OLD.verified_at;

  IF OLD.wallet_address IS NOT NULL
     AND NEW.wallet_address IS DISTINCT FROM OLD.wallet_address THEN
    RAISE EXCEPTION 'CONTACT_WALLET_CHANGE_REQUIRES_NOTICE'
      USING HINT = 'Use request_contact_wallet_change so affected trips are notified first.';
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_01_contacts_guard ON public.contacts;
CREATE TRIGGER trg_01_contacts_guard
  BEFORE INSERT OR UPDATE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.guard_contact_row();

DROP TRIGGER IF EXISTS trg_02_contacts_set_updated_at ON public.contacts;
CREATE TRIGGER trg_02_contacts_set_updated_at
  BEFORE UPDATE ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contacts_select_owner ON public.contacts;
CREATE POLICY contacts_select_owner ON public.contacts
  FOR SELECT USING (owner_wallet = public.current_wallet());

DROP POLICY IF EXISTS contacts_insert_owner ON public.contacts;
CREATE POLICY contacts_insert_owner ON public.contacts
  FOR INSERT WITH CHECK (owner_wallet = public.current_wallet());

DROP POLICY IF EXISTS contacts_update_owner ON public.contacts;
CREATE POLICY contacts_update_owner ON public.contacts
  FOR UPDATE USING      (owner_wallet = public.current_wallet())
             WITH CHECK (owner_wallet = public.current_wallet());

DROP POLICY IF EXISTS contacts_delete_owner ON public.contacts;
CREATE POLICY contacts_delete_owner ON public.contacts
  FOR DELETE USING (owner_wallet = public.current_wallet());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.contacts TO authenticated;

-- â”€â”€ Wallet change history â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Written only by the functions below. Readable by the contact's owner and by
-- every member of an affected trip, which is how those groups are notified.
CREATE TABLE IF NOT EXISTS public.contact_wallet_changes (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id         UUID        NOT NULL REFERENCES public.contacts (id) ON DELETE CASCADE,
  owner_wallet       TEXT        NOT NULL,
  contact_name       TEXT        NOT NULL,
  old_wallet         TEXT,
  new_wallet         TEXT        NOT NULL CHECK (new_wallet ~ '^G[A-Z2-7]{55}$'),
  status             TEXT        NOT NULL DEFAULT 'pending_notice'
                     CHECK (status IN ('pending_notice', 'applied', 'cancelled')),
  affected_trip_ids  TEXT[]      NOT NULL DEFAULT ARRAY[]::TEXT[],
  notice_until       TIMESTAMPTZ NOT NULL,
  verified           BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_contact_wallet_changes_contact_created_at
  ON public.contact_wallet_changes (contact_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_contact_wallet_changes_affected_trips
  ON public.contact_wallet_changes USING GIN (affected_trip_ids);

-- At most one pending change per contact.
CREATE UNIQUE INDEX IF NOT EXISTS contact_wallet_changes_one_pending_idx
  ON public.contact_wallet_changes (contact_id)
  WHERE status = 'pending_notice';

ALTER TABLE public.contact_wallet_changes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contact_wallet_changes_select_party ON public.contact_wallet_changes;
CREATE POLICY contact_wallet_changes_select_party ON public.contact_wallet_changes
  FOR SELECT USING (
    owner_wallet = public.current_wallet()
    OR EXISTS (
      SELECT 1 FROM public.trips t
       WHERE t.id::TEXT = ANY (affected_trip_ids)
         AND t.member_wallets @> ARRAY[public.current_wallet()]
    )
  );

GRANT SELECT ON public.contact_wallet_changes TO authenticated;

-- â”€â”€ request_contact_wallet_change â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.request_contact_wallet_change(
  p_contact_id  UUID,
  p_new_wallet  TEXT
)
RETURNS SETOF public.contact_wallet_changes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_wallet   TEXT := public.current_wallet();
  v_contact  public.contacts%ROWTYPE;
  v_new      TEXT := upper(btrim(COALESCE(p_new_wallet, '')));
  v_affected TEXT[];
BEGIN
  IF v_wallet IS NULL THEN
    RAISE EXCEPTION 'CONTACT_UNAUTHENTICATED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_contact FROM public.contacts
   WHERE id = p_contact_id AND owner_wallet = v_wallet
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONTACT_NOT_FOUND';
  END IF;

  IF v_new !~ '^G[A-Z2-7]{55}$' THEN
    RAISE EXCEPTION 'CONTACT_INVALID_WALLET';
  END IF;
  IF v_new = v_contact.wallet_address THEN
    RAISE EXCEPTION 'CONTACT_WALLET_UNCHANGED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.contacts
              WHERE owner_wallet = v_wallet AND wallet_address = v_new AND id <> p_contact_id) THEN
    RAISE EXCEPTION 'CONTACT_DUPLICATE_WALLET';
  END IF;

  UPDATE public.contact_wallet_changes
     SET status = 'cancelled'
   WHERE contact_id = p_contact_id AND status = 'pending_notice';

  -- Active trips the owner shares with the old wallet. Settled trips are
  -- history and are left alone.
  SELECT COALESCE(array_agg(t.id::TEXT), ARRAY[]::TEXT[]) INTO v_affected
    FROM public.trips t
   WHERE v_contact.wallet_address IS NOT NULL
     AND t.settled = FALSE
     AND t.member_wallets @> ARRAY[v_wallet]
     AND t.member_wallets @> ARRAY[v_contact.wallet_address];

  RETURN QUERY
  INSERT INTO public.contact_wallet_changes (
    contact_id, owner_wallet, contact_name, old_wallet, new_wallet,
    affected_trip_ids, notice_until, verified
  ) VALUES (
    p_contact_id, v_wallet, v_contact.display_name, v_contact.wallet_address, v_new,
    v_affected,
    CASE WHEN cardinality(v_affected) = 0 THEN NOW() ELSE NOW() + INTERVAL '24 hours' END,
    -- An address typed by the owner is never verified; only a claim is.
    FALSE
  )
  RETURNING *;
END;
$fn$;

-- â”€â”€ apply / cancel â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.apply_contact_wallet_change(p_change_id UUID)
RETURNS SETOF public.contacts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_wallet TEXT := public.current_wallet();
  v_change public.contact_wallet_changes%ROWTYPE;
BEGIN
  IF v_wallet IS NULL THEN
    RAISE EXCEPTION 'CONTACT_UNAUTHENTICATED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_change FROM public.contact_wallet_changes
   WHERE id = p_change_id AND owner_wallet = v_wallet
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONTACT_CHANGE_NOT_FOUND';
  END IF;
  IF v_change.status <> 'pending_notice' THEN
    RAISE EXCEPTION 'CONTACT_CHANGE_NOT_PENDING';
  END IF;
  IF cardinality(v_change.affected_trip_ids) > 0 AND v_change.notice_until > NOW() THEN
    RAISE EXCEPTION 'CONTACT_NOTICE_PERIOD_ACTIVE: affected trips are still being notified until %',
      v_change.notice_until;
  END IF;

  PERFORM set_config('stellar_star.contact_privileged', 'on', true);

  UPDATE public.contact_wallet_changes
     SET status = 'applied', applied_at = NOW()
   WHERE id = p_change_id;

  RETURN QUERY
  UPDATE public.contacts
     SET wallet_address    = v_change.new_wallet,
         wallet_verified   = v_change.verified,
         claimed_by_wallet = CASE WHEN v_change.verified THEN v_change.new_wallet END,
         verified_at       = CASE WHEN v_change.verified THEN NOW() END
   WHERE id = v_change.contact_id
  RETURNING *;

  PERFORM set_config('stellar_star.contact_privileged', 'off', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.cancel_contact_wallet_change(p_change_id UUID)
RETURNS SETOF public.contact_wallet_changes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF public.current_wallet() IS NULL THEN
    RAISE EXCEPTION 'CONTACT_UNAUTHENTICATED' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  UPDATE public.contact_wallet_changes
     SET status = 'cancelled'
   WHERE id = p_change_id
     AND owner_wallet = public.current_wallet()
     AND status = 'pending_notice'
  RETURNING *;
END;
$fn$;

-- â”€â”€ claim_contact_profile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- The wallet owner proves control by signing in (the session JWT carries the
-- signature-verified wallet) and presenting the one-time claim token.
CREATE OR REPLACE FUNCTION public.claim_contact_profile(p_token_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_claimant TEXT := public.current_wallet();
  v_contact  public.contacts%ROWTYPE;
  v_change   public.contact_wallet_changes%ROWTYPE;
BEGIN
  IF v_claimant IS NULL THEN
    RAISE EXCEPTION 'CONTACT_UNAUTHENTICATED' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_contact FROM public.contacts
   WHERE claim_token_hash = p_token_hash
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONTACT_CLAIM_INVALID';
  END IF;
  IF v_contact.claim_expires_at IS NULL OR v_contact.claim_expires_at <= NOW() THEN
    RAISE EXCEPTION 'CONTACT_CLAIM_EXPIRED';
  END IF;
  IF v_contact.owner_wallet = v_claimant THEN
    RAISE EXCEPTION 'CONTACT_CLAIM_SELF';
  END IF;
  IF EXISTS (SELECT 1 FROM public.contacts
              WHERE owner_wallet = v_contact.owner_wallet
                AND wallet_address = v_claimant
                AND id <> v_contact.id) THEN
    RAISE EXCEPTION 'CONTACT_DUPLICATE_WALLET';
  END IF;

  PERFORM set_config('stellar_star.contact_privileged', 'on', true);

  -- One-time token: consumed whatever happens next.
  UPDATE public.contacts SET claim_token_hash = NULL, claim_expires_at = NULL
   WHERE id = v_contact.id;

  IF v_contact.wallet_address IS NULL OR v_contact.wallet_address = v_claimant THEN
    -- No address in use yet, or the claim confirms the one already entered:
    -- nothing historic changes, so verify immediately.
    UPDATE public.contacts
       SET wallet_address = v_claimant, wallet_verified = TRUE,
           claimed_by_wallet = v_claimant, verified_at = NOW()
     WHERE id = v_contact.id;

    PERFORM set_config('stellar_star.contact_privileged', 'off', true);
    RETURN jsonb_build_object(
      'status', 'verified',
      'contact_name', v_contact.display_name,
      'owner_wallet', v_contact.owner_wallet
    );
  END IF;

  -- The claimant controls a different wallet than the one on file. Treat it as
  -- an address change, so the owner's active trips are notified first.
  UPDATE public.contact_wallet_changes SET status = 'cancelled'
   WHERE contact_id = v_contact.id AND status = 'pending_notice';

  INSERT INTO public.contact_wallet_changes (
    contact_id, owner_wallet, contact_name, old_wallet, new_wallet,
    affected_trip_ids, notice_until, verified
  )
  SELECT v_contact.id, v_contact.owner_wallet, v_contact.display_name,
         v_contact.wallet_address, v_claimant, affected,
         CASE WHEN cardinality(affected) = 0 THEN NOW() ELSE NOW() + INTERVAL '24 hours' END,
         TRUE
    FROM (
      SELECT COALESCE(array_agg(t.id::TEXT), ARRAY[]::TEXT[]) AS affected
        FROM public.trips t
       WHERE t.settled = FALSE
         AND t.member_wallets @> ARRAY[v_contact.owner_wallet]
         AND t.member_wallets @> ARRAY[v_contact.wallet_address]
    ) a
  RETURNING * INTO v_change;

  PERFORM set_config('stellar_star.contact_privileged', 'off', true);
  RETURN jsonb_build_object(
    'status', 'pending_notice',
    'contact_name', v_contact.display_name,
    'owner_wallet', v_contact.owner_wallet,
    'notice_until', v_change.notice_until
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.request_contact_wallet_change(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_contact_wallet_change(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_contact_wallet_change(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_contact_profile(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_contact_wallet_change(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_contact_wallet_change(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_contact_wallet_change(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_contact_profile(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.schema_migrations (version, name, checksum)
VALUES ('0009', '0009_contacts_member_profiles', 'contacts_member_profiles_v1')
ON CONFLICT (version) DO NOTHING;

-- ============================================================================
-- Stellar-star Migration 0009: Receipt attachments with private storage
-- (issue #318)
-- ============================================================================
-- Receipts are private documents. The files live in a PRIVATE storage bucket
-- reachable only with the service-role key; clients never get a public URL,
-- only a signed link minted by the server after a membership check.
--
-- This table is the metadata and the access-control anchor: clients may READ
-- rows for expenses they are a member of (same rule as expenses), and nobody
-- but the server writes them.

CREATE TABLE IF NOT EXISTS public.expense_receipts (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- SET NULL, not CASCADE: deleting an expense must not orphan the stored file
  -- silently. A NULL expense_id is picked up by the retention sweep, which
  -- deletes the object and tombstones the row.
  expense_id         UUID REFERENCES public.expenses (id) ON DELETE SET NULL,
  storage_path       TEXT        NOT NULL UNIQUE,
  file_name          TEXT        CHECK (file_name IS NULL OR char_length(file_name) <= 120),
  content_type       TEXT        NOT NULL CHECK (content_type IN (
                       'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'
                     )),
  size_bytes         INT         NOT NULL CHECK (size_bytes > 0),
  checksum_sha256    TEXT        NOT NULL CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),
  caption            TEXT        CHECK (caption IS NULL OR char_length(caption) <= 200),
  status             TEXT        NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'quarantined', 'removed')),
  scan_result        JSONB       NOT NULL DEFAULT '{}'::jsonb,
  uploaded_by_wallet TEXT        NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  retain_until       TIMESTAMPTZ NOT NULL,
  removed_at         TIMESTAMPTZ,
  removed_by_wallet  TEXT,
  removal_reason     TEXT        CHECK (removal_reason IS NULL OR removal_reason IN ('user', 'retention', 'expense_deleted'))
);

-- Listing an expense's receipts, newest first.
CREATE INDEX IF NOT EXISTS idx_expense_receipts_expense_created_at
  ON public.expense_receipts (expense_id, created_at DESC);

-- The retention sweep scans live rows by expiry.
CREATE INDEX IF NOT EXISTS idx_expense_receipts_retain_until
  ON public.expense_receipts (retain_until)
  WHERE status <> 'removed';

-- The same bytes attached twice to one expense is a mistake, not two receipts.
CREATE UNIQUE INDEX IF NOT EXISTS expense_receipts_live_checksum_key
  ON public.expense_receipts (expense_id, checksum_sha256)
  WHERE status <> 'removed';

ALTER TABLE public.expense_receipts ENABLE ROW LEVEL SECURITY;

-- Read-only for members of the parent expense. No INSERT/UPDATE/DELETE
-- policies: every write goes through the server routes, which authorize the
-- caller first and then act with the service role.
DROP POLICY IF EXISTS expense_receipts_select_members ON public.expense_receipts;
CREATE POLICY expense_receipts_select_members ON public.expense_receipts
  FOR SELECT TO authenticated
  USING (
    public.current_wallet() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.expenses e
      WHERE e.id = expense_receipts.expense_id
        AND e.member_wallets @> ARRAY[public.current_wallet()]
    )
  );

GRANT SELECT ON public.expense_receipts TO authenticated;

-- â”€â”€â”€ Private storage bucket â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Guarded so the migration also applies to a plain Postgres without Supabase
-- Storage (CI, local restores). No storage.objects policies are created, so
-- anon/authenticated cannot list, read or write the bucket at all.
DO $bucket$
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'storage' AND table_name = 'buckets'
               AND column_name = 'allowed_mime_types') THEN
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES (
      'expense-receipts', 'expense-receipts', FALSE, 4194304,
      ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf']
    )
    ON CONFLICT (id) DO UPDATE
      SET public = FALSE,
          file_size_limit = EXCLUDED.file_size_limit,
          allowed_mime_types = EXCLUDED.allowed_mime_types;
  ELSE
    INSERT INTO storage.buckets (id, name, public)
    VALUES ('expense-receipts', 'expense-receipts', FALSE)
    ON CONFLICT (id) DO UPDATE SET public = FALSE;
  END IF;
END
$bucket$;

INSERT INTO public.schema_migrations (version, name, checksum)
VALUES ('0009', '0009_expense_receipts', 'expense_receipts_v1')
ON CONFLICT (version) DO NOTHING;

-- ============================================================================
-- Stellar-star Migration 0010: Multi-currency entry & FX provenance (#323)
-- ============================================================================
-- Records the full provenance of a converted expense so it can be shown in the
-- expense history, and makes every part of it immutable once saved:
--
--   entered_amount        what the user typed, in `currency` (exact decimal)
--   currency              the entered display currency (existing)
--   exchange_rate         the locked quote's rate (existing)
--   exchange_rate_source  which provider produced the quote
--   exchange_rate_timestamp  when the quote was fetched (existing)
--   total_amount          converted amount in the settlement asset (existing)
--   settlement_asset      Stellar asset the expense settles in ('native' = XLM)
--
-- Rows written before this migration have NULL entered_amount/source and are
-- treated as native-settled, which is what every historical expense was.

ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS entered_amount       TEXT,
  ADD COLUMN IF NOT EXISTS exchange_rate_source TEXT,
  ADD COLUMN IF NOT EXISTS settlement_asset     TEXT NOT NULL DEFAULT 'native';

-- Same identity freeze as 0005, extended to the new provenance columns: a
-- member may edit an expense's title or split, never the quote behind it.
CREATE OR REPLACE FUNCTION public.freeze_row_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
  old_json JSONB;
  new_json JSONB;
BEGIN
  old_json := to_jsonb(OLD);
  new_json := to_jsonb(NEW);

  new_json := new_json
    || jsonb_build_object('id', old_json -> 'id')
    || jsonb_build_object('created_at', old_json -> 'created_at')
    || jsonb_build_object('created_by_wallet', old_json -> 'created_by_wallet');

  -- The original fiat/XLM snapshot is part of the debt. Freeze it even when
  -- exchange_rate is NULL (for native XLM expenses), and freeze the source and
  -- timestamp together with the rate so the provenance cannot be rewritten.
  new_json := new_json
    || jsonb_build_object('total_amount', old_json -> 'total_amount')
    || jsonb_build_object('currency', old_json -> 'currency')
    || jsonb_build_object('exchange_rate', old_json -> 'exchange_rate')
    || jsonb_build_object('exchange_rate_timestamp', old_json -> 'exchange_rate_timestamp')
    || jsonb_build_object('exchange_rate_source', old_json -> 'exchange_rate_source')
    || jsonb_build_object('entered_amount', old_json -> 'entered_amount')
    || jsonb_build_object('settlement_asset', old_json -> 'settlement_asset');

  RETURN jsonb_populate_record(NEW, new_json);
END;
$fn$;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.schema_migrations (version, name, checksum)
VALUES ('0010', '0010_fx_quote_provenance', 'fx_quote_provenance_v1')
ON CONFLICT (version) DO NOTHING;

INSERT INTO public.schema_migrations (version, name, checksum)
VALUES ('0012', '0012_receipt_capture_prerequisites', 'receipt_capture_prerequisites_v1')
ON CONFLICT (version) DO NOTHING;
