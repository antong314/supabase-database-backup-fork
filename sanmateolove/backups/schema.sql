


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






CREATE TYPE "public"."bot_conversation_phase" AS ENUM (
    'awaiting_description',
    'awaiting_category',
    'review_optional',
    'awaiting_review'
);


ALTER TYPE "public"."bot_conversation_phase" OWNER TO "postgres";


CREATE TYPE "public"."provider_deletion_reason" AS ENUM (
    'outdated',
    'duplicate',
    'closed',
    'incorrect',
    'other'
);


ALTER TYPE "public"."provider_deletion_reason" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_audited_wiki_write"("p_action_type" "text", "p_slug" "text", "p_title" "text", "p_category" "text", "p_content" "text", "p_expected_version" integer, "p_requester_whatsapp" "text", "p_requester_name" "text" DEFAULT NULL::"text", "p_verification_method" "text" DEFAULT 'whatsapp_inbound'::"text", "p_verification_action_id" "uuid" DEFAULT NULL::"uuid", "p_twilio_message_sid" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "slug" "text", "title" "text", "content" "text", "excerpt" "text", "category" "text", "version" integer, "updated_at" timestamp with time zone, "event_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_action TEXT := lower(btrim(COALESCE(p_action_type, '')));
  v_slug TEXT := lower(btrim(COALESCE(p_slug, '')));
  v_title TEXT := btrim(COALESCE(p_title, ''));
  v_category TEXT := COALESCE(NULLIF(btrim(COALESCE(p_category, '')), ''), 'Uncategorized');
  v_phone TEXT := btrim(COALESCE(p_requester_whatsapp, ''));
  v_current public.wiki_pages%ROWTYPE;
  v_next public.wiki_pages%ROWTYPE;
  v_before JSONB;
  v_after JSONB;
  v_event_id UUID;
  v_existing public.wiki_change_events%ROWTYPE;
  v_snapshot JSONB;
BEGIN
  IF v_action NOT IN ('wiki_create', 'wiki_update', 'wiki_delete')
    OR v_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    OR v_phone !~ '^\+[1-9][0-9]{7,14}$'
    OR p_verification_method NOT IN ('whatsapp_inbound', 'trusted_session')
    OR ((p_verification_action_id IS NULL) = (p_twilio_message_sid IS NULL)) THEN
    RAISE EXCEPTION 'Invalid audited wiki change' USING ERRCODE = '22023';
  END IF;
  IF length(v_title) > 160 OR length(v_category) > 80
    OR length(COALESCE(p_content, '')) > 200000 THEN
    RAISE EXCEPTION 'Wiki change is too large' USING ERRCODE = '22023';
  END IF;
  IF v_action <> 'wiki_delete' THEN
    IF v_title = '' OR p_content IS NULL OR jsonb_typeof(p_content::JSONB) <> 'array' THEN
      RAISE EXCEPTION 'Wiki content must be a BlockNote JSON array' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_twilio_message_sid IS NOT NULL OR p_verification_action_id IS NOT NULL THEN
    SELECT events.* INTO v_existing
    FROM public.wiki_change_events AS events
    WHERE (
        (p_twilio_message_sid IS NOT NULL AND events.twilio_message_sid = p_twilio_message_sid)
        OR (p_verification_action_id IS NOT NULL
          AND events.verification_action_id = p_verification_action_id)
      )
      AND events.page_slug = v_slug
      AND events.action_type = v_action
    LIMIT 1;
    IF FOUND THEN
      v_snapshot := COALESCE(v_existing.after_snapshot, v_existing.before_snapshot);
      RETURN QUERY SELECT
        (v_snapshot->>'id')::UUID,
        v_existing.page_slug,
        v_snapshot->>'title',
        v_snapshot->>'content',
        v_snapshot->>'excerpt',
        v_snapshot->>'category',
        (v_snapshot->>'version')::INTEGER,
        (v_snapshot->>'updated_at')::TIMESTAMPTZ,
        v_existing.id;
      RETURN;
    END IF;
  END IF;

  SELECT pages.* INTO v_current
  FROM public.wiki_pages AS pages
  WHERE pages.slug = v_slug AND pages.is_published = TRUE
  LIMIT 1 FOR UPDATE;

  IF v_action = 'wiki_create' THEN
    IF FOUND THEN RAISE EXCEPTION 'Wiki page already exists' USING ERRCODE = '23505'; END IF;
    v_next.id := gen_random_uuid();
    v_next.slug := v_slug;
    v_next.title := v_title;
    v_next.content := to_jsonb(p_content);
    v_next.excerpt := 'A page about ' || v_title;
    v_next.category := v_category;
    v_next.version := 0;
    v_next.is_published := TRUE;
    v_next.created_at := now();
    v_next.updated_at := now();
    INSERT INTO public.wiki_pages (
      id, slug, title, content, excerpt, category, version, is_published,
      created_at, updated_at, created_by
    ) VALUES (
      v_next.id, v_next.slug, v_next.title, v_next.content, v_next.excerpt,
      v_next.category, v_next.version, TRUE, v_next.created_at, v_next.updated_at, NULL
    ) RETURNING * INTO v_next;
    v_before := NULL;
    v_after := jsonb_build_object('id', v_next.id, 'slug', v_next.slug,
      'title', v_next.title, 'content', v_next.content, 'excerpt', v_next.excerpt,
      'category', v_next.category, 'version', v_next.version,
      'created_at', v_next.created_at, 'updated_at', v_next.updated_at);
  ELSE
    IF NOT FOUND THEN RAISE EXCEPTION 'Wiki page not found' USING ERRCODE = 'P0002'; END IF;
    IF p_expected_version IS NULL OR v_current.version <> p_expected_version THEN
      RAISE EXCEPTION 'Wiki page changed since it was read' USING ERRCODE = '40001';
    END IF;
    v_before := jsonb_build_object('id', v_current.id, 'slug', v_current.slug,
      'title', v_current.title, 'content', v_current.content, 'excerpt', v_current.excerpt,
      'category', v_current.category, 'version', v_current.version,
      'created_at', v_current.created_at, 'updated_at', v_current.updated_at);
    UPDATE public.wiki_pages AS pages SET is_published = FALSE
    WHERE pages.id = v_current.id AND pages.version = v_current.version;

    IF v_action = 'wiki_delete' THEN
      v_next := v_current;
      v_after := NULL;
    ELSE
      INSERT INTO public.wiki_pages (
        id, slug, title, content, excerpt, category, version, is_published,
        created_at, updated_at, created_by
      ) VALUES (
        v_current.id, v_slug, v_title, to_jsonb(p_content),
        COALESCE(v_current.excerpt, 'A page about ' || v_title), v_category,
        v_current.version + 1, TRUE, v_current.created_at, now(), v_current.created_by
      ) RETURNING * INTO v_next;
      v_after := jsonb_build_object('id', v_next.id, 'slug', v_next.slug,
        'title', v_next.title, 'content', v_next.content, 'excerpt', v_next.excerpt,
        'category', v_next.category, 'version', v_next.version,
        'created_at', v_next.created_at, 'updated_at', v_next.updated_at);
    END IF;
  END IF;

  INSERT INTO public.wiki_change_events (
    page_id, page_slug, action_type, requester_whatsapp, requester_name,
    verification_method, verification_action_id, twilio_message_sid,
    before_snapshot, after_snapshot
  ) VALUES (
    v_next.id, v_slug, v_action, v_phone, NULLIF(btrim(COALESCE(p_requester_name, '')), ''),
    p_verification_method, p_verification_action_id, p_twilio_message_sid,
    v_before, v_after
  ) RETURNING wiki_change_events.id INTO v_event_id;

  RETURN QUERY SELECT v_next.id, v_next.slug, v_next.title, v_next.content #>> '{}',
    v_next.excerpt, v_next.category, v_next.version::INTEGER, v_next.updated_at, v_event_id;
END;
$_$;


ALTER FUNCTION "public"."apply_audited_wiki_write"("p_action_type" "text", "p_slug" "text", "p_title" "text", "p_category" "text", "p_content" "text", "p_expected_version" integer, "p_requester_whatsapp" "text", "p_requester_name" "text", "p_verification_method" "text", "p_verification_action_id" "uuid", "p_twilio_message_sid" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_bot_conversation"("p_conversation_key" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  DELETE FROM public.bot_conversations
  WHERE conversation_key = lower(btrim(COALESCE(p_conversation_key, '')));
$$;


ALTER FUNCTION "public"."clear_bot_conversation"("p_conversation_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_bot_search_session"("p_conversation_key" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  DELETE FROM public.bot_search_sessions
  WHERE conversation_key = lower(btrim(COALESCE(p_conversation_key, '')));
$$;


ALTER FUNCTION "public"."clear_bot_search_session"("p_conversation_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_bot_wiki_session"("p_conversation_key" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  DELETE FROM public.bot_wiki_sessions
  WHERE conversation_key = lower(btrim(COALESCE(p_conversation_key, '')));
$$;


ALTER FUNCTION "public"."clear_bot_wiki_session"("p_conversation_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_verified_provider_deletion"("p_action_id" "uuid", "p_undo_token_hash" "text") RETURNS TABLE("event_id" "uuid", "undo_expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_action public.community_verification_actions%ROWTYPE;
  v_event_id UUID;
  v_undo_expires_at TIMESTAMPTZ;
BEGIN
  SELECT actions.* INTO v_action
  FROM public.community_verification_actions AS actions
  WHERE actions.id = p_action_id
  FOR UPDATE;

  IF NOT FOUND OR v_action.action_type <> 'provider_delete'
    OR v_action.status <> 'verified' OR v_action.consumed_at IS NOT NULL
    OR v_action.expires_at <= now() THEN
    RAISE EXCEPTION 'Verified deletion action is unavailable' USING ERRCODE = '22023';
  END IF;

  SELECT result.event_id, result.undo_expires_at
  INTO v_event_id, v_undo_expires_at
  FROM public.perform_provider_soft_delete(
    (v_action.payload->>'providerId')::UUID,
    v_action.payload->>'providerNameConfirmation',
    v_action.payload->>'reason',
    v_action.requester_whatsapp,
    p_undo_token_hash
  ) AS result;

  UPDATE public.provider_deletion_events AS events
  SET
    verification_action_id = v_action.id,
    verification_method = v_action.verification_method,
    verified_at = v_action.verified_at,
    twilio_verification_sid = v_action.twilio_verification_sid
  WHERE events.id = v_event_id;

  UPDATE public.community_verification_actions
  SET status = 'completed', consumed_at = now(), result_id = v_event_id
  WHERE id = v_action.id;

  RETURN QUERY SELECT v_event_id, v_undo_expires_at;
END;
$$;


ALTER FUNCTION "public"."complete_verified_provider_deletion"("p_action_id" "uuid", "p_undo_token_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_verified_provider_review"("p_action_id" "uuid", "p_image_paths" "text"[] DEFAULT ARRAY[]::"text"[]) RETURNS TABLE("id" "uuid", "contact_id" "uuid", "rating" smallint, "comment" "text", "reviewer_name" "text", "created_at" timestamp with time zone, "image_paths" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_action public.community_verification_actions%ROWTYPE;
  v_result RECORD;
  v_expected_images INTEGER;
BEGIN
  SELECT actions.* INTO v_action
  FROM public.community_verification_actions AS actions
  WHERE actions.id = p_action_id
  FOR UPDATE;

  IF NOT FOUND OR v_action.action_type <> 'provider_review'
    OR v_action.status <> 'verified' OR v_action.consumed_at IS NOT NULL
    OR v_action.expires_at <= now() THEN
    RAISE EXCEPTION 'Verified review action is unavailable' USING ERRCODE = '22023';
  END IF;

  v_expected_images := COALESCE((v_action.payload->>'imageCount')::INTEGER, 0);
  IF cardinality(COALESCE(p_image_paths, ARRAY[]::TEXT[])) <> v_expected_images THEN
    RAISE EXCEPTION 'Review image count does not match the verified action' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_result
  FROM public.submit_provider_review(
    (v_action.payload->>'providerId')::UUID,
    (v_action.payload->>'rating')::SMALLINT,
    v_action.requester_whatsapp,
    COALESCE(p_image_paths, ARRAY[]::TEXT[]),
    v_action.payload->>'comment',
    v_action.payload->>'reviewerName',
    v_action.verification_method,
    v_action.id,
    v_action.twilio_verification_sid
  );

  UPDATE public.community_verification_actions
  SET status = 'completed', consumed_at = now(), result_id = v_result.id
  WHERE community_verification_actions.id = v_action.id;

  RETURN QUERY SELECT
    v_result.id,
    v_result.contact_id,
    v_result.rating,
    v_result.comment,
    v_result.reviewer_name,
    v_result.created_at,
    v_result.image_paths;
END;
$$;


ALTER FUNCTION "public"."complete_verified_provider_review"("p_action_id" "uuid", "p_image_paths" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_verified_provider_write"("p_action_id" "uuid", "p_image_path" "text" DEFAULT NULL::"text", "p_image_url" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "title" "text", "subtitle" "text", "category" "text", "phone_number" "text", "website_url" "text", "map_url" "text", "image_url" "text", "previous_image_url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'storage'
    AS $_$
DECLARE
  v_action public.community_verification_actions%ROWTYPE;
  v_contact public.contacts%ROWTYPE;
  v_previous_image_url TEXT;
  v_image_change TEXT;
  v_next_image_url TEXT;
  v_before_snapshot JSONB;
  v_after_snapshot JSONB;
BEGIN
  SELECT actions.* INTO v_action
  FROM public.community_verification_actions AS actions
  WHERE actions.id = p_action_id
  FOR UPDATE;

  IF NOT FOUND OR v_action.action_type NOT IN ('provider_create', 'provider_update')
    OR v_action.status <> 'verified' OR v_action.consumed_at IS NOT NULL
    OR v_action.expires_at <= now() THEN
    RAISE EXCEPTION 'Verified provider action is unavailable' USING ERRCODE = '22023';
  END IF;

  v_image_change := v_action.payload->>'imageChange';
  IF v_image_change = 'replace' THEN
    IF p_image_path IS NULL
      OR p_image_path !~ (
        '^' || v_action.id::TEXT
        || '/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
        || '\.(jpg|jpeg|png|webp)$'
      )
      OR p_image_url IS NULL
      OR p_image_url !~ (
        '^https?://[^[:space:]]+/storage/v1/object/public/contact-images/'
        || replace(replace(p_image_path, '.', '\.'), '/', '\/')
        || '$'
      ) THEN
      RAISE EXCEPTION 'A verified provider logo is required' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects AS objects
      WHERE objects.bucket_id = 'contact-images' AND objects.name = p_image_path
    ) THEN
      RAISE EXCEPTION 'The verified provider logo was not uploaded' USING ERRCODE = '22023';
    END IF;
    v_next_image_url := p_image_url;
  ELSIF p_image_path IS NOT NULL OR p_image_url IS NOT NULL THEN
    RAISE EXCEPTION 'This provider action does not allow a new logo' USING ERRCODE = '22023';
  END IF;

  IF v_action.action_type = 'provider_create' THEN
    IF v_image_change IS NULL OR v_image_change NOT IN ('none', 'replace') THEN
      RAISE EXCEPTION 'Invalid provider image action' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.contacts AS contacts (
      title,
      category,
      subtitle,
      phone_number,
      website_url,
      map_url,
      image_url,
      is_deleted
    ) VALUES (
      v_action.payload->>'name',
      v_action.payload->>'category',
      v_action.payload->>'description',
      v_action.payload->>'providerPhone',
      NULLIF(v_action.payload->>'website', ''),
      NULLIF(v_action.payload->>'mapUrl', ''),
      v_next_image_url,
      FALSE
    )
    RETURNING contacts.* INTO v_contact;
  ELSE
    IF v_image_change IS NULL OR v_image_change NOT IN ('keep', 'remove', 'replace') THEN
      RAISE EXCEPTION 'Invalid provider image action' USING ERRCODE = '22023';
    END IF;

    SELECT contacts.* INTO v_contact
    FROM public.contacts AS contacts
    WHERE contacts.id = (v_action.payload->>'providerId')::UUID
      AND contacts.is_deleted = FALSE
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Provider not found' USING ERRCODE = 'P0002';
    END IF;

    v_before_snapshot := jsonb_build_object(
      'name', v_contact.title,
      'category', v_contact.category,
      'description', v_contact.subtitle,
      'phone', v_contact.phone_number,
      'website', v_contact.website_url,
      'mapUrl', v_contact.map_url,
      'imageUrl', v_contact.image_url
    );
    v_previous_image_url := v_contact.image_url;
    IF v_image_change = 'keep' THEN
      v_next_image_url := v_contact.image_url;
    ELSIF v_image_change = 'remove' THEN
      v_next_image_url := NULL;
    END IF;

    UPDATE public.contacts AS contacts
    SET
      title = v_action.payload->>'name',
      category = v_action.payload->>'category',
      subtitle = v_action.payload->>'description',
      phone_number = v_action.payload->>'providerPhone',
      website_url = NULLIF(v_action.payload->>'website', ''),
      map_url = NULLIF(v_action.payload->>'mapUrl', ''),
      image_url = v_next_image_url
    WHERE contacts.id = v_contact.id
    RETURNING contacts.* INTO v_contact;
  END IF;

  v_after_snapshot := jsonb_build_object(
    'name', v_contact.title,
    'category', v_contact.category,
    'description', v_contact.subtitle,
    'phone', v_contact.phone_number,
    'website', v_contact.website_url,
    'mapUrl', v_contact.map_url,
    'imageUrl', v_contact.image_url
  );

  INSERT INTO public.provider_change_events (
    contact_id,
    action_type,
    requester_whatsapp,
    verification_method,
    verification_action_id,
    before_snapshot,
    after_snapshot
  ) VALUES (
    v_contact.id,
    v_action.action_type,
    v_action.requester_whatsapp,
    v_action.verification_method,
    v_action.id,
    v_before_snapshot,
    v_after_snapshot
  );

  UPDATE public.community_verification_actions AS actions
  SET status = 'completed', consumed_at = now(), result_id = v_contact.id
  WHERE actions.id = v_action.id;

  RETURN QUERY SELECT
    v_contact.id,
    v_contact.title,
    v_contact.subtitle,
    v_contact.category,
    v_contact.phone_number,
    v_contact.website_url,
    v_contact.map_url,
    v_contact.image_url,
    v_previous_image_url;
END;
$_$;


ALTER FUNCTION "public"."complete_verified_provider_write"("p_action_id" "uuid", "p_image_path" "text", "p_image_url" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."complete_verified_provider_write"("p_action_id" "uuid", "p_image_path" "text", "p_image_url" "text") IS 'Atomically creates or updates a provider from an unconsumed WhatsApp-verified action.';



CREATE OR REPLACE FUNCTION "public"."complete_verified_wiki_write"("p_action_id" "uuid") RETURNS TABLE("id" "uuid", "slug" "text", "title" "text", "content" "text", "excerpt" "text", "category" "text", "version" integer, "updated_at" timestamp with time zone, "event_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_action public.community_verification_actions%ROWTYPE;
BEGIN
  SELECT actions.* INTO v_action
  FROM public.community_verification_actions AS actions
  WHERE actions.id = p_action_id
  FOR UPDATE;

  IF NOT FOUND OR v_action.action_type NOT IN ('wiki_create', 'wiki_update', 'wiki_delete')
    OR v_action.requester_whatsapp IS NULL
    OR NOT (
      (v_action.status = 'verified' AND v_action.consumed_at IS NULL)
      OR (v_action.status = 'completed' AND v_action.consumed_at IS NOT NULL)
    ) THEN
    RAISE EXCEPTION 'Verified wiki action is not ready' USING ERRCODE = 'P0001';
  END IF;

  IF v_action.status = 'completed' THEN
    RETURN QUERY SELECT writes.*
    FROM public.apply_audited_wiki_write(
      v_action.action_type,
      v_action.payload->>'slug',
      v_action.payload->>'title',
      v_action.payload->>'category',
      v_action.payload->>'content',
      (v_action.payload->>'expectedVersion')::INTEGER,
      v_action.requester_whatsapp,
      NULL,
      v_action.verification_method,
      v_action.id,
      NULL
    ) AS writes;
    RETURN;
  END IF;

  RETURN QUERY
  WITH applied AS (
    SELECT writes.*
    FROM public.apply_audited_wiki_write(
      v_action.action_type,
      v_action.payload->>'slug',
      v_action.payload->>'title',
      v_action.payload->>'category',
      v_action.payload->>'content',
      (v_action.payload->>'expectedVersion')::INTEGER,
      v_action.requester_whatsapp,
      NULL,
      v_action.verification_method,
      v_action.id,
      NULL
    ) AS writes
  ), completed AS (
    UPDATE public.community_verification_actions AS actions
    SET status = 'completed', consumed_at = now(), result_id = applied.id
    FROM applied
    WHERE actions.id = v_action.id
      AND actions.status = 'verified'
      AND actions.consumed_at IS NULL
    RETURNING applied.*
  )
  SELECT completed.* FROM completed;
END;
$$;


ALTER FUNCTION "public"."complete_verified_wiki_write"("p_action_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."find_active_contact_by_phone"("p_phone" "text") RETURNS TABLE("id" "uuid", "title" "text", "subtitle" "text", "category" "text", "phone_number" "text", "website_url" "text", "map_url" "text", "image_url" "text")
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT
    contacts.id,
    contacts.title,
    contacts.subtitle,
    contacts.category,
    contacts.phone_number,
    contacts.website_url,
    contacts.map_url,
    contacts.image_url
  FROM public.contacts AS contacts
  WHERE contacts.is_deleted = FALSE
    AND contacts.phone_normalized = public.normalize_contact_phone(p_phone)
  LIMIT 1;
$$;


ALTER FUNCTION "public"."find_active_contact_by_phone"("p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bot_conversation"("p_conversation_key" "text") RETURNS TABLE("contact_id" "uuid", "phase" "text", "context" "jsonb", "expires_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT
    conversations.contact_id,
    conversations.phase::TEXT,
    conversations.context,
    conversations.expires_at
  FROM public.bot_conversations AS conversations
  JOIN public.contacts AS contacts
    ON contacts.id = conversations.contact_id
   AND contacts.is_deleted = FALSE
  WHERE conversations.conversation_key = lower(btrim(COALESCE(p_conversation_key, '')))
    AND conversations.expires_at > now()
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_bot_conversation"("p_conversation_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bot_search_session"("p_conversation_key" "text") RETURNS TABLE("context" "jsonb", "expires_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT
    sessions.context,
    sessions.expires_at
  FROM public.bot_search_sessions AS sessions
  WHERE sessions.conversation_key = lower(btrim(COALESCE(p_conversation_key, '')))
    AND sessions.expires_at > now()
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_bot_search_session"("p_conversation_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bot_wiki_session"("p_conversation_key" "text") RETURNS TABLE("context" "jsonb", "expires_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
  SELECT sessions.context, sessions.expires_at
  FROM public.bot_wiki_sessions AS sessions
  WHERE sessions.conversation_key = lower(btrim(COALESCE(p_conversation_key, '')))
    AND sessions.expires_at > now()
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_bot_wiki_session"("p_conversation_key" "text") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."normalize_contact_phone"("p_phone" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'pg_catalog'
    AS $$
  SELECT NULLIF(
    CASE
      WHEN left(normalized.digits, 2) = '00' THEN substring(normalized.digits FROM 3)
      ELSE normalized.digits
    END,
    ''
  )
  FROM (
    SELECT regexp_replace(COALESCE(p_phone, ''), '[^0-9]+', '', 'g') AS digits
  ) AS normalized;
$$;


ALTER FUNCTION "public"."normalize_contact_phone"("p_phone" "text") OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."reject_anonymous_contact_image_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public', 'storage', 'auth'
    AS $$
DECLARE
  v_bucket_id TEXT := CASE WHEN TG_OP = 'DELETE' THEN OLD.bucket_id ELSE NEW.bucket_id END;
BEGIN
  IF v_bucket_id = 'contact-images'
    AND auth.role() IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'Provider logos require a verified server action'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."reject_anonymous_contact_image_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_bot_conversation"("p_conversation_key" "text", "p_contact_id" "uuid", "p_phase" "text", "p_context" "jsonb" DEFAULT '{}'::"jsonb", "p_ttl_hours" integer DEFAULT 72) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_key TEXT := lower(btrim(COALESCE(p_conversation_key, '')));
  v_phase public.bot_conversation_phase;
  v_context JSONB := COALESCE(p_context, '{}'::JSONB);
  v_ttl_hours INTEGER := LEAST(GREATEST(COALESCE(p_ttl_hours, 72), 1), 168);
BEGIN
  IF v_key !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid conversation key' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(v_context) <> 'object' THEN
    RAISE EXCEPTION 'Conversation context must be an object' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.contacts
    WHERE id = p_contact_id AND is_deleted = FALSE
  ) THEN
    RAISE EXCEPTION 'Provider not found' USING ERRCODE = 'P0002';
  END IF;

  BEGIN
    v_phase := p_phase::public.bot_conversation_phase;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Invalid conversation phase' USING ERRCODE = '22023';
  END;

  INSERT INTO public.bot_conversations AS conversations (
    conversation_key,
    contact_id,
    phase,
    context,
    expires_at,
    updated_at
  )
  VALUES (
    v_key,
    p_contact_id,
    v_phase,
    v_context,
    now() + make_interval(hours => v_ttl_hours),
    now()
  )
  ON CONFLICT (conversation_key) DO UPDATE
  SET
    contact_id = EXCLUDED.contact_id,
    phase = EXCLUDED.phase,
    context = EXCLUDED.context,
    expires_at = EXCLUDED.expires_at,
    updated_at = now();
END;
$_$;


ALTER FUNCTION "public"."set_bot_conversation"("p_conversation_key" "text", "p_contact_id" "uuid", "p_phase" "text", "p_context" "jsonb", "p_ttl_hours" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_bot_search_session"("p_conversation_key" "text", "p_context" "jsonb" DEFAULT '{}'::"jsonb", "p_ttl_hours" integer DEFAULT 24) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_key TEXT := lower(btrim(COALESCE(p_conversation_key, '')));
  v_context JSONB := COALESCE(p_context, '{}'::JSONB);
  v_ttl_hours INTEGER := LEAST(GREATEST(COALESCE(p_ttl_hours, 24), 1), 72);
BEGIN
  IF v_key !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invalid conversation key' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(v_context) <> 'object' THEN
    RAISE EXCEPTION 'Search context must be an object' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.bot_search_sessions AS sessions (
    conversation_key,
    context,
    expires_at,
    updated_at
  )
  VALUES (
    v_key,
    v_context,
    now() + make_interval(hours => v_ttl_hours),
    now()
  )
  ON CONFLICT (conversation_key) DO UPDATE
  SET
    context = EXCLUDED.context,
    expires_at = EXCLUDED.expires_at,
    updated_at = now();
END;
$_$;


ALTER FUNCTION "public"."set_bot_search_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_bot_wiki_session"("p_conversation_key" "text", "p_context" "jsonb" DEFAULT '{}'::"jsonb", "p_ttl_hours" integer DEFAULT 24) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_key TEXT := lower(btrim(COALESCE(p_conversation_key, '')));
  v_context JSONB := COALESCE(p_context, '{}'::JSONB);
  v_ttl_hours INTEGER := LEAST(GREATEST(COALESCE(p_ttl_hours, 24), 1), 72);
BEGIN
  IF v_key !~ '^[0-9a-f]{64}$' OR jsonb_typeof(v_context) <> 'object' THEN
    RAISE EXCEPTION 'Invalid wiki conversation state' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.bot_wiki_sessions AS sessions (
    conversation_key, context, expires_at, updated_at
  ) VALUES (
    v_key, v_context, now() + make_interval(hours => v_ttl_hours), now()
  ) ON CONFLICT (conversation_key) DO UPDATE SET
    context = EXCLUDED.context,
    expires_at = EXCLUDED.expires_at,
    updated_at = now();
END;
$_$;


ALTER FUNCTION "public"."set_bot_wiki_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[] DEFAULT ARRAY[]::"text"[], "p_comment" "text" DEFAULT NULL::"text", "p_reviewer_name" "text" DEFAULT NULL::"text", "p_verification_method" "text" DEFAULT 'whatsapp_inbound'::"text", "p_verification_action_id" "uuid" DEFAULT NULL::"uuid", "p_twilio_verification_sid" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "contact_id" "uuid", "rating" smallint, "comment" "text", "reviewer_name" "text", "created_at" timestamp with time zone, "image_paths" "text"[])
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public', 'storage'
    AS $_$
DECLARE
  v_comment TEXT;
  v_reviewer_name TEXT;
  v_reviewer_whatsapp TEXT;
  v_image_paths TEXT[] := COALESCE(p_image_paths, ARRAY[]::TEXT[]);
  v_review public.provider_reviews%ROWTYPE;
  v_storage_path TEXT;
BEGIN
  IF p_rating IS NULL OR p_rating NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'Rating must be a whole number between 1 and 5' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.contacts AS contacts
    WHERE contacts.id = p_contact_id AND contacts.is_deleted = FALSE
  ) THEN
    RAISE EXCEPTION 'Provider not found' USING ERRCODE = 'P0002';
  END IF;

  IF cardinality(v_image_paths) > 4 THEN
    RAISE EXCEPTION 'A review can include at most 4 images' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_image_paths) <> cardinality(ARRAY(SELECT DISTINCT unnest(v_image_paths))) THEN
    RAISE EXCEPTION 'Review image paths must be unique' USING ERRCODE = '22023';
  END IF;

  FOREACH v_storage_path IN ARRAY v_image_paths LOOP
    IF v_storage_path !~ ('^' || p_contact_id::TEXT || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$') THEN
      RAISE EXCEPTION 'Invalid review image path' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM unnest(v_image_paths) AS paths(storage_path)
    WHERE NOT EXISTS (
      SELECT 1 FROM storage.objects AS objects
      WHERE objects.bucket_id = 'review-images' AND objects.name = paths.storage_path
    )
  ) THEN
    RAISE EXCEPTION 'One or more review images were not uploaded' USING ERRCODE = '22023';
  END IF;

  v_comment := NULLIF(btrim(regexp_replace(COALESCE(p_comment, ''), E'\r\n?', E'\n', 'g')), '');
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
  ELSIF v_reviewer_whatsapp ~ '^[1-9][0-9]{7,14}$' THEN
    v_reviewer_whatsapp := '+' || v_reviewer_whatsapp;
  END IF;

  IF v_comment IS NOT NULL AND char_length(v_comment) > 1000 THEN
    RAISE EXCEPTION 'Comment must be 1000 characters or fewer' USING ERRCODE = '22023';
  END IF;
  IF v_reviewer_name IS NOT NULL AND char_length(v_reviewer_name) > 80 THEN
    RAISE EXCEPTION 'Reviewer name must be 80 characters or fewer' USING ERRCODE = '22023';
  END IF;
  IF v_reviewer_whatsapp !~ '^\+[1-9][0-9]{7,14}$' THEN
    RAISE EXCEPTION 'Enter a valid WhatsApp number including country code' USING ERRCODE = '22023';
  END IF;
  IF p_verification_method NOT IN ('whatsapp_otp', 'whatsapp_inbound', 'trusted_session') THEN
    RAISE EXCEPTION 'A verified WhatsApp method is required' USING ERRCODE = '22023';
  END IF;

  SELECT reviews.* INTO v_review
  FROM public.provider_reviews AS reviews
  WHERE reviews.contact_id = p_contact_id
    AND reviews.reviewer_whatsapp = v_reviewer_whatsapp
    AND reviews.is_deleted = FALSE
  FOR UPDATE;

  IF FOUND THEN
    DELETE FROM public.provider_review_images AS images WHERE images.review_id = v_review.id;
    UPDATE public.provider_reviews AS reviews
    SET
      rating = p_rating,
      comment = v_comment,
      reviewer_name = v_reviewer_name,
      verification_method = p_verification_method,
      verification_action_id = COALESCE(p_verification_action_id, reviews.verification_action_id),
      verified_at = now(),
      twilio_verification_sid = p_twilio_verification_sid,
      updated_at = now()
    WHERE reviews.id = v_review.id
    RETURNING reviews.* INTO v_review;
  ELSE
    INSERT INTO public.provider_reviews AS reviews (
      contact_id,
      rating,
      comment,
      reviewer_name,
      reviewer_whatsapp,
      verification_method,
      verification_action_id,
      verified_at,
      twilio_verification_sid
    ) VALUES (
      p_contact_id,
      p_rating,
      v_comment,
      v_reviewer_name,
      v_reviewer_whatsapp,
      p_verification_method,
      p_verification_action_id,
      now(),
      p_twilio_verification_sid
    )
    RETURNING reviews.* INTO v_review;
  END IF;

  INSERT INTO public.provider_review_images (review_id, storage_path, position)
  SELECT v_review.id, paths.storage_path, (paths.ordinality - 1)::SMALLINT
  FROM unnest(v_image_paths) WITH ORDINALITY AS paths(storage_path, ordinality);

  RETURN QUERY SELECT
    v_review.id,
    v_review.contact_id,
    v_review.rating,
    v_review.comment,
    v_review.reviewer_name,
    v_review.created_at,
    v_image_paths;
END;
$_$;


ALTER FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text", "p_verification_method" "text", "p_verification_action_id" "uuid", "p_twilio_verification_sid" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."undo_last_inbound_wiki_change"("p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") RETURNS TABLE("slug" "text", "title" "text", "version" integer, "event_id" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
DECLARE
  v_original public.wiki_change_events%ROWTYPE;
  v_current public.wiki_pages%ROWTYPE;
  v_restored public.wiki_pages%ROWTYPE;
  v_before JSONB;
  v_after JSONB;
  v_event_id UUID;
  v_existing public.wiki_change_events%ROWTYPE;
  v_snapshot JSONB;
BEGIN
  IF btrim(COALESCE(p_requester_whatsapp, '')) !~ '^\+[1-9][0-9]{7,14}$'
    OR NULLIF(btrim(COALESCE(p_twilio_message_sid, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Invalid wiki undo request' USING ERRCODE = '22023';
  END IF;

  SELECT events.* INTO v_existing
  FROM public.wiki_change_events AS events
  WHERE events.twilio_message_sid = p_twilio_message_sid
    AND events.action_type = 'wiki_restore'
  LIMIT 1;
  IF FOUND THEN
    v_snapshot := COALESCE(v_existing.after_snapshot, v_existing.before_snapshot);
    RETURN QUERY SELECT v_existing.page_slug, v_snapshot->>'title',
      COALESCE((v_existing.after_snapshot->>'version')::INTEGER, -1), v_existing.id;
    RETURN;
  END IF;

  SELECT events.* INTO v_original
  FROM public.wiki_change_events AS events
  WHERE events.requester_whatsapp = btrim(COALESCE(p_requester_whatsapp, ''))
    AND events.twilio_message_sid IS NOT NULL
    AND events.action_type IN ('wiki_create', 'wiki_update', 'wiki_delete')
    AND events.reverted_at IS NULL
    AND events.changed_at > now() - interval '24 hours'
  ORDER BY events.changed_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No recent wiki change to undo' USING ERRCODE = 'P0002'; END IF;

  SELECT pages.* INTO v_current FROM public.wiki_pages AS pages
  WHERE pages.slug = v_original.page_slug AND pages.is_published = TRUE
  LIMIT 1 FOR UPDATE;

  IF v_original.action_type = 'wiki_create' THEN
    IF NOT FOUND OR v_current.version <> (v_original.after_snapshot->>'version')::INTEGER THEN
      RAISE EXCEPTION 'Wiki page changed after your edit' USING ERRCODE = '40001';
    END IF;
    v_before := v_original.after_snapshot;
    UPDATE public.wiki_pages AS pages SET is_published = FALSE
    WHERE pages.id = v_current.id AND pages.version = v_current.version;
    v_restored := v_current;
    v_after := NULL;
  ELSE
    IF v_original.action_type = 'wiki_update'
      AND (NOT FOUND OR v_current.version <> (v_original.after_snapshot->>'version')::INTEGER) THEN
      RAISE EXCEPTION 'Wiki page changed after your edit' USING ERRCODE = '40001';
    END IF;
    IF v_original.action_type = 'wiki_delete' AND FOUND THEN
      RAISE EXCEPTION 'Wiki page changed after your edit' USING ERRCODE = '40001';
    END IF;
    IF FOUND THEN
      v_before := jsonb_build_object('id', v_current.id, 'slug', v_current.slug,
        'title', v_current.title, 'content', v_current.content, 'excerpt', v_current.excerpt,
        'category', v_current.category, 'version', v_current.version,
        'created_at', v_current.created_at, 'updated_at', v_current.updated_at);
      UPDATE public.wiki_pages AS pages SET is_published = FALSE
      WHERE pages.id = v_current.id AND pages.version = v_current.version;
    ELSE
      v_before := NULL;
    END IF;
    INSERT INTO public.wiki_pages (
      id, slug, title, content, excerpt, category, version, is_published,
      created_at, updated_at, created_by
    ) SELECT
      (v_original.before_snapshot->>'id')::UUID,
      v_original.before_snapshot->>'slug', v_original.before_snapshot->>'title',
      v_original.before_snapshot->'content', v_original.before_snapshot->>'excerpt',
      v_original.before_snapshot->>'category',
      COALESCE((SELECT max(pages.version) + 1 FROM public.wiki_pages AS pages
        WHERE pages.id = (v_original.before_snapshot->>'id')::UUID), 0),
      TRUE, COALESCE((v_original.before_snapshot->>'created_at')::TIMESTAMPTZ, now()),
      now(), NULL
    RETURNING * INTO v_restored;
    v_after := jsonb_build_object('id', v_restored.id, 'slug', v_restored.slug,
      'title', v_restored.title, 'content', v_restored.content, 'excerpt', v_restored.excerpt,
      'category', v_restored.category, 'version', v_restored.version,
      'created_at', v_restored.created_at, 'updated_at', v_restored.updated_at);
  END IF;

  INSERT INTO public.wiki_change_events (
    page_id, page_slug, action_type, requester_whatsapp, requester_name,
    verification_method, twilio_message_sid, before_snapshot, after_snapshot
  ) VALUES (
    v_original.page_id, v_original.page_slug, 'wiki_restore', v_original.requester_whatsapp,
    NULLIF(btrim(COALESCE(p_requester_name, '')), ''), 'whatsapp_inbound',
    p_twilio_message_sid, v_before, v_after
  ) RETURNING wiki_change_events.id INTO v_event_id;
  UPDATE public.wiki_change_events SET reverted_at = now(), reverted_by_event_id = v_event_id
  WHERE wiki_change_events.id = v_original.id;

  RETURN QUERY SELECT v_original.page_slug,
    COALESCE(v_restored.title, v_original.after_snapshot->>'title'),
    COALESCE(v_restored.version, -1), v_event_id;
END;
$_$;


ALTER FUNCTION "public"."undo_last_inbound_wiki_change"("p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."update_inbound_provider_contact"("p_contact_id" "uuid", "p_changes" "jsonb", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") RETURNS TABLE("id" "uuid", "title" "text", "subtitle" "text", "category" "text", "phone_number" "text", "website_url" "text", "map_url" "text", "image_url" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_before public.contacts%ROWTYPE;
  v_after public.contacts%ROWTYPE;
BEGIN
  IF jsonb_typeof(COALESCE(p_changes, '{}'::JSONB)) <> 'object'
    OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_changes) AS keys(key)
      WHERE keys.key NOT IN ('title', 'subtitle', 'category')) THEN
    RAISE EXCEPTION 'Invalid provider changes' USING ERRCODE = '22023';
  END IF;
  SELECT contacts.* INTO v_before FROM public.contacts AS contacts
  WHERE contacts.id = p_contact_id AND contacts.is_deleted = FALSE FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Provider not found' USING ERRCODE = 'P0002'; END IF;
  UPDATE public.contacts AS contacts SET
    title = CASE WHEN p_changes ? 'title' THEN left(btrim(p_changes->>'title'), 160) ELSE contacts.title END,
    subtitle = CASE WHEN p_changes ? 'subtitle' THEN left(btrim(p_changes->>'subtitle'), 2000) ELSE contacts.subtitle END,
    category = CASE WHEN p_changes ? 'category' THEN left(btrim(p_changes->>'category'), 80) ELSE contacts.category END
  WHERE contacts.id = p_contact_id RETURNING contacts.* INTO v_after;
  IF to_jsonb(v_before) IS DISTINCT FROM to_jsonb(v_after) THEN
    INSERT INTO public.provider_change_events (
      contact_id, action_type, requester_whatsapp, requester_name,
      verification_method, twilio_message_sid, before_snapshot, after_snapshot
    ) VALUES (
      v_after.id, 'provider_update', p_requester_whatsapp,
      NULLIF(btrim(COALESCE(p_requester_name, '')), ''), 'whatsapp_inbound',
      p_twilio_message_sid, to_jsonb(v_before) - 'phone_normalized',
      to_jsonb(v_after) - 'phone_normalized'
    ) ON CONFLICT (twilio_message_sid, contact_id, action_type)
      WHERE twilio_message_sid IS NOT NULL DO NOTHING;
  END IF;
  RETURN QUERY SELECT v_after.id, v_after.title, v_after.subtitle, v_after.category,
    v_after.phone_number, v_after.website_url, v_after.map_url, v_after.image_url;
END;
$$;


ALTER FUNCTION "public"."update_inbound_provider_contact"("p_contact_id" "uuid", "p_changes" "jsonb", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."upsert_inbound_provider_contact"("p_name" "text", "p_phone" "text", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") RETURNS TABLE("id" "uuid", "title" "text", "subtitle" "text", "category" "text", "phone_number" "text", "website_url" "text", "map_url" "text", "image_url" "text", "created" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_contact public.contacts%ROWTYPE;
  v_created BOOLEAN := FALSE;
BEGIN
  SELECT contacts.* INTO v_contact FROM public.contacts AS contacts
  WHERE contacts.is_deleted = FALSE
    AND contacts.phone_normalized = public.normalize_contact_phone(p_phone)
  LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO public.contacts (title, subtitle, category, phone_number, is_deleted)
    VALUES (left(btrim(COALESCE(p_name, p_phone)), 160), '', 'Service', p_phone, FALSE)
    RETURNING * INTO v_contact;
    v_created := TRUE;
    INSERT INTO public.provider_change_events (
      contact_id, action_type, requester_whatsapp, requester_name,
      verification_method, twilio_message_sid, before_snapshot, after_snapshot
    ) VALUES (
      v_contact.id, 'provider_create', p_requester_whatsapp,
      NULLIF(btrim(COALESCE(p_requester_name, '')), ''), 'whatsapp_inbound',
      p_twilio_message_sid, NULL, to_jsonb(v_contact) - 'phone_normalized'
    ) ON CONFLICT (twilio_message_sid, contact_id, action_type)
      WHERE twilio_message_sid IS NOT NULL DO NOTHING;
  END IF;
  RETURN QUERY SELECT v_contact.id, v_contact.title, v_contact.subtitle,
    v_contact.category, v_contact.phone_number, v_contact.website_url,
    v_contact.map_url, v_contact.image_url, v_created;
END;
$$;


ALTER FUNCTION "public"."upsert_inbound_provider_contact"("p_name" "text", "p_phone" "text", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."bot_conversations" (
    "conversation_key" "text" NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "phase" "public"."bot_conversation_phase" NOT NULL,
    "context" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bot_conversations_check" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "bot_conversations_context_check" CHECK (("jsonb_typeof"("context") = 'object'::"text")),
    CONSTRAINT "bot_conversations_conversation_key_check" CHECK (("conversation_key" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "public"."bot_conversations" OWNER TO "postgres";


COMMENT ON TABLE "public"."bot_conversations" IS 'Short-lived Machu bot state keyed by a server-generated HMAC; contains no submitter phone numbers.';



CREATE TABLE IF NOT EXISTS "public"."bot_search_sessions" (
    "conversation_key" "text" NOT NULL,
    "context" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bot_search_sessions_check" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "bot_search_sessions_context_check" CHECK (("jsonb_typeof"("context") = 'object'::"text")),
    CONSTRAINT "bot_search_sessions_conversation_key_check" CHECK (("conversation_key" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "public"."bot_search_sessions" OWNER TO "postgres";


COMMENT ON TABLE "public"."bot_search_sessions" IS 'Short-lived Machu search result queues keyed by a server-generated HMAC; contains no submitter phone numbers.';



CREATE TABLE IF NOT EXISTS "public"."bot_wiki_sessions" (
    "conversation_key" "text" NOT NULL,
    "context" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "bot_wiki_sessions_check" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "bot_wiki_sessions_context_check" CHECK (("jsonb_typeof"("context") = 'object'::"text")),
    CONSTRAINT "bot_wiki_sessions_conversation_key_check" CHECK (("conversation_key" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "public"."bot_wiki_sessions" OWNER TO "postgres";


COMMENT ON TABLE "public"."bot_wiki_sessions" IS 'Short-lived wiki context keyed by a server HMAC; contains no WhatsApp numbers.';



CREATE TABLE IF NOT EXISTS "public"."community_verification_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "action_type" "text" NOT NULL,
    "requester_whatsapp" "text",
    "payload" "jsonb" NOT NULL,
    "client_secret_hash" "text" NOT NULL,
    "request_ip_hash" "text",
    "twilio_verification_sid" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "check_attempts" smallint DEFAULT 0 NOT NULL,
    "result_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval) NOT NULL,
    "verified_at" timestamp with time zone,
    "consumed_at" timestamp with time zone,
    "verification_method" "text" DEFAULT 'whatsapp_otp'::"text" NOT NULL,
    "trusted_session_id" "uuid",
    CONSTRAINT "community_verification_actions_action_type_check" CHECK (("action_type" = ANY (ARRAY['provider_create'::"text", 'provider_update'::"text", 'provider_delete'::"text", 'provider_review'::"text", 'wiki_create'::"text", 'wiki_update'::"text", 'wiki_delete'::"text"]))),
    CONSTRAINT "community_verification_actions_check" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "community_verification_actions_check1" CHECK ((("verified_at" IS NULL) OR ("verified_at" >= "created_at"))),
    CONSTRAINT "community_verification_actions_check2" CHECK ((("consumed_at" IS NULL) OR ("verified_at" IS NOT NULL))),
    CONSTRAINT "community_verification_actions_check_attempts_check" CHECK ((("check_attempts" >= 0) AND ("check_attempts" <= 10))),
    CONSTRAINT "community_verification_actions_client_secret_hash_check" CHECK (("client_secret_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "community_verification_actions_payload_check" CHECK (("jsonb_typeof"("payload") = 'object'::"text")),
    CONSTRAINT "community_verification_actions_request_ip_hash_check" CHECK ((("request_ip_hash" IS NULL) OR ("request_ip_hash" ~ '^[0-9a-f]{64}$'::"text"))),
    CONSTRAINT "community_verification_actions_requester_whatsapp_check" CHECK (("requester_whatsapp" ~ '^\+[1-9][0-9]{7,14}$'::"text")),
    CONSTRAINT "community_verification_actions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'verified'::"text", 'completed'::"text", 'failed'::"text", 'expired'::"text"]))),
    CONSTRAINT "community_verification_actions_twilio_verification_sid_check" CHECK ((("twilio_verification_sid" IS NULL) OR ("twilio_verification_sid" ~ '^VE[0-9a-fA-F]{32}$'::"text"))),
    CONSTRAINT "community_verification_actions_verification_method_check" CHECK (("verification_method" = ANY (ARRAY['whatsapp_otp'::"text", 'whatsapp_inbound'::"text", 'trusted_session'::"text"]))),
    CONSTRAINT "community_verification_actions_verified_actor_check" CHECK ((("requester_whatsapp" IS NOT NULL) OR (("verification_method" = 'whatsapp_inbound'::"text") AND ("status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'failed'::"text", 'expired'::"text"])))))
);


ALTER TABLE "public"."community_verification_actions" OWNER TO "postgres";


COMMENT ON TABLE "public"."community_verification_actions" IS 'Private, short-lived actions bound to a Twilio WhatsApp possession verification.';



COMMENT ON COLUMN "public"."community_verification_actions"."requester_whatsapp" IS 'Private verified actor. For inbound flows this is populated atomically from the Twilio-signed WhatsApp sender; pending actions are unclaimed.';



COMMENT ON COLUMN "public"."community_verification_actions"."verification_method" IS 'Possession proof used for this action; new browser actions use a signed inbound Machu message.';



CREATE TABLE IF NOT EXISTS "public"."community_verified_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "token_hash" "text" NOT NULL,
    "verified_whatsapp" "text" NOT NULL,
    "source_action_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_used_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "community_verified_sessions_check" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "community_verified_sessions_check1" CHECK (("last_used_at" >= "created_at")),
    CONSTRAINT "community_verified_sessions_check2" CHECK ((("revoked_at" IS NULL) OR ("revoked_at" >= "created_at"))),
    CONSTRAINT "community_verified_sessions_token_hash_check" CHECK (("token_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "community_verified_sessions_verified_whatsapp_check" CHECK (("verified_whatsapp" ~ '^\+[1-9][0-9]{7,14}$'::"text"))
);


ALTER TABLE "public"."community_verified_sessions" OWNER TO "postgres";


COMMENT ON TABLE "public"."community_verified_sessions" IS 'Private 30-day browser sessions mapped to a WhatsApp number proven through Machu.';



COMMENT ON COLUMN "public"."community_verified_sessions"."token_hash" IS 'SHA-256 of the opaque HttpOnly browser credential; the raw credential is never stored.';



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
    "is_deleted" boolean DEFAULT false NOT NULL,
    "phone_normalized" "text" GENERATED ALWAYS AS ("public"."normalize_contact_phone"("phone_number")) STORED
);


ALTER TABLE "public"."contacts" OWNER TO "postgres";


COMMENT ON COLUMN "public"."contacts"."title" IS 'Name of the contact/business';



COMMENT ON COLUMN "public"."contacts"."category" IS 'Category assignment (single value)';



COMMENT ON COLUMN "public"."contacts"."subtitle" IS 'Short description or tagline';



COMMENT ON COLUMN "public"."contacts"."phone_number" IS 'Contact phone number';



COMMENT ON COLUMN "public"."contacts"."website_url" IS 'Link to website or social media';



COMMENT ON COLUMN "public"."contacts"."image_url" IS 'Public URL of the image stored in Supabase Storage';



CREATE TABLE IF NOT EXISTS "public"."provider_change_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "requester_whatsapp" "text" NOT NULL,
    "verification_method" "text" NOT NULL,
    "verification_action_id" "uuid",
    "before_snapshot" "jsonb",
    "after_snapshot" "jsonb" NOT NULL,
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "requester_name" "text",
    "twilio_message_sid" "text",
    CONSTRAINT "provider_change_events_action_type_check" CHECK (("action_type" = ANY (ARRAY['provider_create'::"text", 'provider_update'::"text"]))),
    CONSTRAINT "provider_change_events_actor_source_check" CHECK (((("verification_action_id" IS NOT NULL) AND ("twilio_message_sid" IS NULL)) OR (("verification_action_id" IS NULL) AND ("twilio_message_sid" IS NOT NULL)))),
    CONSTRAINT "provider_change_events_after_snapshot_check" CHECK (("jsonb_typeof"("after_snapshot") = 'object'::"text")),
    CONSTRAINT "provider_change_events_before_snapshot_check" CHECK ((("before_snapshot" IS NULL) OR ("jsonb_typeof"("before_snapshot") = 'object'::"text"))),
    CONSTRAINT "provider_change_events_check" CHECK (((("action_type" = 'provider_create'::"text") AND ("before_snapshot" IS NULL)) OR (("action_type" = 'provider_update'::"text") AND ("before_snapshot" IS NOT NULL)))),
    CONSTRAINT "provider_change_events_requester_whatsapp_check" CHECK (("requester_whatsapp" ~ '^\+[1-9][0-9]{7,14}$'::"text")),
    CONSTRAINT "provider_change_events_verification_method_check" CHECK (("verification_method" = ANY (ARRAY['whatsapp_otp'::"text", 'whatsapp_inbound'::"text", 'trusted_session'::"text"])))
);


ALTER TABLE "public"."provider_change_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."provider_change_events" IS 'Private immutable administrator audit trail for provider additions and edits.';



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
    "verification_action_id" "uuid",
    "verification_method" "text" DEFAULT 'legacy_community_code'::"text" NOT NULL,
    "verified_at" timestamp with time zone,
    "twilio_verification_sid" "text",
    CONSTRAINT "provider_deletion_events_check" CHECK (("undo_expires_at" > "deleted_at")),
    CONSTRAINT "provider_deletion_events_check1" CHECK ((("undone_at" IS NULL) OR ("undone_at" <= "undo_expires_at"))),
    CONSTRAINT "provider_deletion_events_provider_name_snapshot_check" CHECK (("char_length"("provider_name_snapshot") > 0)),
    CONSTRAINT "provider_deletion_events_requester_whatsapp_check" CHECK (((("char_length"("requester_whatsapp") >= 8) AND ("char_length"("requester_whatsapp") <= 16)) AND ("requester_whatsapp" ~ '^\+?[0-9]{8,15}$'::"text"))),
    CONSTRAINT "provider_deletion_events_twilio_verification_sid_check" CHECK ((("twilio_verification_sid" IS NULL) OR ("twilio_verification_sid" ~ '^VE[0-9a-fA-F]{32}$'::"text"))),
    CONSTRAINT "provider_deletion_events_undo_token_hash_check" CHECK (("undo_token_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "provider_deletion_events_verification_method_check" CHECK (("verification_method" = ANY (ARRAY['legacy_community_code'::"text", 'whatsapp_otp'::"text", 'whatsapp_inbound'::"text", 'trusted_session'::"text"])))
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
    "verification_action_id" "uuid",
    "verification_method" "text" DEFAULT 'legacy_unverified'::"text" NOT NULL,
    "verified_at" timestamp with time zone,
    "twilio_verification_sid" "text",
    CONSTRAINT "provider_reviews_check" CHECK (((("is_deleted" = false) AND ("deleted_at" IS NULL)) OR (("is_deleted" = true) AND ("deleted_at" IS NOT NULL)))),
    CONSTRAINT "provider_reviews_comment_check" CHECK ((("comment" IS NULL) OR ("char_length"("comment") <= 1000))),
    CONSTRAINT "provider_reviews_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5))),
    CONSTRAINT "provider_reviews_reviewer_name_check" CHECK ((("reviewer_name" IS NULL) OR ("char_length"("reviewer_name") <= 80))),
    CONSTRAINT "provider_reviews_reviewer_whatsapp_check" CHECK (((("char_length"("reviewer_whatsapp") >= 8) AND ("char_length"("reviewer_whatsapp") <= 16)) AND ("reviewer_whatsapp" ~ '^\+?[0-9]{8,15}$'::"text"))),
    CONSTRAINT "provider_reviews_verification_method_check" CHECK (("verification_method" = ANY (ARRAY['legacy_unverified'::"text", 'whatsapp_otp'::"text", 'whatsapp_inbound'::"text", 'trusted_session'::"text"])))
);


ALTER TABLE "public"."provider_reviews" OWNER TO "postgres";


COMMENT ON TABLE "public"."provider_reviews" IS 'Account-free provider reviews. reviewer_whatsapp is private and must never be exposed by public RPCs.';



COMMENT ON COLUMN "public"."provider_reviews"."reviewer_whatsapp" IS 'Private abuse/contact signal. Never include this column in a public RPC return type.';



CREATE TABLE IF NOT EXISTS "public"."wiki_change_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "page_id" "uuid" NOT NULL,
    "page_slug" "text" NOT NULL,
    "action_type" "text" NOT NULL,
    "requester_whatsapp" "text" NOT NULL,
    "requester_name" "text",
    "verification_method" "text" NOT NULL,
    "verification_action_id" "uuid",
    "twilio_message_sid" "text",
    "before_snapshot" "jsonb",
    "after_snapshot" "jsonb",
    "reverted_at" timestamp with time zone,
    "reverted_by_event_id" "uuid",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "wiki_change_events_action_type_check" CHECK (("action_type" = ANY (ARRAY['wiki_create'::"text", 'wiki_update'::"text", 'wiki_delete'::"text", 'wiki_restore'::"text"]))),
    CONSTRAINT "wiki_change_events_after_snapshot_check" CHECK ((("after_snapshot" IS NULL) OR ("jsonb_typeof"("after_snapshot") = 'object'::"text"))),
    CONSTRAINT "wiki_change_events_before_snapshot_check" CHECK ((("before_snapshot" IS NULL) OR ("jsonb_typeof"("before_snapshot") = 'object'::"text"))),
    CONSTRAINT "wiki_change_events_check" CHECK (((("verification_action_id" IS NOT NULL) AND ("twilio_message_sid" IS NULL)) OR (("verification_action_id" IS NULL) AND ("twilio_message_sid" IS NOT NULL)))),
    CONSTRAINT "wiki_change_events_check1" CHECK (((("action_type" = 'wiki_create'::"text") AND ("before_snapshot" IS NULL) AND ("after_snapshot" IS NOT NULL)) OR (("action_type" = 'wiki_update'::"text") AND ("before_snapshot" IS NOT NULL) AND ("after_snapshot" IS NOT NULL)) OR (("action_type" = 'wiki_delete'::"text") AND ("before_snapshot" IS NOT NULL) AND ("after_snapshot" IS NULL)) OR (("action_type" = 'wiki_restore'::"text") AND (("before_snapshot" IS NOT NULL) OR ("after_snapshot" IS NOT NULL))))),
    CONSTRAINT "wiki_change_events_requester_whatsapp_check" CHECK (("requester_whatsapp" ~ '^\+[1-9][0-9]{7,14}$'::"text")),
    CONSTRAINT "wiki_change_events_verification_method_check" CHECK (("verification_method" = ANY (ARRAY['whatsapp_inbound'::"text", 'trusted_session'::"text"])))
);


ALTER TABLE "public"."wiki_change_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."wiki_change_events" IS 'Private immutable actor trail for current wiki mutations through Machu and verified web sessions.';



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


ALTER TABLE ONLY "public"."bot_conversations"
    ADD CONSTRAINT "bot_conversations_pkey" PRIMARY KEY ("conversation_key");



ALTER TABLE ONLY "public"."bot_search_sessions"
    ADD CONSTRAINT "bot_search_sessions_pkey" PRIMARY KEY ("conversation_key");



ALTER TABLE ONLY "public"."bot_wiki_sessions"
    ADD CONSTRAINT "bot_wiki_sessions_pkey" PRIMARY KEY ("conversation_key");



ALTER TABLE ONLY "public"."community_verification_actions"
    ADD CONSTRAINT "community_verification_actions_client_secret_hash_key" UNIQUE ("client_secret_hash");



ALTER TABLE ONLY "public"."community_verification_actions"
    ADD CONSTRAINT "community_verification_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_verified_sessions"
    ADD CONSTRAINT "community_verified_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_verified_sessions"
    ADD CONSTRAINT "community_verified_sessions_token_hash_key" UNIQUE ("token_hash");



ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_change_events"
    ADD CONSTRAINT "provider_change_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."provider_change_events"
    ADD CONSTRAINT "provider_change_events_verification_action_id_key" UNIQUE ("verification_action_id");



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



ALTER TABLE ONLY "public"."wiki_change_events"
    ADD CONSTRAINT "wiki_change_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wiki_change_events"
    ADD CONSTRAINT "wiki_change_events_verification_action_id_key" UNIQUE ("verification_action_id");



ALTER TABLE ONLY "public"."wiki_pages"
    ADD CONSTRAINT "wiki_pages_pkey" PRIMARY KEY ("id", "version");



CREATE INDEX "bot_conversations_expiry_idx" ON "public"."bot_conversations" USING "btree" ("expires_at");



CREATE INDEX "bot_search_sessions_expiry_idx" ON "public"."bot_search_sessions" USING "btree" ("expires_at");



CREATE INDEX "bot_wiki_sessions_expiry_idx" ON "public"."bot_wiki_sessions" USING "btree" ("expires_at");



CREATE INDEX "community_verification_actions_expiry_idx" ON "public"."community_verification_actions" USING "btree" ("expires_at") WHERE ("consumed_at" IS NULL);



CREATE INDEX "community_verification_actions_ip_created_idx" ON "public"."community_verification_actions" USING "btree" ("request_ip_hash", "created_at" DESC) WHERE ("request_ip_hash" IS NOT NULL);



CREATE INDEX "community_verification_actions_phone_created_idx" ON "public"."community_verification_actions" USING "btree" ("requester_whatsapp", "created_at" DESC);



CREATE INDEX "community_verified_sessions_expiry_idx" ON "public"."community_verified_sessions" USING "btree" ("expires_at") WHERE ("revoked_at" IS NULL);



CREATE INDEX "community_verified_sessions_phone_created_idx" ON "public"."community_verified_sessions" USING "btree" ("verified_whatsapp", "created_at" DESC);



CREATE UNIQUE INDEX "contacts_active_phone_normalized_unique_idx" ON "public"."contacts" USING "btree" ("phone_normalized") WHERE (("is_deleted" = false) AND ("phone_normalized" IS NOT NULL));



CREATE INDEX "provider_change_events_actor_changed_idx" ON "public"."provider_change_events" USING "btree" ("requester_whatsapp", "changed_at" DESC);



CREATE INDEX "provider_change_events_contact_changed_idx" ON "public"."provider_change_events" USING "btree" ("contact_id", "changed_at" DESC);



CREATE UNIQUE INDEX "provider_change_events_inbound_message_idx" ON "public"."provider_change_events" USING "btree" ("twilio_message_sid", "contact_id", "action_type") WHERE ("twilio_message_sid" IS NOT NULL);



CREATE INDEX "provider_deletion_events_contact_deleted_idx" ON "public"."provider_deletion_events" USING "btree" ("contact_id", "deleted_at" DESC);



CREATE INDEX "provider_deletion_events_pending_undo_idx" ON "public"."provider_deletion_events" USING "btree" ("undo_expires_at") WHERE ("undone_at" IS NULL);



CREATE UNIQUE INDEX "provider_deletion_events_verification_action_uidx" ON "public"."provider_deletion_events" USING "btree" ("verification_action_id") WHERE ("verification_action_id" IS NOT NULL);



CREATE INDEX "provider_review_images_review_position_idx" ON "public"."provider_review_images" USING "btree" ("review_id", "position");



CREATE UNIQUE INDEX "provider_reviews_one_active_per_whatsapp_uidx" ON "public"."provider_reviews" USING "btree" ("contact_id", "reviewer_whatsapp") WHERE ("is_deleted" = false);



COMMENT ON INDEX "public"."provider_reviews_one_active_per_whatsapp_uidx" IS 'One active review per provider per canonical verified WhatsApp number.';



CREATE INDEX "provider_reviews_public_contact_created_idx" ON "public"."provider_reviews" USING "btree" ("contact_id", "created_at" DESC) WHERE ("is_deleted" = false);



CREATE UNIQUE INDEX "provider_reviews_verification_action_uidx" ON "public"."provider_reviews" USING "btree" ("verification_action_id") WHERE ("verification_action_id" IS NOT NULL);



CREATE INDEX "wiki_change_events_actor_changed_idx" ON "public"."wiki_change_events" USING "btree" ("requester_whatsapp", "changed_at" DESC);



CREATE UNIQUE INDEX "wiki_change_events_inbound_message_idx" ON "public"."wiki_change_events" USING "btree" ("twilio_message_sid", "page_slug", "action_type") WHERE ("twilio_message_sid" IS NOT NULL);



CREATE INDEX "wiki_change_events_page_changed_idx" ON "public"."wiki_change_events" USING "btree" ("page_id", "changed_at" DESC);



CREATE INDEX "wiki_pages_content_idx" ON "public"."wiki_pages" USING "gin" ("content");



CREATE INDEX "wiki_pages_content_tsv_idx" ON "public"."wiki_pages" USING "gin" ("content_tsv");



CREATE INDEX "wiki_pages_slug_idx" ON "public"."wiki_pages" USING "btree" ("slug");



CREATE INDEX "wiki_pages_title_idx" ON "public"."wiki_pages" USING "gin" ("to_tsvector"('"english"'::"regconfig", "title"));



CREATE OR REPLACE TRIGGER "on_contacts_updated" BEFORE UPDATE ON "public"."contacts" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_provider_review_updated_at" BEFORE UPDATE ON "public"."provider_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."set_provider_review_updated_at"();



CREATE OR REPLACE TRIGGER "wiki_pages_tsv_update" BEFORE INSERT OR UPDATE ON "public"."wiki_pages" FOR EACH ROW EXECUTE FUNCTION "public"."update_wiki_content_tsv"();



ALTER TABLE ONLY "public"."bot_conversations"
    ADD CONSTRAINT "bot_conversations_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_verification_actions"
    ADD CONSTRAINT "community_verification_actions_trusted_session_id_fkey" FOREIGN KEY ("trusted_session_id") REFERENCES "public"."community_verified_sessions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."community_verified_sessions"
    ADD CONSTRAINT "community_verified_sessions_source_action_id_fkey" FOREIGN KEY ("source_action_id") REFERENCES "public"."community_verification_actions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."provider_change_events"
    ADD CONSTRAINT "provider_change_events_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."provider_change_events"
    ADD CONSTRAINT "provider_change_events_verification_action_id_fkey" FOREIGN KEY ("verification_action_id") REFERENCES "public"."community_verification_actions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."provider_deletion_events"
    ADD CONSTRAINT "provider_deletion_events_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."provider_deletion_events"
    ADD CONSTRAINT "provider_deletion_events_verification_action_id_fkey" FOREIGN KEY ("verification_action_id") REFERENCES "public"."community_verification_actions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."provider_review_images"
    ADD CONSTRAINT "provider_review_images_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."provider_reviews"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."provider_reviews"
    ADD CONSTRAINT "provider_reviews_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."provider_reviews"
    ADD CONSTRAINT "provider_reviews_verification_action_id_fkey" FOREIGN KEY ("verification_action_id") REFERENCES "public"."community_verification_actions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."wiki_change_events"
    ADD CONSTRAINT "wiki_change_events_reverted_by_event_id_fkey" FOREIGN KEY ("reverted_by_event_id") REFERENCES "public"."wiki_change_events"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."wiki_change_events"
    ADD CONSTRAINT "wiki_change_events_verification_action_id_fkey" FOREIGN KEY ("verification_action_id") REFERENCES "public"."community_verification_actions"("id") ON DELETE RESTRICT;



CREATE POLICY "All access for All Users" ON "public"."wiki_pages" USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."wiki_pages" FOR SELECT USING (true);



CREATE POLICY "Public can read active contacts" ON "public"."contacts" FOR SELECT TO "authenticated", "anon" USING (("is_deleted" = false));



ALTER TABLE "public"."bot_conversations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bot_search_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bot_wiki_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_verification_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_verified_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_change_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_deletion_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_review_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."provider_reviews" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wiki_change_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wiki_pages" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON TYPE "public"."provider_deletion_reason" FROM PUBLIC;
GRANT ALL ON TYPE "public"."provider_deletion_reason" TO "service_role";

















































































































































































REVOKE ALL ON FUNCTION "public"."apply_audited_wiki_write"("p_action_type" "text", "p_slug" "text", "p_title" "text", "p_category" "text", "p_content" "text", "p_expected_version" integer, "p_requester_whatsapp" "text", "p_requester_name" "text", "p_verification_method" "text", "p_verification_action_id" "uuid", "p_twilio_message_sid" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_audited_wiki_write"("p_action_type" "text", "p_slug" "text", "p_title" "text", "p_category" "text", "p_content" "text", "p_expected_version" integer, "p_requester_whatsapp" "text", "p_requester_name" "text", "p_verification_method" "text", "p_verification_action_id" "uuid", "p_twilio_message_sid" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clear_bot_conversation"("p_conversation_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clear_bot_conversation"("p_conversation_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."clear_bot_conversation"("p_conversation_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_bot_conversation"("p_conversation_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clear_bot_search_session"("p_conversation_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clear_bot_search_session"("p_conversation_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."clear_bot_search_session"("p_conversation_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_bot_search_session"("p_conversation_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clear_bot_wiki_session"("p_conversation_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clear_bot_wiki_session"("p_conversation_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_verified_provider_deletion"("p_action_id" "uuid", "p_undo_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_verified_provider_deletion"("p_action_id" "uuid", "p_undo_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_verified_provider_review"("p_action_id" "uuid", "p_image_paths" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_verified_provider_review"("p_action_id" "uuid", "p_image_paths" "text"[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_verified_provider_write"("p_action_id" "uuid", "p_image_path" "text", "p_image_url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_verified_provider_write"("p_action_id" "uuid", "p_image_path" "text", "p_image_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_verified_wiki_write"("p_action_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_verified_wiki_write"("p_action_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."find_active_contact_by_phone"("p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."find_active_contact_by_phone"("p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."find_active_contact_by_phone"("p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."find_active_contact_by_phone"("p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_bot_conversation"("p_conversation_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_bot_conversation"("p_conversation_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_bot_conversation"("p_conversation_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bot_conversation"("p_conversation_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_bot_search_session"("p_conversation_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_bot_search_session"("p_conversation_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_bot_search_session"("p_conversation_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bot_search_session"("p_conversation_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_bot_wiki_session"("p_conversation_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_bot_wiki_session"("p_conversation_key" "text") TO "service_role";



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



REVOKE ALL ON FUNCTION "public"."normalize_contact_phone"("p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."normalize_contact_phone"("p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_contact_phone"("p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_contact_phone"("p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."perform_provider_soft_delete"("p_contact_id" "uuid", "p_provider_name_confirmation" "text", "p_reason" "text", "p_requester_whatsapp" "text", "p_undo_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_anonymous_contact_image_mutation"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_anonymous_contact_image_mutation"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_bot_conversation"("p_conversation_key" "text", "p_contact_id" "uuid", "p_phase" "text", "p_context" "jsonb", "p_ttl_hours" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_bot_conversation"("p_conversation_key" "text", "p_contact_id" "uuid", "p_phase" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."set_bot_conversation"("p_conversation_key" "text", "p_contact_id" "uuid", "p_phase" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_bot_conversation"("p_conversation_key" "text", "p_contact_id" "uuid", "p_phase" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_bot_search_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_bot_search_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."set_bot_search_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_bot_search_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_bot_wiki_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_bot_wiki_session"("p_conversation_key" "text", "p_context" "jsonb", "p_ttl_hours" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_provider_review_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_provider_review_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text", "p_verification_method" "text", "p_verification_action_id" "uuid", "p_twilio_verification_sid" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_provider_review"("p_contact_id" "uuid", "p_rating" smallint, "p_reviewer_whatsapp" "text", "p_image_paths" "text"[], "p_comment" "text", "p_reviewer_name" "text", "p_verification_method" "text", "p_verification_action_id" "uuid", "p_twilio_verification_sid" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."undo_last_inbound_wiki_change"("p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."undo_last_inbound_wiki_change"("p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."undo_provider_soft_delete"("p_event_id" "uuid", "p_undo_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_inbound_provider_contact"("p_contact_id" "uuid", "p_changes" "jsonb", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_inbound_provider_contact"("p_contact_id" "uuid", "p_changes" "jsonb", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."upsert_inbound_provider_contact"("p_name" "text", "p_phone" "text", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."upsert_inbound_provider_contact"("p_name" "text", "p_phone" "text", "p_requester_whatsapp" "text", "p_requester_name" "text", "p_twilio_message_sid" "text") TO "service_role";


















GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."bot_conversations" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."bot_search_sessions" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."bot_wiki_sessions" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."community_verification_actions" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."community_verified_sessions" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."contacts" TO "anon";
GRANT SELECT ON TABLE "public"."contacts" TO "authenticated";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_change_events" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_deletion_events" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_review_images" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."provider_reviews" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."wiki_change_events" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."wiki_pages" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."wiki_pages" TO "authenticated";
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































