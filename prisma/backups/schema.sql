

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


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE TYPE "public"."audit_status" AS ENUM (
    'pending',
    'in_progress',
    'partially_completed',
    'completed',
    'failed'
);


ALTER TYPE "public"."audit_status" OWNER TO "postgres";


CREATE TYPE "public"."audit_type_enum" AS ENUM (
    'lead_generation',
    'lead_conversion'
);


ALTER TYPE "public"."audit_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."call_direction" AS ENUM (
    'inbound',
    'outbound'
);


ALTER TYPE "public"."call_direction" OWNER TO "postgres";


CREATE TYPE "public"."micro_task_status" AS ENUM (
    'pending',
    'running',
    'completed',
    'failed'
);


ALTER TYPE "public"."micro_task_status" OWNER TO "postgres";


CREATE TYPE "public"."personality_source_type" AS ENUM (
    'onboarding',
    'inferred'
);


ALTER TYPE "public"."personality_source_type" OWNER TO "postgres";


CREATE TYPE "public"."role_type" AS ENUM (
    'user',
    'ai'
);


ALTER TYPE "public"."role_type" OWNER TO "postgres";


CREATE TYPE "public"."task_group_status" AS ENUM (
    'pending',
    'in_progress',
    'completed',
    'failed'
);


ALTER TYPE "public"."task_group_status" OWNER TO "postgres";


CREATE TYPE "public"."workflow_status" AS ENUM (
    'waiting',
    'started',
    'running',
    'success',
    'failed'
);


ALTER TYPE "public"."workflow_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_and_summarize_if_threshold_met"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_msg_count int;
  v_summary_text text;
  v_last_summary_at timestamp;
  v_user_id uuid;
  v_overlap int := 5;
  v_threshold int := 30;
  v_limit int := 50;
begin
  -- Get user_id from chat_sessions
  select user_id into v_user_id
  from chat_sessions
  where id = new.session_id;

  -- Get latest summary timestamp for this user
  select max(created_at) into v_last_summary_at
  from chat_archived_summaries
  where user_id = v_user_id;

  -- Fallback to session creation time if no summary exists
  if v_last_summary_at is null then
    select created_at into v_last_summary_at
    from chat_sessions
    where id = new.session_id;
  end if;

  -- Advisory lock (prevents race conditions)
  perform pg_advisory_xact_lock(hashtext(new.session_id::text));

  -- Count messages since last summary
  select count(*) into v_msg_count
  from chat_messages
  where session_id = new.session_id
    and created_at > v_last_summary_at;

  -- Only proceed if threshold met
  if v_msg_count >= v_threshold then
    with ordered_messages as (
      select created_at, role, message
      from chat_messages
      where session_id = new.session_id
        and created_at > v_last_summary_at
      order by created_at
    ), with_overlap as (
      select role, message
      from ordered_messages
      order by created_at
      limit v_limit
      offset greatest(v_msg_count - v_limit - v_overlap, 0)
    )
    select string_agg(role || ': ' || message, E'\n') into v_summary_text
    from with_overlap;

    -- Trigger summarization in n8n
    perform net.http_post(
      'https://referrizer.app.n8n.cloud/webhook/summarize_and_vectorize_chat',
      json_build_object(
        'session_id', new.session_id,
        'user_id', v_user_id,
        'text', v_summary_text
      )::jsonb,
      '{}'::jsonb,
      json_build_object('Content-Type', 'application/json')::jsonb
    );
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."check_and_summarize_if_threshold_met"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_personality_analysis_threshold"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
 current_count INT;
 uid UUID;
 payload JSON;
BEGIN
 IF NEW.role != 'user' THEN
   RETURN NEW;
 END IF;


 -- Get user_id from session
 SELECT user_id INTO uid FROM public.chat_sessions WHERE id = NEW.session_id;


 -- Upsert message count
 INSERT INTO public.personality_message_tracker (user_id, message_count)
 VALUES (uid, 1)
 ON CONFLICT (user_id)
 DO UPDATE SET message_count = personality_message_tracker.message_count + 1;


 -- Fetch updated count
 SELECT message_count INTO current_count FROM public.personality_message_tracker
 WHERE user_id = uid;


 IF current_count >= 30 THEN
   -- Reset count
   UPDATE public.personality_message_tracker SET message_count = 0 WHERE user_id = uid;


   -- Notify n8n
   payload := json_build_object(
     'user_id', uid,
     'session_id', NEW.session_id
   );


   PERFORM net.http_post(
     'https://referrizer.app.n8n.cloud/webhook/personality_analysis',
     payload::jsonb,
     '{}'::jsonb,
     json_build_object('Content-Type', 'application/json')::jsonb
   );
 END IF;


 RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_personality_analysis_threshold"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_unclaimed_businesses"("search" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  total INT;
BEGIN
  SELECT COUNT(*)
  INTO total
  FROM public.businesses b
  WHERE
    b.is_claimed IS DISTINCT FROM TRUE
    AND (
      search IS NULL
      OR search = ''
      OR b.business_name ILIKE '%' || search || '%'
      OR b.address ILIKE '%' || search || '%'
    );

  RETURN total;
END;
$$;


ALTER FUNCTION "public"."count_unclaimed_businesses"("search" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_public_user"("uid" "uuid", "uemail" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
    new_referral_code VARCHAR(50);
    attempts INTEGER := 0;
    max_attempts INTEGER := 10;
BEGIN
    -- Skip if already exists
    IF EXISTS (SELECT 1 FROM public.users WHERE id = uid) THEN
        RETURN;
    END IF;

    -- Generate unique referral code
    LOOP
        new_referral_code := UPPER(SUBSTRING(MD5(RANDOM()::TEXT || CLOCK_TIMESTAMP()::TEXT) FROM 1 FOR 8));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.users WHERE referral_code = new_referral_code);
        attempts := attempts + 1;
        IF attempts >= max_attempts THEN
            RAISE EXCEPTION 'REFERRAL_CODE_GENERATION_FAILED after % attempts', max_attempts;
        END IF;
    END LOOP;

    -- Insert into public.users
    INSERT INTO public.users (
        id,
        email,
        referral_code,
        created_at,
        updated_at,
        subscription_id,
        credits
    ) VALUES (
        uid,
        uemail,
        new_referral_code,
        NOW(),
        NOW(),
        NULL,
        0
    );
END;
$$;


ALTER FUNCTION "public"."create_public_user"("uid" "uuid", "uemail" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_credits"() RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT credits FROM users WHERE id = (SELECT auth.uid());
$$;


ALTER FUNCTION "public"."current_user_credits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT is_admin FROM users WHERE id = (SELECT auth.uid());
$$;


ALTER FUNCTION "public"."current_user_is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_user_owned_business_ids"() RETURNS SETOF character varying
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
  SELECT id FROM public.businesses WHERE owner_id = (SELECT auth.uid());
$$;


ALTER FUNCTION "public"."current_user_owned_business_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deduct_credits_for_audit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
    user_credits INTEGER;
    audit_cost INTEGER;
BEGIN
    -- Define credit costs for different audit types
    CASE NEW.audit_type
        WHEN 'lead_generation' THEN audit_cost := 20;
        WHEN 'lead_conversion' THEN audit_cost := 30;
        WHEN 'customer_retention' THEN audit_cost := 30;
        WHEN 'employee_retention' THEN audit_cost := 25;
        WHEN 'full' THEN audit_cost := 100;
        ELSE 
            RAISE EXCEPTION 'INVALID_AUDIT_TYPE: Unknown audit type %', NEW.audit_type;
    END CASE;
    
    -- Get current user credits with row lock to prevent race conditions
    SELECT credits INTO user_credits
    FROM public.users
    WHERE id = NEW.requested_by
    FOR UPDATE;
    
    IF user_credits IS NULL THEN
        RAISE EXCEPTION 'USER_NOT_FOUND: User % not found', NEW.requested_by;
    END IF;
    
    -- Check if user has enough credits
    IF user_credits < audit_cost THEN
        RAISE EXCEPTION 'INSUFFICIENT_CREDITS: Required % credits for % audit, but user has only % credits', 
            audit_cost, NEW.audit_type, user_credits;
    END IF;
    
    -- Deduct credits
    UPDATE public.users
    SET credits = credits - audit_cost
    WHERE id = NEW.requested_by;
    
    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        -- Re-raise with context
        RAISE EXCEPTION 'CREDIT_DEDUCTION_ERROR: % (User: %, Audit Type: %)', SQLERRM, NEW.requested_by, NEW.audit_type;
END;
$$;


ALTER FUNCTION "public"."deduct_credits_for_audit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_chat_session"("_user_id" "uuid") RETURNS TABLE("session_id" "uuid", "newly_created" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  inserted_id UUID;
BEGIN
  -- Try insert (skip if conflict)
  INSERT INTO public.chat_sessions (user_id)
  VALUES (_user_id)
  ON CONFLICT (user_id) DO NOTHING
  RETURNING id INTO inserted_id;

  IF inserted_id IS NOT NULL THEN
    -- Insert succeeded
    RETURN QUERY SELECT inserted_id, TRUE;
  ELSE
    -- Fetch existing session
    RETURN QUERY
    SELECT id, FALSE
    FROM public.chat_sessions
    WHERE user_id = _user_id;
  END IF;
END;
$$;


ALTER FUNCTION "public"."get_or_create_chat_session"("_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_unclaimed_businesses"("search" "text" DEFAULT NULL::"text", "page_size" integer DEFAULT 50, "page_offset" integer DEFAULT 0) RETURNS TABLE("id" character varying, "business_name" character varying, "address" "text", "website" character varying, "is_claimed" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    b.id,
    b.business_name,
    b.address,
    b.website,
    b.is_claimed
  FROM public.businesses b
  WHERE
    -- Unclaimed includes NULL and FALSE, excludes TRUE
    b.is_claimed IS DISTINCT FROM TRUE
    AND (
      search IS NULL
      OR search = ''
      OR b.business_name ILIKE '%' || search || '%'
      OR b.address ILIKE '%' || search || '%'
    )
  ORDER BY b.business_name
  LIMIT page_size
  OFFSET page_offset;
END;
$$;


ALTER FUNCTION "public"."get_unclaimed_businesses"("search" "text", "page_size" integer, "page_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_email_verification"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    IF NEW.email_confirmed_at IS NOT NULL AND OLD.email_confirmed_at IS NULL THEN
        PERFORM create_public_user(NEW.id, NEW.email);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_email_verification"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
    IF NEW.email_confirmed_at IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM create_public_user(NEW.id, NEW.email);
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_subscription_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
    new_plan_credits INTEGER;
    old_plan_credits INTEGER := 0;
    credit_adjustment INTEGER;
    user_current_credits INTEGER;
    old_subscription RECORD;
BEGIN
    -- Handle new subscription or reactivation
    IF NEW.status = 'active' AND (OLD IS NULL OR OLD.status != 'active') THEN
        
        -- Get credits from the new subscription plan
        SELECT credits_per_month INTO new_plan_credits
        FROM public.subscription_plans
        WHERE id = NEW.plan_id;
        
        IF new_plan_credits IS NULL THEN
            RAISE EXCEPTION 'INVALID_PLAN: Subscription plan % not found', NEW.plan_id;
        END IF;
        
        -- Check if user is upgrading from an existing plan
        SELECT s.*, sp.credits_per_month 
        INTO old_subscription
        FROM public.subscriptions s
        JOIN public.subscription_plans sp ON sp.id = s.plan_id
        WHERE s.user_id = NEW.user_id 
        AND s.status = 'active'
        AND s.id != NEW.id;
        
        IF old_subscription.id IS NOT NULL THEN
            -- This is an upgrade/downgrade scenario
            old_plan_credits := old_subscription.credits_per_month;
            credit_adjustment := new_plan_credits - old_plan_credits;
            
            -- Deactivate the old subscription
            UPDATE public.subscriptions
            SET status = 'cancelled'
            WHERE id = old_subscription.id;
        ELSE
            -- New subscription
            credit_adjustment := new_plan_credits;
        END IF;
        
        -- Get current user credits
        SELECT credits INTO user_current_credits
        FROM public.users
        WHERE id = NEW.user_id;
        
        -- Ensure credits don't go negative
        IF user_current_credits + credit_adjustment < 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_CREDITS_FOR_DOWNGRADE: Downgrade would result in negative credits. Current: %, Adjustment: %', 
                user_current_credits, credit_adjustment;
        END IF;
        
        -- Update user with new subscription and adjust credits
        UPDATE public.users
        SET 
            subscription_id = NEW.id,
            credits = credits + credit_adjustment
        WHERE id = NEW.user_id;
        
    -- Handle subscription cancellation or expiration
    ELSIF NEW.status IN ('cancelled', 'expired') AND OLD.status = 'active' THEN
        -- Remove subscription reference from user
        UPDATE public.users
        SET subscription_id = NULL
        WHERE id = NEW.user_id AND subscription_id = NEW.id;
    END IF;
    
    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'SUBSCRIPTION_CHANGE_ERROR: % (User: %, Plan: %)', SQLERRM, NEW.user_id, NEW.plan_id;
END;
$$;


ALTER FUNCTION "public"."handle_subscription_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_chat_message"("_session_id" "uuid", "_role" "public"."role_type", "_message" "text", "_token_count" integer) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  msg_id UUID;
BEGIN
  INSERT INTO public.chat_messages (
    session_id,
    role,
    message,
    token_count
  ) VALUES (
    _session_id,
    _role,
    _message,
    _token_count
  )
  RETURNING id INTO msg_id;

  RETURN msg_id;
END;
$$;


ALTER FUNCTION "public"."insert_chat_message"("_session_id" "uuid", "_role" "public"."role_type", "_message" "text", "_token_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_new_audit_to_n8n"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
  payload json;
begin
  payload := json_build_object(
    'event', 'NEW_AUDIT',
    'data', row_to_json(NEW)
  );

  perform net.http_post(
    'https://referrizer.app.n8n.cloud/webhook/new_audit',
    payload::jsonb,
    '{}'::jsonb,
    json_build_object(
      'Content-Type', 'application/json',
         'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ2Y2ltdXF3cW1zZ2JyeWJpb2dnIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MTM2MjYyMywiZXhwIjoyMDY2OTM4NjIzfQ.5wD3PWslfewxTO8hawLlAPExafgmJK8RS7-2ZxYpXsU'
  
    )::jsonb
  );

  return NEW;
end;
$$;


ALTER FUNCTION "public"."notify_new_audit_to_n8n"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_new_user_message"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
  payload json;
  _user_id uuid;
begin
  if new.role = 'user' then
    -- Fetch the user_id from the associated chat session
    select cs.user_id into _user_id
    from chat_sessions cs
    where cs.id = new.session_id;

    -- Safety check in case no matching session is found
    if _user_id is null then
      raise exception 'User ID not found for session_id %', new.session_id;
    end if;

    -- Build the JSON payload including user_id
    payload := json_build_object(
      'session_id', new.session_id,
      'message', new.message,
      'user_id', _user_id
    );

    -- Send the payload to the webhook
    perform net.http_post(
      'https://referrizer.app.n8n.cloud/webhook/new_user_message',
      payload::jsonb,
      '{}'::jsonb,
      json_build_object('Content-Type', 'application/json')::jsonb
    );
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."notify_new_user_message"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_referral_code"("new_user_id" "uuid", "used_referral_code" character varying) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
    referrer_record RECORD;
    referral_reward INTEGER := 50; -- Credits for both referrer and referred
    new_user_email VARCHAR(255);
BEGIN
    -- Validate inputs
    IF new_user_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_USER_ID: User ID cannot be null';
    END IF;
    
    IF used_referral_code IS NULL OR TRIM(used_referral_code) = '' THEN
        RAISE EXCEPTION 'INVALID_REFERRAL_CODE: Referral code cannot be empty';
    END IF;
    
    -- Get new user's email
    SELECT email INTO new_user_email
    FROM public.users
    WHERE id = new_user_id;
    
    IF new_user_email IS NULL THEN
        RAISE EXCEPTION 'USER_NOT_FOUND: User with ID % not found', new_user_id;
    END IF;
    
    -- Find the user who owns this referral code
    SELECT id, email INTO referrer_record
    FROM public.users
    WHERE UPPER(referral_code) = UPPER(used_referral_code);
    
    IF referrer_record.id IS NULL THEN
        RAISE EXCEPTION 'REFERRAL_CODE_NOT_FOUND: Referral code % does not exist', used_referral_code;
    END IF;
    
    -- Prevent self-referral
    IF referrer_record.id = new_user_id THEN
        RAISE EXCEPTION 'SELF_REFERRAL_NOT_ALLOWED: Users cannot refer themselves';
    END IF;
    
    -- Check if this user was already referred
    IF EXISTS (SELECT 1 FROM public.users WHERE id = new_user_id AND referred_by IS NOT NULL) THEN
        RAISE EXCEPTION 'ALREADY_REFERRED: User has already been referred';
    END IF;
    
    -- Update the new user's referred_by field
    UPDATE public.users
    SET referred_by = referrer_record.id
    WHERE id = new_user_id;
    
    -- Award credits to both users
    UPDATE public.users
    SET credits = credits + referral_reward
    WHERE id IN (referrer_record.id, new_user_id);
    
    -- Create referral record
    INSERT INTO public.referrals (
        referrer_id,
        referred_email,
        referred_user_id,
        referral_code,
        status,
        completed_at,
        reward_credits
    ) VALUES (
        referrer_record.id,
        new_user_email,
        new_user_id,
        used_referral_code,
        'completed',
        NOW(),
        referral_reward
    );
    
EXCEPTION
    WHEN OTHERS THEN
        -- Re-raise with context
        RAISE EXCEPTION 'REFERRAL_PROCESSING_ERROR: % (Code: %)', SQLERRM, used_referral_code;
END;
$$;


ALTER FUNCTION "public"."process_referral_code"("new_user_id" "uuid", "used_referral_code" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_started_and_completed_timestamps"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog'
    AS $$
BEGIN
  IF NEW.status IN ('started', 'running') AND OLD.status IS DISTINCT FROM NEW.status THEN
    NEW.started_at := NOW();
  END IF;

  IF NEW.status IN ('success', 'failed') AND OLD.status = 'running' THEN
    NEW.completed_at := NOW();
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_started_and_completed_timestamps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_subscription_end_date"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog'
    AS $$
declare
  billing varchar;
begin
  -- Get billing_type from the plan
  select billing_type into billing
  from public.subscription_plans
  where id = NEW.plan_id;

  -- Set end_date based on billing_type
  if billing = 'monthly' then
    NEW.end_date := NEW.start_date + interval '1 month';
  elsif billing = 'yearly' then
    NEW.end_date := NEW.start_date + interval '1 year';
  else
    raise exception 'Unsupported billing_type: %', billing;
  end if;

  -- Set grace_period_ends
  NEW.grace_period_ends := NEW.end_date + interval '7 days';

  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_subscription_end_date"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_user_id_from_metadata"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  extracted_user_id uuid;
BEGIN
  IF NEW.metadata ? 'user_id' THEN
    BEGIN
      extracted_user_id := (NEW.metadata->>'user_id')::uuid;
      NEW.user_id := extracted_user_id;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Invalid user_id in metadata: %', NEW.metadata->>'user_id';
    END;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_user_id_from_metadata"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_business_audit_reference"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog'
    AS $$
BEGIN
    -- Update business with latest audit reference
    UPDATE public.businesses
    SET 
        current_audit_id = NEW.id,
        last_audited_at = NEW.created_at
    WHERE id = NEW.business_id;
    
    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'BUSINESS_AUDIT_UPDATE_ERROR: % (Business: %, Audit: %)', SQLERRM, NEW.business_id, NEW.id;
END;
$$;


ALTER FUNCTION "public"."update_business_audit_reference"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_chat_session_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  UPDATE public.chat_sessions SET updated_at = now() WHERE id = NEW.session_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_chat_session_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_last_analyzed_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth'
    AS $$
begin
  new.last_analyzed_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."update_last_analyzed_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_personality_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'auth'
    AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_user_personality_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_business_ownership"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
    existing_business_count INTEGER;
    max_businesses INTEGER;
BEGIN
    -- Only validate when claiming a business (owner_id being set)
    IF NEW.owner_id IS NOT NULL AND (OLD.owner_id IS NULL OR OLD.owner_id != NEW.owner_id) THEN
        
        -- Get user's subscription plan limits
        SELECT sp.max_businesses INTO max_businesses
        FROM public.users u
        LEFT JOIN public.subscriptions s ON s.id = u.subscription_id
        LEFT JOIN public.subscription_plans sp ON sp.id = s.plan_id
        WHERE u.id = NEW.owner_id
        AND s.status = 'active';
        
        -- Default to 1 business for free users
        max_businesses := COALESCE(max_businesses, 1);
        
        -- Count existing businesses owned by this user
        SELECT COUNT(*) INTO existing_business_count
        FROM public.businesses
        WHERE owner_id = NEW.owner_id
        AND id != NEW.id;
        
        -- Check if user has reached their limit
        IF existing_business_count >= max_businesses THEN
            RAISE EXCEPTION 'BUSINESS_LIMIT_REACHED: User has reached maximum business limit of % businesses. Upgrade subscription to add more.', 
                max_businesses;
        END IF;
        
        -- Set is_claimed to true when owner is assigned
        NEW.is_claimed := TRUE;
    END IF;
    
    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        -- Re-raise with context
        RAISE;
END;
$$;


ALTER FUNCTION "public"."validate_business_ownership"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_competitor_relationship"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog'
    AS $$
BEGIN
    -- Check if trying to add self as competitor
    IF NEW.business_id = NEW.competitor_id THEN
        RAISE EXCEPTION 'SELF_COMPETITOR_ERROR: A business cannot be its own competitor (Business ID: %)', NEW.business_id;
    END IF;
    
    -- Check if relationship already exists (active or inactive)
    IF EXISTS (
        SELECT 1 FROM public.business_competitors
        WHERE business_id = NEW.business_id 
        AND competitor_id = NEW.competitor_id
        AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID)
    ) THEN
        RAISE EXCEPTION 'DUPLICATE_COMPETITOR: This competitor relationship already exists (Business: %, Competitor: %)', 
            NEW.business_id, NEW.competitor_id;
    END IF;
    
    -- Check reverse relationship
    IF EXISTS (
        SELECT 1 FROM public.business_competitors
        WHERE business_id = NEW.competitor_id 
        AND competitor_id = NEW.business_id
    ) THEN
        RAISE EXCEPTION 'REVERSE_RELATIONSHIP_EXISTS: A reverse competitor relationship already exists (Business: %, Competitor: %)', 
            NEW.competitor_id, NEW.business_id;
    END IF;
    
    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        -- Re-raise with context
        RAISE;
END;
$$;


ALTER FUNCTION "public"."validate_competitor_relationship"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."audits" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "business_id" character varying(255) NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "audit_type" "public"."audit_type_enum" DEFAULT 'lead_generation'::"public"."audit_type_enum" NOT NULL,
    "status" "public"."audit_status" DEFAULT 'pending'::"public"."audit_status" NOT NULL,
    "overall_score" integer,
    "lead_generation_score" integer,
    "lead_conversion_score" integer,
    "customer_retention_score" integer,
    "employee_retention_score" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "insights" "jsonb" DEFAULT '{}'::"jsonb",
    "recommendations" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "audits_customer_retention_score_check" CHECK ((("customer_retention_score" >= 0) AND ("customer_retention_score" <= 100))),
    CONSTRAINT "audits_employee_retention_score_check" CHECK ((("employee_retention_score" >= 0) AND ("employee_retention_score" <= 100))),
    CONSTRAINT "audits_lead_conversion_score_check" CHECK ((("lead_conversion_score" >= 0) AND ("lead_conversion_score" <= 100))),
    CONSTRAINT "audits_lead_generation_score_check" CHECK ((("lead_generation_score" >= 0) AND ("lead_generation_score" <= 100))),
    CONSTRAINT "audits_overall_score_check" CHECK ((("overall_score" >= 0) AND ("overall_score" <= 100)))
);


ALTER TABLE "public"."audits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."business_competitors" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "business_id" character varying(255) NOT NULL,
    "competitor_id" character varying(255) NOT NULL,
    "added_by" "uuid" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"(),
    "is_active" boolean DEFAULT true,
    CONSTRAINT "no_self_competitor" CHECK ((("business_id")::"text" <> ("competitor_id")::"text"))
);


ALTER TABLE "public"."business_competitors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."businesses" (
    "id" character varying(255) NOT NULL,
    "business_name" character varying(255) NOT NULL,
    "business_category" character varying(100),
    "website" character varying(500),
    "phone_number" character varying(255),
    "email" character varying(255),
    "address" "text",
    "latitude" numeric(10,8),
    "longitude" numeric(11,8),
    "formatted_address" "text",
    "street_number" character varying(255),
    "street_name" character varying(255),
    "city" character varying(100),
    "state_province" character varying(100),
    "postal_code" character varying(20),
    "country" character varying(100),
    "country_code" character varying(2),
    "plus_code" character varying(255),
    "timezone" character varying(255),
    "location_metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "google_maps_url" character varying(500),
    "facebook_handle" character varying(255),
    "instagram_handle" character varying(255),
    "linkedin_handle" character varying(255),
    "twitter_handle" character varying(255),
    "youtube_channel" character varying(255),
    "owner_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "current_audit_id" "uuid",
    "last_audited_at" timestamp with time zone,
    "is_claimed" boolean GENERATED ALWAYS AS (("owner_id" IS NOT NULL)) STORED,
    "logo" character varying
);


ALTER TABLE "public"."businesses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."call_report_evaluations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "report_id" "uuid" NOT NULL,
    "question" "text",
    "answer" "text",
    "evaluation" "text" NOT NULL
);


ALTER TABLE "public"."call_report_evaluations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."call_transcripts" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "transcript" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "call_id" "uuid"
);


ALTER TABLE "public"."call_transcripts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."calls" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "direction" "public"."call_direction" NOT NULL,
    "call_sid" character varying(255),
    "business_id" character varying(255) NOT NULL,
    "report_id" "uuid",
    "task_group_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "call_initiate_time" timestamp with time zone,
    "call_accepted_time" timestamp with time zone,
    "to_number" character varying(50),
    "from_number" character varying(50),
    "summary" "text",
    "agent_id" character varying(100),
    "cost" "jsonb" DEFAULT '{}'::"jsonb",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "conv_id" character varying(255),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "call_duration" integer,
    "interruptions" integer,
    "termination_reason" "text"
);


ALTER TABLE "public"."calls" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_archived_summaries" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "metadata" "jsonb",
    "content" "text",
    "embedding" "public"."vector"(3072)
);


ALTER TABLE "public"."chat_archived_summaries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_messages" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "role" "public"."role_type" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "token_count" integer,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);

ALTER TABLE ONLY "public"."chat_messages" REPLICA IDENTITY FULL;


ALTER TABLE "public"."chat_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_sessions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."chat_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."competitor_comparisons" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "audit_id" "uuid" NOT NULL,
    "business_id" character varying(255) NOT NULL,
    "competitor_id" character varying(255) NOT NULL,
    "comparison_metrics" "jsonb" DEFAULT '{}'::"jsonb",
    "business_advantages" "jsonb" DEFAULT '{}'::"jsonb",
    "competitor_advantages" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."competitor_comparisons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."generated_call_reports" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "business_id" character varying(255) NOT NULL,
    "audit_id" "uuid" NOT NULL,
    "task_group_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "overall_summary" "text",
    "engagement_level" "text",
    "professionalism" "text",
    "script_adherence" "text",
    "issues_detected" "jsonb" DEFAULT '{}'::"jsonb",
    "positive_highlight" "jsonb" DEFAULT '{}'::"jsonb",
    "improvement_ideas" "jsonb" DEFAULT '[]'::"jsonb",
    "agent_name" "text",
    "engagement_and_relationship_building_score" integer,
    "product_service_knowledge_and_education_score" integer,
    "answering_questions_score" integer,
    "ability_to_upsell_and_cross_sell_score" integer,
    "closing_for_appointment_and_call_to_action_score" integer,
    "overall_success_rate_out_of_100" integer,
    "appointment_booked" boolean,
    "initial_wait_time" "text",
    "on_hold_time" "text",
    "representative_tone" "text",
    "tone_consistency" "text",
    "clarity" "text",
    "accuracy" "text",
    "helpfulness" "text",
    "call_opening" "text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."generated_call_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."micro_tasks" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "task_group_id" "uuid" NOT NULL,
    "task_type" "text" NOT NULL,
    "status" "public"."micro_task_status" DEFAULT 'pending'::"public"."micro_task_status" NOT NULL,
    "n8n_workflow_id" "text",
    "n8n_execution_id" "text",
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "retry_count" integer DEFAULT 0 NOT NULL,
    "result_data" "jsonb" DEFAULT '{}'::"jsonb",
    "error_message" "text",
    "error_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."micro_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."personality_analysis_log" (
    "user_id" "uuid" NOT NULL,
    "last_analyzed_at" timestamp with time zone DEFAULT "now"(),
    "total_messages_analyzed" integer DEFAULT 0
);


ALTER TABLE "public"."personality_analysis_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."personality_message_tracker" (
    "user_id" "uuid" NOT NULL,
    "message_count" integer DEFAULT 0
);


ALTER TABLE "public"."personality_message_tracker" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."referrals" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "referrer_id" "uuid" NOT NULL,
    "referred_email" character varying(255) NOT NULL,
    "referred_user_id" "uuid",
    "referral_code" character varying(50) NOT NULL,
    "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    "completed_at" timestamp with time zone,
    "reward_credits" integer DEFAULT 0,
    CONSTRAINT "referrals_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'completed'::character varying])::"text"[])))
);


ALTER TABLE "public"."referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_plans" (
    "id" character varying(50) NOT NULL,
    "name" character varying(255) NOT NULL,
    "credits_per_month" integer NOT NULL,
    "max_businesses" integer NOT NULL,
    "features" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "billing_type" character varying(10) NOT NULL,
    "price" numeric(10,2) NOT NULL,
    CONSTRAINT "subscription_plans_billing_type_check" CHECK ((("billing_type")::"text" = ANY ((ARRAY['monthly'::character varying, 'yearly'::character varying])::"text"[])))
);


ALTER TABLE "public"."subscription_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscriptions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "plan_id" character varying(50) NOT NULL,
    "status" character varying(20) NOT NULL,
    "start_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "end_date" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "payment_method_sub_id" character varying(255),
    "grace_period_ends" timestamp with time zone NOT NULL,
    "payment_failures" integer DEFAULT 0,
    "cancellation_reason" character varying(100),
    CONSTRAINT "subscriptions_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['active'::character varying, 'cancelled'::character varying, 'expired'::character varying, 'pending'::character varying])::"text"[])))
);


ALTER TABLE "public"."subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."task_groups" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "audit_id" "uuid" NOT NULL,
    "business_id" "text" NOT NULL,
    "task_name" "text" NOT NULL,
    "status" "public"."task_group_status" DEFAULT 'pending'::"public"."task_group_status" NOT NULL,
    "n8n_workflow_id" "text",
    "n8n_execution_id" "text",
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "result_data" "jsonb" DEFAULT '{}'::"jsonb",
    "error_message" "text",
    "scheduled_at" timestamp with time zone
);


ALTER TABLE "public"."task_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_personality" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "communication_style" "text",
    "response_length" "text",
    "tone_preference" "text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "source" "public"."personality_source_type" DEFAULT 'onboarding'::"public"."personality_source_type",
    "confidence_score" double precision DEFAULT 1.0,
    "detailed_personality_summary" "text",
    CONSTRAINT "chk_confidence_score_range" CHECK ((("confidence_score" >= (0.0)::double precision) AND ("confidence_score" <= (1.0)::double precision)))
);


ALTER TABLE "public"."user_personality" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "email" character varying(255) NOT NULL,
    "display_name" character varying(255),
    "phone_number" character varying(50),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "subscription_id" "uuid",
    "referral_code" character varying(50) DEFAULT "upper"(SUBSTRING("md5"(("random"())::"text") FROM 1 FOR 8)),
    "referred_by" "uuid",
    "credits" integer DEFAULT 0,
    "is_deleted" boolean DEFAULT false,
    "deleted_at" timestamp with time zone,
    "is_admin" boolean DEFAULT false NOT NULL,
    "profile_photo" character varying,
    CONSTRAINT "users_credits_check" CHECK (("credits" >= 0)),
    CONSTRAINT "valid_email" CHECK ((("email")::"text" ~* '^.+@.+\..+$'::"text"))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


ALTER TABLE ONLY "public"."audits"
    ADD CONSTRAINT "audits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_competitors"
    ADD CONSTRAINT "business_competitors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."call_report_evaluations"
    ADD CONSTRAINT "call_report_evaluations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."call_transcripts"
    ADD CONSTRAINT "call_transcripts_call_id_key" UNIQUE ("call_id");



ALTER TABLE ONLY "public"."call_transcripts"
    ADD CONSTRAINT "call_transcripts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_archived_summaries"
    ADD CONSTRAINT "chat_archived_summaries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_sessions"
    ADD CONSTRAINT "chat_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."competitor_comparisons"
    ADD CONSTRAINT "competitor_comparisons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."generated_call_reports"
    ADD CONSTRAINT "generated_call_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."micro_tasks"
    ADD CONSTRAINT "micro_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "one_active_subscription_per_user" EXCLUDE USING "btree" ("user_id" WITH =) WHERE ((("status")::"text" = 'active'::"text"));



ALTER TABLE ONLY "public"."personality_analysis_log"
    ADD CONSTRAINT "personality_analysis_log_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."personality_message_tracker"
    ADD CONSTRAINT "personality_message_tracker_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscription_plans"
    ADD CONSTRAINT "subscription_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."task_groups"
    ADD CONSTRAINT "task_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."business_competitors"
    ADD CONSTRAINT "unique_competitor_pair" UNIQUE ("business_id", "competitor_id");



ALTER TABLE ONLY "public"."subscription_plans"
    ADD CONSTRAINT "unique_plan_per_type" UNIQUE ("name", "billing_type");



ALTER TABLE ONLY "public"."user_personality"
    ADD CONSTRAINT "user_personality_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_personality"
    ADD CONSTRAINT "user_personality_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_referral_code_key" UNIQUE ("referral_code");



CREATE INDEX "idx_archived_summaries_created_at" ON "public"."chat_archived_summaries" USING "btree" ("created_at");



CREATE INDEX "idx_archived_summaries_user_id" ON "public"."chat_archived_summaries" USING "btree" ("user_id");



CREATE INDEX "idx_audits_business_id" ON "public"."audits" USING "btree" ("business_id");



CREATE INDEX "idx_audits_created_at" ON "public"."audits" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_audits_requested_by" ON "public"."audits" USING "btree" ("requested_by");



CREATE INDEX "idx_audits_status" ON "public"."audits" USING "btree" ("status");



CREATE INDEX "idx_business_competitors_added_by" ON "public"."business_competitors" USING "btree" ("added_by");



CREATE INDEX "idx_business_competitors_business_id" ON "public"."business_competitors" USING "btree" ("business_id");



CREATE INDEX "idx_business_competitors_competitor_id" ON "public"."business_competitors" USING "btree" ("competitor_id");



CREATE INDEX "idx_businesses_current_audit_id" ON "public"."businesses" USING "btree" ("current_audit_id");



CREATE INDEX "idx_businesses_email" ON "public"."businesses" USING "btree" ("email");



CREATE INDEX "idx_businesses_owner_id" ON "public"."businesses" USING "btree" ("owner_id");



CREATE INDEX "idx_businesses_phone_number" ON "public"."businesses" USING "btree" ("phone_number");



CREATE INDEX "idx_call_report_evaluations_report_id" ON "public"."call_report_evaluations" USING "btree" ("report_id");



CREATE INDEX "idx_call_transcripts_call_id" ON "public"."call_transcripts" USING "btree" ("call_id");



CREATE INDEX "idx_calls_business_id" ON "public"."calls" USING "btree" ("business_id");



CREATE INDEX "idx_calls_conv_id" ON "public"."calls" USING "btree" ("conv_id");



CREATE UNIQUE INDEX "idx_calls_conv_id_unique" ON "public"."calls" USING "btree" ("conv_id");



CREATE INDEX "idx_calls_report_id" ON "public"."calls" USING "btree" ("report_id");



CREATE INDEX "idx_calls_task_group_id" ON "public"."calls" USING "btree" ("task_group_id");



CREATE INDEX "idx_chat_archived_summaries_user_created_at" ON "public"."chat_archived_summaries" USING "btree" ("user_id", "created_at");



CREATE INDEX "idx_chat_messages_created_at" ON "public"."chat_messages" USING "btree" ("created_at");



CREATE INDEX "idx_chat_messages_session_created_at" ON "public"."chat_messages" USING "btree" ("session_id", "created_at");



CREATE INDEX "idx_chat_messages_session_id" ON "public"."chat_messages" USING "btree" ("session_id");



CREATE INDEX "idx_competitor_comparisons_audit_id" ON "public"."competitor_comparisons" USING "btree" ("audit_id");



CREATE INDEX "idx_competitor_comparisons_business_id" ON "public"."competitor_comparisons" USING "btree" ("business_id");



CREATE INDEX "idx_competitor_comparisons_competitor_id" ON "public"."competitor_comparisons" USING "btree" ("competitor_id");



CREATE INDEX "idx_generated_call_reports_agent_task_id" ON "public"."generated_call_reports" USING "btree" ("task_group_id");



CREATE INDEX "idx_generated_call_reports_audit_id" ON "public"."generated_call_reports" USING "btree" ("audit_id");



CREATE INDEX "idx_generated_call_reports_business_id" ON "public"."generated_call_reports" USING "btree" ("business_id");



CREATE INDEX "idx_micro_tasks_status" ON "public"."micro_tasks" USING "btree" ("status");



CREATE INDEX "idx_micro_tasks_task_group_id" ON "public"."micro_tasks" USING "btree" ("task_group_id");



CREATE INDEX "idx_referrals_referral_code" ON "public"."referrals" USING "btree" ("referral_code");



CREATE INDEX "idx_referrals_referred_user_id" ON "public"."referrals" USING "btree" ("referred_user_id");



CREATE INDEX "idx_referrals_referrer_id" ON "public"."referrals" USING "btree" ("referrer_id");



CREATE INDEX "idx_referrals_status" ON "public"."referrals" USING "btree" ("status");



CREATE INDEX "idx_subscription_plans_name" ON "public"."subscription_plans" USING "btree" ("name");



CREATE INDEX "idx_subscriptions_plan_id" ON "public"."subscriptions" USING "btree" ("plan_id");



CREATE INDEX "idx_subscriptions_status" ON "public"."subscriptions" USING "btree" ("status");



CREATE INDEX "idx_subscriptions_user_id" ON "public"."subscriptions" USING "btree" ("user_id");



CREATE INDEX "idx_task_groups_audit_id" ON "public"."task_groups" USING "btree" ("audit_id");



CREATE INDEX "idx_task_groups_scheduled_at" ON "public"."task_groups" USING "btree" ("scheduled_at");



CREATE INDEX "idx_task_groups_status" ON "public"."task_groups" USING "btree" ("status");



CREATE UNIQUE INDEX "idx_unique_chat_session_user" ON "public"."chat_sessions" USING "btree" ("user_id");



CREATE INDEX "idx_user_personality_user_id" ON "public"."user_personality" USING "btree" ("user_id");



CREATE INDEX "idx_users_email" ON "public"."users" USING "btree" ("email");



CREATE INDEX "idx_users_referral_code" ON "public"."users" USING "btree" ("referral_code");



CREATE INDEX "idx_users_referred_by" ON "public"."users" USING "btree" ("referred_by");



CREATE INDEX "idx_users_subscription_id" ON "public"."users" USING "btree" ("subscription_id");



CREATE UNIQUE INDEX "unique_micro_task_type_per_group" ON "public"."micro_tasks" USING "btree" ("task_group_id", "task_type");



CREATE UNIQUE INDEX "unique_task_group_per_audit_name" ON "public"."task_groups" USING "btree" ("audit_id", "task_name");



CREATE OR REPLACE TRIGGER "deduct_credits_on_audit_create" BEFORE INSERT ON "public"."audits" FOR EACH ROW EXECUTE FUNCTION "public"."deduct_credits_for_audit"();



CREATE OR REPLACE TRIGGER "notify_new_audit_to_n8n" AFTER INSERT ON "public"."audits" FOR EACH ROW EXECUTE FUNCTION "public"."notify_new_audit_to_n8n"();



CREATE OR REPLACE TRIGGER "on_subscription_change" AFTER INSERT OR UPDATE OF "status" ON "public"."subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."handle_subscription_change"();



CREATE OR REPLACE TRIGGER "set_end_date_on_insert" BEFORE INSERT ON "public"."subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."set_subscription_end_date"();



CREATE OR REPLACE TRIGGER "set_user_id_from_metadata" BEFORE INSERT ON "public"."chat_archived_summaries" FOR EACH ROW EXECUTE FUNCTION "public"."sync_user_id_from_metadata"();



CREATE OR REPLACE TRIGGER "trg_check_personality_threshold" AFTER INSERT ON "public"."chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."check_personality_analysis_threshold"();



CREATE OR REPLACE TRIGGER "trg_notify_user_message" AFTER INSERT ON "public"."chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."notify_new_user_message"();



CREATE OR REPLACE TRIGGER "trg_set_last_analyzed_at" BEFORE INSERT OR UPDATE ON "public"."personality_analysis_log" FOR EACH ROW EXECUTE FUNCTION "public"."update_last_analyzed_at"();



CREATE OR REPLACE TRIGGER "trg_set_updated_at_user_personality" BEFORE INSERT OR UPDATE ON "public"."user_personality" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_personality_timestamp"();



CREATE OR REPLACE TRIGGER "trg_update_micro_task_ts" BEFORE UPDATE ON "public"."micro_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trg_update_session_timestamp" AFTER INSERT ON "public"."chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."update_chat_session_timestamp"();



CREATE OR REPLACE TRIGGER "trg_update_task_group_ts" BEFORE UPDATE ON "public"."task_groups" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trigger_check_summary_threshold" AFTER INSERT ON "public"."chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."check_and_summarize_if_threshold_met"();



CREATE OR REPLACE TRIGGER "update_audits_updated_at" BEFORE UPDATE ON "public"."audits" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_business_competitors_updated_at" BEFORE UPDATE ON "public"."business_competitors" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_business_on_audit_create" AFTER INSERT ON "public"."audits" FOR EACH ROW EXECUTE FUNCTION "public"."update_business_audit_reference"();



CREATE OR REPLACE TRIGGER "update_businesses_updated_at" BEFORE UPDATE ON "public"."businesses" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_calls_updated_at" BEFORE UPDATE ON "public"."calls" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_competitor_comparisons_updated_at" BEFORE UPDATE ON "public"."competitor_comparisons" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_generated_call_reports_updated_at" BEFORE UPDATE ON "public"."generated_call_reports" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_referrals_updated_at" BEFORE UPDATE ON "public"."referrals" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_subscriptions_updated_at" BEFORE UPDATE ON "public"."subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_users_updated_at" BEFORE UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "validate_business_before_claim" BEFORE UPDATE OF "owner_id" ON "public"."businesses" FOR EACH ROW EXECUTE FUNCTION "public"."validate_business_ownership"();



CREATE OR REPLACE TRIGGER "validate_competitor_before_insert" BEFORE INSERT ON "public"."business_competitors" FOR EACH ROW EXECUTE FUNCTION "public"."validate_competitor_relationship"();



ALTER TABLE ONLY "public"."audits"
    ADD CONSTRAINT "audits_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."audits"
    ADD CONSTRAINT "audits_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."business_competitors"
    ADD CONSTRAINT "business_competitors_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."business_competitors"
    ADD CONSTRAINT "business_competitors_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."business_competitors"
    ADD CONSTRAINT "business_competitors_competitor_id_fkey" FOREIGN KEY ("competitor_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."call_report_evaluations"
    ADD CONSTRAINT "call_report_evaluations_report_id_fkey" FOREIGN KEY ("report_id") REFERENCES "public"."generated_call_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."call_transcripts"
    ADD CONSTRAINT "call_transcripts_call_id_fkey" FOREIGN KEY ("call_id") REFERENCES "public"."calls"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "calls_task_group_id_fkey" FOREIGN KEY ("task_group_id") REFERENCES "public"."task_groups"("id");



ALTER TABLE ONLY "public"."chat_archived_summaries"
    ADD CONSTRAINT "chat_archived_summaries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."chat_sessions"("id");



ALTER TABLE ONLY "public"."chat_sessions"
    ADD CONSTRAINT "chat_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."competitor_comparisons"
    ADD CONSTRAINT "competitor_comparisons_audit_id_fkey" FOREIGN KEY ("audit_id") REFERENCES "public"."audits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."competitor_comparisons"
    ADD CONSTRAINT "competitor_comparisons_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."competitor_comparisons"
    ADD CONSTRAINT "competitor_comparisons_competitor_id_fkey" FOREIGN KEY ("competitor_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "fk_businesses_current_audit" FOREIGN KEY ("current_audit_id") REFERENCES "public"."audits"("id");



ALTER TABLE ONLY "public"."calls"
    ADD CONSTRAINT "fk_calls_report" FOREIGN KEY ("report_id") REFERENCES "public"."generated_call_reports"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "fk_users_subscription" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id");



ALTER TABLE ONLY "public"."generated_call_reports"
    ADD CONSTRAINT "generated_call_reports_audit_id_fkey" FOREIGN KEY ("audit_id") REFERENCES "public"."audits"("id");



ALTER TABLE ONLY "public"."generated_call_reports"
    ADD CONSTRAINT "generated_call_reports_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."generated_call_reports"
    ADD CONSTRAINT "generated_call_reports_task_group_id_fkey" FOREIGN KEY ("task_group_id") REFERENCES "public"."task_groups"("id");



ALTER TABLE ONLY "public"."micro_tasks"
    ADD CONSTRAINT "micro_tasks_task_group_id_fkey" FOREIGN KEY ("task_group_id") REFERENCES "public"."task_groups"("id");



ALTER TABLE ONLY "public"."personality_analysis_log"
    ADD CONSTRAINT "personality_analysis_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."personality_message_tracker"
    ADD CONSTRAINT "personality_message_tracker_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_referred_user_id_fkey" FOREIGN KEY ("referred_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."referrals"
    ADD CONSTRAINT "referrals_referrer_id_fkey" FOREIGN KEY ("referrer_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."subscription_plans"("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."task_groups"
    ADD CONSTRAINT "task_groups_audit_id_fkey" FOREIGN KEY ("audit_id") REFERENCES "public"."audits"("id");



ALTER TABLE ONLY "public"."task_groups"
    ADD CONSTRAINT "task_groups_business_id_fkey" FOREIGN KEY ("business_id") REFERENCES "public"."businesses"("id");



ALTER TABLE ONLY "public"."user_personality"
    ADD CONSTRAINT "user_personality_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_referred_by_fkey" FOREIGN KEY ("referred_by") REFERENCES "public"."users"("id");



CREATE POLICY "Admins can access all chat sessions" ON "public"."chat_sessions" FOR SELECT USING ("public"."current_user_is_admin"());



CREATE POLICY "Users can access their chat session" ON "public"."chat_sessions" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can access their messages" ON "public"."chat_messages" FOR SELECT USING (("session_id" IN ( SELECT "chat_sessions"."id"
   FROM "public"."chat_sessions"
  WHERE ("chat_sessions"."user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "Users can access their personality profile" ON "public"."user_personality" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can access their summaries" ON "public"."chat_archived_summaries" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."audits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audits_insert_own_business" ON "public"."audits" FOR INSERT WITH CHECK ((("requested_by" = ( SELECT "auth"."uid"() AS "uid")) AND (("business_id")::"text" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids")) AND ("public"."current_user_credits"() > 0)));



CREATE POLICY "audits_select_own_or_admin" ON "public"."audits" FOR SELECT USING ((("requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."current_user_is_admin"()));



CREATE POLICY "audits_update_system" ON "public"."audits" FOR UPDATE USING (false);



ALTER TABLE "public"."business_competitors" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "business_competitors_delete_own" ON "public"."business_competitors" FOR DELETE USING (("added_by" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "business_competitors_insert_own" ON "public"."business_competitors" FOR INSERT WITH CHECK ((("added_by" = "auth"."uid"()) AND (("business_id")::"text" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids"))));



CREATE POLICY "business_competitors_select_own" ON "public"."business_competitors" FOR SELECT USING ((("added_by" = ( SELECT "auth"."uid"() AS "uid")) OR (("business_id")::"text" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids"))));



CREATE POLICY "business_competitors_update_own" ON "public"."business_competitors" FOR UPDATE USING (("added_by" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."businesses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "businesses_insert_own" ON "public"."businesses" FOR INSERT TO "authenticated" WITH CHECK (("owner_id" = "auth"."uid"()));



CREATE POLICY "businesses_select_own_competitors_admin" ON "public"."businesses" FOR SELECT USING ((("owner_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."business_competitors" "bc"
  WHERE (("bc"."is_active" = true) AND (("bc"."competitor_id")::"text" = ("businesses"."id")::"text") AND (("bc"."business_id")::"text" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids"))))) OR "public"."current_user_is_admin"()));



CREATE POLICY "businesses_update_own" ON "public"."businesses" FOR UPDATE TO "authenticated" USING ((("owner_id" = "auth"."uid"()) OR ("owner_id" IS NULL))) WITH CHECK ((("owner_id" = "auth"."uid"()) OR ("owner_id" IS NULL)));



ALTER TABLE "public"."call_report_evaluations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "call_report_evaluations_insert_system" ON "public"."call_report_evaluations" FOR INSERT WITH CHECK (false);



CREATE POLICY "call_report_evaluations_select_via_reports" ON "public"."call_report_evaluations" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM ("public"."generated_call_reports" "gcr"
     JOIN "public"."audits" "a" ON (("a"."id" = "gcr"."audit_id")))
  WHERE (("gcr"."id" = "call_report_evaluations"."report_id") AND ("a"."requested_by" = ( SELECT "auth"."uid"() AS "uid"))))) OR "public"."current_user_is_admin"()));



ALTER TABLE "public"."call_transcripts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "call_transcripts_insert_system" ON "public"."call_transcripts" FOR INSERT WITH CHECK (false);



ALTER TABLE "public"."calls" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "calls_insert_system" ON "public"."calls" FOR INSERT WITH CHECK (false);



CREATE POLICY "calls_select_admin_all" ON "public"."calls" FOR SELECT USING ("public"."current_user_is_admin"());



CREATE POLICY "calls_select_owned_businesses" ON "public"."calls" FOR SELECT USING ((("business_id")::"text" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids")));



CREATE POLICY "calls_update_system" ON "public"."calls" FOR UPDATE USING (false);



ALTER TABLE "public"."chat_archived_summaries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."competitor_comparisons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "competitor_comparisons_insert_system" ON "public"."competitor_comparisons" FOR INSERT WITH CHECK (false);



CREATE POLICY "competitor_comparisons_select_own_audits" ON "public"."competitor_comparisons" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."audits"
  WHERE (("audits"."id" = "competitor_comparisons"."audit_id") AND ("audits"."requested_by" = ( SELECT "auth"."uid"() AS "uid"))))) OR "public"."current_user_is_admin"()));



ALTER TABLE "public"."generated_call_reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "generated_call_reports_insert_system" ON "public"."generated_call_reports" FOR INSERT WITH CHECK (false);



CREATE POLICY "generated_call_reports_select_own_audits" ON "public"."generated_call_reports" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."audits"
  WHERE (("audits"."id" = "generated_call_reports"."audit_id") AND ("audits"."requested_by" = ( SELECT "auth"."uid"() AS "uid"))))) OR "public"."current_user_is_admin"()));



CREATE POLICY "insert_user_personality" ON "public"."user_personality" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."micro_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."personality_analysis_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."personality_message_tracker" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."referrals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "referrals_insert_own" ON "public"."referrals" FOR INSERT WITH CHECK ((("referrer_id" = ( SELECT "auth"."uid"() AS "uid")) AND (("status")::"text" = 'pending'::"text")));



CREATE POLICY "referrals_select_own" ON "public"."referrals" FOR SELECT USING ((("referrer_id" = ( SELECT "auth"."uid"() AS "uid")) OR ("referred_user_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."current_user_is_admin"()));



CREATE POLICY "referrals_update_system" ON "public"."referrals" FOR UPDATE USING (false);



ALTER TABLE "public"."subscription_plans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "subscription_plans_delete_admin" ON "public"."subscription_plans" FOR DELETE USING ("public"."current_user_is_admin"());



CREATE POLICY "subscription_plans_insert_admin" ON "public"."subscription_plans" FOR INSERT WITH CHECK ("public"."current_user_is_admin"());



CREATE POLICY "subscription_plans_select_all" ON "public"."subscription_plans" FOR SELECT USING (true);



CREATE POLICY "subscription_plans_update_admin" ON "public"."subscription_plans" FOR UPDATE USING ("public"."current_user_is_admin"());



ALTER TABLE "public"."subscriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "subscriptions_insert_system" ON "public"."subscriptions" FOR INSERT WITH CHECK (false);



CREATE POLICY "subscriptions_select_own_or_admin" ON "public"."subscriptions" FOR SELECT USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."current_user_is_admin"()));



CREATE POLICY "subscriptions_update_system" ON "public"."subscriptions" FOR UPDATE USING (false);



ALTER TABLE "public"."task_groups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "task_groups_delete_admin_only" ON "public"."task_groups" FOR DELETE USING ("public"."current_user_is_admin"());



CREATE POLICY "task_groups_insert_owned_or_admin" ON "public"."task_groups" FOR INSERT WITH CHECK (("public"."current_user_is_admin"() OR ("business_id" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids"))));



CREATE POLICY "task_groups_select_owned_or_admin" ON "public"."task_groups" FOR SELECT USING (("public"."current_user_is_admin"() OR ("business_id" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids"))));



CREATE POLICY "task_groups_update_owned_or_admin" ON "public"."task_groups" FOR UPDATE USING (("public"."current_user_is_admin"() OR ("business_id" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids")))) WITH CHECK (("public"."current_user_is_admin"() OR ("business_id" IN ( SELECT "public"."current_user_owned_business_ids"() AS "current_user_owned_business_ids"))));



ALTER TABLE "public"."user_personality" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_delete_own" ON "public"."users" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "id"));



CREATE POLICY "users_insert_self" ON "public"."users" FOR INSERT WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "id") AND ("is_admin" = false)));



CREATE POLICY "users_select_own_or_admin" ON "public"."users" FOR SELECT USING (((( SELECT "auth"."uid"() AS "uid") = "id") OR "public"."current_user_is_admin"()));



CREATE POLICY "users_update_own" ON "public"."users" FOR UPDATE USING (("id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK ((("id" = ( SELECT "auth"."uid"() AS "uid")) AND ("is_admin" = "public"."current_user_is_admin"()) AND ("credits" >= 0)));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."audits";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."chat_messages";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_and_summarize_if_threshold_met"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_and_summarize_if_threshold_met"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_and_summarize_if_threshold_met"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_personality_analysis_threshold"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_personality_analysis_threshold"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_personality_analysis_threshold"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



REVOKE ALL ON FUNCTION "public"."count_unclaimed_businesses"("search" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."count_unclaimed_businesses"("search" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."count_unclaimed_businesses"("search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_unclaimed_businesses"("search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_public_user"("uid" "uuid", "uemail" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_public_user"("uid" "uuid", "uemail" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_public_user"("uid" "uuid", "uemail" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_credits"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_credits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_credits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."current_user_owned_business_ids"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_owned_business_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_owned_business_ids"() TO "service_role";



GRANT ALL ON FUNCTION "public"."deduct_credits_for_audit"() TO "anon";
GRANT ALL ON FUNCTION "public"."deduct_credits_for_audit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."deduct_credits_for_audit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_chat_session"("_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_chat_session"("_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_chat_session"("_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_unclaimed_businesses"("search" "text", "page_size" integer, "page_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_unclaimed_businesses"("search" "text", "page_size" integer, "page_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_unclaimed_businesses"("search" "text", "page_size" integer, "page_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_unclaimed_businesses"("search" "text", "page_size" integer, "page_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_email_verification"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_email_verification"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_email_verification"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_subscription_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_subscription_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_subscription_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_chat_message"("_session_id" "uuid", "_role" "public"."role_type", "_message" "text", "_token_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."insert_chat_message"("_session_id" "uuid", "_role" "public"."role_type", "_message" "text", "_token_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_chat_message"("_session_id" "uuid", "_role" "public"."role_type", "_message" "text", "_token_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_new_audit_to_n8n"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_new_audit_to_n8n"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_new_audit_to_n8n"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_new_user_message"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_new_user_message"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_new_user_message"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_referral_code"("new_user_id" "uuid", "used_referral_code" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."process_referral_code"("new_user_id" "uuid", "used_referral_code" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_referral_code"("new_user_id" "uuid", "used_referral_code" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_started_and_completed_timestamps"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_started_and_completed_timestamps"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_started_and_completed_timestamps"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_subscription_end_date"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_subscription_end_date"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_subscription_end_date"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_user_id_from_metadata"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_user_id_from_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_user_id_from_metadata"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_business_audit_reference"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_business_audit_reference"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_business_audit_reference"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_chat_session_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_chat_session_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_chat_session_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_last_analyzed_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_last_analyzed_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_last_analyzed_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_personality_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_personality_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_personality_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_business_ownership"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_business_ownership"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_business_ownership"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_competitor_relationship"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_competitor_relationship"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_competitor_relationship"() TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";















GRANT ALL ON TABLE "public"."audits" TO "anon";
GRANT ALL ON TABLE "public"."audits" TO "authenticated";
GRANT ALL ON TABLE "public"."audits" TO "service_role";



GRANT ALL ON TABLE "public"."business_competitors" TO "anon";
GRANT ALL ON TABLE "public"."business_competitors" TO "authenticated";
GRANT ALL ON TABLE "public"."business_competitors" TO "service_role";



GRANT ALL ON TABLE "public"."businesses" TO "anon";
GRANT ALL ON TABLE "public"."businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."businesses" TO "service_role";



GRANT ALL ON TABLE "public"."call_report_evaluations" TO "anon";
GRANT ALL ON TABLE "public"."call_report_evaluations" TO "authenticated";
GRANT ALL ON TABLE "public"."call_report_evaluations" TO "service_role";



GRANT ALL ON TABLE "public"."call_transcripts" TO "anon";
GRANT ALL ON TABLE "public"."call_transcripts" TO "authenticated";
GRANT ALL ON TABLE "public"."call_transcripts" TO "service_role";



GRANT ALL ON TABLE "public"."calls" TO "anon";
GRANT ALL ON TABLE "public"."calls" TO "authenticated";
GRANT ALL ON TABLE "public"."calls" TO "service_role";



GRANT ALL ON TABLE "public"."chat_archived_summaries" TO "anon";
GRANT ALL ON TABLE "public"."chat_archived_summaries" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_archived_summaries" TO "service_role";



GRANT ALL ON TABLE "public"."chat_messages" TO "anon";
GRANT ALL ON TABLE "public"."chat_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_messages" TO "service_role";



GRANT ALL ON TABLE "public"."chat_sessions" TO "anon";
GRANT ALL ON TABLE "public"."chat_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."competitor_comparisons" TO "anon";
GRANT ALL ON TABLE "public"."competitor_comparisons" TO "authenticated";
GRANT ALL ON TABLE "public"."competitor_comparisons" TO "service_role";



GRANT ALL ON TABLE "public"."generated_call_reports" TO "anon";
GRANT ALL ON TABLE "public"."generated_call_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."generated_call_reports" TO "service_role";



GRANT ALL ON TABLE "public"."micro_tasks" TO "anon";
GRANT ALL ON TABLE "public"."micro_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."micro_tasks" TO "service_role";



GRANT ALL ON TABLE "public"."personality_analysis_log" TO "anon";
GRANT ALL ON TABLE "public"."personality_analysis_log" TO "authenticated";
GRANT ALL ON TABLE "public"."personality_analysis_log" TO "service_role";



GRANT ALL ON TABLE "public"."personality_message_tracker" TO "anon";
GRANT ALL ON TABLE "public"."personality_message_tracker" TO "authenticated";
GRANT ALL ON TABLE "public"."personality_message_tracker" TO "service_role";



GRANT ALL ON TABLE "public"."referrals" TO "anon";
GRANT ALL ON TABLE "public"."referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."referrals" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_plans" TO "anon";
GRANT ALL ON TABLE "public"."subscription_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_plans" TO "service_role";



GRANT ALL ON TABLE "public"."subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."task_groups" TO "anon";
GRANT ALL ON TABLE "public"."task_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."task_groups" TO "service_role";



GRANT ALL ON TABLE "public"."user_personality" TO "anon";
GRANT ALL ON TABLE "public"."user_personality" TO "authenticated";
GRANT ALL ON TABLE "public"."user_personality" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






























RESET ALL;
