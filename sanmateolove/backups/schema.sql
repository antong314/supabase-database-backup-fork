


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pgsodium";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."provider_deletion_reason" AS ENUM (
    'outdated',
    'duplicate',
    'closed',
    'incorrect',
    'other'
);


ALTER TYPE "public"."provider_deletion_reason" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS TABLE("contact_id" "uuid", "average_rating" numeric, "review_count" bigint, "rating_counts" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT
    contacts.id AS contact_id,
    COALESCE(round(avg(reviews.rating)::numeric, 2), 0.00)::numeric(3, 2) AS average_rating,
    count(reviews.id)::bigint AS review_count,
    jsonb_build_object(
      '1', count(reviews.id) FILTER (WHERE reviews.rating = 1),
      '2', count(reviews.id) FILTER (WHERE reviews.rating = 2),
      '3', count(reviews.id) FILTER (WHERE reviews.rating = 3),
      '4', count(reviews.id) FILTER (WHERE reviews.rating = 4),
      '5', count(reviews.id) FILTER (WHERE reviews.rating = 5)
    ) AS rating_counts
  FROM public.contacts AS contacts
  LEFT JOIN public.provider_reviews AS reviews
    ON reviews.contact_id = contacts.id
   AND reviews.is_deleted = FALSE
  WHERE COALESCE(contacts.is_deleted, FALSE) = FALSE
    AND (p_contact_ids IS NULL OR contacts.id = ANY(p_contact_ids))
  GROUP BY contacts.id
  ORDER BY contacts.id;
$$;


ALTER FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[]) IS 'Returns aggregate ratings for selected active providers, or all active providers when passed NULL.';



CREATE OR REPLACE FUNCTION "public"."get_provider_review_summary"("p_contact_id" "uuid") RETURNS TABLE("contact_id" "uuid", "average_rating" numeric, "review_count" bigint, "rating_counts" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT *
  FROM public.get_provider_review_summaries(ARRAY[p_contact_id]);
$$;


ALTER FUNCTION "public"."get_provider_review_summary"("p_contact_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer DEFAULT 20, "p_offset" integer DEFAULT 0) RETURNS TABLE("id" "uuid", "contact_id" "uuid", "rating" smallint, "comment" "text", "reviewer_name" "text", "created_at" timestamp with time zone, "image_paths" "text"[])
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT
    reviews.id,
    reviews.contact_id,
    reviews.rating,
    reviews.comment,
    reviews.reviewer_name,
    reviews.created_at,
    COALESCE(images.image_paths, ARRAY[]::TEXT[]) AS image_paths
  FROM public.provider_reviews AS reviews
  LEFT JOIN LATERAL (
    SELECT array_agg(review_images.storage_path ORDER BY review_images.position) AS image_paths
    FROM public.provider_review_images AS review_images
    WHERE review_images.review_id = reviews.id
  ) AS images ON TRUE
  WHERE reviews.contact_id = p_contact_id
    AND reviews.is_deleted = FALSE
  ORDER BY reviews.created_at DESC, reviews.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$;


ALTER FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer, "p_offset" integer) IS 'Returns public review fields and ordered image paths; never returns reviewer WhatsApp.';



CREATE OR REPLACE FUNCTION "public"."handle_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") RETURNS TABLE("event_id" "uuid", "undo_expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_provider_name TEXT;
  v_confirmation TEXT;
  v_reason TEXT;
  v_requester_whatsapp TEXT;
  v_undo_token_hash TEXT;
  v_event_id UUID;
  v_deleted_at TIMESTAMPTZ := now();
  v_undo_expires_at TIMESTAMPTZ := now() + INTERVAL '2 minutes';
BEGIN
  SELECT contacts.title
  INTO v_provider_name
  FROM public.contacts AS contacts
  WHERE contacts.id = p_contact_id
    AND contacts.is_deleted = FALSE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Provider not found or already removed'
      USING ERRCODE = 'P0002';
  END IF;

  v_confirmation := regexp_replace(
    lower(btrim(COALESCE(p_provider_name_confirmation, ''))),
    '[[:space:]]+',
    ' ',
    'g'
  );

  IF v_confirmation = '' OR v_confirmation <> regexp_replace(
    lower(btrim(COALESCE(v_provider_name, ''))),
    '[[:space:]]+',
    ' ',
    'g'
  ) THEN
    RAISE EXCEPTION 'Provider name confirmation does not match'
      USING ERRCODE = '22023';
  END IF;

  v_reason := lower(btrim(COALESCE(p_reason, '')));
  IF v_reason NOT IN ('outdated', 'duplicate', 'closed', 'incorrect', 'other') THEN
    RAISE EXCEPTION 'Select a valid deletion reason'
      USING ERRCODE = '22023';
  END IF;

  v_requester_whatsapp := regexp_replace(
    btrim(COALESCE(p_requester_whatsapp, '')),
    '[[:space:]().-]+',
    '',
    'g'
  );
  IF left(v_requester_whatsapp, 2) = '00' THEN
    v_requester_whatsapp := '+' || substring(v_requester_whatsapp FROM 3);
  END IF;
  IF v_requester_whatsapp !~ '^\+?[0-9]{8,15}$' THEN
    RAISE EXCEPTION 'Enter a valid WhatsApp number with 8 to 15 digits'
      USING ERRCODE = '22023';
  END IF;

  v_undo_token_hash := lower(btrim(COALESCE(p_undo_token_hash, '')));
  IF v_undo_token_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid undo token hash'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.provider_deletion_events (
    contact_id,
    provider_name_snapshot,
    reason,
    requester_whatsapp,
    undo_token_hash,
    deleted_at,
    undo_expires_at
  )
  VALUES (
    p_contact_id,
    btrim(regexp_replace(v_provider_name, '[[:space:]]+', ' ', 'g')),
    v_reason::public.provider_deletion_reason,
    v_requester_whatsapp,
    v_undo_token_hash,
    v_deleted_at,
    v_undo_expires_at
  )
  RETURNING provider_deletion_events.id INTO v_event_id;

  UPDATE public.contacts
  SET is_deleted = TRUE
  WHERE id = p_contact_id;

  RETURN QUERY SELECT v_event_id, v_undo_expires_at;
END;
$_$;


ALTER FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") IS 'Service-role-only atomic provider soft deletion with name, reason, WhatsApp, and token-hash validation.';



CREATE OR REPLACE FUNCTION "public"."set_provider_review_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_provider_review_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[] DEFAULT ARRAY[]::"text"[], "p_comment" "text" DEFAULT NULL::"text", "p_reviewer_name" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "contact_id" "uuid", "rating" smallint, "comment" "text", "reviewer_name" "text", "created_at" timestamp with time zone, "image_paths" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_comment TEXT;
  v_reviewer_name TEXT;
  v_reviewer_whatsapp TEXT;
  v_image_paths TEXT[] := COALESCE(p_image_paths, ARRAY[]::TEXT[]);
  v_review public.provider_reviews%ROWTYPE;
BEGIN
  IF p_rating IS NULL OR p_rating NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'Rating must be a whole number between 1 and 5'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.contacts AS contacts
    WHERE contacts.id = p_contact_id
      AND COALESCE(contacts.is_deleted, FALSE) = FALSE
  ) THEN
    RAISE EXCEPTION 'Provider not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF cardinality(v_image_paths) > 4 THEN
    RAISE EXCEPTION 'A review can include at most 4 images'
      USING ERRCODE = '22023';
  END IF;

  IF cardinality(v_image_paths) <> (
    SELECT count(DISTINCT paths.storage_path)
    FROM unnest(v_image_paths) AS paths(storage_path)
  ) THEN
    RAISE EXCEPTION 'Review image paths must be unique'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_image_paths) AS paths(storage_path)
    WHERE paths.storage_path IS NULL
      OR paths.storage_path !~ (
        '^' || p_contact_id::TEXT ||
        '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
      )
  ) THEN
    RAISE EXCEPTION 'Review images must use the provider/image path format and an allowed extension'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_image_paths) AS paths(storage_path)
    WHERE NOT EXISTS (
      SELECT 1
      FROM storage.objects AS objects
      WHERE objects.bucket_id = 'review-images'
        AND objects.name = paths.storage_path
    )
  ) THEN
    RAISE EXCEPTION 'One or more review images were not uploaded'
      USING ERRCODE = '22023';
  END IF;

  v_comment := NULLIF(
    btrim(regexp_replace(COALESCE(p_comment, ''), E'\r\n?', E'\n', 'g')),
    ''
  );
  v_reviewer_name := NULLIF(
    btrim(regexp_replace(COALESCE(p_reviewer_name, ''), '[[:space:]]+', ' ', 'g')),
    ''
  );
  v_reviewer_whatsapp := regexp_replace(
    btrim(COALESCE(p_reviewer_whatsapp, '')),
    '[[:space:]().-]+',
    '',
    'g'
  );

  IF left(v_reviewer_whatsapp, 2) = '00' THEN
    v_reviewer_whatsapp := '+' || substring(v_reviewer_whatsapp FROM 3);
  END IF;

  IF v_comment IS NOT NULL AND char_length(v_comment) > 1000 THEN
    RAISE EXCEPTION 'Comment must be 1000 characters or fewer'
      USING ERRCODE = '22023';
  END IF;

  IF v_reviewer_name IS NOT NULL AND char_length(v_reviewer_name) > 80 THEN
    RAISE EXCEPTION 'Reviewer name must be 80 characters or fewer'
      USING ERRCODE = '22023';
  END IF;

  IF v_reviewer_whatsapp !~ '^\+?[0-9]{8,15}$' THEN
    RAISE EXCEPTION 'Enter a valid WhatsApp number with 8 to 15 digits'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.provider_reviews AS reviews (
    contact_id,
    rating,
    comment,
    reviewer_name,
    reviewer_whatsapp
  )
  VALUES (
    p_contact_id,
    p_rating,
    v_comment,
    v_reviewer_name,
    v_reviewer_whatsapp
  )
  RETURNING reviews.* INTO v_review;

  INSERT INTO public.provider_review_images (review_id, storage_path, position)
  SELECT
    v_review.id,
    paths.storage_path,
    (paths.ordinality - 1)::SMALLINT
  FROM unnest(v_image_paths) WITH ORDINALITY AS paths(storage_path, ordinality);

  RETURN QUERY
  SELECT
    v_review.id,
    v_review.contact_id,
    v_review.rating,
    v_review.comment,
    v_review.reviewer_name,
    v_review.created_at,
    v_image_paths;
END;
$_$;


ALTER FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text") IS 'Creates an immediately public review and ordered image metadata without returning reviewer WhatsApp.';



CREATE OR REPLACE FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_event public.provider_deletion_events%ROWTYPE;
  v_undo_token_hash TEXT := lower(btrim(COALESCE(p_undo_token_hash, '')));
BEGIN
  SELECT events.*
  INTO v_event
  FROM public.provider_deletion_events AS events
  WHERE events.id = p_event_id
  FOR UPDATE;

  IF NOT FOUND
    OR v_event.undone_at IS NOT NULL
    OR v_event.undo_token_hash <> v_undo_token_hash
    OR now() >= v_event.undo_expires_at
  THEN
    RAISE EXCEPTION 'Undo link is invalid or no longer available'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.contacts AS contacts
  WHERE contacts.id = v_event.contact_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Provider no longer exists'
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.contacts
  SET is_deleted = FALSE
  WHERE id = v_event.contact_id;

  UPDATE public.provider_deletion_events
  SET undone_at = now()
  WHERE id = v_event.id;
END;
$$;


ALTER FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") IS 'Service-role-only single-use undo before the server-assigned expiry.';



CREATE OR REPLACE FUNCTION "public"."update_wiki_content_tsv"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.content_tsv := to_tsvector('english', 
    coalesce(NEW.title, '') || ' ' ||
    regexp_replace(NEW.content::text, '["\\\\{\\}\\[\\],:]+', ' ', 'g')
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_wiki_content_tsv"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "title" "text" NOT NULL,
    "category" "text",
    "subtitle" "text",
    "phone_number" "text",
    "website_url" "text",
    "image_url" "text",
    "map_url" "text",
    "is_deleted" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."contacts" OWNER TO "postgres";


COMMENT ON COLUMN "public"."contacts"."title" IS 'Name of the contact/business';



COMMENT ON COLUMN "public"."contacts"."category" IS 'Category assignment (single value)';



COMMENT ON COLUMN "public"."contacts"."subtitle" IS 'Short description or tagline';



COMMENT ON COLUMN "public"."contacts"."phone_number" IS 'Contact phone number';



COMMENT ON COLUMN "public"."contacts"."website_url" IS 'Link to website or social media';



COMMENT ON COLUMN "public"."contacts"."image_url" IS 'Public URL of the image stored in Supabase Storage';



CREATE TABLE IF NOT EXISTS "public"."provider_deletion_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "provider_name_snapshot" "text" NOT NULL,
    "reason" "public"."provider_deletion_reason" NOT NULL,
    "requester_whatsapp" "text" NOT NULL,
    "undo_token_hash" "text" NOT NULL,
    "deleted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "undo_expires_at" timestamp with time zone NOT NULL,
    "undone_at" timestamp with time zone,
    CONSTRAINT "provider_deletion_events_check" CHECK (("undo_expires_at" > "deleted_at")),
    CONSTRAINT "provider_deletion_events_check1" CHECK ((("undone_at" IS NULL) OR ("undone_at" <= "undo_expires_at"))),
    CONSTRAINT "provider_deletion_events_provider_name_snapshot_check" CHECK (("char_length"("provider_name_snapshot") > 0)),
    CONSTRAINT "provider_deletion_events_requester_whatsapp_check" CHECK (((("char_length"("requester_whatsapp") >= 8) AND ("char_length"("requester_whatsapp") <= 16)) AND ("requester_whatsapp" ~ '^\+?[0-9]{8,15}$'::"text"))),
    CONSTRAINT "provider_deletion_events_undo_token_hash_check" CHECK (("undo_token_hash" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "public"."provider_deletion_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."provider_deletion_events" IS 'Private audit trail for service-authorized provider soft deletion and short-lived undo.';



COMMENT ON COLUMN "public"."provider_deletion_events"."requester_whatsapp" IS 'Private normalized requester contact. Never expose through public APIs.';



COMMENT ON COLUMN "public"."provider_deletion_events"."undo_token_hash" IS 'Unique SHA-256 hash of a single-use token returned only by the Edge Function.';



CREATE TABLE IF NOT EXISTS "public"."provider_review_images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "review_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "position" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_review_images_position_check" CHECK ((("position" >= 0) AND ("position" <= 3))),
    CONSTRAINT "provider_review_images_storage_path_check" CHECK (("storage_path" ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'::"text"))
);


ALTER TABLE "public"."provider_review_images" OWNER TO "postgres";


COMMENT ON TABLE "public"."provider_review_images" IS 'Private relational metadata for ordered public review-image objects; read through review RPCs only.';



CREATE TABLE IF NOT EXISTS "public"."provider_reviews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "rating" smallint NOT NULL,
    "comment" "text",
    "reviewer_name" "text",
    "reviewer_whatsapp" "text" NOT NULL,
    "is_deleted" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_reviews_check" CHECK (((("is_deleted" = false) AND ("deleted_at" IS NULL)) OR (("is_deleted" = true) AND ("deleted_at" IS NOT NULL)))),
    CONSTRAINT "provider_reviews_comment_check" CHECK ((("comment" IS NULL) OR ("char_length"("comment") <= 1000))),
    CONSTRAINT "provider_reviews_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5))),
    CONSTRAINT "provider_reviews_reviewer_name_check" CHECK ((("reviewer_name" IS NULL) OR ("char_length"("reviewer_name") <= 80))),
    CONSTRAINT "provider_reviews_reviewer_whatsapp_check" CHECK (((("char_length"("reviewer_whatsapp") >= 8) AND ("char_length"("reviewer_whatsapp") <= 16)) AND ("reviewer_whatsapp" ~ '^\+?[0-9]{8,15}$'::"text")))
);


ALTER TABLE "public"."provider_reviews" OWNER TO "postgres";


COMMENT ON TABLE "public"."provider_reviews" IS 'Account-free provider reviews. reviewer_whatsapp is private and must never be exposed by public RPCs.';



COMMENT ON COLUMN "public"."provider_reviews"."reviewer_whatsapp" IS 'Private abuse/contact signal. Never include this column in a public RPC return type.';



CREATE TABLE IF NOT EXISTS "public"."wiki_pages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "title" "text" NOT NULL,
    "content" "jsonb" NOT NULL,
    "excerpt" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    "is_published" boolean DEFAULT true,
    "category" "text",
    "version" smallint DEFAULT '0'::smallint NOT NULL,
    "content_tsv" "tsvector"
);


ALTER TABLE "public"."wiki_pages" OWNER TO "postgres";


ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_deletion_events"
    ADD CONSTRAINT "provider_deletion_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_deletion_events"
    ADD CONSTRAINT "provider_deletion_events_undo_token_hash_key" UNIQUE ("undo_token_hash");



ALTER TABLE ONLY "public"."provider_review_images"
    ADD CONSTRAINT "provider_review_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_review_images"
    ADD CONSTRAINT "provider_review_images_review_id_position_key" UNIQUE ("review_id", "position");



ALTER TABLE ONLY "public"."provider_review_images"
    ADD CONSTRAINT "provider_review_images_storage_path_key" UNIQUE ("storage_path");



ALTER TABLE ONLY "public"."provider_reviews"
    ADD CONSTRAINT "provider_reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wiki_pages"
    ADD CONSTRAINT "wiki_pages_pkey" PRIMARY KEY ("id", "version");



CREATE INDEX "provider_deletion_events_contact_deleted_idx" ON "public"."provider_deletion_events" USING "btree" ("contact_id", "deleted_at" DESC);



CREATE INDEX "provider_deletion_events_pending_undo_idx" ON "public"."provider_deletion_events" USING "btree" ("undo_expires_at") WHERE ("undone_at" IS NULL);



CREATE INDEX "provider_review_images_review_position_idx" ON "public"."provider_review_images" USING "btree" ("review_id", "position");



CREATE INDEX "provider_reviews_public_contact_created_idx" ON "public"."provider_reviews" USING "btree" ("contact_id", "created_at" DESC) WHERE ("is_deleted" = false);



CREATE INDEX "wiki_pages_content_idx" ON "public"."wiki_pages" USING "gin" ("content");



CREATE INDEX "wiki_pages_content_tsv_idx" ON "public"."wiki_pages" USING "gin" ("content_tsv");



CREATE INDEX "wiki_pages_slug_idx" ON "public"."wiki_pages" USING "btree" ("slug");



CREATE INDEX "wiki_pages_title_idx" ON "public"."wiki_pages" USING "gin" ("to_tsvector"('"english"'::"regconfig", "title"));



CREATE OR REPLACE TRIGGER "on_contacts_updated" BEFORE UPDATE ON "public"."contacts" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_provider_review_updated_at" BEFORE UPDATE ON "public"."provider_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."set_provider_review_updated_at"();



CREATE OR REPLACE TRIGGER "wiki_pages_tsv_update" BEFORE INSERT OR UPDATE ON "public"."wiki_pages" FOR EACH ROW EXECUTE FUNCTION "public"."update_wiki_content_tsv"();



ALTER TABLE ONLY "public"."provider_deletion_events"
    ADD CONSTRAINT "provider_deletion_events_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."provider_review_images"
    ADD CONSTRAINT "provider_review_images_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."provider_reviews"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."provider_reviews"
    ADD CONSTRAINT "provider_reviews_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE CASCADE;



CREATE POLICY "All access for All Users" ON "public"."wiki_pages" USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."wiki_pages" FOR SELECT USING (true);



CREATE POLICY "Public can add active contacts" ON "public"."contacts" FOR INSERT TO "authenticated", "anon" WITH CHECK (("is_deleted" = false));



CREATE POLICY "Public can edit active contacts" ON "public"."contacts" FOR UPDATE TO "authenticated", "anon" USING (("is_deleted" = false)) WITH CHECK (("is_deleted" = false));



CREATE POLICY "Public can read active contacts" ON "public"."contacts" FOR SELECT TO "authenticated", "anon" USING (("is_deleted" = false));



ALTER TABLE "public"."contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_deletion_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_review_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_reviews" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wiki_pages" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON TYPE "public"."provider_deletion_reason" FROM PUBLIC;
GRANT ALL ON TYPE "public"."provider_deletion_reason" TO "service_role";

















































































































































































REVOKE ALL ON FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_provider_review_summaries"("p_contact_ids" "uuid"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_provider_review_summary"("p_contact_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_provider_review_summary"("p_contact_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_provider_review_summary"("p_contact_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_provider_review_summary"("p_contact_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_provider_reviews"("p_contact_id" "uuid", "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_provider_review_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_provider_review_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "service_role";


















GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."contacts" TO "anon";
GRANT SELECT ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("title"),UPDATE("title") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("title"),UPDATE("title") ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("category"),UPDATE("category") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("category"),UPDATE("category") ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("subtitle"),UPDATE("subtitle") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("subtitle"),UPDATE("subtitle") ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("phone_number"),UPDATE("phone_number") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("phone_number"),UPDATE("phone_number") ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("website_url"),UPDATE("website_url") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("website_url"),UPDATE("website_url") ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("image_url"),UPDATE("image_url") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("image_url"),UPDATE("image_url") ON TABLE "public"."contacts" TO "authenticated";



GRANT INSERT("map_url"),UPDATE("map_url") ON TABLE "public"."contacts" TO "anon";
GRANT INSERT("map_url"),UPDATE("map_url") ON TABLE "public"."contacts" TO "authenticated";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_deletion_events" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_review_images" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_reviews" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."wiki_pages" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."wiki_pages" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."wiki_pages" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO "service_role";































