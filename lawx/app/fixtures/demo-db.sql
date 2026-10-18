-- LawX demo database (fictional data) for the in-browser agent
CREATE ROLE lawx_owner; CREATE ROLE lawx_app; CREATE ROLE lawx_agent; GRANT lawx_agent TO lawx_app;
--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Homebrew)
-- Dumped by pg_dump version 16.15 (Homebrew)

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

--
-- Name: agent; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA agent;


--
-- Name: perm_scope; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.perm_scope AS ENUM (
    'none',
    'own',
    'team',
    'department',
    'all'
);


--
-- Name: accessible_case_ids(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.accessible_case_ids(p_resource text, p_action text) RETURNS SETOF integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    s perm_scope := has_scope(p_resource, p_action);
BEGIN
    IF s = 'all' THEN
        RETURN QUERY SELECT id FROM legal_case;
    ELSIF s > 'none' THEN
        RETURN QUERY
            SELECT DISTINCT a.case_id FROM case_assignment a
             WHERE a.employee_id IN (SELECT scope_employee_ids(s));
    END IF;
END $$;


--
-- Name: agent_questions_today(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.agent_questions_today() RETURNS bigint
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT count(*) FROM agent_message WHERE role = 'user' AND created_at >= current_date
$$;


--
-- Name: app_eid(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_eid() RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT employee_id FROM app_user WHERE id = app_uid() AND is_active
$$;


--
-- Name: app_uid(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_uid() RETURNS integer
    LANGUAGE sql STABLE
    AS $$
    SELECT nullif(current_setting('app.user_id', true), '')::int
$$;


--
-- Name: audit_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    o jsonb;
    n jsonb;
BEGIN
    IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD) - 'password_hash'; END IF;
    IF TG_OP <> 'DELETE' THEN n := to_jsonb(NEW) - 'password_hash'; END IF;
    INSERT INTO audit_log (user_id, action, table_name, row_pk, old_data, new_data)
    VALUES (app_uid(), lower(TG_OP), TG_TABLE_NAME, coalesce(n, o)->>'id', o, n);
    RETURN NULL;
END $$;


--
-- Name: auth_lookup(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_lookup(p_username text) RETURNS TABLE(id integer, password_hash text, is_active boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT id, password_hash, is_active FROM app_user WHERE username = p_username
$$;


--
-- Name: auth_password_hash(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_password_hash(p_user_id integer) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT password_hash FROM app_user WHERE id = p_user_id
$$;


--
-- Name: can_access_case(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_access_case(p_case_id integer, p_resource text, p_action text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT p_case_id IN (SELECT accessible_case_ids(p_resource, p_action))
$$;


--
-- Name: can_access_client(integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_access_client(p_client_id integer, p_action text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT has_scope('client', p_action) = 'all'
        OR EXISTS (SELECT 1 FROM client
                    WHERE id = p_client_id
                      AND originating_lawyer_id IN (SELECT scope_employee_ids(has_scope('client', p_action))))
        OR p_client_id IN (SELECT client_ids_via_cases(p_action))
$$;


--
-- Name: change_own_password(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.change_own_password(p_new_hash text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF app_uid() IS NULL THEN
        RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
    END IF;
    UPDATE app_user SET password_hash = p_new_hash WHERE id = app_uid();
END $$;


--
-- Name: client_ids_via_cases(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.client_ids_via_cases(p_action text) RETURNS SETOF integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT DISTINCT c.client_id FROM legal_case c
     WHERE c.client_id IS NOT NULL
       AND c.id IN (SELECT accessible_case_ids('client', p_action))
$$;


--
-- Name: create_case(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_case(p jsonb, p_lead_employee_id integer) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    s       perm_scope := has_scope('case', 'write');
    v_id    int;
    v_client int := (p->>'client_id')::int;
BEGIN
    IF s = 'none' THEN
        RAISE EXCEPTION 'no permission to create cases' USING ERRCODE = '42501';
    END IF;
    IF s <> 'all' AND p_lead_employee_id NOT IN (SELECT scope_employee_ids(s)) THEN
        RAISE EXCEPTION 'lead lawyer is outside your scope' USING ERRCODE = '42501';
    END IF;
    IF v_client IS NOT NULL AND NOT can_access_client(v_client, 'read') THEN
        RAISE EXCEPTION 'client is outside your scope' USING ERRCODE = '42501';
    END IF;

    INSERT INTO legal_case (case_number, title, client_id, practice_area, case_type, status,
                            court, opposing_party, opened_at, description, created_by)
    SELECT r.case_number, r.title, r.client_id, r.practice_area, r.case_type,
           coalesce(r.status, 'active'), r.court, r.opposing_party,
           coalesce(r.opened_at, current_date), r.description, app_eid()
      FROM jsonb_populate_record(NULL::legal_case, p) r
    RETURNING id INTO v_id;

    INSERT INTO case_assignment (case_id, employee_id, role) VALUES (v_id, p_lead_employee_id, 'lead');
    RETURN v_id;
END $$;


--
-- Name: guard_case_publish(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_case_publish() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.is_public IS DISTINCT FROM OLD.is_public
       AND app_uid() IS NOT NULL
       AND has_scope('case', 'publish') <> 'all'
       AND NOT can_access_case(OLD.id, 'case', 'publish') THEN
        RAISE EXCEPTION 'no permission to change public flag' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END $$;


--
-- Name: has_scope(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_scope(p_resource text, p_action text) RETURNS public.perm_scope
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM app_user WHERE id = app_uid() AND is_active)
            THEN 'none'::perm_scope
        ELSE coalesce(
            (SELECT o.scope FROM user_permission_override o
              WHERE o.user_id = app_uid() AND o.resource = p_resource AND o.action = p_action),
            (SELECT max(rp.scope) FROM user_role ur
               JOIN role_permission rp ON rp.role_id = ur.role_id
              WHERE ur.user_id = app_uid() AND rp.resource = p_resource AND rp.action = p_action),
            'none'::perm_scope)
    END
$$;


--
-- Name: initial_setup(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.initial_setup(p_username text, p_password_hash text, p_full_name text, p_firm_name text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_emp  int;
    v_user int;
BEGIN
    LOCK TABLE app_user IN EXCLUSIVE MODE;
    IF EXISTS (SELECT 1 FROM app_user) THEN
        RAISE EXCEPTION 'system is already set up' USING ERRCODE = '42501';
    END IF;
    INSERT INTO employee (full_name, title) VALUES (p_full_name, '管理员') RETURNING id INTO v_emp;
    INSERT INTO app_user (username, password_hash, employee_id) VALUES (p_username, p_password_hash, v_emp)
        RETURNING id INTO v_user;
    INSERT INTO user_role (user_id, role_id) SELECT v_user, id FROM role WHERE code = 'admin';
    INSERT INTO app_setting (key, value) VALUES ('firm_name', to_jsonb(p_firm_name))
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    RETURN v_user;
END $$;


--
-- Name: is_user_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_user_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT has_scope('user', 'manage') = 'all'
$$;


--
-- Name: log_event(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_event(p_action text, p_meta jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    INSERT INTO audit_log (user_id, action, meta) VALUES (app_uid(), p_action, p_meta);
$$;


--
-- Name: my_permissions(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_permissions() RETURNS TABLE(resource text, action text, scope public.perm_scope)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT pc.resource, pc.action, has_scope(pc.resource, pc.action)
      FROM permission_catalog pc
     ORDER BY 1, 2
$$;


--
-- Name: my_report_ids(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_report_ids() RETURNS SETOF integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT id FROM agent_report WHERE user_id = app_uid()
$$;


--
-- Name: public_info(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.public_info() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT jsonb_build_object(
        'firm_name', (SELECT value #>> '{}' FROM app_setting WHERE key = 'firm_name'),
        'setup_needed', NOT EXISTS (SELECT 1 FROM app_user))
$$;


--
-- Name: record_login(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_login(p_user_id integer) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    UPDATE app_user SET last_login_at = now() WHERE id = p_user_id;
    INSERT INTO audit_log (user_id, action) VALUES (p_user_id, 'login');
$$;


--
-- Name: reports_shared_with_me(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reports_shared_with_me() RETURNS SETOF integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT report_id FROM agent_report_share WHERE user_id = app_uid()
$$;


--
-- Name: scope_employee_ids(public.perm_scope); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.scope_employee_ids(p_scope public.perm_scope) RETURNS SETOF integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    WITH RECURSIVE me AS (
        SELECT app_eid() AS id
    ), team AS (
        SELECT id FROM me WHERE id IS NOT NULL
        UNION
        SELECT e.id FROM employee e JOIN team t ON e.supervisor_id = t.id
    )
    SELECT id FROM me WHERE p_scope >= 'own' AND id IS NOT NULL
    UNION
    SELECT id FROM team WHERE p_scope >= 'team'
    UNION
    SELECT e.id FROM employee e
      JOIN department_head dh ON dh.department_id = e.department_id
     WHERE p_scope >= 'department' AND dh.employee_id = (SELECT id FROM me)
    UNION
    SELECT id FROM employee WHERE p_scope = 'all'
$$;


--
-- Name: share_targets(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.share_targets() RETURNS TABLE(user_id integer, full_name text, title text, department text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT u.id, s.full_name, s.title, s.department
      FROM app_user u JOIN staff_directory s ON s.id = u.employee_id
     WHERE u.is_active AND u.id <> app_uid() AND app_uid() IS NOT NULL
     ORDER BY s.department, s.full_name
$$;


--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: case_assignment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_assignment (
    case_id integer NOT NULL,
    employee_id integer NOT NULL,
    role text DEFAULT 'associate'::text NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT case_assignment_role_check CHECK ((role = ANY (ARRAY['lead'::text, 'associate'::text])))
);


--
-- Name: case_team; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.case_team WITH (security_invoker='true') AS
 SELECT case_id,
    employee_id,
    role
   FROM public.case_assignment;


--
-- Name: legal_case; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_case (
    id integer NOT NULL,
    case_number text,
    title text NOT NULL,
    client_id integer,
    practice_area text,
    case_type text,
    status text DEFAULT 'active'::text NOT NULL,
    court text,
    opposing_party text,
    opened_at date DEFAULT CURRENT_DATE,
    closed_at date,
    outcome text,
    description text,
    is_public boolean DEFAULT false NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT legal_case_outcome_check CHECK ((outcome = ANY (ARRAY['won'::text, 'lost'::text, 'settled'::text, 'withdrawn'::text, 'other'::text]))),
    CONSTRAINT legal_case_status_check CHECK ((status = ANY (ARRAY['intake'::text, 'active'::text, 'suspended'::text, 'closed'::text])))
);


--
-- Name: cases; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.cases WITH (security_invoker='true') AS
 SELECT id,
    case_number,
    title,
    client_id,
    practice_area,
    case_type,
    status,
    court,
    opened_at AS opened_on,
    closed_at AS closed_on,
    outcome,
    is_public
   FROM public.legal_case c
  WHERE ((( SELECT public.has_scope('case'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (id IN ( SELECT public.accessible_case_ids('case'::text, 'read'::text) AS accessible_case_ids)));


--
-- Name: client; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client (
    id integer NOT NULL,
    name text NOT NULL,
    client_type text DEFAULT 'company'::text NOT NULL,
    id_number text,
    contact_name text,
    phone text,
    email text,
    address text,
    industry text,
    acquisition_channel text,
    referral_source text,
    originating_lawyer_id integer,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT client_client_type_check CHECK ((client_type = ANY (ARRAY['individual'::text, 'company'::text])))
);


--
-- Name: clients; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.clients WITH (security_invoker='true') AS
 SELECT id,
    name,
    client_type,
    industry,
    acquisition_channel,
    referral_source,
    originating_lawyer_id,
    (created_at)::date AS created_on
   FROM public.client;


--
-- Name: department; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.department (
    id integer NOT NULL,
    name text NOT NULL,
    name_en text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: departments; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.departments WITH (security_invoker='true') AS
 SELECT id,
    name,
    name_en
   FROM public.department;


--
-- Name: fee_agreement; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fee_agreement (
    id integer NOT NULL,
    case_id integer NOT NULL,
    fee_type text NOT NULL,
    fixed_amount numeric(14,2),
    hourly_rate numeric(10,2),
    contingency_pct numeric(5,2),
    currency text DEFAULT 'CNY'::text NOT NULL,
    signed_date date,
    notes text,
    CONSTRAINT fee_agreement_fee_type_check CHECK ((fee_type = ANY (ARRAY['hourly'::text, 'fixed'::text, 'contingency'::text, 'mixed'::text])))
);


--
-- Name: fee_agreements; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.fee_agreements WITH (security_invoker='true') AS
 SELECT id,
    case_id,
    fee_type,
    fixed_amount,
    hourly_rate,
    contingency_pct,
    signed_date
   FROM public.fee_agreement;


--
-- Name: invoice; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoice (
    id integer NOT NULL,
    case_id integer NOT NULL,
    invoice_no text,
    issue_date date NOT NULL,
    due_date date,
    amount numeric(14,2) NOT NULL,
    status text DEFAULT 'issued'::text NOT NULL,
    notes text,
    CONSTRAINT invoice_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'issued'::text, 'partial'::text, 'paid'::text, 'void'::text])))
);


--
-- Name: invoices; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.invoices WITH (security_invoker='true') AS
 SELECT id,
    case_id,
    invoice_no,
    issue_date,
    due_date,
    amount,
    status
   FROM public.invoice;


--
-- Name: law_document; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.law_document (
    id integer NOT NULL,
    doc_type text NOT NULL,
    title text NOT NULL,
    issuer text,
    issued_date date,
    effective_date date,
    content text,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    source_url text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT law_document_doc_type_check CHECK ((doc_type = ANY (ARRAY['statute'::text, 'regulation'::text, 'judicial_interpretation'::text, 'precedent'::text, 'template'::text, 'internal_note'::text])))
);


--
-- Name: law_documents; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.law_documents WITH (security_invoker='true') AS
 SELECT id,
    doc_type,
    title,
    issuer,
    issued_date,
    effective_date,
    content,
    tags
   FROM public.law_document;


--
-- Name: payment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment (
    id integer NOT NULL,
    invoice_id integer NOT NULL,
    paid_date date NOT NULL,
    amount numeric(14,2) NOT NULL,
    method text,
    notes text
);


--
-- Name: payments; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.payments WITH (security_invoker='true') AS
 SELECT id,
    invoice_id,
    paid_date,
    amount,
    method
   FROM public.payment;


--
-- Name: public_cases; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.public_cases WITH (security_invoker='true') AS
 SELECT id,
    case_number,
    title,
    practice_area,
    case_type,
    status,
    court,
    opened_at AS opened_on,
    closed_at AS closed_on,
    outcome,
    description
   FROM public.legal_case
  WHERE is_public;


--
-- Name: employee; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee (
    id integer NOT NULL,
    full_name text NOT NULL,
    email text,
    phone text,
    title text,
    department_id integer,
    supervisor_id integer,
    hire_date date,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT employee_check CHECK ((supervisor_id IS DISTINCT FROM id)),
    CONSTRAINT employee_status_check CHECK ((status = ANY (ARRAY['active'::text, 'left'::text])))
);


--
-- Name: staff_directory; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.staff_directory AS
 SELECT e.id,
    e.full_name,
    e.title,
    e.department_id,
    d.name AS department
   FROM (public.employee e
     LEFT JOIN public.department d ON ((d.id = e.department_id)))
  WHERE ((e.status = 'active'::text) AND (public.app_uid() IS NOT NULL));


--
-- Name: staff; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.staff WITH (security_invoker='true') AS
 SELECT id,
    full_name,
    title,
    department_id,
    department
   FROM public.staff_directory;


--
-- Name: time_entry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.time_entry (
    id integer NOT NULL,
    case_id integer NOT NULL,
    employee_id integer NOT NULL,
    work_date date NOT NULL,
    hours numeric(6,2) NOT NULL,
    rate numeric(10,2),
    billable boolean DEFAULT true NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT time_entry_hours_check CHECK ((hours > (0)::numeric))
);


--
-- Name: time_entries; Type: VIEW; Schema: agent; Owner: -
--

CREATE VIEW agent.time_entries WITH (security_invoker='true') AS
 SELECT id,
    case_id,
    employee_id,
    work_date,
    hours,
    rate,
    billable
   FROM public.time_entry;


--
-- Name: agent_conversation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_conversation (
    id integer NOT NULL,
    user_id integer NOT NULL,
    title text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_conversation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_conversation_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_conversation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_conversation_id_seq OWNED BY public.agent_conversation.id;


--
-- Name: agent_message; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_message (
    id bigint NOT NULL,
    conversation_id integer NOT NULL,
    role text NOT NULL,
    content text,
    tool_calls jsonb,
    tool_call_id text,
    tool_name text,
    meta jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_message_role_check CHECK ((role = ANY (ARRAY['user'::text, 'assistant'::text, 'tool'::text])))
);


--
-- Name: agent_message_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_message_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_message_id_seq OWNED BY public.agent_message.id;


--
-- Name: agent_report; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_report (
    id integer NOT NULL,
    user_id integer NOT NULL,
    conversation_id integer,
    title text NOT NULL,
    spec jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_report_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_report_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_report_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_report_id_seq OWNED BY public.agent_report.id;


--
-- Name: agent_report_share; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_report_share (
    report_id integer NOT NULL,
    user_id integer NOT NULL,
    shared_by integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_setting; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_setting (
    key text NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_user (
    id integer NOT NULL,
    username text NOT NULL,
    password_hash text NOT NULL,
    employee_id integer,
    is_active boolean DEFAULT true NOT NULL,
    language text DEFAULT 'zh'::text NOT NULL,
    wechat_openid text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_login_at timestamp with time zone,
    CONSTRAINT app_user_language_check CHECK ((language = ANY (ARRAY['zh'::text, 'en'::text])))
);


--
-- Name: app_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.app_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: app_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.app_user_id_seq OWNED BY public.app_user.id;


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    user_id integer,
    action text NOT NULL,
    table_name text,
    row_pk text,
    old_data jsonb,
    new_data jsonb,
    meta jsonb
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;


--
-- Name: case_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.case_event (
    id integer NOT NULL,
    case_id integer NOT NULL,
    event_type text NOT NULL,
    event_date date NOT NULL,
    description text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: case_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.case_event_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: case_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.case_event_id_seq OWNED BY public.case_event.id;


--
-- Name: client_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_id_seq OWNED BY public.client.id;


--
-- Name: department_head; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.department_head (
    department_id integer NOT NULL,
    employee_id integer NOT NULL
);


--
-- Name: department_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.department_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: department_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.department_id_seq OWNED BY public.department.id;


--
-- Name: employee_hr; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.employee_hr (
    employee_id integer NOT NULL,
    base_salary numeric(12,2),
    bonus numeric(12,2),
    id_number text,
    bank_account text,
    notes text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: employee_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.employee_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: employee_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.employee_id_seq OWNED BY public.employee.id;


--
-- Name: fee_agreement_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.fee_agreement_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fee_agreement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.fee_agreement_id_seq OWNED BY public.fee_agreement.id;


--
-- Name: invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invoice_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invoice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invoice_id_seq OWNED BY public.invoice.id;


--
-- Name: law_document_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.law_document_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: law_document_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.law_document_id_seq OWNED BY public.law_document.id;


--
-- Name: legal_case_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.legal_case_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: legal_case_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.legal_case_id_seq OWNED BY public.legal_case.id;


--
-- Name: payment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payment_id_seq OWNED BY public.payment.id;


--
-- Name: permission_catalog; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permission_catalog (
    resource text NOT NULL,
    action text NOT NULL,
    description text
);


--
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role (
    id integer NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    description text,
    is_builtin boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.role_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.role_id_seq OWNED BY public.role.id;


--
-- Name: role_permission; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permission (
    role_id integer NOT NULL,
    resource text NOT NULL,
    action text NOT NULL,
    scope public.perm_scope NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    name text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: time_entry_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.time_entry_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: time_entry_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.time_entry_id_seq OWNED BY public.time_entry.id;


--
-- Name: user_permission_override; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_permission_override (
    user_id integer NOT NULL,
    resource text NOT NULL,
    action text NOT NULL,
    scope public.perm_scope NOT NULL
);


--
-- Name: user_role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_role (
    user_id integer NOT NULL,
    role_id integer NOT NULL
);


--
-- Name: agent_conversation id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_conversation ALTER COLUMN id SET DEFAULT nextval('public.agent_conversation_id_seq'::regclass);


--
-- Name: agent_message id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_message ALTER COLUMN id SET DEFAULT nextval('public.agent_message_id_seq'::regclass);


--
-- Name: agent_report id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report ALTER COLUMN id SET DEFAULT nextval('public.agent_report_id_seq'::regclass);


--
-- Name: app_user id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user ALTER COLUMN id SET DEFAULT nextval('public.app_user_id_seq'::regclass);


--
-- Name: audit_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log ALTER COLUMN id SET DEFAULT nextval('public.audit_log_id_seq'::regclass);


--
-- Name: case_event id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_event ALTER COLUMN id SET DEFAULT nextval('public.case_event_id_seq'::regclass);


--
-- Name: client id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client ALTER COLUMN id SET DEFAULT nextval('public.client_id_seq'::regclass);


--
-- Name: department id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department ALTER COLUMN id SET DEFAULT nextval('public.department_id_seq'::regclass);


--
-- Name: employee id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee ALTER COLUMN id SET DEFAULT nextval('public.employee_id_seq'::regclass);


--
-- Name: fee_agreement id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fee_agreement ALTER COLUMN id SET DEFAULT nextval('public.fee_agreement_id_seq'::regclass);


--
-- Name: invoice id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice ALTER COLUMN id SET DEFAULT nextval('public.invoice_id_seq'::regclass);


--
-- Name: law_document id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.law_document ALTER COLUMN id SET DEFAULT nextval('public.law_document_id_seq'::regclass);


--
-- Name: legal_case id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_case ALTER COLUMN id SET DEFAULT nextval('public.legal_case_id_seq'::regclass);


--
-- Name: payment id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment ALTER COLUMN id SET DEFAULT nextval('public.payment_id_seq'::regclass);


--
-- Name: role id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role ALTER COLUMN id SET DEFAULT nextval('public.role_id_seq'::regclass);


--
-- Name: time_entry id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_entry ALTER COLUMN id SET DEFAULT nextval('public.time_entry_id_seq'::regclass);


--
-- Name: SCHEMA agent; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA agent TO lawx_agent;
GRANT USAGE ON SCHEMA agent TO lawx_app;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO lawx_app;
GRANT USAGE ON SCHEMA public TO lawx_agent;


--
-- Name: FUNCTION accessible_case_ids(p_resource text, p_action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.accessible_case_ids(p_resource text, p_action text) TO lawx_app;


--
-- Name: FUNCTION agent_questions_today(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.agent_questions_today() FROM PUBLIC;
GRANT ALL ON FUNCTION public.agent_questions_today() TO lawx_app;


--
-- Name: FUNCTION app_eid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_eid() TO lawx_app;


--
-- Name: FUNCTION app_uid(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_uid() TO lawx_app;


--
-- Name: FUNCTION audit_trigger(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.audit_trigger() TO lawx_app;


--
-- Name: FUNCTION auth_lookup(p_username text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.auth_lookup(p_username text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.auth_lookup(p_username text) TO lawx_app;


--
-- Name: FUNCTION auth_password_hash(p_user_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.auth_password_hash(p_user_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.auth_password_hash(p_user_id integer) TO lawx_app;


--
-- Name: FUNCTION can_access_case(p_case_id integer, p_resource text, p_action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_access_case(p_case_id integer, p_resource text, p_action text) TO lawx_app;


--
-- Name: FUNCTION can_access_client(p_client_id integer, p_action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_access_client(p_client_id integer, p_action text) TO lawx_app;


--
-- Name: FUNCTION change_own_password(p_new_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.change_own_password(p_new_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.change_own_password(p_new_hash text) TO lawx_app;


--
-- Name: FUNCTION client_ids_via_cases(p_action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.client_ids_via_cases(p_action text) TO lawx_app;


--
-- Name: FUNCTION create_case(p jsonb, p_lead_employee_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_case(p jsonb, p_lead_employee_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_case(p jsonb, p_lead_employee_id integer) TO lawx_app;


--
-- Name: FUNCTION guard_case_publish(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.guard_case_publish() TO lawx_app;


--
-- Name: FUNCTION has_scope(p_resource text, p_action text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.has_scope(p_resource text, p_action text) TO lawx_app;


--
-- Name: FUNCTION initial_setup(p_username text, p_password_hash text, p_full_name text, p_firm_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.initial_setup(p_username text, p_password_hash text, p_full_name text, p_firm_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.initial_setup(p_username text, p_password_hash text, p_full_name text, p_firm_name text) TO lawx_app;


--
-- Name: FUNCTION is_user_admin(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_user_admin() TO lawx_app;


--
-- Name: FUNCTION log_event(p_action text, p_meta jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.log_event(p_action text, p_meta jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.log_event(p_action text, p_meta jsonb) TO lawx_app;


--
-- Name: FUNCTION my_permissions(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.my_permissions() TO lawx_app;


--
-- Name: FUNCTION my_report_ids(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.my_report_ids() TO lawx_app;


--
-- Name: FUNCTION public_info(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.public_info() FROM PUBLIC;
GRANT ALL ON FUNCTION public.public_info() TO lawx_app;


--
-- Name: FUNCTION record_login(p_user_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_login(p_user_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_login(p_user_id integer) TO lawx_app;


--
-- Name: FUNCTION reports_shared_with_me(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.reports_shared_with_me() TO lawx_app;


--
-- Name: FUNCTION scope_employee_ids(p_scope public.perm_scope); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.scope_employee_ids(p_scope public.perm_scope) TO lawx_app;


--
-- Name: FUNCTION share_targets(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.share_targets() FROM PUBLIC;
GRANT ALL ON FUNCTION public.share_targets() TO lawx_app;


--
-- Name: FUNCTION touch_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.touch_updated_at() TO lawx_app;


--
-- Name: TABLE case_assignment; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.case_assignment TO lawx_app;
GRANT SELECT ON TABLE public.case_assignment TO lawx_agent;


--
-- Name: TABLE case_team; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.case_team TO lawx_agent;
GRANT SELECT ON TABLE agent.case_team TO lawx_app;


--
-- Name: TABLE legal_case; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.legal_case TO lawx_app;
GRANT SELECT ON TABLE public.legal_case TO lawx_agent;


--
-- Name: TABLE cases; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.cases TO lawx_agent;
GRANT SELECT ON TABLE agent.cases TO lawx_app;


--
-- Name: TABLE client; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.client TO lawx_app;
GRANT SELECT ON TABLE public.client TO lawx_agent;


--
-- Name: TABLE clients; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.clients TO lawx_agent;
GRANT SELECT ON TABLE agent.clients TO lawx_app;


--
-- Name: TABLE department; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.department TO lawx_app;
GRANT SELECT ON TABLE public.department TO lawx_agent;


--
-- Name: TABLE departments; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.departments TO lawx_agent;
GRANT SELECT ON TABLE agent.departments TO lawx_app;


--
-- Name: TABLE fee_agreement; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.fee_agreement TO lawx_app;
GRANT SELECT ON TABLE public.fee_agreement TO lawx_agent;


--
-- Name: TABLE fee_agreements; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.fee_agreements TO lawx_agent;
GRANT SELECT ON TABLE agent.fee_agreements TO lawx_app;


--
-- Name: TABLE invoice; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.invoice TO lawx_app;
GRANT SELECT ON TABLE public.invoice TO lawx_agent;


--
-- Name: TABLE invoices; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.invoices TO lawx_agent;
GRANT SELECT ON TABLE agent.invoices TO lawx_app;


--
-- Name: TABLE law_document; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.law_document TO lawx_app;
GRANT SELECT ON TABLE public.law_document TO lawx_agent;


--
-- Name: TABLE law_documents; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.law_documents TO lawx_agent;
GRANT SELECT ON TABLE agent.law_documents TO lawx_app;


--
-- Name: TABLE payment; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payment TO lawx_app;
GRANT SELECT ON TABLE public.payment TO lawx_agent;


--
-- Name: TABLE payments; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.payments TO lawx_agent;
GRANT SELECT ON TABLE agent.payments TO lawx_app;


--
-- Name: TABLE public_cases; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.public_cases TO lawx_agent;
GRANT SELECT ON TABLE agent.public_cases TO lawx_app;


--
-- Name: TABLE employee; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employee TO lawx_app;


--
-- Name: TABLE staff_directory; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.staff_directory TO lawx_app;
GRANT SELECT ON TABLE public.staff_directory TO lawx_agent;


--
-- Name: TABLE staff; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.staff TO lawx_agent;
GRANT SELECT ON TABLE agent.staff TO lawx_app;


--
-- Name: TABLE time_entry; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.time_entry TO lawx_app;
GRANT SELECT ON TABLE public.time_entry TO lawx_agent;


--
-- Name: TABLE time_entries; Type: ACL; Schema: agent; Owner: -
--

GRANT SELECT ON TABLE agent.time_entries TO lawx_agent;
GRANT SELECT ON TABLE agent.time_entries TO lawx_app;


--
-- Name: TABLE agent_conversation; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.agent_conversation TO lawx_app;


--
-- Name: SEQUENCE agent_conversation_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.agent_conversation_id_seq TO lawx_app;


--
-- Name: TABLE agent_message; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT ON TABLE public.agent_message TO lawx_app;


--
-- Name: SEQUENCE agent_message_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.agent_message_id_seq TO lawx_app;


--
-- Name: TABLE agent_report; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.agent_report TO lawx_app;


--
-- Name: SEQUENCE agent_report_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.agent_report_id_seq TO lawx_app;


--
-- Name: TABLE agent_report_share; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE ON TABLE public.agent_report_share TO lawx_app;


--
-- Name: TABLE app_setting; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.app_setting TO lawx_app;


--
-- Name: TABLE app_user; Type: ACL; Schema: public; Owner: -
--

GRANT DELETE ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.username; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(username),INSERT(username),UPDATE(username) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.password_hash; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(password_hash),UPDATE(password_hash) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.employee_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(employee_id),INSERT(employee_id),UPDATE(employee_id) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.is_active; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(is_active),INSERT(is_active),UPDATE(is_active) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.language; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(language),INSERT(language),UPDATE(language) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.wechat_openid; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(wechat_openid),UPDATE(wechat_openid) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.app_user TO lawx_app;


--
-- Name: COLUMN app_user.last_login_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(last_login_at) ON TABLE public.app_user TO lawx_app;


--
-- Name: SEQUENCE app_user_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.app_user_id_seq TO lawx_app;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.audit_log TO lawx_app;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.audit_log_id_seq TO lawx_app;


--
-- Name: TABLE case_event; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.case_event TO lawx_app;


--
-- Name: SEQUENCE case_event_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.case_event_id_seq TO lawx_app;


--
-- Name: SEQUENCE client_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.client_id_seq TO lawx_app;


--
-- Name: TABLE department_head; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.department_head TO lawx_app;


--
-- Name: SEQUENCE department_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.department_id_seq TO lawx_app;


--
-- Name: TABLE employee_hr; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employee_hr TO lawx_app;


--
-- Name: SEQUENCE employee_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.employee_id_seq TO lawx_app;


--
-- Name: SEQUENCE fee_agreement_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.fee_agreement_id_seq TO lawx_app;


--
-- Name: SEQUENCE invoice_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.invoice_id_seq TO lawx_app;


--
-- Name: SEQUENCE law_document_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.law_document_id_seq TO lawx_app;


--
-- Name: SEQUENCE legal_case_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.legal_case_id_seq TO lawx_app;


--
-- Name: SEQUENCE payment_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.payment_id_seq TO lawx_app;


--
-- Name: TABLE permission_catalog; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.permission_catalog TO lawx_app;


--
-- Name: TABLE role; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role TO lawx_app;


--
-- Name: SEQUENCE role_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.role_id_seq TO lawx_app;


--
-- Name: TABLE role_permission; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_permission TO lawx_app;


--
-- Name: SEQUENCE time_entry_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.time_entry_id_seq TO lawx_app;


--
-- Name: TABLE user_permission_override; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_permission_override TO lawx_app;


--
-- Name: TABLE user_role; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_role TO lawx_app;


--
-- PostgreSQL database dump complete
--


INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (1, 'admin', '-', 1, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (2, 'p1', '-', 2, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (3, 'p2', '-', 3, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (4, 'l1', '-', 4, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (5, 'l2', '-', 5, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (6, 'l3', '-', 6, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (7, 'l4', '-', 7, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (8, 'p3', '-', 8, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (9, 'l5', '-', 9, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (10, 'l6', '-', 10, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (11, 'l7', '-', 11, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (12, 'l8', '-', 12, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (13, 'l9', '-', 13, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (14, 'l10', '-', 14, true, 'zh');
INSERT INTO public.app_user (id, username, password_hash, employee_id, is_active, language) VALUES (15, 'guest', '-', NULL, true, 'zh');
--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Homebrew)
-- Dumped by pg_dump version 16.15 (Homebrew)

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

--
-- Data for Name: app_setting; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.app_setting VALUES
	('firm_name', '"LawX 演示律师事务所"', '2026-10-18 19:28:59.660717+08');


--
-- Data for Name: department; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.department VALUES
	(1, '诉讼部', 'Litigation', '2026-10-18 19:23:26.224524+08'),
	(2, '公司部', 'Corporate', '2026-10-18 19:23:26.224524+08'),
	(3, '知识产权部', 'IP', '2026-10-18 19:23:26.224524+08');


--
-- Data for Name: employee; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.employee VALUES
	(1, '王管理', NULL, NULL, '行政', NULL, NULL, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(2, '张合伙', NULL, NULL, '合伙人', 1, NULL, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(3, '李合伙', NULL, NULL, '合伙人', 2, NULL, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(4, '赵律师', NULL, NULL, '律师', 1, 2, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(5, '钱律师', NULL, NULL, '律师', 1, 2, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(6, '孙律师', NULL, NULL, '律师', 2, 3, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(7, '周律师', NULL, NULL, '律师', 1, 3, '2022-01-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(8, '吴合伙', NULL, NULL, '合伙人', 3, NULL, '2021-06-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(9, '郑律师', NULL, NULL, '律师', 1, 2, '2020-08-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(10, '冯律师', NULL, NULL, '律师', 1, 2, '2024-02-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(11, '陈律师', NULL, NULL, '律师', 2, 3, '2020-10-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(12, '褚律师', NULL, NULL, '律师', 2, 3, '2022-10-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(13, '卫律师', NULL, NULL, '律师', 3, 8, '2024-09-01', 'active', '2026-10-18 19:23:26.224524+08'),
	(14, '蒋律师', NULL, NULL, '律师', 3, 8, '2021-03-01', 'active', '2026-10-18 19:23:26.224524+08');


--
-- Data for Name: client; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.client VALUES
	(1, '甲科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 4, NULL, '2026-10-18 19:23:26.224524+08'),
	(2, '乙贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, NULL, 'website', NULL, 5, NULL, '2026-10-18 19:23:26.224524+08'),
	(3, '丙制造集团', 'company', NULL, NULL, NULL, NULL, NULL, NULL, 'event', NULL, 6, NULL, '2026-10-18 19:23:26.224524+08'),
	(4, '丁先生', 'company', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 6, NULL, '2026-10-18 19:23:26.224524+08'),
	(5, '戊地产', 'company', NULL, NULL, NULL, NULL, NULL, NULL, 'website', NULL, 7, NULL, '2026-10-18 19:23:26.224524+08'),
	(6, '深圳华创海纳物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 11, NULL, '2026-07-22 00:00:00+08'),
	(7, '深圳东方合众文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'partner_org', NULL, 11, NULL, '2024-03-03 00:00:00+08'),
	(8, '刘先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'wechat', NULL, 9, NULL, '2026-06-23 00:00:00+08'),
	(9, '深圳星河东方贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'website', NULL, 14, NULL, '2024-01-05 00:00:00+08'),
	(10, '深圳海纳恒达科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'referral', NULL, 13, NULL, '2024-09-05 00:00:00+08'),
	(11, '深圳嘉禾中科贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'existing_client', NULL, 2, NULL, '2025-09-28 00:00:00+08'),
	(12, '深圳鹏程宏图科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'referral', NULL, 5, NULL, '2025-04-04 00:00:00+08'),
	(13, '深圳博雅宏图贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'existing_client', NULL, 12, NULL, '2024-10-22 00:00:00+08'),
	(14, '周先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 2, NULL, '2024-01-17 00:00:00+08'),
	(15, '朱先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 9, NULL, '2026-10-15 00:00:00+08'),
	(16, '深圳汇通嘉禾文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'event', NULL, 11, NULL, '2024-03-20 00:00:00+08'),
	(17, '深圳博雅东方文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'website', NULL, 8, NULL, '2025-01-09 00:00:00+08'),
	(18, '胡先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'partner_org', NULL, 7, NULL, '2026-10-01 00:00:00+08'),
	(19, '深圳瑞丰星河物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'partner_org', NULL, 8, NULL, '2025-11-20 00:00:00+08'),
	(20, '朱女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 4, NULL, '2026-05-24 00:00:00+08'),
	(21, '胡先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 4, NULL, '2025-12-29 00:00:00+08'),
	(22, '深圳智联云帆医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'website', NULL, 9, NULL, '2025-01-20 00:00:00+08'),
	(23, '马先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 2, NULL, '2025-10-20 00:00:00+08'),
	(24, '深圳卓越金桥金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'existing_client', NULL, 11, NULL, '2024-07-10 00:00:00+08'),
	(25, '深圳智联远航文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'referral', NULL, 8, NULL, '2025-04-06 00:00:00+08'),
	(26, '深圳华创恒达文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'wechat', NULL, 5, NULL, '2025-05-06 00:00:00+08'),
	(27, '罗女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 4, NULL, '2024-12-18 00:00:00+08'),
	(28, '深圳合众前海医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'event', NULL, 12, NULL, '2025-10-01 00:00:00+08'),
	(29, '深圳立信云帆医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 2, NULL, '2025-03-09 00:00:00+08'),
	(30, '深圳东方华创金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'existing_client', NULL, 2, NULL, '2025-06-04 00:00:00+08'),
	(31, '深圳安信恒达物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'wechat', NULL, 2, NULL, '2024-09-02 00:00:00+08'),
	(32, '赵女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 7, NULL, '2026-02-28 00:00:00+08'),
	(33, '朱女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 10, NULL, '2024-11-14 00:00:00+08'),
	(34, '刘女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 4, NULL, '2026-09-26 00:00:00+08'),
	(35, '深圳新元嘉禾医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'existing_client', NULL, 11, NULL, '2024-12-13 00:00:00+08'),
	(36, '深圳恒达星河科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'website', NULL, 9, NULL, '2026-03-21 00:00:00+08'),
	(37, '深圳博雅卓越房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'partner_org', NULL, 12, NULL, '2025-04-24 00:00:00+08'),
	(38, '深圳远航嘉禾房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'existing_client', NULL, 5, NULL, '2025-02-19 00:00:00+08'),
	(39, '深圳天成华创文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'event', NULL, 10, NULL, '2026-07-05 00:00:00+08'),
	(40, '深圳智联嘉禾金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'referral', NULL, 7, NULL, '2026-10-09 00:00:00+08'),
	(41, '深圳金桥海纳房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'referral', NULL, 10, NULL, '2024-05-25 00:00:00+08'),
	(42, '深圳天成立信制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'referral', NULL, 11, NULL, '2024-04-24 00:00:00+08'),
	(43, '深圳汇通永盛房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'wechat', NULL, 8, NULL, '2026-04-13 00:00:00+08'),
	(44, '深圳安信汇通房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'existing_client', NULL, 9, NULL, '2025-07-06 00:00:00+08'),
	(45, '李女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'website', NULL, 4, NULL, '2026-03-29 00:00:00+08'),
	(46, '刘先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'partner_org', NULL, 10, NULL, '2026-09-19 00:00:00+08'),
	(47, '王先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'wechat', NULL, 4, NULL, '2025-09-21 00:00:00+08'),
	(48, '深圳天成南山物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'existing_client', NULL, 9, NULL, '2024-02-27 00:00:00+08'),
	(49, '深圳汇通新元金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'website', NULL, 14, NULL, '2025-10-20 00:00:00+08'),
	(50, '深圳南山东方文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'existing_client', NULL, 13, NULL, '2024-10-16 00:00:00+08'),
	(51, '深圳海纳星河贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'existing_client', NULL, 9, NULL, '2024-09-04 00:00:00+08'),
	(52, '深圳云帆启明科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'wechat', NULL, 2, NULL, '2026-07-17 00:00:00+08'),
	(53, '刘女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'website', NULL, 4, NULL, '2026-05-25 00:00:00+08'),
	(54, '深圳安信恒达医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'existing_client', NULL, 4, NULL, '2026-09-16 00:00:00+08'),
	(55, '深圳汇通华创金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'event', NULL, 11, NULL, '2024-10-28 00:00:00+08'),
	(56, '深圳瑞丰海纳文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'partner_org', NULL, 6, NULL, '2025-08-19 00:00:00+08'),
	(57, '深圳新元卓越贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'partner_org', NULL, 6, NULL, '2025-02-27 00:00:00+08'),
	(58, '深圳合众博雅物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'existing_client', NULL, 9, NULL, '2025-03-15 00:00:00+08'),
	(59, '深圳金桥嘉禾制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'referral', NULL, 7, NULL, '2024-08-31 00:00:00+08'),
	(60, '深圳中科立信房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'referral', NULL, 13, NULL, '2025-10-03 00:00:00+08'),
	(61, '林先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'wechat', NULL, 7, NULL, '2025-08-05 00:00:00+08'),
	(62, '深圳天成金桥物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'wechat', NULL, 3, NULL, '2024-10-23 00:00:00+08'),
	(63, '深圳嘉禾新元房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'referral', NULL, 2, NULL, '2024-07-31 00:00:00+08'),
	(64, '深圳云帆汇通科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'existing_client', NULL, 10, NULL, '2026-07-02 00:00:00+08'),
	(65, '深圳智联汇通制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'referral', NULL, 10, NULL, '2024-11-25 00:00:00+08'),
	(66, '深圳智联合众房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'existing_client', NULL, 6, NULL, '2025-10-17 00:00:00+08'),
	(67, '深圳金桥嘉禾贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 5, NULL, '2026-01-12 00:00:00+08'),
	(68, '深圳安信汇通医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 14, NULL, '2024-10-28 00:00:00+08'),
	(69, '陈先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 2, NULL, '2024-05-08 00:00:00+08'),
	(70, '深圳瑞丰永盛医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'wechat', NULL, 3, NULL, '2026-03-30 00:00:00+08'),
	(71, '深圳永盛鹏程医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 13, NULL, '2026-08-07 00:00:00+08'),
	(72, '深圳鹏程合众房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'wechat', NULL, 11, NULL, '2024-07-24 00:00:00+08'),
	(73, '深圳前海前海制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'referral', NULL, 14, NULL, '2025-11-02 00:00:00+08'),
	(74, '深圳华创恒达金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'existing_client', NULL, 2, NULL, '2024-07-04 00:00:00+08'),
	(75, '深圳恒达南山物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 9, NULL, '2024-08-19 00:00:00+08'),
	(76, '深圳天成南山贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 5, NULL, '2024-04-12 00:00:00+08'),
	(77, '陈女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 10, NULL, '2026-05-27 00:00:00+08'),
	(78, '深圳云帆卓越房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'existing_client', NULL, 13, NULL, '2025-01-25 00:00:00+08'),
	(79, '深圳卓越安信医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'website', NULL, 3, NULL, '2026-08-30 00:00:00+08'),
	(80, '深圳云帆前海金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'referral', NULL, 2, NULL, '2026-07-17 00:00:00+08'),
	(81, '深圳卓越金桥科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'existing_client', NULL, 2, NULL, '2026-07-23 00:00:00+08'),
	(82, '深圳星河智联科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'event', NULL, 9, NULL, '2024-07-03 00:00:00+08'),
	(83, '深圳远航新元房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'event', NULL, 12, NULL, '2026-05-17 00:00:00+08'),
	(84, '深圳云帆鹏程物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 7, NULL, '2024-10-31 00:00:00+08'),
	(85, '深圳嘉禾海纳制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'website', NULL, 12, NULL, '2024-11-30 00:00:00+08'),
	(86, '深圳新元云帆文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'existing_client', NULL, 6, NULL, '2025-02-25 00:00:00+08'),
	(87, '胡先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 7, NULL, '2025-02-16 00:00:00+08'),
	(88, '深圳鹏程中科医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'website', NULL, 12, NULL, '2026-06-29 00:00:00+08'),
	(89, '郭女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 9, NULL, '2024-08-13 00:00:00+08'),
	(90, '孙先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'wechat', NULL, 7, NULL, '2026-01-09 00:00:00+08'),
	(91, '深圳瑞丰立信物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'existing_client', NULL, 2, NULL, '2024-12-22 00:00:00+08'),
	(92, '深圳启明海纳物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'wechat', NULL, 11, NULL, '2024-11-23 00:00:00+08'),
	(93, '深圳天成鹏程金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'partner_org', NULL, 7, NULL, '2024-04-11 00:00:00+08'),
	(94, '深圳鹏程天成文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'existing_client', NULL, 5, NULL, '2026-09-23 00:00:00+08'),
	(95, '深圳合众南山医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'existing_client', NULL, 6, NULL, '2024-01-21 00:00:00+08'),
	(96, '深圳新元天成贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'website', NULL, 7, NULL, '2026-01-16 00:00:00+08'),
	(97, '深圳立信金桥物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'website', NULL, 9, NULL, '2025-04-08 00:00:00+08'),
	(98, '深圳星河恒达房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'website', NULL, 11, NULL, '2024-10-08 00:00:00+08'),
	(99, '深圳宏图汇通物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 3, NULL, '2025-02-09 00:00:00+08'),
	(100, '林先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'partner_org', NULL, 5, NULL, '2024-05-10 00:00:00+08'),
	(101, '深圳嘉禾宏图医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'wechat', NULL, 11, NULL, '2024-12-22 00:00:00+08'),
	(102, '深圳华创博雅房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'website', NULL, 7, NULL, '2024-02-29 00:00:00+08'),
	(103, '深圳天成新元贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 10, NULL, '2024-03-23 00:00:00+08'),
	(104, '深圳东方合众房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'website', NULL, 10, NULL, '2024-05-17 00:00:00+08'),
	(105, '深圳宏图永盛科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'referral', NULL, 6, NULL, '2024-09-09 00:00:00+08'),
	(106, '深圳天成瑞丰物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'website', NULL, 7, NULL, '2024-01-14 00:00:00+08'),
	(107, '深圳瑞丰合众贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'existing_client', NULL, 2, NULL, '2026-03-13 00:00:00+08'),
	(108, '深圳启明东方贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'wechat', NULL, 11, NULL, '2026-10-02 00:00:00+08'),
	(109, '深圳卓越鹏程制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'existing_client', NULL, 11, NULL, '2026-04-15 00:00:00+08'),
	(110, '深圳云帆智联房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'referral', NULL, 11, NULL, '2024-03-29 00:00:00+08'),
	(111, '深圳智联嘉禾房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'existing_client', NULL, 9, NULL, '2024-08-27 00:00:00+08'),
	(112, '深圳卓越启明贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 2, NULL, '2024-02-10 00:00:00+08'),
	(113, '深圳鹏程前海文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'website', NULL, 13, NULL, '2025-09-30 00:00:00+08'),
	(114, '深圳立信永盛贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'event', NULL, 7, NULL, '2024-07-20 00:00:00+08'),
	(115, '深圳智联智联文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'website', NULL, 3, NULL, '2025-10-07 00:00:00+08'),
	(116, '深圳金桥立信物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'wechat', NULL, 5, NULL, '2024-02-01 00:00:00+08'),
	(117, '深圳南山新元制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'referral', NULL, 5, NULL, '2024-03-21 00:00:00+08'),
	(118, '深圳海纳智联医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 4, NULL, '2024-03-31 00:00:00+08'),
	(119, '深圳鹏程恒达制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'wechat', NULL, 11, NULL, '2025-11-23 00:00:00+08'),
	(120, '深圳智联汇通医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 9, NULL, '2026-04-28 00:00:00+08'),
	(121, '深圳前海智联房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'existing_client', NULL, 8, NULL, '2025-06-08 00:00:00+08'),
	(122, '深圳远航云帆物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'event', NULL, 10, NULL, '2026-01-28 00:00:00+08'),
	(123, '深圳云帆华创科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'referral', NULL, 4, NULL, '2025-08-05 00:00:00+08'),
	(124, '周先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 8, NULL, '2024-04-22 00:00:00+08'),
	(125, '深圳东方智联物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'event', NULL, 5, NULL, '2026-04-09 00:00:00+08'),
	(126, '深圳金桥嘉禾制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'referral', NULL, 3, NULL, '2026-02-02 00:00:00+08'),
	(127, '深圳天成永盛文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'event', NULL, 2, NULL, '2025-08-01 00:00:00+08'),
	(128, '深圳金桥汇通医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 4, NULL, '2025-03-29 00:00:00+08'),
	(129, '深圳恒达启明科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'referral', NULL, 12, NULL, '2026-07-03 00:00:00+08'),
	(130, '深圳瑞丰天成金融有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '金融', 'wechat', NULL, 5, NULL, '2025-10-01 00:00:00+08'),
	(131, '深圳鹏程鹏程文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'referral', NULL, 8, NULL, '2025-04-03 00:00:00+08'),
	(132, '深圳前海海纳物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'website', NULL, 2, NULL, '2024-07-13 00:00:00+08'),
	(133, '刘先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'partner_org', NULL, 10, NULL, '2025-09-05 00:00:00+08'),
	(134, '深圳宏图合众制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'partner_org', NULL, 6, NULL, '2026-06-04 00:00:00+08'),
	(135, '深圳前海远航房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'website', NULL, 9, NULL, '2026-01-08 00:00:00+08'),
	(136, '深圳中科前海物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 5, NULL, '2025-05-27 00:00:00+08'),
	(137, '深圳东方云帆科技有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '科技', 'wechat', NULL, 2, NULL, '2024-03-23 00:00:00+08'),
	(138, '深圳南山安信物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 3, NULL, '2025-06-06 00:00:00+08'),
	(139, '深圳中科合众医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'event', NULL, 14, NULL, '2024-11-09 00:00:00+08'),
	(140, '赵女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'referral', NULL, 7, NULL, '2026-03-16 00:00:00+08'),
	(141, '深圳宏图博雅文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'event', NULL, 5, NULL, '2026-08-06 00:00:00+08'),
	(142, '深圳瑞丰新元物流有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '物流', 'referral', NULL, 11, NULL, '2025-11-30 00:00:00+08'),
	(143, '深圳启明汇通贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 10, NULL, '2024-03-02 00:00:00+08'),
	(144, '马女士', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'wechat', NULL, 9, NULL, '2025-06-08 00:00:00+08'),
	(145, '李先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'existing_client', NULL, 7, NULL, '2024-11-20 00:00:00+08'),
	(146, '深圳远航博雅贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'existing_client', NULL, 4, NULL, '2025-05-05 00:00:00+08'),
	(147, '深圳恒达新元房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'partner_org', NULL, 4, NULL, '2025-05-22 00:00:00+08'),
	(148, '深圳远航立信制造有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '制造', 'website', NULL, 2, NULL, '2026-06-23 00:00:00+08'),
	(149, '深圳合众启明房地产有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '房地产', 'wechat', NULL, 2, NULL, '2026-04-09 00:00:00+08'),
	(150, '深圳合众宏图贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'website', NULL, 8, NULL, '2025-01-25 00:00:00+08'),
	(151, '深圳前海远航医疗健康有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '医疗健康', 'referral', NULL, 5, NULL, '2026-03-02 00:00:00+08'),
	(152, '深圳云帆远航贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 11, NULL, '2024-10-26 00:00:00+08'),
	(153, '黄先生', 'individual', NULL, NULL, NULL, NULL, NULL, NULL, 'wechat', NULL, 8, NULL, '2025-04-04 00:00:00+08'),
	(154, '深圳卓越南山文化传媒有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '文化传媒', 'website', NULL, 13, NULL, '2024-08-30 00:00:00+08'),
	(155, '深圳立信智联贸易有限公司', 'company', NULL, NULL, NULL, NULL, NULL, '贸易', 'referral', NULL, 10, NULL, '2024-09-22 00:00:00+08');


--
-- Data for Name: legal_case; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.legal_case VALUES
	(1, 'K1', '甲科技 合同纠纷', 1, 'litigation', NULL, 'active', NULL, NULL, '2026-03-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(2, 'K2', '乙贸易 货款追索', 2, 'litigation', NULL, 'active', NULL, NULL, '2026-03-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(3, 'K3', '丙制造 并购尽调', 3, 'corporate', NULL, 'active', NULL, NULL, '2026-03-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(4, 'K4', '丁先生 劳动争议（典型案例）', 4, 'labor', NULL, 'active', NULL, NULL, '2026-03-01', NULL, NULL, NULL, true, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(5, 'K5', '甲科技 股权重组', 1, 'corporate', NULL, 'active', NULL, NULL, '2026-03-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(6, 'K6', '戊地产 建设工程纠纷', 5, 'litigation', NULL, 'active', NULL, NULL, '2026-03-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(7, 'LX2026-0000', '深圳华创海纳物流 股权投资', 6, 'corporate', NULL, 'active', NULL, NULL, '2026-08-11', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(8, 'LX2024-0010', '深圳东方合众文化 股权投资', 7, 'corporate', NULL, 'closed', NULL, NULL, '2024-03-06', '2024-04-25', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(9, 'LX2024-0011', '深圳东方合众文化 取保候审', 7, 'criminal', NULL, 'closed', NULL, NULL, '2024-05-31', '2024-09-02', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(10, 'LX2026-0020', '刘先生 买卖合同纠纷', 8, 'litigation', NULL, 'closed', NULL, NULL, '2026-07-09', '2026-08-23', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(11, 'LX2024-0030', '深圳星河东方贸易 专利无效宣告', 9, 'ip', NULL, 'closed', NULL, NULL, '2024-01-09', '2025-04-05', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(12, 'LX2024-0031', '深圳星河东方贸易 并购尽职调查', 9, 'corporate', NULL, 'closed', NULL, NULL, '2024-08-23', '2024-09-15', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(13, 'LX2025-0032', '深圳星河东方贸易 股权投资', 9, 'corporate', NULL, 'closed', NULL, NULL, '2025-06-13', '2025-08-15', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(14, 'LX2024-0040', '深圳海纳恒达科技 商业秘密保护', 10, 'ip', NULL, 'closed', NULL, NULL, '2024-09-06', '2025-05-08', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(15, 'LX2025-0050', '深圳嘉禾中科贸易 股东出资纠纷', 11, 'litigation', NULL, 'closed', NULL, NULL, '2025-10-01', '2026-02-13', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(16, 'LX2026-0051', '深圳嘉禾中科贸易 股东出资纠纷', 11, 'litigation', NULL, 'closed', NULL, NULL, '2026-02-13', '2026-05-26', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(17, 'LX2025-0060', '深圳鹏程宏图科技 建设工程施工合同纠纷', 12, 'real_estate', NULL, 'closed', NULL, NULL, '2025-04-17', '2025-08-22', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(18, 'LX2024-0070', '深圳博雅宏图贸易 股权投资', 13, 'corporate', NULL, 'closed', NULL, NULL, '2024-10-30', '2024-12-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(19, 'LX2025-0071', '深圳博雅宏图贸易 专利无效宣告', 13, 'ip', NULL, 'closed', NULL, NULL, '2025-03-26', '2025-11-03', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(20, 'LX2024-0080', '周先生 刑事辩护', 14, 'criminal', NULL, 'closed', NULL, NULL, '2024-01-20', '2025-01-14', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(21, 'LX2024-0100', '深圳汇通嘉禾文化 公司常年法律顾问', 16, 'corporate', NULL, 'closed', NULL, NULL, '2024-03-21', '2024-09-22', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(22, 'LX2024-0101', '深圳汇通嘉禾文化 专利无效宣告', 16, 'ip', NULL, 'closed', NULL, NULL, '2024-08-30', '2024-12-16', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(23, 'LX2025-0110', '深圳博雅东方文化 商标侵权纠纷', 17, 'ip', NULL, 'closed', NULL, NULL, '2025-01-22', '2025-05-18', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(24, 'LX2026-0120', '胡先生 竞业限制纠纷', 18, 'labor', NULL, 'intake', NULL, NULL, '2026-10-06', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(25, 'LX2025-0130', '深圳瑞丰星河物流 商标侵权纠纷', 19, 'ip', NULL, 'closed', NULL, NULL, '2025-11-20', '2026-06-13', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(26, 'LX2026-0140', '朱女士 工伤赔偿', 20, 'labor', NULL, 'closed', NULL, NULL, '2026-06-11', '2026-07-11', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(27, 'LX2025-0150', '胡先生 建设工程施工合同纠纷', 21, 'real_estate', NULL, 'closed', NULL, NULL, '2025-12-29', '2026-10-02', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(28, 'LX2026-0151', '胡先生 租赁合同纠纷', 21, 'real_estate', NULL, 'active', NULL, NULL, '2026-05-14', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(29, 'LX2025-0160', '深圳智联云帆医疗 房屋买卖合同纠纷', 22, 'real_estate', NULL, 'closed', NULL, NULL, '2025-02-02', '2025-09-26', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(30, 'LX2025-0170', '马先生 竞业限制纠纷', 23, 'labor', NULL, 'closed', NULL, NULL, '2025-11-07', '2026-05-20', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(31, 'LX2026-0171', '马先生 劳动争议仲裁', 23, 'labor', NULL, 'closed', NULL, NULL, '2026-06-04', '2026-08-22', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(32, 'LX2024-0180', '深圳卓越金桥金融 股权激励方案', 24, 'corporate', NULL, 'closed', NULL, NULL, '2024-07-20', '2024-11-23', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(33, 'LX2025-0181', '深圳卓越金桥金融 股权激励方案', 24, 'corporate', NULL, 'closed', NULL, NULL, '2025-02-25', '2025-07-27', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(34, 'LX2025-0190', '深圳智联远航文化 专利无效宣告', 25, 'ip', NULL, 'closed', NULL, NULL, '2025-04-16', '2025-06-30', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(35, 'LX2025-0200', '深圳华创恒达文化 劳动争议仲裁', 26, 'labor', NULL, 'closed', NULL, NULL, '2025-05-07', '2026-05-09', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(36, 'LX2024-0210', '罗女士 竞业限制纠纷', 27, 'labor', NULL, 'closed', NULL, NULL, '2024-12-18', '2025-02-16', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(37, 'LX2025-0211', '罗女士 建设工程施工合同纠纷', 27, 'real_estate', NULL, 'active', NULL, NULL, '2025-10-26', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(38, 'LX2025-0220', '深圳合众前海医疗 股权激励方案', 28, 'corporate', NULL, 'closed', NULL, NULL, '2025-10-12', '2025-11-25', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(39, 'LX2025-0230', '深圳立信云帆医疗 买卖合同纠纷', 29, 'litigation', NULL, 'closed', NULL, NULL, '2025-03-10', '2026-04-04', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(40, 'LX2025-0240', '深圳东方华创金融 房屋买卖合同纠纷', 30, 'real_estate', NULL, 'closed', NULL, NULL, '2025-06-23', '2025-10-22', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(41, 'LX2026-0241', '深圳东方华创金融 劳动争议仲裁', 30, 'labor', NULL, 'active', NULL, NULL, '2026-07-07', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(42, 'LX2024-0250', '深圳安信恒达物流 职务侵占辩护', 31, 'criminal', NULL, 'closed', NULL, NULL, '2024-09-18', '2025-10-26', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(43, 'LX2026-0260', '赵女士 买卖合同纠纷', 32, 'litigation', NULL, 'active', NULL, NULL, '2026-03-12', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(44, 'LX2024-0270', '朱女士 服务合同纠纷', 33, 'litigation', NULL, 'closed', NULL, NULL, '2024-11-24', '2025-12-04', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(45, 'LX2026-0280', '刘女士 违法解除劳动合同纠纷', 34, 'labor', NULL, 'intake', NULL, NULL, '2026-10-10', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(46, 'LX2025-0290', '深圳新元嘉禾医疗 公司常年法律顾问', 35, 'corporate', NULL, 'closed', NULL, NULL, '2025-01-02', '2025-04-11', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(47, 'LX2025-0291', '深圳新元嘉禾医疗 房屋买卖合同纠纷', 35, 'real_estate', NULL, 'closed', NULL, NULL, '2025-12-24', '2026-09-19', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(48, 'LX2026-0300', '深圳恒达星河科技 买卖合同纠纷', 36, 'litigation', NULL, 'active', NULL, NULL, '2026-03-27', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(49, 'LX2026-0301', '深圳恒达星河科技 著作权许可', 36, 'ip', NULL, 'active', NULL, NULL, '2026-10-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(50, 'LX2025-0310', '深圳博雅卓越房地 并购尽职调查', 37, 'corporate', NULL, 'closed', NULL, NULL, '2025-04-30', '2025-09-26', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(51, 'LX2025-0320', '深圳远航嘉禾房地 房屋买卖合同纠纷', 38, 'real_estate', NULL, 'closed', NULL, NULL, '2025-02-21', '2025-08-13', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(52, 'LX2025-0321', '深圳远航嘉禾房地 股权激励方案', 38, 'corporate', NULL, 'closed', NULL, NULL, '2025-06-30', '2025-11-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(53, 'LX2026-0330', '深圳天成华创文化 工伤赔偿', 39, 'labor', NULL, 'active', NULL, NULL, '2026-07-10', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(54, 'LX2026-0340', '深圳智联嘉禾金融 借款合同纠纷', 40, 'litigation', NULL, 'intake', NULL, NULL, '2026-10-15', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(55, 'LX2024-0350', '深圳金桥海纳房地 借款合同纠纷', 41, 'litigation', NULL, 'closed', NULL, NULL, '2024-05-28', '2025-11-11', 'withdrawn', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(56, 'LX2024-0360', '深圳天成立信制造 公司常年法律顾问', 42, 'corporate', NULL, 'closed', NULL, NULL, '2024-05-06', '2024-07-18', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(57, 'LX2026-0370', '深圳汇通永盛房地 商标侵权纠纷', 43, 'ip', NULL, 'active', NULL, NULL, '2026-04-18', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(58, 'LX2025-0380', '深圳安信汇通房地 买卖合同纠纷', 44, 'litigation', NULL, 'closed', NULL, NULL, '2025-07-22', '2025-08-23', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(59, 'LX2025-0381', '深圳安信汇通房地 股东出资纠纷', 44, 'litigation', NULL, 'active', NULL, NULL, '2025-12-26', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(60, 'LX2026-0390', '李女士 违法解除劳动合同纠纷', 45, 'labor', NULL, 'active', NULL, NULL, '2026-04-07', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(61, 'LX2026-0400', '刘先生 工伤赔偿', 46, 'labor', NULL, 'active', NULL, NULL, '2026-09-19', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(62, 'LX2025-0410', '王先生 股东出资纠纷', 47, 'litigation', NULL, 'closed', NULL, NULL, '2025-09-22', '2026-02-11', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(63, 'LX2024-0420', '深圳天成南山物流 劳动争议仲裁', 48, 'labor', NULL, 'closed', NULL, NULL, '2024-03-06', '2024-06-13', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(64, 'LX2024-0421', '深圳天成南山物流 买卖合同纠纷', 48, 'litigation', NULL, 'closed', NULL, NULL, '2024-11-22', '2025-09-07', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(65, 'LX2025-0430', '深圳汇通新元金融 商标侵权纠纷', 49, 'ip', NULL, 'closed', NULL, NULL, '2025-10-27', '2026-07-29', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(66, 'LX2026-0431', '深圳汇通新元金融 著作权许可', 49, 'ip', NULL, 'active', NULL, NULL, '2026-08-21', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(67, 'LX2024-0440', '深圳南山东方文化 专利无效宣告', 50, 'ip', NULL, 'closed', NULL, NULL, '2024-10-29', '2025-04-13', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(68, 'LX2025-0441', '深圳南山东方文化 股东出资纠纷', 50, 'litigation', NULL, 'closed', NULL, NULL, '2025-07-31', '2026-09-07', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(69, 'LX2024-0450', '深圳海纳星河贸易 服务合同纠纷', 51, 'litigation', NULL, 'closed', NULL, NULL, '2024-09-22', '2025-10-28', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(70, 'LX2025-0451', '深圳海纳星河贸易 著作权许可', 51, 'ip', NULL, 'closed', NULL, NULL, '2025-01-09', '2026-02-18', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(71, 'LX2026-0460', '深圳云帆启明科技 股东出资纠纷', 52, 'litigation', NULL, 'active', NULL, NULL, '2026-08-06', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(72, 'LX2026-0470', '刘女士 职务侵占辩护', 53, 'criminal', NULL, 'active', NULL, NULL, '2026-06-02', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(73, 'LX2026-0480', '深圳安信恒达医疗 服务合同纠纷', 54, 'litigation', NULL, 'active', NULL, NULL, '2026-09-28', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(74, 'LX2024-0490', '深圳汇通华创金融 公司常年法律顾问', 55, 'corporate', NULL, 'closed', NULL, NULL, '2024-11-12', '2025-06-24', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(75, 'LX2025-0500', '深圳瑞丰海纳文化 股权投资', 56, 'corporate', NULL, 'closed', NULL, NULL, '2025-08-28', '2025-12-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(76, 'LX2025-0510', '深圳新元卓越贸易 股权激励方案', 57, 'corporate', NULL, 'closed', NULL, NULL, '2025-03-02', '2025-03-24', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(77, 'LX2025-0520', '深圳合众博雅物流 服务合同纠纷', 58, 'litigation', NULL, 'closed', NULL, NULL, '2025-03-28', '2026-06-18', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(78, 'LX2025-0521', '深圳合众博雅物流 股东出资纠纷', 58, 'litigation', NULL, 'active', NULL, NULL, '2025-09-08', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(79, 'LX2025-0522', '深圳合众博雅物流 工伤赔偿', 58, 'labor', NULL, 'active', NULL, NULL, '2025-12-03', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(80, 'LX2024-0530', '深圳金桥嘉禾制造 股东出资纠纷', 59, 'litigation', NULL, 'closed', NULL, NULL, '2024-08-31', '2026-01-28', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(81, 'LX2025-0540', '深圳中科立信房地 专利无效宣告', 60, 'ip', NULL, 'closed', NULL, NULL, '2025-10-20', '2026-05-13', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(82, 'LX2025-0550', '林先生 劳动争议仲裁', 61, 'labor', NULL, 'active', NULL, NULL, '2025-08-20', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(83, 'LX2024-0560', '深圳天成金桥物流 股权投资', 62, 'corporate', NULL, 'closed', NULL, NULL, '2024-11-01', '2025-01-27', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(84, 'LX2024-0570', '深圳嘉禾新元房地 服务合同纠纷', 63, 'litigation', NULL, 'closed', NULL, NULL, '2024-07-31', '2025-03-27', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(85, 'LX2026-0580', '深圳云帆汇通科技 建设工程施工合同纠纷', 64, 'real_estate', NULL, 'closed', NULL, NULL, '2026-07-02', '2026-10-17', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(86, 'LX2024-0590', '深圳智联汇通制造 竞业限制纠纷', 65, 'labor', NULL, 'closed', NULL, NULL, '2024-12-11', '2025-02-09', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(87, 'LX2025-0591', '深圳智联汇通制造 房屋买卖合同纠纷', 65, 'real_estate', NULL, 'closed', NULL, NULL, '2025-03-05', '2026-02-17', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(88, 'LX2025-0600', '深圳智联合众房地 并购尽职调查', 66, 'corporate', NULL, 'closed', NULL, NULL, '2025-10-30', '2025-11-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(89, 'LX2026-0601', '深圳智联合众房地 并购尽职调查', 66, 'corporate', NULL, 'closed', NULL, NULL, '2026-03-07', '2026-07-28', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(90, 'LX2026-0610', '深圳金桥嘉禾贸易 服务合同纠纷', 67, 'litigation', NULL, 'active', NULL, NULL, '2026-01-17', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(91, 'LX2024-0620', '深圳安信汇通医疗 商业秘密保护', 68, 'ip', NULL, 'closed', NULL, NULL, '2024-11-15', '2025-08-06', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(92, 'LX2024-0630', '陈先生 职务侵占辩护', 69, 'criminal', NULL, 'closed', NULL, NULL, '2024-05-23', '2024-06-29', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(93, 'LX2024-0631', '陈先生 劳动争议仲裁', 69, 'labor', NULL, 'closed', NULL, NULL, '2024-09-23', '2025-02-17', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(94, 'LX2025-0632', '陈先生 买卖合同纠纷', 69, 'litigation', NULL, 'closed', NULL, NULL, '2025-01-25', '2026-02-27', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(95, 'LX2026-0640', '深圳瑞丰永盛医疗 股权激励方案', 70, 'corporate', NULL, 'active', NULL, NULL, '2026-04-03', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(96, 'LX2026-0650', '深圳永盛鹏程医疗 商标侵权纠纷', 71, 'ip', NULL, 'active', NULL, NULL, '2026-08-22', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(97, 'LX2024-0660', '深圳鹏程合众房地 公司常年法律顾问', 72, 'corporate', NULL, 'closed', NULL, NULL, '2024-08-02', '2024-12-18', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(98, 'LX2025-0670', '深圳前海前海制造 著作权许可', 73, 'ip', NULL, 'closed', NULL, NULL, '2025-11-21', '2026-07-03', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(99, 'LX2026-0671', '深圳前海前海制造 专利无效宣告', 73, 'ip', NULL, 'closed', NULL, NULL, '2026-03-30', '2026-05-18', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(100, 'LX2024-0680', '深圳华创恒达金融 借款合同纠纷', 74, 'litigation', NULL, 'closed', NULL, NULL, '2024-07-23', '2025-05-02', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(101, 'LX2024-0681', '深圳华创恒达金融 股权投资', 74, 'corporate', NULL, 'closed', NULL, NULL, '2024-12-01', '2025-02-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(102, 'LX2024-0690', '深圳恒达南山物流 股东出资纠纷', 75, 'litigation', NULL, 'closed', NULL, NULL, '2024-08-21', '2025-07-28', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(103, 'LX2024-0700', '深圳天成南山贸易 竞业限制纠纷', 76, 'labor', NULL, 'closed', NULL, NULL, '2024-04-20', '2025-02-25', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(104, 'LX2026-0710', '陈女士 劳动争议仲裁', 77, 'labor', NULL, 'active', NULL, NULL, '2026-06-03', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(105, 'LX2025-0720', '深圳云帆卓越房地 商业秘密保护', 78, 'ip', NULL, 'closed', NULL, NULL, '2025-01-28', '2025-12-30', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(106, 'LX2026-0721', '深圳云帆卓越房地 租赁合同纠纷', 78, 'real_estate', NULL, 'closed', NULL, NULL, '2026-02-19', '2026-05-02', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(107, 'LX2026-0730', '深圳卓越安信医疗 股权激励方案', 79, 'corporate', NULL, 'active', NULL, NULL, '2026-09-18', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(108, 'LX2026-0740', '深圳云帆前海金融 建设工程施工合同纠纷', 80, 'real_estate', NULL, 'active', NULL, NULL, '2026-07-22', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(109, 'LX2026-0750', '深圳卓越金桥科技 借款合同纠纷', 81, 'litigation', NULL, 'active', NULL, NULL, '2026-08-12', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(110, 'LX2024-0760', '深圳星河智联科技 股东出资纠纷', 82, 'litigation', NULL, 'closed', NULL, NULL, '2024-07-14', '2025-05-18', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(111, 'LX2026-0770', '深圳远航新元房地 并购尽职调查', 83, 'corporate', NULL, 'closed', NULL, NULL, '2026-05-23', '2026-07-03', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(112, 'LX2024-0780', '深圳云帆鹏程物流 竞业限制纠纷', 84, 'labor', NULL, 'closed', NULL, NULL, '2024-11-12', '2025-06-13', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(113, 'LX2024-0790', '深圳嘉禾海纳制造 股权投资', 85, 'corporate', NULL, 'closed', NULL, NULL, '2024-12-20', '2025-07-03', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(114, 'LX2025-0800', '深圳新元云帆文化 股权激励方案', 86, 'corporate', NULL, 'closed', NULL, NULL, '2025-03-09', '2025-11-02', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(115, 'LX2026-0801', '深圳新元云帆文化 借款合同纠纷', 86, 'litigation', NULL, 'active', NULL, NULL, '2026-03-22', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(116, 'LX2025-0810', '胡先生 劳动争议仲裁', 87, 'labor', NULL, 'closed', NULL, NULL, '2025-02-17', '2025-09-04', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(117, 'LX2026-0820', '深圳鹏程中科医疗 公司常年法律顾问', 88, 'corporate', NULL, 'active', NULL, NULL, '2026-07-01', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(118, 'LX2024-0830', '郭女士 刑事辩护', 89, 'criminal', NULL, 'closed', NULL, NULL, '2024-09-02', '2025-11-06', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(119, 'LX2025-0831', '郭女士 工伤赔偿', 89, 'labor', NULL, 'closed', NULL, NULL, '2025-03-21', '2026-05-20', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(120, 'LX2025-0832', '郭女士 借款合同纠纷', 89, 'litigation', NULL, 'active', NULL, NULL, '2025-06-20', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(121, 'LX2026-0840', '孙先生 股东出资纠纷', 90, 'litigation', NULL, 'active', NULL, NULL, '2026-01-27', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(122, 'LX2025-0850', '深圳瑞丰立信物流 买卖合同纠纷', 91, 'litigation', NULL, 'closed', NULL, NULL, '2025-01-03', '2026-03-12', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(123, 'LX2025-0851', '深圳瑞丰立信物流 股东出资纠纷', 91, 'litigation', NULL, 'active', NULL, NULL, '2025-11-30', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(124, 'LX2026-0852', '深圳瑞丰立信物流 房屋买卖合同纠纷', 91, 'real_estate', NULL, 'active', NULL, NULL, '2026-09-06', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(125, 'LX2024-0860', '深圳启明海纳物流 公司常年法律顾问', 92, 'corporate', NULL, 'closed', NULL, NULL, '2024-12-08', '2025-04-29', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(126, 'LX2025-0861', '深圳启明海纳物流 商标侵权纠纷', 92, 'ip', NULL, 'active', NULL, NULL, '2025-08-09', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(127, 'LX2026-0862', '深圳启明海纳物流 股权投资', 92, 'corporate', NULL, 'closed', NULL, NULL, '2026-02-02', '2026-06-29', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(128, 'LX2024-0870', '深圳天成鹏程金融 借款合同纠纷', 93, 'litigation', NULL, 'closed', NULL, NULL, '2024-04-25', '2025-02-18', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(129, 'LX2026-0880', '深圳鹏程天成文化 房屋买卖合同纠纷', 94, 'real_estate', NULL, 'active', NULL, NULL, '2026-09-24', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(130, 'LX2024-0890', '深圳合众南山医疗 股权投资', 95, 'corporate', NULL, 'closed', NULL, NULL, '2024-01-27', '2024-03-02', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(131, 'LX2024-0891', '深圳合众南山医疗 竞业限制纠纷', 95, 'labor', NULL, 'closed', NULL, NULL, '2024-09-02', '2024-11-14', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(132, 'LX2026-0900', '深圳新元天成贸易 股东出资纠纷', 96, 'litigation', NULL, 'closed', NULL, NULL, '2026-01-28', '2026-07-03', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(133, 'LX2025-0910', '深圳立信金桥物流 股东出资纠纷', 97, 'litigation', NULL, 'closed', NULL, NULL, '2025-04-15', '2025-06-02', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(134, 'LX2024-0920', '深圳星河恒达房地 股权投资', 98, 'corporate', NULL, 'closed', NULL, NULL, '2024-10-12', '2025-01-13', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(135, 'LX2025-0930', '深圳宏图汇通物流 公司常年法律顾问', 99, 'corporate', NULL, 'closed', NULL, NULL, '2025-02-15', '2025-10-01', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(136, 'LX2024-0940', '林先生 借款合同纠纷', 100, 'litigation', NULL, 'closed', NULL, NULL, '2024-05-29', '2025-10-18', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(137, 'LX2024-0950', '深圳嘉禾宏图医疗 公司常年法律顾问', 101, 'corporate', NULL, 'closed', NULL, NULL, '2024-12-26', '2025-06-26', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(138, 'LX2024-0960', '深圳华创博雅房地 服务合同纠纷', 102, 'litigation', NULL, 'closed', NULL, NULL, '2024-03-12', '2025-03-13', 'withdrawn', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(139, 'LX2024-0970', '深圳天成新元贸易 工伤赔偿', 103, 'labor', NULL, 'closed', NULL, NULL, '2024-03-26', '2025-05-05', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(140, 'LX2024-0980', '深圳东方合众房地 房屋买卖合同纠纷', 104, 'real_estate', NULL, 'closed', NULL, NULL, '2024-06-06', '2025-05-14', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(141, 'LX2024-0990', '深圳宏图永盛科技 股权激励方案', 105, 'corporate', NULL, 'closed', NULL, NULL, '2024-09-24', '2025-03-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(142, 'LX2025-0991', '深圳宏图永盛科技 竞业限制纠纷', 105, 'labor', NULL, 'closed', NULL, NULL, '2025-02-10', '2025-07-19', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(143, 'LX2024-1000', '深圳天成瑞丰物流 借款合同纠纷', 106, 'litigation', NULL, 'closed', NULL, NULL, '2024-01-27', '2024-04-05', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(144, 'LX2025-1001', '深圳天成瑞丰物流 并购尽职调查', 106, 'corporate', NULL, 'closed', NULL, NULL, '2025-01-27', '2025-09-01', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(145, 'LX2026-1010', '深圳瑞丰合众贸易 房屋买卖合同纠纷', 107, 'real_estate', NULL, 'closed', NULL, NULL, '2026-04-01', '2026-05-19', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(146, 'LX2026-1020', '深圳启明东方贸易 股权激励方案', 108, 'corporate', NULL, 'active', NULL, NULL, '2026-10-04', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(147, 'LX2026-1030', '深圳卓越鹏程制造 公司常年法律顾问', 109, 'corporate', NULL, 'closed', NULL, NULL, '2026-05-04', '2026-10-18', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(148, 'LX2026-1031', '深圳卓越鹏程制造 商标侵权纠纷', 109, 'ip', NULL, 'active', NULL, NULL, '2026-09-26', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(149, 'LX2024-1040', '深圳云帆智联房地 并购尽职调查', 110, 'corporate', NULL, 'closed', NULL, NULL, '2024-03-30', '2024-10-14', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(150, 'LX2024-1050', '深圳智联嘉禾房地 服务合同纠纷', 111, 'litigation', NULL, 'closed', NULL, NULL, '2024-09-16', '2024-11-27', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(151, 'LX2025-1051', '深圳智联嘉禾房地 股东出资纠纷', 111, 'litigation', NULL, 'closed', NULL, NULL, '2025-09-19', '2026-08-31', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(152, 'LX2026-1052', '深圳智联嘉禾房地 商业秘密保护', 111, 'ip', NULL, 'active', NULL, NULL, '2026-08-23', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(153, 'LX2024-1060', '深圳卓越启明贸易 借款合同纠纷', 112, 'litigation', NULL, 'closed', NULL, NULL, '2024-02-10', '2024-03-28', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(154, 'LX2024-1061', '深圳卓越启明贸易 房屋买卖合同纠纷', 112, 'real_estate', NULL, 'closed', NULL, NULL, '2024-08-22', '2025-08-16', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(155, 'LX2025-1062', '深圳卓越启明贸易 股权激励方案', 112, 'corporate', NULL, 'closed', NULL, NULL, '2025-08-11', '2025-12-19', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(156, 'LX2025-1070', '深圳鹏程前海文化 商标侵权纠纷', 113, 'ip', NULL, 'active', NULL, NULL, '2025-10-15', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(157, 'LX2026-1071', '深圳鹏程前海文化 并购尽职调查', 113, 'corporate', NULL, 'active', NULL, NULL, '2026-08-10', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(158, 'LX2024-1080', '深圳立信永盛贸易 股东出资纠纷', 114, 'litigation', NULL, 'closed', NULL, NULL, '2024-07-25', '2024-09-10', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(159, 'LX2025-1081', '深圳立信永盛贸易 股东出资纠纷', 114, 'litigation', NULL, 'closed', NULL, NULL, '2025-01-16', '2025-04-07', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(160, 'LX2025-1090', '深圳智联智联文化 股权投资', 115, 'corporate', NULL, 'closed', NULL, NULL, '2025-10-15', '2026-01-22', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(161, 'LX2026-1091', '深圳智联智联文化 股权投资', 115, 'corporate', NULL, 'active', NULL, NULL, '2026-07-23', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(162, 'LX2024-1100', '深圳金桥立信物流 服务合同纠纷', 116, 'litigation', NULL, 'closed', NULL, NULL, '2024-02-09', '2024-12-09', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(163, 'LX2024-1101', '深圳金桥立信物流 商标侵权纠纷', 116, 'ip', NULL, 'closed', NULL, NULL, '2024-10-21', '2025-06-10', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(164, 'LX2024-1110', '深圳南山新元制造 股东出资纠纷', 117, 'litigation', NULL, 'closed', NULL, NULL, '2024-04-05', '2024-08-28', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(165, 'LX2024-1120', '深圳海纳智联医疗 股东出资纠纷', 118, 'litigation', NULL, 'closed', NULL, NULL, '2024-04-01', '2024-05-24', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(166, 'LX2025-1130', '深圳鹏程恒达制造 并购尽职调查', 119, 'corporate', NULL, 'closed', NULL, NULL, '2025-12-04', '2026-04-17', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(167, 'LX2026-1131', '深圳鹏程恒达制造 股权激励方案', 119, 'corporate', NULL, 'closed', NULL, NULL, '2026-03-13', '2026-04-02', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(168, 'LX2026-1132', '深圳鹏程恒达制造 租赁合同纠纷', 119, 'real_estate', NULL, 'intake', NULL, NULL, '2026-10-05', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(169, 'LX2026-1140', '深圳智联汇通医疗 借款合同纠纷', 120, 'litigation', NULL, 'active', NULL, NULL, '2026-05-13', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(170, 'LX2025-1150', '深圳前海智联房地 商业秘密保护', 121, 'ip', NULL, 'closed', NULL, NULL, '2025-06-10', '2026-08-26', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(171, 'LX2026-1151', '深圳前海智联房地 并购尽职调查', 121, 'corporate', NULL, 'closed', NULL, NULL, '2026-03-15', '2026-09-25', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(172, 'LX2026-1152', '深圳前海智联房地 刑事辩护', 121, 'criminal', NULL, 'active', NULL, NULL, '2026-07-25', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(173, 'LX2026-1160', '深圳远航云帆物流 股东出资纠纷', 122, 'litigation', NULL, 'closed', NULL, NULL, '2026-01-31', '2026-08-06', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(174, 'LX2025-1170', '深圳云帆华创科技 建设工程施工合同纠纷', 123, 'real_estate', NULL, 'closed', NULL, NULL, '2025-08-16', '2026-01-11', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(175, 'LX2024-1180', '周先生 专利无效宣告', 124, 'ip', NULL, 'closed', NULL, NULL, '2024-04-22', '2024-06-16', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(176, 'LX2024-1181', '周先生 劳动争议仲裁', 124, 'labor', NULL, 'closed', NULL, NULL, '2024-10-01', '2024-12-04', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(177, 'LX2026-1190', '深圳东方智联物流 借款合同纠纷', 125, 'litigation', NULL, 'active', NULL, NULL, '2026-04-18', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(178, 'LX2026-1200', '深圳金桥嘉禾制造 股权投资', 126, 'corporate', NULL, 'closed', NULL, NULL, '2026-02-02', '2026-07-16', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(179, 'LX2026-1201', '深圳金桥嘉禾制造 违法解除劳动合同纠纷', 126, 'labor', NULL, 'active', NULL, NULL, '2026-06-22', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(180, 'LX2025-1210', '深圳天成永盛文化 房屋买卖合同纠纷', 127, 'real_estate', NULL, 'active', NULL, NULL, '2025-08-07', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(181, 'LX2025-1211', '深圳天成永盛文化 租赁合同纠纷', 127, 'real_estate', NULL, 'active', NULL, NULL, '2025-12-15', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(182, 'LX2025-1220', '深圳金桥汇通医疗 建设工程施工合同纠纷', 128, 'real_estate', NULL, 'closed', NULL, NULL, '2025-04-02', '2026-01-02', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(183, 'LX2026-1230', '深圳恒达启明科技 并购尽职调查', 129, 'corporate', NULL, 'active', NULL, NULL, '2026-07-15', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(184, 'LX2025-1240', '深圳瑞丰天成金融 工伤赔偿', 130, 'labor', NULL, 'closed', NULL, NULL, '2025-10-19', '2026-08-21', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(185, 'LX2025-1250', '深圳鹏程鹏程文化 商业秘密保护', 131, 'ip', NULL, 'closed', NULL, NULL, '2025-04-13', '2025-07-02', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(186, 'LX2024-1260', '深圳前海海纳物流 买卖合同纠纷', 132, 'litigation', NULL, 'closed', NULL, NULL, '2024-07-30', '2026-01-13', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(187, 'LX2025-1270', '刘先生 买卖合同纠纷', 133, 'litigation', NULL, 'closed', NULL, NULL, '2025-09-11', '2026-10-18', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(188, 'LX2026-1280', '深圳宏图合众制造 股权激励方案', 134, 'corporate', NULL, 'active', NULL, NULL, '2026-06-08', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(189, 'LX2026-1290', '深圳前海远航房地 建设工程施工合同纠纷', 135, 'real_estate', NULL, 'active', NULL, NULL, '2026-01-15', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(190, 'LX2025-1300', '深圳中科前海物流 借款合同纠纷', 136, 'litigation', NULL, 'closed', NULL, NULL, '2025-06-04', '2026-02-17', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(191, 'LX2024-1310', '深圳东方云帆科技 租赁合同纠纷', 137, 'real_estate', NULL, 'closed', NULL, NULL, '2024-04-08', '2025-07-21', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(192, 'LX2025-1320', '深圳南山安信物流 公司常年法律顾问', 138, 'corporate', NULL, 'closed', NULL, NULL, '2025-06-25', '2025-07-28', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(193, 'LX2024-1330', '深圳中科合众医疗 著作权许可', 139, 'ip', NULL, 'closed', NULL, NULL, '2024-11-27', '2025-12-16', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(194, 'LX2025-1331', '深圳中科合众医疗 商业秘密保护', 139, 'ip', NULL, 'closed', NULL, NULL, '2025-03-24', '2026-05-21', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(195, 'LX2026-1340', '赵女士 建设工程施工合同纠纷', 140, 'real_estate', NULL, 'active', NULL, NULL, '2026-04-05', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(196, 'LX2026-1350', '深圳宏图博雅文化 服务合同纠纷', 141, 'litigation', NULL, 'active', NULL, NULL, '2026-08-08', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(197, 'LX2025-1360', '深圳瑞丰新元物流 股权激励方案', 142, 'corporate', NULL, 'closed', NULL, NULL, '2025-12-08', '2026-02-06', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(198, 'LX2024-1370', '深圳启明汇通贸易 服务合同纠纷', 143, 'litigation', NULL, 'closed', NULL, NULL, '2024-03-22', '2025-05-04', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(199, 'LX2025-1371', '深圳启明汇通贸易 工伤赔偿', 143, 'labor', NULL, 'closed', NULL, NULL, '2025-01-20', '2025-11-09', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(200, 'LX2025-1380', '马女士 股东出资纠纷', 144, 'litigation', NULL, 'closed', NULL, NULL, '2025-06-23', '2026-07-05', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08');
INSERT INTO public.legal_case VALUES
	(201, 'LX2024-1390', '李先生 租赁合同纠纷', 145, 'real_estate', NULL, 'closed', NULL, NULL, '2024-12-01', '2025-12-12', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(202, 'LX2025-1391', '李先生 借款合同纠纷', 145, 'litigation', NULL, 'closed', NULL, NULL, '2025-01-31', '2026-02-28', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(203, 'LX2025-1392', '李先生 取保候审', 145, 'criminal', NULL, 'closed', NULL, NULL, '2025-05-12', '2025-08-06', 'lost', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(204, 'LX2025-1400', '深圳远航博雅贸易 取保候审', 146, 'criminal', NULL, 'closed', NULL, NULL, '2025-05-15', '2026-01-29', 'settled', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(205, 'LX2025-1401', '深圳远航博雅贸易 借款合同纠纷', 146, 'litigation', NULL, 'closed', NULL, NULL, '2025-07-22', '2026-07-03', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(206, 'LX2025-1410', '深圳恒达新元房地 借款合同纠纷', 147, 'litigation', NULL, 'closed', NULL, NULL, '2025-06-04', '2025-07-23', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(207, 'LX2026-1420', '深圳远航立信制造 买卖合同纠纷', 148, 'litigation', NULL, 'active', NULL, NULL, '2026-07-04', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(208, 'LX2026-1430', '深圳合众启明房地 房屋买卖合同纠纷', 149, 'real_estate', NULL, 'active', NULL, NULL, '2026-04-17', NULL, NULL, NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(209, 'LX2025-1440', '深圳合众宏图贸易 专利无效宣告', 150, 'ip', NULL, 'closed', NULL, NULL, '2025-02-02', '2025-08-02', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(210, 'LX2026-1450', '深圳前海远航医疗 房屋买卖合同纠纷', 151, 'real_estate', NULL, 'closed', NULL, NULL, '2026-03-16', '2026-04-25', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(211, 'LX2024-1460', '深圳云帆远航贸易 股权投资', 152, 'corporate', NULL, 'closed', NULL, NULL, '2024-10-30', '2025-05-22', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(212, 'LX2025-1470', '黄先生 商业秘密保护', 153, 'ip', NULL, 'closed', NULL, NULL, '2025-04-16', '2026-02-03', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(213, 'LX2024-1480', '深圳卓越南山文化 商标侵权纠纷', 154, 'ip', NULL, 'closed', NULL, NULL, '2024-09-09', '2025-01-10', 'other', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08'),
	(214, 'LX2024-1490', '深圳立信智联贸易 借款合同纠纷', 155, 'litigation', NULL, 'closed', NULL, NULL, '2024-09-27', '2025-03-09', 'won', NULL, false, NULL, '2026-10-18 19:23:26.224524+08', '2026-10-18 19:23:26.224524+08');


--
-- Data for Name: case_assignment; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.case_assignment VALUES
	(1, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(2, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(3, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(4, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(5, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(5, 6, 'associate', '2026-10-18 19:23:26.224524+08'),
	(6, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(7, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(7, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(8, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(8, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(9, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(9, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(10, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(10, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(11, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(12, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(12, 6, 'associate', '2026-10-18 19:23:26.224524+08'),
	(13, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(14, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(15, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(15, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(16, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(16, 9, 'associate', '2026-10-18 19:23:26.224524+08'),
	(17, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(18, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(18, 11, 'associate', '2026-10-18 19:23:26.224524+08'),
	(19, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(20, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(20, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(21, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(22, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(22, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(23, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(24, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(25, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(25, 14, 'associate', '2026-10-18 19:23:26.224524+08'),
	(26, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(26, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(27, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(28, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(28, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(29, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(30, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(31, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(32, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(32, 12, 'associate', '2026-10-18 19:23:26.224524+08'),
	(33, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(34, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(35, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(36, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(36, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(37, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(37, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(38, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(39, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(40, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(41, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(41, 9, 'associate', '2026-10-18 19:23:26.224524+08'),
	(42, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(43, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(43, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(44, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(44, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(45, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(45, 9, 'associate', '2026-10-18 19:23:26.224524+08'),
	(46, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(46, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(47, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(48, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(49, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(49, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(50, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(51, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(51, 4, 'associate', '2026-10-18 19:23:26.224524+08'),
	(52, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(52, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(53, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(54, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(54, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(55, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(55, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(56, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(57, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(58, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(59, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(60, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(61, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(61, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(62, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(62, 7, 'associate', '2026-10-18 19:23:26.224524+08'),
	(63, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(63, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(64, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(65, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(65, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(66, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(67, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(68, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(69, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(70, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(70, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(71, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(71, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(72, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(72, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(73, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(73, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(74, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(75, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(76, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(77, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(77, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(78, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(78, 10, 'associate', '2026-10-18 19:23:26.224524+08'),
	(79, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(80, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(81, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(81, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(82, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(82, 5, 'associate', '2026-10-18 19:23:26.224524+08'),
	(83, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(84, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(84, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(85, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(85, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(86, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(86, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(87, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(87, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(88, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(89, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(90, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(90, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(91, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(91, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(92, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(93, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(94, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(95, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(95, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(96, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(97, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(98, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(99, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(100, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(100, 5, 'associate', '2026-10-18 19:23:26.224524+08'),
	(101, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(102, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(103, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(103, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(104, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(105, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(106, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(106, 7, 'associate', '2026-10-18 19:23:26.224524+08'),
	(107, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(107, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(108, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(108, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(109, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(110, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(110, 5, 'associate', '2026-10-18 19:23:26.224524+08'),
	(111, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(112, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(113, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(113, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(114, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(115, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(115, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(116, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(117, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(117, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(118, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(119, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(120, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(120, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(121, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(122, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(123, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(124, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(124, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(125, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(125, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(126, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(126, 14, 'associate', '2026-10-18 19:23:26.224524+08'),
	(127, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(127, 6, 'associate', '2026-10-18 19:23:26.224524+08'),
	(128, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(129, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(130, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(131, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(132, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(133, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(134, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(135, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(136, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(137, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(137, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(138, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(138, 2, 'associate', '2026-10-18 19:23:26.224524+08');
INSERT INTO public.case_assignment VALUES
	(139, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(139, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(140, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(141, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(141, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(142, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(142, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(143, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(143, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(144, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(144, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(145, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(146, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(147, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(147, 6, 'associate', '2026-10-18 19:23:26.224524+08'),
	(148, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(148, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(149, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(150, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(151, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(152, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(153, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(154, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(154, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(155, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(155, 12, 'associate', '2026-10-18 19:23:26.224524+08'),
	(156, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(156, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(157, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(158, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(158, 5, 'associate', '2026-10-18 19:23:26.224524+08'),
	(159, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(159, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(160, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(161, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(162, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(162, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(163, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(163, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(164, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(164, 7, 'associate', '2026-10-18 19:23:26.224524+08'),
	(165, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(166, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(167, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(167, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(168, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(168, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(169, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(170, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(170, 13, 'associate', '2026-10-18 19:23:26.224524+08'),
	(171, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(172, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(172, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(173, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(174, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(175, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(176, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(176, 10, 'associate', '2026-10-18 19:23:26.224524+08'),
	(177, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(178, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(179, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(179, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(180, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(181, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(182, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(183, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(184, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(185, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(185, 8, 'associate', '2026-10-18 19:23:26.224524+08'),
	(186, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(187, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(187, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(188, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(188, 12, 'associate', '2026-10-18 19:23:26.224524+08'),
	(189, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(189, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(190, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(191, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(191, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(192, 6, 'lead', '2026-10-18 19:23:26.224524+08'),
	(193, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(194, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(194, 13, 'associate', '2026-10-18 19:23:26.224524+08'),
	(195, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(195, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(196, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(197, 12, 'lead', '2026-10-18 19:23:26.224524+08'),
	(197, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(198, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(198, 5, 'associate', '2026-10-18 19:23:26.224524+08'),
	(199, 10, 'lead', '2026-10-18 19:23:26.224524+08'),
	(200, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(200, 4, 'associate', '2026-10-18 19:23:26.224524+08'),
	(201, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(202, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(202, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(203, 7, 'lead', '2026-10-18 19:23:26.224524+08'),
	(204, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(204, 10, 'associate', '2026-10-18 19:23:26.224524+08'),
	(205, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(205, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(206, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(207, 9, 'lead', '2026-10-18 19:23:26.224524+08'),
	(208, 4, 'lead', '2026-10-18 19:23:26.224524+08'),
	(208, 2, 'associate', '2026-10-18 19:23:26.224524+08'),
	(209, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(209, 13, 'associate', '2026-10-18 19:23:26.224524+08'),
	(210, 5, 'lead', '2026-10-18 19:23:26.224524+08'),
	(211, 11, 'lead', '2026-10-18 19:23:26.224524+08'),
	(211, 3, 'associate', '2026-10-18 19:23:26.224524+08'),
	(212, 14, 'lead', '2026-10-18 19:23:26.224524+08'),
	(213, 13, 'lead', '2026-10-18 19:23:26.224524+08'),
	(214, 10, 'lead', '2026-10-18 19:23:26.224524+08');


--
-- Data for Name: case_event; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: department_head; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.department_head VALUES
	(1, 2),
	(2, 3),
	(3, 8);


--
-- Data for Name: fee_agreement; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.fee_agreement VALUES
	(1, 1, 'fixed', 120000.00, NULL, NULL, 'CNY', NULL, NULL),
	(2, 2, 'fixed', 80000.00, NULL, NULL, 'CNY', NULL, NULL),
	(3, 3, 'fixed', 300000.00, NULL, NULL, 'CNY', NULL, NULL),
	(4, 4, 'fixed', 30000.00, NULL, NULL, 'CNY', NULL, NULL),
	(5, 5, 'fixed', 200000.00, NULL, NULL, 'CNY', NULL, NULL),
	(6, 6, 'fixed', 150000.00, NULL, NULL, 'CNY', NULL, NULL),
	(7, 7, 'mixed', 319000.00, 1200.00, NULL, 'CNY', '2026-08-11', NULL),
	(8, 8, 'fixed', 332000.00, NULL, NULL, 'CNY', '2024-03-06', NULL),
	(9, 9, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-05-31', NULL),
	(10, 10, 'contingency', NULL, NULL, 10.00, 'CNY', '2026-07-09', NULL),
	(11, 11, 'mixed', 91000.00, 1200.00, NULL, 'CNY', '2024-01-09', NULL),
	(12, 12, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-08-23', NULL),
	(13, 13, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-06-13', NULL),
	(14, 14, 'fixed', 201000.00, NULL, NULL, 'CNY', '2024-09-06', NULL),
	(15, 15, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-10-01', NULL),
	(16, 16, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-02-13', NULL),
	(17, 17, 'fixed', 409000.00, NULL, NULL, 'CNY', '2025-04-17', NULL),
	(18, 18, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-10-30', NULL),
	(19, 19, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-03-26', NULL),
	(20, 20, 'contingency', NULL, NULL, 10.00, 'CNY', '2024-01-20', NULL),
	(21, 21, 'fixed', 327000.00, NULL, NULL, 'CNY', '2024-03-21', NULL),
	(22, 22, 'fixed', 128000.00, NULL, NULL, 'CNY', '2024-08-30', NULL),
	(23, 23, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-01-22', NULL),
	(24, 24, 'contingency', NULL, NULL, 20.00, 'CNY', '2026-10-06', NULL),
	(25, 25, 'fixed', 51000.00, NULL, NULL, 'CNY', '2025-11-20', NULL),
	(26, 26, 'fixed', 39000.00, NULL, NULL, 'CNY', '2026-06-11', NULL),
	(27, 27, 'contingency', NULL, NULL, 20.00, 'CNY', '2025-12-29', NULL),
	(28, 28, 'fixed', 563000.00, NULL, NULL, 'CNY', '2026-05-14', NULL),
	(29, 29, 'fixed', 137000.00, NULL, NULL, 'CNY', '2025-02-02', NULL),
	(30, 30, 'contingency', NULL, NULL, 15.00, 'CNY', '2025-11-07', NULL),
	(31, 31, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-06-04', NULL),
	(32, 32, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-07-20', NULL),
	(33, 33, 'fixed', 515000.00, NULL, NULL, 'CNY', '2025-02-25', NULL),
	(34, 34, 'fixed', 224000.00, NULL, NULL, 'CNY', '2025-04-16', NULL),
	(35, 35, 'mixed', 20000.00, 1200.00, NULL, 'CNY', '2025-05-07', NULL),
	(36, 36, 'fixed', 52000.00, NULL, NULL, 'CNY', '2024-12-18', NULL),
	(37, 37, 'fixed', 220000.00, NULL, NULL, 'CNY', '2025-10-26', NULL),
	(38, 38, 'fixed', 152000.00, NULL, NULL, 'CNY', '2025-10-12', NULL),
	(39, 39, 'fixed', 134000.00, NULL, NULL, 'CNY', '2025-03-10', NULL),
	(40, 40, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-06-23', NULL),
	(41, 41, 'mixed', 61000.00, 1800.00, NULL, 'CNY', '2026-07-07', NULL),
	(42, 42, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-09-18', NULL),
	(43, 43, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-03-12', NULL),
	(44, 44, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-11-24', NULL),
	(45, 45, 'fixed', 38000.00, NULL, NULL, 'CNY', '2026-10-10', NULL),
	(46, 46, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-01-02', NULL),
	(47, 47, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-12-24', NULL),
	(48, 48, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-03-27', NULL),
	(49, 49, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-10-01', NULL),
	(50, 50, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-04-30', NULL),
	(51, 51, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-02-21', NULL),
	(52, 52, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-06-30', NULL),
	(53, 53, 'mixed', 28000.00, 1200.00, NULL, 'CNY', '2026-07-10', NULL),
	(54, 54, 'fixed', 289000.00, NULL, NULL, 'CNY', '2026-10-15', NULL),
	(55, 55, 'mixed', 59000.00, 1200.00, NULL, 'CNY', '2024-05-28', NULL),
	(56, 56, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-05-06', NULL),
	(57, 57, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-04-18', NULL),
	(58, 58, 'fixed', 160000.00, NULL, NULL, 'CNY', '2025-07-22', NULL),
	(59, 59, 'fixed', 387000.00, NULL, NULL, 'CNY', '2025-12-26', NULL),
	(60, 60, 'contingency', NULL, NULL, 15.00, 'CNY', '2026-04-07', NULL),
	(61, 61, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-09-19', NULL),
	(62, 62, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-09-22', NULL),
	(63, 63, 'fixed', 52000.00, NULL, NULL, 'CNY', '2024-03-06', NULL),
	(64, 64, 'fixed', 146000.00, NULL, NULL, 'CNY', '2024-11-22', NULL),
	(65, 65, 'fixed', 58000.00, NULL, NULL, 'CNY', '2025-10-27', NULL),
	(66, 66, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-08-21', NULL),
	(67, 67, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-10-29', NULL),
	(68, 68, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-07-31', NULL),
	(69, 69, 'fixed', 206000.00, NULL, NULL, 'CNY', '2024-09-22', NULL),
	(70, 70, 'fixed', 132000.00, NULL, NULL, 'CNY', '2025-01-09', NULL),
	(71, 71, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-08-06', NULL),
	(72, 72, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-06-02', NULL),
	(73, 73, 'fixed', 185000.00, NULL, NULL, 'CNY', '2026-09-28', NULL),
	(74, 74, 'mixed', 492000.00, 1200.00, NULL, 'CNY', '2024-11-12', NULL),
	(75, 75, 'fixed', 649000.00, NULL, NULL, 'CNY', '2025-08-28', NULL),
	(76, 76, 'fixed', 112000.00, NULL, NULL, 'CNY', '2025-03-02', NULL),
	(77, 77, 'fixed', 102000.00, NULL, NULL, 'CNY', '2025-03-28', NULL),
	(78, 78, 'fixed', 99000.00, NULL, NULL, 'CNY', '2025-09-08', NULL),
	(79, 79, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-12-03', NULL),
	(80, 80, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-08-31', NULL),
	(81, 81, 'fixed', 220000.00, NULL, NULL, 'CNY', '2025-10-20', NULL),
	(82, 82, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-08-20', NULL),
	(83, 83, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-11-01', NULL),
	(84, 84, 'fixed', 61000.00, NULL, NULL, 'CNY', '2024-07-31', NULL),
	(85, 85, 'fixed', 211000.00, NULL, NULL, 'CNY', '2026-07-02', NULL),
	(86, 86, 'mixed', 27000.00, 1200.00, NULL, 'CNY', '2024-12-11', NULL),
	(87, 87, 'fixed', 245000.00, NULL, NULL, 'CNY', '2025-03-05', NULL),
	(88, 88, 'fixed', 610000.00, NULL, NULL, 'CNY', '2025-10-30', NULL),
	(89, 89, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-03-07', NULL),
	(90, 90, 'fixed', 204000.00, NULL, NULL, 'CNY', '2026-01-17', NULL),
	(91, 91, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-11-15', NULL),
	(92, 92, 'contingency', NULL, NULL, 10.00, 'CNY', '2024-05-23', NULL),
	(93, 93, 'fixed', 18000.00, NULL, NULL, 'CNY', '2024-09-23', NULL),
	(94, 94, 'fixed', 379000.00, NULL, NULL, 'CNY', '2025-01-25', NULL),
	(95, 95, 'fixed', 135000.00, NULL, NULL, 'CNY', '2026-04-03', NULL),
	(96, 96, 'mixed', 179000.00, 1800.00, NULL, 'CNY', '2026-08-22', NULL),
	(97, 97, 'fixed', 119000.00, NULL, NULL, 'CNY', '2024-08-02', NULL),
	(98, 98, 'fixed', 302000.00, NULL, NULL, 'CNY', '2025-11-21', NULL),
	(99, 99, 'fixed', 55000.00, NULL, NULL, 'CNY', '2026-03-30', NULL),
	(100, 100, 'fixed', 130000.00, NULL, NULL, 'CNY', '2024-07-23', NULL),
	(101, 101, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-12-01', NULL),
	(102, 102, 'fixed', 348000.00, NULL, NULL, 'CNY', '2024-08-21', NULL),
	(103, 103, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-04-20', NULL),
	(104, 104, 'fixed', 65000.00, NULL, NULL, 'CNY', '2026-06-03', NULL),
	(105, 105, 'fixed', 271000.00, NULL, NULL, 'CNY', '2025-01-28', NULL),
	(106, 106, 'fixed', 219000.00, NULL, NULL, 'CNY', '2026-02-19', NULL),
	(107, 107, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-09-18', NULL),
	(108, 108, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-07-22', NULL),
	(109, 109, 'fixed', 190000.00, NULL, NULL, 'CNY', '2026-08-12', NULL),
	(110, 110, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-07-14', NULL),
	(111, 111, 'fixed', 189000.00, NULL, NULL, 'CNY', '2026-05-23', NULL),
	(112, 112, 'fixed', 67000.00, NULL, NULL, 'CNY', '2024-11-12', NULL),
	(113, 113, 'fixed', 182000.00, NULL, NULL, 'CNY', '2024-12-20', NULL),
	(114, 114, 'fixed', 576000.00, NULL, NULL, 'CNY', '2025-03-09', NULL),
	(115, 115, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-03-22', NULL),
	(116, 116, 'fixed', 22000.00, NULL, NULL, 'CNY', '2025-02-17', NULL),
	(117, 117, 'fixed', 457000.00, NULL, NULL, 'CNY', '2026-07-01', NULL),
	(118, 118, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-09-02', NULL),
	(119, 119, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-03-21', NULL),
	(120, 120, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-06-20', NULL),
	(121, 121, 'fixed', 147000.00, NULL, NULL, 'CNY', '2026-01-27', NULL),
	(122, 122, 'fixed', 164000.00, NULL, NULL, 'CNY', '2025-01-03', NULL),
	(123, 123, 'mixed', 259000.00, 1800.00, NULL, 'CNY', '2025-11-30', NULL),
	(124, 124, 'contingency', NULL, NULL, 20.00, 'CNY', '2026-09-06', NULL),
	(125, 125, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-12-08', NULL),
	(126, 126, 'fixed', 119000.00, NULL, NULL, 'CNY', '2025-08-09', NULL),
	(127, 127, 'fixed', 276000.00, NULL, NULL, 'CNY', '2026-02-02', NULL),
	(128, 128, 'fixed', 306000.00, NULL, NULL, 'CNY', '2024-04-25', NULL),
	(129, 129, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-09-24', NULL),
	(130, 130, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-01-27', NULL),
	(131, 131, 'mixed', 44000.00, 1200.00, NULL, 'CNY', '2024-09-02', NULL),
	(132, 132, 'fixed', 177000.00, NULL, NULL, 'CNY', '2026-01-28', NULL),
	(133, 133, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-04-15', NULL),
	(134, 134, 'fixed', 385000.00, NULL, NULL, 'CNY', '2024-10-12', NULL),
	(135, 135, 'fixed', 686000.00, NULL, NULL, 'CNY', '2025-02-15', NULL),
	(136, 136, 'fixed', 44000.00, NULL, NULL, 'CNY', '2024-05-29', NULL),
	(137, 137, 'fixed', 60000.00, NULL, NULL, 'CNY', '2024-12-26', NULL),
	(138, 138, 'fixed', 126000.00, NULL, NULL, 'CNY', '2024-03-12', NULL),
	(139, 139, 'fixed', 19000.00, NULL, NULL, 'CNY', '2024-03-26', NULL),
	(140, 140, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-06-06', NULL),
	(141, 141, 'fixed', 343000.00, NULL, NULL, 'CNY', '2024-09-24', NULL),
	(142, 142, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-02-10', NULL),
	(143, 143, 'mixed', 234000.00, 1200.00, NULL, 'CNY', '2024-01-27', NULL),
	(144, 144, 'fixed', 400000.00, NULL, NULL, 'CNY', '2025-01-27', NULL),
	(145, 145, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-04-01', NULL),
	(146, 146, 'fixed', 366000.00, NULL, NULL, 'CNY', '2026-10-04', NULL),
	(147, 147, 'fixed', 284000.00, NULL, NULL, 'CNY', '2026-05-04', NULL),
	(148, 148, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-09-26', NULL),
	(149, 149, 'fixed', 148000.00, NULL, NULL, 'CNY', '2024-03-30', NULL),
	(150, 150, 'contingency', NULL, NULL, 15.00, 'CNY', '2024-09-16', NULL),
	(151, 151, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-09-19', NULL),
	(152, 152, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-08-23', NULL),
	(153, 153, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-02-10', NULL),
	(154, 154, 'fixed', 209000.00, NULL, NULL, 'CNY', '2024-08-22', NULL),
	(155, 155, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-08-11', NULL),
	(156, 156, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-10-15', NULL),
	(157, 157, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-08-10', NULL),
	(158, 158, 'fixed', 82000.00, NULL, NULL, 'CNY', '2024-07-25', NULL),
	(159, 159, 'fixed', 72000.00, NULL, NULL, 'CNY', '2025-01-16', NULL),
	(160, 160, 'fixed', 291000.00, NULL, NULL, 'CNY', '2025-10-15', NULL),
	(161, 161, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-07-23', NULL),
	(162, 162, 'fixed', 50000.00, NULL, NULL, 'CNY', '2024-02-09', NULL),
	(163, 163, 'fixed', 33000.00, NULL, NULL, 'CNY', '2024-10-21', NULL),
	(164, 164, 'fixed', 185000.00, NULL, NULL, 'CNY', '2024-04-05', NULL),
	(165, 165, 'hourly', NULL, 1800.00, NULL, 'CNY', '2024-04-01', NULL),
	(166, 166, 'fixed', 372000.00, NULL, NULL, 'CNY', '2025-12-04', NULL),
	(167, 167, 'mixed', 180000.00, 1200.00, NULL, 'CNY', '2026-03-13', NULL),
	(168, 168, 'fixed', 61000.00, NULL, NULL, 'CNY', '2026-10-05', NULL),
	(169, 169, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-05-13', NULL),
	(170, 170, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-06-10', NULL),
	(171, 171, 'fixed', 706000.00, NULL, NULL, 'CNY', '2026-03-15', NULL),
	(172, 172, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-07-25', NULL),
	(173, 173, 'mixed', 36000.00, 1200.00, NULL, 'CNY', '2026-01-31', NULL),
	(174, 174, 'fixed', 349000.00, NULL, NULL, 'CNY', '2025-08-16', NULL),
	(175, 175, 'fixed', 89000.00, NULL, NULL, 'CNY', '2024-04-22', NULL),
	(176, 176, 'contingency', NULL, NULL, 10.00, 'CNY', '2024-10-01', NULL),
	(177, 177, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-04-18', NULL),
	(178, 178, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-02-02', NULL),
	(179, 179, 'mixed', 28000.00, 1200.00, NULL, 'CNY', '2026-06-22', NULL),
	(180, 180, 'fixed', 220000.00, NULL, NULL, 'CNY', '2025-08-07', NULL),
	(181, 181, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-12-15', NULL),
	(182, 182, 'fixed', 385000.00, NULL, NULL, 'CNY', '2025-04-02', NULL),
	(183, 183, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-07-15', NULL),
	(184, 184, 'fixed', 14000.00, NULL, NULL, 'CNY', '2025-10-19', NULL),
	(185, 185, 'fixed', 272000.00, NULL, NULL, 'CNY', '2025-04-13', NULL),
	(186, 186, 'contingency', NULL, NULL, 20.00, 'CNY', '2024-07-30', NULL),
	(187, 187, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-09-11', NULL),
	(188, 188, 'fixed', 650000.00, NULL, NULL, 'CNY', '2026-06-08', NULL),
	(189, 189, 'mixed', 344000.00, 1800.00, NULL, 'CNY', '2026-01-15', NULL),
	(190, 190, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-06-04', NULL),
	(191, 191, 'fixed', 191000.00, NULL, NULL, 'CNY', '2024-04-08', NULL),
	(192, 192, 'hourly', NULL, 1800.00, NULL, 'CNY', '2025-06-25', NULL),
	(193, 193, 'fixed', 225000.00, NULL, NULL, 'CNY', '2024-11-27', NULL),
	(194, 194, 'fixed', 192000.00, NULL, NULL, 'CNY', '2025-03-24', NULL),
	(195, 195, 'fixed', 410000.00, NULL, NULL, 'CNY', '2026-04-05', NULL),
	(196, 196, 'hourly', NULL, 1200.00, NULL, 'CNY', '2026-08-08', NULL),
	(197, 197, 'fixed', 363000.00, NULL, NULL, 'CNY', '2025-12-08', NULL),
	(198, 198, 'contingency', NULL, NULL, 20.00, 'CNY', '2024-03-22', NULL),
	(199, 199, 'contingency', NULL, NULL, 15.00, 'CNY', '2025-01-20', NULL),
	(200, 200, 'fixed', 169000.00, NULL, NULL, 'CNY', '2025-06-23', NULL);
INSERT INTO public.fee_agreement VALUES
	(201, 201, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-12-01', NULL),
	(202, 202, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-01-31', NULL),
	(203, 203, 'fixed', 384000.00, NULL, NULL, 'CNY', '2025-05-12', NULL),
	(204, 204, 'contingency', NULL, NULL, 20.00, 'CNY', '2025-05-15', NULL),
	(205, 205, 'fixed', 255000.00, NULL, NULL, 'CNY', '2025-07-22', NULL),
	(206, 206, 'hourly', NULL, 1200.00, NULL, 'CNY', '2025-06-04', NULL),
	(207, 207, 'hourly', NULL, 1800.00, NULL, 'CNY', '2026-07-04', NULL),
	(208, 208, 'fixed', 271000.00, NULL, NULL, 'CNY', '2026-04-17', NULL),
	(209, 209, 'fixed', 167000.00, NULL, NULL, 'CNY', '2025-02-02', NULL),
	(210, 210, 'contingency', NULL, NULL, 20.00, 'CNY', '2026-03-16', NULL),
	(211, 211, 'hourly', NULL, 1200.00, NULL, 'CNY', '2024-10-30', NULL),
	(212, 212, 'mixed', 102000.00, 1200.00, NULL, 'CNY', '2025-04-16', NULL),
	(213, 213, 'fixed', 34000.00, NULL, NULL, 'CNY', '2024-09-09', NULL),
	(214, 214, 'fixed', 66000.00, NULL, NULL, 'CNY', '2024-09-27', NULL);


--
-- Data for Name: invoice; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.invoice VALUES
	(1, 1, 'INV-k1', '2026-04-01', NULL, 120000.00, 'paid', NULL),
	(2, 2, 'INV-k2', '2026-04-01', NULL, 80000.00, 'paid', NULL),
	(3, 3, 'INV-k3', '2026-04-01', NULL, 300000.00, 'paid', NULL),
	(4, 4, 'INV-k4', '2026-04-01', NULL, 30000.00, 'paid', NULL),
	(5, 5, 'INV-k5', '2026-04-01', NULL, 200000.00, 'paid', NULL),
	(6, 6, 'INV-k6', '2026-04-01', NULL, 150000.00, 'paid', NULL),
	(7, 7, 'INV-0007-1', '2026-08-14', '2026-09-13', 159500.00, 'paid', NULL),
	(8, 7, 'INV-0007-2', '2026-09-17', '2026-10-17', 159500.00, 'issued', NULL),
	(9, 8, 'INV-0008-1', '2024-03-09', '2024-04-08', 99600.00, 'paid', NULL),
	(10, 8, 'INV-0008-2', '2024-03-25', '2024-04-24', 132800.00, 'paid', NULL),
	(11, 8, 'INV-0008-3', '2024-04-11', '2024-05-11', 99600.00, 'paid', NULL),
	(12, 9, 'INV-0009-1', '2024-06-01', '2024-07-01', 29400.00, 'paid', NULL),
	(13, 9, 'INV-0009-2', '2024-07-01', '2024-07-31', 60000.00, 'paid', NULL),
	(14, 9, 'INV-0009-3', '2024-08-01', '2024-08-31', 76800.00, 'paid', NULL),
	(15, 9, 'INV-0009-4', '2024-09-01', '2024-10-01', 14700.00, 'paid', NULL),
	(16, 9, 'INV-0009-5', '2024-10-01', '2024-10-31', 51000.00, 'paid', NULL),
	(17, 10, 'INV-0010-1', '2026-08-28', '2026-09-27', 179000.00, 'paid', NULL),
	(18, 11, 'INV-0011-1', '2024-01-12', '2024-02-11', 91000.00, 'paid', NULL),
	(19, 12, 'INV-0012-1', '2024-09-01', '2024-10-01', 14700.00, 'paid', NULL),
	(20, 12, 'INV-0012-2', '2024-10-01', '2024-10-31', 47400.00, 'paid', NULL),
	(21, 13, 'INV-0013-1', '2025-07-01', '2025-07-31', 13200.00, 'issued', NULL),
	(22, 13, 'INV-0013-2', '2025-08-01', '2025-08-31', 20400.00, 'issued', NULL),
	(23, 13, 'INV-0013-3', '2025-09-01', '2025-10-01', 15000.00, 'paid', NULL),
	(24, 14, 'INV-0014-1', '2024-09-09', '2024-10-09', 60300.00, 'paid', NULL),
	(25, 14, 'INV-0014-2', '2024-11-29', '2024-12-29', 80400.00, 'paid', NULL),
	(26, 14, 'INV-0014-3', '2025-02-18', '2025-03-20', 60300.00, 'issued', NULL),
	(27, 15, 'INV-0015-1', '2025-11-01', '2025-12-01', 41100.00, 'paid', NULL),
	(28, 15, 'INV-0015-2', '2025-12-01', '2025-12-31', 16800.00, 'paid', NULL),
	(29, 15, 'INV-0015-3', '2026-01-01', '2026-01-31', 69300.00, 'paid', NULL),
	(30, 15, 'INV-0015-4', '2026-02-01', '2026-03-03', 41700.00, 'paid', NULL),
	(31, 15, 'INV-0015-5', '2026-03-01', '2026-03-31', 73800.00, 'paid', NULL),
	(32, 16, 'INV-0016-1', '2026-03-01', '2026-03-31', 10500.00, 'issued', NULL),
	(33, 16, 'INV-0016-2', '2026-04-01', '2026-05-01', 30600.00, 'paid', NULL),
	(34, 16, 'INV-0016-3', '2026-05-01', '2026-05-31', 13800.00, 'paid', NULL),
	(35, 16, 'INV-0016-4', '2026-06-01', '2026-07-01', 30600.00, 'paid', NULL),
	(36, 17, 'INV-0017-1', '2025-04-20', '2025-05-20', 204500.00, 'issued', NULL),
	(37, 17, 'INV-0017-2', '2025-06-22', '2025-07-22', 204500.00, 'paid', NULL),
	(38, 18, 'INV-0018-1', '2024-11-01', '2024-12-01', 25800.00, 'paid', NULL),
	(39, 18, 'INV-0018-2', '2024-12-01', '2024-12-31', 23100.00, 'paid', NULL),
	(40, 18, 'INV-0018-3', '2025-01-01', '2025-01-31', 29700.00, 'partial', NULL),
	(41, 19, 'INV-0019-1', '2025-04-01', '2025-05-01', 18900.00, 'paid', NULL),
	(42, 19, 'INV-0019-2', '2025-05-01', '2025-05-31', 4500.00, 'issued', NULL),
	(43, 19, 'INV-0019-3', '2025-06-01', '2025-07-01', 12600.00, 'paid', NULL),
	(44, 19, 'INV-0019-4', '2025-07-01', '2025-07-31', 7200.00, 'paid', NULL),
	(45, 19, 'INV-0019-5', '2025-08-01', '2025-08-31', 22500.00, 'paid', NULL),
	(46, 19, 'INV-0019-6', '2025-09-01', '2025-10-01', 3600.00, 'paid', NULL),
	(47, 19, 'INV-0019-7', '2025-10-01', '2025-10-31', 18900.00, 'paid', NULL),
	(48, 19, 'INV-0019-8', '2025-11-01', '2025-12-01', 8100.00, 'paid', NULL),
	(49, 19, 'INV-0019-9', '2025-12-01', '2025-12-31', 22500.00, 'paid', NULL),
	(50, 20, 'INV-0020-1', '2025-01-19', '2025-02-18', 160000.00, 'paid', NULL),
	(51, 21, 'INV-0021-1', '2024-03-24', '2024-04-23', 98100.00, 'paid', NULL),
	(52, 21, 'INV-0021-2', '2024-05-24', '2024-06-23', 130800.00, 'paid', NULL),
	(53, 21, 'INV-0021-3', '2024-07-25', '2024-08-24', 98100.00, 'paid', NULL),
	(54, 22, 'INV-0022-1', '2024-09-02', '2024-10-02', 128000.00, 'paid', NULL),
	(55, 23, 'INV-0023-1', '2025-02-01', '2025-03-03', 10800.00, 'paid', NULL),
	(56, 23, 'INV-0023-2', '2025-03-01', '2025-03-31', 21600.00, 'paid', NULL),
	(57, 23, 'INV-0023-3', '2025-04-01', '2025-05-01', 8400.00, 'issued', NULL),
	(58, 23, 'INV-0023-4', '2025-05-01', '2025-05-31', 4800.00, 'paid', NULL),
	(59, 23, 'INV-0023-5', '2025-06-01', '2025-07-01', 8400.00, 'paid', NULL),
	(60, 25, 'INV-0025-1', '2025-11-23', '2025-12-23', 25500.00, 'paid', NULL),
	(61, 25, 'INV-0025-2', '2026-03-05', '2026-04-04', 25500.00, 'paid', NULL),
	(62, 26, 'INV-0026-1', '2026-06-14', '2026-07-14', 19500.00, 'paid', NULL),
	(63, 26, 'INV-0026-2', '2026-06-29', '2026-07-29', 19500.00, 'paid', NULL),
	(64, 28, 'INV-0028-1', '2026-05-17', '2026-06-16', 563000.00, 'paid', NULL),
	(65, 29, 'INV-0029-1', '2025-02-05', '2025-03-07', 137000.00, 'paid', NULL),
	(66, 30, 'INV-0030-1', '2026-05-25', '2026-06-24', 38000.00, 'paid', NULL),
	(67, 31, 'INV-0031-1', '2026-07-01', '2026-07-31', 4800.00, 'paid', NULL),
	(68, 31, 'INV-0031-2', '2026-08-01', '2026-08-31', 8400.00, 'paid', NULL),
	(69, 31, 'INV-0031-3', '2026-09-01', '2026-10-01', 5400.00, 'issued', NULL),
	(70, 32, 'INV-0032-1', '2024-08-01', '2024-08-31', 28800.00, 'paid', NULL),
	(71, 32, 'INV-0032-2', '2024-09-01', '2024-10-01', 43200.00, 'paid', NULL),
	(72, 32, 'INV-0032-3', '2024-10-01', '2024-10-31', 40500.00, 'paid', NULL),
	(73, 32, 'INV-0032-4', '2024-11-01', '2024-12-01', 35100.00, 'issued', NULL),
	(74, 32, 'INV-0032-5', '2024-12-01', '2024-12-31', 10800.00, 'paid', NULL),
	(75, 33, 'INV-0033-1', '2025-02-28', '2025-03-30', 257500.00, 'paid', NULL),
	(76, 33, 'INV-0033-2', '2025-05-15', '2025-06-14', 257500.00, 'issued', NULL),
	(77, 34, 'INV-0034-1', '2025-04-19', '2025-05-19', 67200.00, 'paid', NULL),
	(78, 34, 'INV-0034-2', '2025-05-14', '2025-06-13', 89600.00, 'paid', NULL),
	(79, 34, 'INV-0034-3', '2025-06-08', '2025-07-08', 67200.00, 'paid', NULL),
	(80, 35, 'INV-0035-1', '2025-05-10', '2025-06-09', 6000.00, 'paid', NULL),
	(81, 35, 'INV-0035-2', '2025-09-09', '2025-10-09', 8000.00, 'paid', NULL),
	(82, 35, 'INV-0035-3', '2026-01-09', '2026-02-08', 6000.00, 'paid', NULL),
	(83, 36, 'INV-0036-1', '2024-12-21', '2025-01-20', 15600.00, 'paid', NULL),
	(84, 36, 'INV-0036-2', '2025-01-10', '2025-02-09', 20800.00, 'paid', NULL),
	(85, 36, 'INV-0036-3', '2025-01-30', '2025-03-01', 15600.00, 'paid', NULL),
	(86, 37, 'INV-0037-1', '2025-10-29', '2025-11-28', 110000.00, 'paid', NULL),
	(87, 37, 'INV-0037-2', '2026-04-25', '2026-05-25', 110000.00, 'paid', NULL),
	(88, 38, 'INV-0038-1', '2025-10-15', '2025-11-14', 76000.00, 'paid', NULL),
	(89, 38, 'INV-0038-2', '2025-11-06', '2025-12-06', 76000.00, 'paid', NULL),
	(90, 39, 'INV-0039-1', '2025-03-13', '2025-04-12', 40200.00, 'paid', NULL),
	(91, 39, 'INV-0039-2', '2025-07-21', '2025-08-20', 53600.00, 'paid', NULL),
	(92, 39, 'INV-0039-3', '2025-11-28', '2025-12-28', 40200.00, 'paid', NULL),
	(93, 40, 'INV-0040-1', '2025-07-01', '2025-07-31', 13500.00, 'paid', NULL),
	(94, 40, 'INV-0040-2', '2025-08-01', '2025-08-31', 14400.00, 'paid', NULL),
	(95, 40, 'INV-0040-3', '2025-09-01', '2025-10-01', 26100.00, 'partial', NULL),
	(96, 40, 'INV-0040-4', '2025-10-01', '2025-10-31', 9900.00, 'paid', NULL),
	(97, 40, 'INV-0040-5', '2025-11-01', '2025-12-01', 10800.00, 'paid', NULL),
	(98, 41, 'INV-0041-1', '2026-07-10', '2026-08-09', 30500.00, 'paid', NULL),
	(99, 41, 'INV-0041-2', '2026-08-30', '2026-09-29', 30500.00, 'paid', NULL),
	(100, 42, 'INV-0042-1', '2024-10-01', '2024-10-31', 17400.00, 'paid', NULL),
	(101, 42, 'INV-0042-2', '2024-11-01', '2024-12-01', 14400.00, 'paid', NULL),
	(102, 42, 'INV-0042-3', '2024-12-01', '2024-12-31', 16200.00, 'paid', NULL),
	(103, 42, 'INV-0042-4', '2025-01-01', '2025-01-31', 7200.00, 'paid', NULL),
	(104, 42, 'INV-0042-5', '2025-02-01', '2025-03-03', 7200.00, 'paid', NULL),
	(105, 42, 'INV-0042-6', '2025-03-01', '2025-03-31', 6000.00, 'paid', NULL),
	(106, 42, 'INV-0042-7', '2025-04-01', '2025-05-01', 13200.00, 'issued', NULL),
	(107, 42, 'INV-0042-8', '2025-05-01', '2025-05-31', 7200.00, 'paid', NULL),
	(108, 42, 'INV-0042-9', '2025-06-01', '2025-07-01', 16800.00, 'paid', NULL),
	(109, 42, 'INV-0042-10', '2025-07-01', '2025-07-31', 3000.00, 'paid', NULL),
	(110, 42, 'INV-0042-11', '2025-08-01', '2025-08-31', 6600.00, 'issued', NULL),
	(111, 42, 'INV-0042-12', '2025-09-01', '2025-10-01', 4800.00, 'paid', NULL),
	(112, 42, 'INV-0042-13', '2025-10-01', '2025-10-31', 19800.00, 'paid', NULL),
	(113, 42, 'INV-0042-14', '2025-11-01', '2025-12-01', 17400.00, 'paid', NULL),
	(114, 43, 'INV-0043-1', '2026-04-01', '2026-05-01', 74400.00, 'paid', NULL),
	(115, 43, 'INV-0043-2', '2026-05-01', '2026-05-31', 24300.00, 'paid', NULL),
	(116, 43, 'INV-0043-3', '2026-06-01', '2026-07-01', 33600.00, 'partial', NULL),
	(117, 43, 'INV-0043-4', '2026-07-01', '2026-07-31', 74700.00, 'paid', NULL),
	(118, 43, 'INV-0043-5', '2026-08-01', '2026-08-31', 18900.00, 'paid', NULL),
	(119, 43, 'INV-0043-6', '2026-09-01', '2026-10-01', 28200.00, 'paid', NULL),
	(120, 43, 'INV-0043-7', '2026-10-01', '2026-10-31', 15900.00, 'issued', NULL),
	(121, 43, 'INV-0043-8', '2026-10-18', '2026-11-17', 51600.00, 'issued', NULL),
	(122, 44, 'INV-0044-1', '2024-12-01', '2024-12-31', 34500.00, 'paid', NULL),
	(123, 44, 'INV-0044-2', '2025-01-01', '2025-01-31', 58800.00, 'partial', NULL),
	(124, 44, 'INV-0044-3', '2025-02-01', '2025-03-03', 48300.00, 'paid', NULL),
	(125, 44, 'INV-0044-4', '2025-03-01', '2025-03-31', 31800.00, 'paid', NULL),
	(126, 44, 'INV-0044-5', '2025-04-01', '2025-05-01', 35400.00, 'paid', NULL),
	(127, 44, 'INV-0044-6', '2025-05-01', '2025-05-31', 10800.00, 'paid', NULL),
	(128, 44, 'INV-0044-7', '2025-06-01', '2025-07-01', 57900.00, 'paid', NULL),
	(129, 44, 'INV-0044-8', '2025-07-01', '2025-07-31', 36300.00, 'paid', NULL),
	(130, 44, 'INV-0044-9', '2025-08-01', '2025-08-31', 52200.00, 'paid', NULL),
	(131, 44, 'INV-0044-10', '2025-09-01', '2025-10-01', 64200.00, 'paid', NULL),
	(132, 44, 'INV-0044-11', '2025-10-01', '2025-10-31', 50100.00, 'paid', NULL),
	(133, 44, 'INV-0044-12', '2025-11-01', '2025-12-01', 32100.00, 'paid', NULL),
	(134, 44, 'INV-0044-13', '2025-12-01', '2025-12-31', 34200.00, 'paid', NULL),
	(135, 44, 'INV-0044-14', '2026-01-01', '2026-01-31', 26700.00, 'partial', NULL),
	(136, 45, 'INV-0045-1', '2026-10-13', '2026-11-12', 38000.00, 'issued', NULL),
	(137, 46, 'INV-0046-1', '2025-02-01', '2025-03-03', 33900.00, 'paid', NULL),
	(138, 46, 'INV-0046-2', '2025-03-01', '2025-03-31', 30000.00, 'paid', NULL),
	(139, 46, 'INV-0046-3', '2025-04-01', '2025-05-01', 37800.00, 'paid', NULL),
	(140, 46, 'INV-0046-4', '2025-05-01', '2025-05-31', 45300.00, 'paid', NULL),
	(141, 47, 'INV-0047-1', '2026-01-01', '2026-01-31', 6600.00, 'paid', NULL),
	(142, 47, 'INV-0047-2', '2026-02-01', '2026-03-03', 4200.00, 'paid', NULL),
	(143, 47, 'INV-0047-3', '2026-03-01', '2026-03-31', 13200.00, 'paid', NULL),
	(144, 47, 'INV-0047-4', '2026-04-01', '2026-05-01', 14400.00, 'paid', NULL),
	(145, 47, 'INV-0047-5', '2026-05-01', '2026-05-31', 13200.00, 'paid', NULL),
	(146, 47, 'INV-0047-6', '2026-06-01', '2026-07-01', 4200.00, 'paid', NULL),
	(147, 47, 'INV-0047-7', '2026-07-01', '2026-07-31', 7800.00, 'partial', NULL),
	(148, 47, 'INV-0047-8', '2026-08-01', '2026-08-31', 6000.00, 'paid', NULL),
	(149, 47, 'INV-0047-9', '2026-09-01', '2026-10-01', 9000.00, 'paid', NULL),
	(150, 47, 'INV-0047-10', '2026-10-01', '2026-10-31', 22800.00, 'issued', NULL),
	(151, 48, 'INV-0048-1', '2026-04-01', '2026-05-01', 14400.00, 'paid', NULL),
	(152, 48, 'INV-0048-2', '2026-05-01', '2026-05-31', 9900.00, 'paid', NULL),
	(153, 48, 'INV-0048-3', '2026-06-01', '2026-07-01', 17100.00, 'paid', NULL),
	(154, 48, 'INV-0048-4', '2026-07-01', '2026-07-31', 8100.00, 'paid', NULL),
	(155, 48, 'INV-0048-5', '2026-08-01', '2026-08-31', 16200.00, 'paid', NULL),
	(156, 48, 'INV-0048-6', '2026-09-01', '2026-10-01', 3600.00, 'issued', NULL),
	(157, 48, 'INV-0048-7', '2026-10-01', '2026-10-31', 7200.00, 'issued', NULL),
	(158, 48, 'INV-0048-8', '2026-10-18', '2026-11-17', 13500.00, 'issued', NULL),
	(159, 49, 'INV-0049-1', '2026-10-18', '2026-11-17', 64500.00, 'issued', NULL),
	(160, 50, 'INV-0050-1', '2025-05-01', '2025-05-31', 27000.00, 'paid', NULL),
	(161, 50, 'INV-0050-2', '2025-06-01', '2025-07-01', 12600.00, 'paid', NULL),
	(162, 50, 'INV-0050-3', '2025-07-01', '2025-07-31', 26100.00, 'paid', NULL),
	(163, 50, 'INV-0050-4', '2025-08-01', '2025-08-31', 17100.00, 'paid', NULL),
	(164, 50, 'INV-0050-5', '2025-09-01', '2025-10-01', 8100.00, 'paid', NULL),
	(165, 50, 'INV-0050-6', '2025-10-01', '2025-10-31', 12600.00, 'paid', NULL),
	(166, 51, 'INV-0051-1', '2025-03-01', '2025-03-31', 23100.00, 'paid', NULL),
	(167, 51, 'INV-0051-2', '2025-04-01', '2025-05-01', 15000.00, 'paid', NULL),
	(168, 51, 'INV-0051-3', '2025-05-01', '2025-05-31', 6900.00, 'paid', NULL),
	(169, 51, 'INV-0051-4', '2025-06-01', '2025-07-01', 42600.00, 'paid', NULL),
	(170, 51, 'INV-0051-5', '2025-07-01', '2025-07-31', 15300.00, 'paid', NULL),
	(171, 51, 'INV-0051-6', '2025-08-01', '2025-08-31', 12600.00, 'paid', NULL),
	(172, 51, 'INV-0051-7', '2025-09-01', '2025-10-01', 27900.00, 'paid', NULL),
	(173, 52, 'INV-0052-1', '2025-07-01', '2025-07-31', 68700.00, 'partial', NULL),
	(174, 52, 'INV-0052-2', '2025-08-01', '2025-08-31', 48600.00, 'paid', NULL),
	(175, 52, 'INV-0052-3', '2025-09-01', '2025-10-01', 45000.00, 'paid', NULL),
	(176, 52, 'INV-0052-4', '2025-10-01', '2025-10-31', 46200.00, 'paid', NULL),
	(177, 52, 'INV-0052-5', '2025-11-01', '2025-12-01', 52800.00, 'paid', NULL),
	(178, 52, 'INV-0052-6', '2025-12-01', '2025-12-31', 55500.00, 'paid', NULL),
	(179, 53, 'INV-0053-1', '2026-07-13', '2026-08-12', 14000.00, 'paid', NULL),
	(180, 53, 'INV-0053-2', '2026-09-01', '2026-10-01', 14000.00, 'paid', NULL),
	(181, 54, 'INV-0054-1', '2026-10-18', '2026-11-17', 289000.00, 'issued', NULL),
	(182, 55, 'INV-0055-1', '2024-05-31', '2024-06-30', 29500.00, 'partial', NULL),
	(183, 55, 'INV-0055-2', '2025-02-21', '2025-03-23', 29500.00, 'partial', NULL),
	(184, 56, 'INV-0056-1', '2024-06-01', '2024-07-01', 7200.00, 'issued', NULL),
	(185, 56, 'INV-0056-2', '2024-07-01', '2024-07-31', 9900.00, 'partial', NULL),
	(186, 56, 'INV-0056-3', '2024-08-01', '2024-08-31', 14400.00, 'paid', NULL),
	(187, 57, 'INV-0057-1', '2026-05-01', '2026-05-31', 13200.00, 'partial', NULL),
	(188, 57, 'INV-0057-2', '2026-06-01', '2026-07-01', 6000.00, 'paid', NULL),
	(189, 57, 'INV-0057-3', '2026-07-01', '2026-07-31', 8400.00, 'paid', NULL),
	(190, 57, 'INV-0057-4', '2026-08-01', '2026-08-31', 11400.00, 'paid', NULL),
	(191, 57, 'INV-0057-5', '2026-09-01', '2026-10-01', 6000.00, 'paid', NULL),
	(192, 57, 'INV-0057-6', '2026-10-01', '2026-10-31', 13200.00, 'issued', NULL),
	(193, 57, 'INV-0057-7', '2026-10-18', '2026-11-17', 16800.00, 'issued', NULL),
	(194, 58, 'INV-0058-1', '2025-07-25', '2025-08-24', 80000.00, 'partial', NULL),
	(195, 58, 'INV-0058-2', '2025-08-10', '2025-09-09', 80000.00, 'paid', NULL),
	(196, 59, 'INV-0059-1', '2025-12-29', '2026-01-28', 387000.00, 'paid', NULL),
	(197, 61, 'INV-0061-1', '2026-10-01', '2026-10-31', 49500.00, 'paid', NULL),
	(198, 61, 'INV-0061-2', '2026-10-18', '2026-11-17', 24300.00, 'issued', NULL),
	(199, 62, 'INV-0062-1', '2025-10-01', '2025-10-31', 9000.00, 'paid', NULL),
	(200, 62, 'INV-0062-2', '2025-11-01', '2025-12-01', 36600.00, 'issued', NULL);
INSERT INTO public.invoice VALUES
	(201, 62, 'INV-0062-3', '2025-12-01', '2025-12-31', 9000.00, 'issued', NULL),
	(202, 62, 'INV-0062-4', '2026-01-01', '2026-01-31', 16200.00, 'paid', NULL),
	(203, 62, 'INV-0062-5', '2026-02-01', '2026-03-03', 25500.00, 'paid', NULL),
	(204, 62, 'INV-0062-6', '2026-03-01', '2026-03-31', 44700.00, 'paid', NULL),
	(205, 63, 'INV-0063-1', '2024-03-09', '2024-04-08', 15600.00, 'paid', NULL),
	(206, 63, 'INV-0063-2', '2024-04-11', '2024-05-11', 20800.00, 'paid', NULL),
	(207, 63, 'INV-0063-3', '2024-05-14', '2024-06-13', 15600.00, 'paid', NULL),
	(208, 64, 'INV-0064-1', '2024-11-25', '2024-12-25', 43800.00, 'issued', NULL),
	(209, 64, 'INV-0064-2', '2025-03-01', '2025-03-31', 58400.00, 'paid', NULL),
	(210, 64, 'INV-0064-3', '2025-06-05', '2025-07-05', 43800.00, 'paid', NULL),
	(211, 65, 'INV-0065-1', '2025-10-30', '2025-11-29', 29000.00, 'paid', NULL),
	(212, 65, 'INV-0065-2', '2026-03-16', '2026-04-15', 29000.00, 'paid', NULL),
	(213, 66, 'INV-0066-1', '2026-09-01', '2026-10-01', 9000.00, 'issued', NULL),
	(214, 66, 'INV-0066-2', '2026-10-01', '2026-10-31', 17400.00, 'issued', NULL),
	(215, 66, 'INV-0066-3', '2026-10-18', '2026-11-17', 15600.00, 'issued', NULL),
	(216, 67, 'INV-0067-1', '2024-11-01', '2024-12-01', 18900.00, 'paid', NULL),
	(217, 67, 'INV-0067-2', '2024-12-01', '2024-12-31', 11700.00, 'paid', NULL),
	(218, 67, 'INV-0067-3', '2025-01-01', '2025-01-31', 21600.00, 'paid', NULL),
	(219, 67, 'INV-0067-4', '2025-02-01', '2025-03-03', 17100.00, 'paid', NULL),
	(220, 67, 'INV-0067-5', '2025-03-01', '2025-03-31', 9000.00, 'issued', NULL),
	(221, 67, 'INV-0067-6', '2025-04-01', '2025-05-01', 7200.00, 'paid', NULL),
	(222, 67, 'INV-0067-7', '2025-05-01', '2025-05-31', 34200.00, 'paid', NULL),
	(223, 68, 'INV-0068-1', '2025-08-01', '2025-08-31', 6000.00, 'paid', NULL),
	(224, 68, 'INV-0068-2', '2025-09-01', '2025-10-01', 3000.00, 'paid', NULL),
	(225, 68, 'INV-0068-3', '2025-10-01', '2025-10-31', 10800.00, 'paid', NULL),
	(226, 68, 'INV-0068-4', '2025-11-01', '2025-12-01', 14400.00, 'paid', NULL),
	(227, 68, 'INV-0068-5', '2025-12-01', '2025-12-31', 6600.00, 'paid', NULL),
	(228, 68, 'INV-0068-6', '2026-01-01', '2026-01-31', 12600.00, 'paid', NULL),
	(229, 68, 'INV-0068-7', '2026-02-01', '2026-03-03', 12000.00, 'paid', NULL),
	(230, 68, 'INV-0068-8', '2026-03-01', '2026-03-31', 12000.00, 'paid', NULL),
	(231, 68, 'INV-0068-9', '2026-04-01', '2026-05-01', 16200.00, 'paid', NULL),
	(232, 68, 'INV-0068-10', '2026-05-01', '2026-05-31', 8400.00, 'paid', NULL),
	(233, 68, 'INV-0068-11', '2026-06-01', '2026-07-01', 1200.00, 'paid', NULL),
	(234, 68, 'INV-0068-12', '2026-07-01', '2026-07-31', 7800.00, 'paid', NULL),
	(235, 68, 'INV-0068-13', '2026-08-01', '2026-08-31', 7800.00, 'paid', NULL),
	(236, 68, 'INV-0068-14', '2026-09-01', '2026-10-01', 4800.00, 'paid', NULL),
	(237, 68, 'INV-0068-15', '2026-10-01', '2026-10-31', 7800.00, 'issued', NULL),
	(238, 69, 'INV-0069-1', '2024-09-25', '2024-10-25', 103000.00, 'paid', NULL),
	(239, 69, 'INV-0069-2', '2025-04-13', '2025-05-13', 103000.00, 'paid', NULL),
	(240, 70, 'INV-0070-1', '2025-01-12', '2025-02-11', 39600.00, 'paid', NULL),
	(241, 70, 'INV-0070-2', '2025-05-27', '2025-06-26', 52800.00, 'paid', NULL),
	(242, 70, 'INV-0070-3', '2025-10-09', '2025-11-08', 39600.00, 'paid', NULL),
	(243, 71, 'INV-0071-1', '2026-09-01', '2026-10-01', 82200.00, 'issued', NULL),
	(244, 71, 'INV-0071-2', '2026-10-01', '2026-10-31', 60900.00, 'issued', NULL),
	(245, 71, 'INV-0071-3', '2026-10-18', '2026-11-17', 26700.00, 'issued', NULL),
	(246, 72, 'INV-0072-1', '2026-07-01', '2026-07-31', 18300.00, 'paid', NULL),
	(247, 72, 'INV-0072-2', '2026-08-01', '2026-08-31', 73200.00, 'issued', NULL),
	(248, 72, 'INV-0072-3', '2026-09-01', '2026-10-01', 13500.00, 'issued', NULL),
	(249, 72, 'INV-0072-4', '2026-10-01', '2026-10-31', 25500.00, 'issued', NULL),
	(250, 72, 'INV-0072-5', '2026-10-18', '2026-11-17', 85500.00, 'issued', NULL),
	(251, 73, 'INV-0073-1', '2026-10-01', '2026-10-31', 55500.00, 'issued', NULL),
	(252, 73, 'INV-0073-2', '2026-10-07', '2026-11-06', 74000.00, 'issued', NULL),
	(253, 73, 'INV-0073-3', '2026-10-14', '2026-11-13', 55500.00, 'issued', NULL),
	(254, 74, 'INV-0074-1', '2024-11-15', '2024-12-15', 246000.00, 'paid', NULL),
	(255, 74, 'INV-0074-2', '2025-03-07', '2025-04-06', 246000.00, 'issued', NULL),
	(256, 75, 'INV-0075-1', '2025-08-31', '2025-09-30', 649000.00, 'partial', NULL),
	(257, 76, 'INV-0076-1', '2025-03-05', '2025-04-04', 33600.00, 'paid', NULL),
	(258, 76, 'INV-0076-2', '2025-03-12', '2025-04-11', 44800.00, 'paid', NULL),
	(259, 76, 'INV-0076-3', '2025-03-19', '2025-04-18', 33600.00, 'paid', NULL),
	(260, 77, 'INV-0077-1', '2025-03-31', '2025-04-30', 102000.00, 'paid', NULL),
	(261, 78, 'INV-0078-1', '2025-09-11', '2025-10-11', 99000.00, 'paid', NULL),
	(262, 79, 'INV-0079-1', '2026-01-01', '2026-01-31', 27000.00, 'paid', NULL),
	(263, 79, 'INV-0079-2', '2026-02-01', '2026-03-03', 26100.00, 'paid', NULL),
	(264, 79, 'INV-0079-3', '2026-03-01', '2026-03-31', 6300.00, 'paid', NULL),
	(265, 79, 'INV-0079-4', '2026-04-01', '2026-05-01', 9000.00, 'paid', NULL),
	(266, 79, 'INV-0079-5', '2026-05-01', '2026-05-31', 20700.00, 'paid', NULL),
	(267, 79, 'INV-0079-6', '2026-06-01', '2026-07-01', 7200.00, 'paid', NULL),
	(268, 79, 'INV-0079-7', '2026-07-01', '2026-07-31', 36900.00, 'paid', NULL),
	(269, 79, 'INV-0079-8', '2026-08-01', '2026-08-31', 14400.00, 'paid', NULL),
	(270, 79, 'INV-0079-9', '2026-09-01', '2026-10-01', 11700.00, 'issued', NULL),
	(271, 79, 'INV-0079-10', '2026-10-01', '2026-10-31', 5400.00, 'issued', NULL),
	(272, 79, 'INV-0079-11', '2026-10-18', '2026-11-17', 7200.00, 'issued', NULL),
	(273, 80, 'INV-0080-1', '2024-09-01', '2024-10-01', 13500.00, 'partial', NULL),
	(274, 80, 'INV-0080-2', '2024-10-01', '2024-10-31', 10800.00, 'paid', NULL),
	(275, 80, 'INV-0080-3', '2024-11-01', '2024-12-01', 23400.00, 'paid', NULL),
	(276, 80, 'INV-0080-4', '2024-12-01', '2024-12-31', 11700.00, 'paid', NULL),
	(277, 80, 'INV-0080-5', '2025-01-01', '2025-01-31', 27900.00, 'paid', NULL),
	(278, 80, 'INV-0080-6', '2025-02-01', '2025-03-03', 7200.00, 'paid', NULL),
	(279, 80, 'INV-0080-7', '2025-03-01', '2025-03-31', 12600.00, 'partial', NULL),
	(280, 80, 'INV-0080-8', '2025-04-01', '2025-05-01', 23400.00, 'paid', NULL),
	(281, 80, 'INV-0080-9', '2025-05-01', '2025-05-31', 12600.00, 'paid', NULL),
	(282, 80, 'INV-0080-10', '2025-06-01', '2025-07-01', 17100.00, 'paid', NULL),
	(283, 80, 'INV-0080-11', '2025-07-01', '2025-07-31', 21600.00, 'paid', NULL),
	(284, 80, 'INV-0080-12', '2025-08-01', '2025-08-31', 17100.00, 'paid', NULL),
	(285, 80, 'INV-0080-13', '2025-09-01', '2025-10-01', 13500.00, 'paid', NULL),
	(286, 80, 'INV-0080-14', '2025-10-01', '2025-10-31', 21600.00, 'paid', NULL),
	(287, 80, 'INV-0080-15', '2025-11-01', '2025-12-01', 18000.00, 'paid', NULL),
	(288, 80, 'INV-0080-16', '2025-12-01', '2025-12-31', 23400.00, 'issued', NULL),
	(289, 80, 'INV-0080-17', '2026-01-01', '2026-01-31', 15300.00, 'paid', NULL),
	(290, 80, 'INV-0080-18', '2026-02-01', '2026-03-03', 10800.00, 'paid', NULL),
	(291, 81, 'INV-0081-1', '2025-10-23', '2025-11-22', 220000.00, 'paid', NULL),
	(292, 82, 'INV-0082-1', '2025-09-01', '2025-10-01', 22200.00, 'paid', NULL),
	(293, 82, 'INV-0082-2', '2025-10-01', '2025-10-31', 30600.00, 'paid', NULL),
	(294, 82, 'INV-0082-3', '2025-11-01', '2025-12-01', 17400.00, 'paid', NULL),
	(295, 82, 'INV-0082-4', '2025-12-01', '2025-12-31', 29400.00, 'issued', NULL),
	(296, 82, 'INV-0082-5', '2026-01-01', '2026-01-31', 24000.00, 'paid', NULL),
	(297, 82, 'INV-0082-6', '2026-02-01', '2026-03-03', 36600.00, 'paid', NULL),
	(298, 82, 'INV-0082-7', '2026-03-01', '2026-03-31', 15600.00, 'paid', NULL),
	(299, 82, 'INV-0082-8', '2026-04-01', '2026-05-01', 27000.00, 'paid', NULL),
	(300, 82, 'INV-0082-9', '2026-05-01', '2026-05-31', 9000.00, 'paid', NULL),
	(301, 82, 'INV-0082-10', '2026-06-01', '2026-07-01', 10800.00, 'paid', NULL),
	(302, 82, 'INV-0082-11', '2026-07-01', '2026-07-31', 16200.00, 'paid', NULL),
	(303, 82, 'INV-0082-12', '2026-08-01', '2026-08-31', 24000.00, 'paid', NULL),
	(304, 82, 'INV-0082-13', '2026-09-01', '2026-10-01', 9600.00, 'issued', NULL),
	(305, 82, 'INV-0082-14', '2026-10-01', '2026-10-31', 27600.00, 'partial', NULL),
	(306, 82, 'INV-0082-15', '2026-10-18', '2026-11-17', 7200.00, 'issued', NULL),
	(307, 83, 'INV-0083-1', '2024-12-01', '2024-12-31', 9000.00, 'issued', NULL),
	(308, 83, 'INV-0083-2', '2025-01-01', '2025-01-31', 16800.00, 'paid', NULL),
	(309, 83, 'INV-0083-3', '2025-02-01', '2025-03-03', 4800.00, 'paid', NULL),
	(310, 84, 'INV-0084-1', '2024-08-03', '2024-09-02', 30500.00, 'paid', NULL),
	(311, 84, 'INV-0084-2', '2024-11-30', '2024-12-30', 30500.00, 'paid', NULL),
	(312, 85, 'INV-0085-1', '2026-07-05', '2026-08-04', 105500.00, 'paid', NULL),
	(313, 85, 'INV-0085-2', '2026-08-27', '2026-09-26', 105500.00, 'issued', NULL),
	(314, 86, 'INV-0086-1', '2024-12-14', '2025-01-13', 27000.00, 'paid', NULL),
	(315, 87, 'INV-0087-1', '2025-03-08', '2025-04-07', 73500.00, 'paid', NULL),
	(316, 87, 'INV-0087-2', '2025-07-02', '2025-08-01', 98000.00, 'paid', NULL),
	(317, 87, 'INV-0087-3', '2025-10-26', '2025-11-25', 73500.00, 'paid', NULL),
	(318, 88, 'INV-0088-1', '2025-11-02', '2025-12-02', 183000.00, 'paid', NULL),
	(319, 88, 'INV-0088-2', '2025-11-09', '2025-12-09', 244000.00, 'partial', NULL),
	(320, 88, 'INV-0088-3', '2025-11-16', '2025-12-16', 183000.00, 'paid', NULL),
	(321, 89, 'INV-0089-1', '2026-04-01', '2026-05-01', 17100.00, 'paid', NULL),
	(322, 89, 'INV-0089-2', '2026-05-01', '2026-05-31', 10800.00, 'paid', NULL),
	(323, 89, 'INV-0089-3', '2026-06-01', '2026-07-01', 10800.00, 'paid', NULL),
	(324, 89, 'INV-0089-4', '2026-07-01', '2026-07-31', 5400.00, 'paid', NULL),
	(325, 89, 'INV-0089-5', '2026-08-01', '2026-08-31', 2700.00, 'paid', NULL),
	(326, 90, 'INV-0090-1', '2026-01-20', '2026-02-19', 204000.00, 'paid', NULL),
	(327, 91, 'INV-0091-1', '2024-12-01', '2024-12-31', 44100.00, 'paid', NULL),
	(328, 91, 'INV-0091-2', '2025-01-01', '2025-01-31', 34500.00, 'paid', NULL),
	(329, 91, 'INV-0091-3', '2025-02-01', '2025-03-03', 38400.00, 'paid', NULL),
	(330, 91, 'INV-0091-4', '2025-03-01', '2025-03-31', 63000.00, 'paid', NULL),
	(331, 91, 'INV-0091-5', '2025-04-01', '2025-05-01', 40200.00, 'paid', NULL),
	(332, 91, 'INV-0091-6', '2025-05-01', '2025-05-31', 48000.00, 'paid', NULL),
	(333, 91, 'INV-0091-7', '2025-06-01', '2025-07-01', 31500.00, 'paid', NULL),
	(334, 91, 'INV-0091-8', '2025-07-01', '2025-07-31', 26700.00, 'paid', NULL),
	(335, 91, 'INV-0091-9', '2025-08-01', '2025-08-31', 33000.00, 'paid', NULL),
	(336, 91, 'INV-0091-10', '2025-09-01', '2025-10-01', 63000.00, 'paid', NULL),
	(337, 93, 'INV-0093-1', '2024-09-26', '2024-10-26', 18000.00, 'paid', NULL),
	(338, 94, 'INV-0094-1', '2025-01-28', '2025-02-27', 189500.00, 'paid', NULL),
	(339, 94, 'INV-0094-2', '2025-08-15', '2025-09-14', 189500.00, 'paid', NULL),
	(340, 95, 'INV-0095-1', '2026-04-06', '2026-05-06', 40500.00, 'paid', NULL),
	(341, 95, 'INV-0095-2', '2026-06-11', '2026-07-11', 54000.00, 'paid', NULL),
	(342, 95, 'INV-0095-3', '2026-08-16', '2026-09-15', 40500.00, 'issued', NULL),
	(343, 96, 'INV-0096-1', '2026-08-25', '2026-09-24', 179000.00, 'issued', NULL),
	(344, 97, 'INV-0097-1', '2024-08-05', '2024-09-04', 119000.00, 'paid', NULL),
	(345, 98, 'INV-0098-1', '2025-11-24', '2025-12-24', 151000.00, 'paid', NULL),
	(346, 98, 'INV-0098-2', '2026-03-16', '2026-04-15', 151000.00, 'paid', NULL),
	(347, 99, 'INV-0099-1', '2026-04-02', '2026-05-02', 16500.00, 'paid', NULL),
	(348, 99, 'INV-0099-2', '2026-04-18', '2026-05-18', 22000.00, 'paid', NULL),
	(349, 99, 'INV-0099-3', '2026-05-04', '2026-06-03', 16500.00, 'paid', NULL),
	(350, 100, 'INV-0100-1', '2024-07-26', '2024-08-25', 130000.00, 'issued', NULL),
	(351, 101, 'INV-0101-1', '2025-01-01', '2025-01-31', 24300.00, 'paid', NULL),
	(352, 101, 'INV-0101-2', '2025-02-01', '2025-03-03', 16200.00, 'paid', NULL),
	(353, 101, 'INV-0101-3', '2025-03-01', '2025-03-31', 12600.00, 'paid', NULL),
	(354, 102, 'INV-0102-1', '2024-08-24', '2024-09-23', 174000.00, 'paid', NULL),
	(355, 102, 'INV-0102-2', '2025-02-10', '2025-03-12', 174000.00, 'paid', NULL),
	(356, 103, 'INV-0103-1', '2024-05-01', '2024-05-31', 24300.00, 'paid', NULL),
	(357, 103, 'INV-0103-2', '2024-06-01', '2024-07-01', 45000.00, 'paid', NULL),
	(358, 103, 'INV-0103-3', '2024-07-01', '2024-07-31', 41100.00, 'paid', NULL),
	(359, 103, 'INV-0103-4', '2024-08-01', '2024-08-31', 37800.00, 'paid', NULL),
	(360, 103, 'INV-0103-5', '2024-09-01', '2024-10-01', 58800.00, 'paid', NULL),
	(361, 103, 'INV-0103-6', '2024-10-01', '2024-10-31', 46500.00, 'partial', NULL),
	(362, 103, 'INV-0103-7', '2024-11-01', '2024-12-01', 25500.00, 'paid', NULL),
	(363, 103, 'INV-0103-8', '2024-12-01', '2024-12-31', 43200.00, 'paid', NULL),
	(364, 103, 'INV-0103-9', '2025-01-01', '2025-01-31', 31800.00, 'paid', NULL),
	(365, 103, 'INV-0103-10', '2025-02-01', '2025-03-03', 27600.00, 'paid', NULL),
	(366, 103, 'INV-0103-11', '2025-03-01', '2025-03-31', 58500.00, 'paid', NULL),
	(367, 104, 'INV-0104-1', '2026-06-06', '2026-07-06', 19500.00, 'paid', NULL),
	(368, 104, 'INV-0104-2', '2026-07-21', '2026-08-20', 26000.00, 'paid', NULL),
	(369, 104, 'INV-0104-3', '2026-09-05', '2026-10-05', 19500.00, 'paid', NULL),
	(370, 105, 'INV-0105-1', '2025-01-31', '2025-03-02', 81300.00, 'paid', NULL),
	(371, 105, 'INV-0105-2', '2025-05-23', '2025-06-22', 108400.00, 'paid', NULL),
	(372, 105, 'INV-0105-3', '2025-09-12', '2025-10-12', 81300.00, 'paid', NULL),
	(373, 106, 'INV-0106-1', '2026-02-22', '2026-03-24', 219000.00, 'paid', NULL),
	(374, 107, 'INV-0107-1', '2026-10-01', '2026-10-31', 49500.00, 'issued', NULL),
	(375, 107, 'INV-0107-2', '2026-10-18', '2026-11-17', 32400.00, 'issued', NULL),
	(376, 108, 'INV-0108-1', '2026-08-01', '2026-08-31', 34200.00, 'paid', NULL),
	(377, 108, 'INV-0108-2', '2026-09-01', '2026-10-01', 33300.00, 'paid', NULL),
	(378, 108, 'INV-0108-3', '2026-10-01', '2026-10-31', 82800.00, 'issued', NULL),
	(379, 108, 'INV-0108-4', '2026-10-18', '2026-11-17', 51300.00, 'issued', NULL),
	(380, 109, 'INV-0109-1', '2026-08-15', '2026-09-14', 95000.00, 'paid', NULL),
	(381, 109, 'INV-0109-2', '2026-09-17', '2026-10-17', 95000.00, 'paid', NULL),
	(382, 110, 'INV-0110-1', '2024-08-01', '2024-08-31', 31500.00, 'partial', NULL),
	(383, 110, 'INV-0110-2', '2024-09-01', '2024-10-01', 17700.00, 'paid', NULL),
	(384, 110, 'INV-0110-3', '2024-10-01', '2024-10-31', 25500.00, 'paid', NULL),
	(385, 110, 'INV-0110-4', '2024-11-01', '2024-12-01', 41700.00, 'paid', NULL),
	(386, 110, 'INV-0110-5', '2024-12-01', '2024-12-31', 36600.00, 'paid', NULL),
	(387, 110, 'INV-0110-6', '2025-01-01', '2025-01-31', 19500.00, 'paid', NULL),
	(388, 110, 'INV-0110-7', '2025-02-01', '2025-03-03', 54000.00, 'paid', NULL),
	(389, 110, 'INV-0110-8', '2025-03-01', '2025-03-31', 23400.00, 'paid', NULL),
	(390, 110, 'INV-0110-9', '2025-04-01', '2025-05-01', 18600.00, 'paid', NULL),
	(391, 110, 'INV-0110-10', '2025-05-01', '2025-05-31', 16200.00, 'paid', NULL),
	(392, 110, 'INV-0110-11', '2025-06-01', '2025-07-01', 34500.00, 'issued', NULL),
	(393, 111, 'INV-0111-1', '2026-05-26', '2026-06-25', 189000.00, 'paid', NULL),
	(394, 112, 'INV-0112-1', '2024-11-15', '2024-12-15', 67000.00, 'paid', NULL),
	(395, 113, 'INV-0113-1', '2024-12-23', '2025-01-22', 182000.00, 'paid', NULL),
	(396, 114, 'INV-0114-1', '2025-03-12', '2025-04-11', 288000.00, 'issued', NULL),
	(397, 114, 'INV-0114-2', '2025-07-09', '2025-08-08', 288000.00, 'paid', NULL),
	(398, 115, 'INV-0115-1', '2026-04-01', '2026-05-01', 30300.00, 'paid', NULL),
	(399, 115, 'INV-0115-2', '2026-05-01', '2026-05-31', 14400.00, 'paid', NULL),
	(400, 115, 'INV-0115-3', '2026-06-01', '2026-07-01', 29700.00, 'partial', NULL);
INSERT INTO public.invoice VALUES
	(401, 115, 'INV-0115-4', '2026-07-01', '2026-07-31', 39900.00, 'paid', NULL),
	(402, 115, 'INV-0115-5', '2026-08-01', '2026-08-31', 27900.00, 'partial', NULL),
	(403, 115, 'INV-0115-6', '2026-09-01', '2026-10-01', 24900.00, 'paid', NULL),
	(404, 115, 'INV-0115-7', '2026-10-01', '2026-10-31', 18600.00, 'issued', NULL),
	(405, 115, 'INV-0115-8', '2026-10-18', '2026-11-17', 13800.00, 'issued', NULL),
	(406, 116, 'INV-0116-1', '2025-02-20', '2025-03-22', 11000.00, 'paid', NULL),
	(407, 116, 'INV-0116-2', '2025-05-30', '2025-06-29', 11000.00, 'paid', NULL),
	(408, 117, 'INV-0117-1', '2026-07-04', '2026-08-03', 457000.00, 'paid', NULL),
	(409, 118, 'INV-0118-1', '2024-10-01', '2024-10-31', 16200.00, 'paid', NULL),
	(410, 118, 'INV-0118-2', '2024-11-01', '2024-12-01', 9000.00, 'paid', NULL),
	(411, 118, 'INV-0118-3', '2024-12-01', '2024-12-31', 9000.00, 'paid', NULL),
	(412, 118, 'INV-0118-4', '2025-01-01', '2025-01-31', 17100.00, 'paid', NULL),
	(413, 118, 'INV-0118-5', '2025-02-01', '2025-03-03', 2700.00, 'paid', NULL),
	(414, 118, 'INV-0118-6', '2025-03-01', '2025-03-31', 26100.00, 'paid', NULL),
	(415, 118, 'INV-0118-7', '2025-04-01', '2025-05-01', 6300.00, 'paid', NULL),
	(416, 118, 'INV-0118-8', '2025-05-01', '2025-05-31', 21600.00, 'paid', NULL),
	(417, 118, 'INV-0118-9', '2025-06-01', '2025-07-01', 17100.00, 'paid', NULL),
	(418, 118, 'INV-0118-10', '2025-07-01', '2025-07-31', 1800.00, 'paid', NULL),
	(419, 118, 'INV-0118-11', '2025-08-01', '2025-08-31', 14400.00, 'paid', NULL),
	(420, 118, 'INV-0118-12', '2025-09-01', '2025-10-01', 9000.00, 'paid', NULL),
	(421, 118, 'INV-0118-13', '2025-10-01', '2025-10-31', 6300.00, 'paid', NULL),
	(422, 118, 'INV-0118-14', '2025-11-01', '2025-12-01', 11700.00, 'paid', NULL),
	(423, 118, 'INV-0118-15', '2025-12-01', '2025-12-31', 8100.00, 'paid', NULL),
	(424, 119, 'INV-0119-1', '2025-04-01', '2025-05-01', 18000.00, 'paid', NULL),
	(425, 119, 'INV-0119-2', '2025-05-01', '2025-05-31', 14400.00, 'paid', NULL),
	(426, 119, 'INV-0119-3', '2025-06-01', '2025-07-01', 18000.00, 'paid', NULL),
	(427, 119, 'INV-0119-4', '2025-07-01', '2025-07-31', 6300.00, 'paid', NULL),
	(428, 119, 'INV-0119-5', '2025-08-01', '2025-08-31', 12600.00, 'paid', NULL),
	(429, 119, 'INV-0119-6', '2025-09-01', '2025-10-01', 27000.00, 'paid', NULL),
	(430, 119, 'INV-0119-7', '2025-10-01', '2025-10-31', 12600.00, 'paid', NULL),
	(431, 119, 'INV-0119-8', '2025-11-01', '2025-12-01', 3600.00, 'paid', NULL),
	(432, 119, 'INV-0119-9', '2025-12-01', '2025-12-31', 11700.00, 'paid', NULL),
	(433, 119, 'INV-0119-10', '2026-01-01', '2026-01-31', 23400.00, 'paid', NULL),
	(434, 119, 'INV-0119-11', '2026-02-01', '2026-03-03', 20700.00, 'paid', NULL),
	(435, 119, 'INV-0119-12', '2026-03-01', '2026-03-31', 9900.00, 'paid', NULL),
	(436, 119, 'INV-0119-13', '2026-04-01', '2026-05-01', 1800.00, 'issued', NULL),
	(437, 119, 'INV-0119-14', '2026-05-01', '2026-05-31', 12600.00, 'paid', NULL),
	(438, 119, 'INV-0119-15', '2026-06-01', '2026-07-01', 12600.00, 'paid', NULL),
	(439, 120, 'INV-0120-1', '2025-07-01', '2025-07-31', 69000.00, 'paid', NULL),
	(440, 120, 'INV-0120-2', '2025-08-01', '2025-08-31', 64800.00, 'paid', NULL),
	(441, 120, 'INV-0120-3', '2025-09-01', '2025-10-01', 50100.00, 'paid', NULL),
	(442, 120, 'INV-0120-4', '2025-10-01', '2025-10-31', 26700.00, 'issued', NULL),
	(443, 120, 'INV-0120-5', '2025-11-01', '2025-12-01', 62100.00, 'paid', NULL),
	(444, 120, 'INV-0120-6', '2025-12-01', '2025-12-31', 71400.00, 'paid', NULL),
	(445, 120, 'INV-0120-7', '2026-01-01', '2026-01-31', 54900.00, 'paid', NULL),
	(446, 120, 'INV-0120-8', '2026-02-01', '2026-03-03', 29400.00, 'paid', NULL),
	(447, 120, 'INV-0120-9', '2026-03-01', '2026-03-31', 51300.00, 'paid', NULL),
	(448, 120, 'INV-0120-10', '2026-04-01', '2026-05-01', 57900.00, 'paid', NULL),
	(449, 120, 'INV-0120-11', '2026-05-01', '2026-05-31', 41100.00, 'paid', NULL),
	(450, 120, 'INV-0120-12', '2026-06-01', '2026-07-01', 10200.00, 'paid', NULL),
	(451, 120, 'INV-0120-13', '2026-07-01', '2026-07-31', 67800.00, 'paid', NULL),
	(452, 120, 'INV-0120-14', '2026-08-01', '2026-08-31', 32400.00, 'paid', NULL),
	(453, 120, 'INV-0120-15', '2026-09-01', '2026-10-01', 55200.00, 'issued', NULL),
	(454, 120, 'INV-0120-16', '2026-10-01', '2026-10-31', 49500.00, 'issued', NULL),
	(455, 120, 'INV-0120-17', '2026-10-18', '2026-11-17', 43800.00, 'issued', NULL),
	(456, 121, 'INV-0121-1', '2026-01-30', '2026-03-01', 44100.00, 'paid', NULL),
	(457, 121, 'INV-0121-2', '2026-04-28', '2026-05-28', 58800.00, 'paid', NULL),
	(458, 121, 'INV-0121-3', '2026-07-25', '2026-08-24', 44100.00, 'paid', NULL),
	(459, 122, 'INV-0122-1', '2025-01-06', '2025-02-05', 82000.00, 'paid', NULL),
	(460, 122, 'INV-0122-2', '2025-08-10', '2025-09-09', 82000.00, 'paid', NULL),
	(461, 123, 'INV-0123-1', '2025-12-03', '2026-01-02', 259000.00, 'paid', NULL),
	(462, 125, 'INV-0125-1', '2025-01-01', '2025-01-31', 27900.00, 'paid', NULL),
	(463, 125, 'INV-0125-2', '2025-02-01', '2025-03-03', 10500.00, 'paid', NULL),
	(464, 125, 'INV-0125-3', '2025-03-01', '2025-03-31', 60600.00, 'paid', NULL),
	(465, 125, 'INV-0125-4', '2025-04-01', '2025-05-01', 45300.00, 'paid', NULL),
	(466, 125, 'INV-0125-5', '2025-05-01', '2025-05-31', 41100.00, 'paid', NULL),
	(467, 126, 'INV-0126-1', '2025-08-12', '2025-09-11', 59500.00, 'paid', NULL),
	(468, 126, 'INV-0126-2', '2026-03-17', '2026-04-16', 59500.00, 'paid', NULL),
	(469, 127, 'INV-0127-1', '2026-02-05', '2026-03-07', 276000.00, 'paid', NULL),
	(470, 128, 'INV-0128-1', '2024-04-28', '2024-05-28', 306000.00, 'paid', NULL),
	(471, 129, 'INV-0129-1', '2026-10-01', '2026-10-31', 9000.00, 'issued', NULL),
	(472, 129, 'INV-0129-2', '2026-10-18', '2026-11-17', 11400.00, 'issued', NULL),
	(473, 130, 'INV-0130-1', '2024-02-01', '2024-03-02', 18900.00, 'partial', NULL),
	(474, 130, 'INV-0130-2', '2024-03-01', '2024-03-31', 17100.00, 'partial', NULL),
	(475, 130, 'INV-0130-3', '2024-04-01', '2024-05-01', 5400.00, 'paid', NULL),
	(476, 131, 'INV-0131-1', '2024-09-05', '2024-10-05', 44000.00, 'paid', NULL),
	(477, 132, 'INV-0132-1', '2026-01-31', '2026-03-02', 177000.00, 'paid', NULL),
	(478, 133, 'INV-0133-1', '2025-05-01', '2025-05-31', 25200.00, 'paid', NULL),
	(479, 133, 'INV-0133-2', '2025-06-01', '2025-07-01', 14400.00, 'issued', NULL),
	(480, 133, 'INV-0133-3', '2025-07-01', '2025-07-31', 19800.00, 'paid', NULL),
	(481, 134, 'INV-0134-1', '2024-10-15', '2024-11-14', 192500.00, 'partial', NULL),
	(482, 134, 'INV-0134-2', '2024-11-30', '2024-12-30', 192500.00, 'partial', NULL),
	(483, 135, 'INV-0135-1', '2025-02-18', '2025-03-20', 686000.00, 'paid', NULL),
	(484, 136, 'INV-0136-1', '2024-06-01', '2024-07-01', 13200.00, 'paid', NULL),
	(485, 136, 'INV-0136-2', '2024-11-17', '2024-12-17', 17600.00, 'paid', NULL),
	(486, 136, 'INV-0136-3', '2025-05-05', '2025-06-04', 13200.00, 'partial', NULL),
	(487, 137, 'INV-0137-1', '2024-12-29', '2025-01-28', 30000.00, 'paid', NULL),
	(488, 137, 'INV-0137-2', '2025-03-30', '2025-04-29', 30000.00, 'paid', NULL),
	(489, 138, 'INV-0138-1', '2024-03-15', '2024-04-14', 63000.00, 'paid', NULL),
	(490, 138, 'INV-0138-2', '2024-09-14', '2024-10-14', 63000.00, 'paid', NULL),
	(491, 139, 'INV-0139-1', '2024-03-29', '2024-04-28', 5700.00, 'paid', NULL),
	(492, 139, 'INV-0139-2', '2024-08-11', '2024-09-10', 7600.00, 'paid', NULL),
	(493, 139, 'INV-0139-3', '2024-12-24', '2025-01-23', 5700.00, 'paid', NULL),
	(494, 140, 'INV-0140-1', '2024-07-01', '2024-07-31', 3600.00, 'paid', NULL),
	(495, 140, 'INV-0140-2', '2024-08-01', '2024-08-31', 17100.00, 'paid', NULL),
	(496, 140, 'INV-0140-3', '2024-09-01', '2024-10-01', 8100.00, 'issued', NULL),
	(497, 140, 'INV-0140-4', '2024-10-01', '2024-10-31', 16200.00, 'paid', NULL),
	(498, 140, 'INV-0140-5', '2024-11-01', '2024-12-01', 27000.00, 'paid', NULL),
	(499, 140, 'INV-0140-6', '2024-12-01', '2024-12-31', 32400.00, 'paid', NULL),
	(500, 140, 'INV-0140-7', '2025-01-01', '2025-01-31', 19800.00, 'paid', NULL),
	(501, 140, 'INV-0140-8', '2025-02-01', '2025-03-03', 30600.00, 'paid', NULL),
	(502, 140, 'INV-0140-9', '2025-03-01', '2025-03-31', 23400.00, 'paid', NULL),
	(503, 140, 'INV-0140-10', '2025-04-01', '2025-05-01', 9000.00, 'paid', NULL),
	(504, 140, 'INV-0140-11', '2025-05-01', '2025-05-31', 18000.00, 'paid', NULL),
	(505, 140, 'INV-0140-12', '2025-06-01', '2025-07-01', 15300.00, 'paid', NULL),
	(506, 141, 'INV-0141-1', '2024-09-27', '2024-10-27', 171500.00, 'paid', NULL),
	(507, 141, 'INV-0141-2', '2024-12-25', '2025-01-24', 171500.00, 'paid', NULL),
	(508, 142, 'INV-0142-1', '2025-03-01', '2025-03-31', 37500.00, 'paid', NULL),
	(509, 142, 'INV-0142-2', '2025-04-01', '2025-05-01', 44100.00, 'paid', NULL),
	(510, 142, 'INV-0142-3', '2025-05-01', '2025-05-31', 18000.00, 'paid', NULL),
	(511, 142, 'INV-0142-4', '2025-06-01', '2025-07-01', 37200.00, 'paid', NULL),
	(512, 142, 'INV-0142-5', '2025-07-01', '2025-07-31', 64500.00, 'paid', NULL),
	(513, 142, 'INV-0142-6', '2025-08-01', '2025-08-31', 12300.00, 'paid', NULL),
	(514, 143, 'INV-0143-1', '2024-01-30', '2024-02-29', 70200.00, 'paid', NULL),
	(515, 143, 'INV-0143-2', '2024-02-22', '2024-03-23', 93600.00, 'paid', NULL),
	(516, 143, 'INV-0143-3', '2024-03-16', '2024-04-15', 70200.00, 'partial', NULL),
	(517, 144, 'INV-0144-1', '2025-01-30', '2025-03-01', 200000.00, 'paid', NULL),
	(518, 144, 'INV-0144-2', '2025-05-18', '2025-06-17', 200000.00, 'paid', NULL),
	(519, 145, 'INV-0145-1', '2026-05-01', '2026-05-31', 8400.00, 'paid', NULL),
	(520, 145, 'INV-0145-2', '2026-06-01', '2026-07-01', 14400.00, 'paid', NULL),
	(521, 146, 'INV-0146-1', '2026-10-07', '2026-11-06', 183000.00, 'issued', NULL),
	(522, 146, 'INV-0146-2', '2026-10-14', '2026-11-13', 183000.00, 'issued', NULL),
	(523, 147, 'INV-0147-1', '2026-05-07', '2026-06-06', 284000.00, 'paid', NULL),
	(524, 148, 'INV-0148-1', '2026-10-01', '2026-10-31', 35100.00, 'issued', NULL),
	(525, 148, 'INV-0148-2', '2026-10-18', '2026-11-17', 39300.00, 'issued', NULL),
	(526, 149, 'INV-0149-1', '2024-04-02', '2024-05-02', 148000.00, 'partial', NULL),
	(527, 150, 'INV-0150-1', '2024-12-02', '2025-01-01', 148000.00, 'paid', NULL),
	(528, 151, 'INV-0151-1', '2025-10-01', '2025-10-31', 17100.00, 'paid', NULL),
	(529, 151, 'INV-0151-2', '2025-11-01', '2025-12-01', 11700.00, 'partial', NULL),
	(530, 151, 'INV-0151-3', '2025-12-01', '2025-12-31', 11700.00, 'issued', NULL),
	(531, 151, 'INV-0151-4', '2026-01-01', '2026-01-31', 13500.00, 'paid', NULL),
	(532, 151, 'INV-0151-5', '2026-02-01', '2026-03-03', 31500.00, 'paid', NULL),
	(533, 151, 'INV-0151-6', '2026-03-01', '2026-03-31', 13500.00, 'partial', NULL),
	(534, 151, 'INV-0151-7', '2026-04-01', '2026-05-01', 24300.00, 'paid', NULL),
	(535, 151, 'INV-0151-8', '2026-05-01', '2026-05-31', 7200.00, 'partial', NULL),
	(536, 151, 'INV-0151-9', '2026-06-01', '2026-07-01', 20700.00, 'paid', NULL),
	(537, 151, 'INV-0151-10', '2026-07-01', '2026-07-31', 24300.00, 'paid', NULL),
	(538, 151, 'INV-0151-11', '2026-08-01', '2026-08-31', 17100.00, 'paid', NULL),
	(539, 151, 'INV-0151-12', '2026-09-01', '2026-10-01', 2700.00, 'paid', NULL),
	(540, 152, 'INV-0152-1', '2026-09-01', '2026-10-01', 11700.00, 'issued', NULL),
	(541, 152, 'INV-0152-2', '2026-10-01', '2026-10-31', 18000.00, 'issued', NULL),
	(542, 152, 'INV-0152-3', '2026-10-18', '2026-11-17', 8100.00, 'issued', NULL),
	(543, 153, 'INV-0153-1', '2024-03-01', '2024-03-31', 15000.00, 'paid', NULL),
	(544, 153, 'INV-0153-2', '2024-04-01', '2024-05-01', 4800.00, 'paid', NULL),
	(545, 154, 'INV-0154-1', '2024-08-25', '2024-09-24', 209000.00, 'paid', NULL),
	(546, 155, 'INV-0155-1', '2025-09-01', '2025-10-01', 58500.00, 'paid', NULL),
	(547, 155, 'INV-0155-2', '2025-10-01', '2025-10-31', 49500.00, 'paid', NULL),
	(548, 155, 'INV-0155-3', '2025-11-01', '2025-12-01', 42300.00, 'paid', NULL),
	(549, 155, 'INV-0155-4', '2025-12-01', '2025-12-31', 28800.00, 'issued', NULL),
	(550, 155, 'INV-0155-5', '2026-01-01', '2026-01-31', 50400.00, 'paid', NULL),
	(551, 156, 'INV-0156-1', '2025-11-01', '2025-12-01', 29700.00, 'paid', NULL),
	(552, 156, 'INV-0156-2', '2025-12-01', '2025-12-31', 32400.00, 'issued', NULL),
	(553, 156, 'INV-0156-3', '2026-01-01', '2026-01-31', 36300.00, 'paid', NULL),
	(554, 156, 'INV-0156-4', '2026-02-01', '2026-03-03', 66300.00, 'paid', NULL),
	(555, 156, 'INV-0156-5', '2026-03-01', '2026-03-31', 16800.00, 'paid', NULL),
	(556, 156, 'INV-0156-6', '2026-04-01', '2026-05-01', 34800.00, 'paid', NULL),
	(557, 156, 'INV-0156-7', '2026-05-01', '2026-05-31', 50400.00, 'paid', NULL),
	(558, 156, 'INV-0156-8', '2026-06-01', '2026-07-01', 21600.00, 'paid', NULL),
	(559, 156, 'INV-0156-9', '2026-07-01', '2026-07-31', 38400.00, 'issued', NULL),
	(560, 156, 'INV-0156-10', '2026-08-01', '2026-08-31', 21900.00, 'paid', NULL),
	(561, 156, 'INV-0156-11', '2026-09-01', '2026-10-01', 37800.00, 'issued', NULL),
	(562, 156, 'INV-0156-12', '2026-10-01', '2026-10-31', 12600.00, 'paid', NULL),
	(563, 156, 'INV-0156-13', '2026-10-18', '2026-11-17', 11100.00, 'issued', NULL),
	(564, 157, 'INV-0157-1', '2026-09-01', '2026-10-01', 15000.00, 'issued', NULL),
	(565, 157, 'INV-0157-2', '2026-10-01', '2026-10-31', 13800.00, 'issued', NULL),
	(566, 157, 'INV-0157-3', '2026-10-18', '2026-11-17', 16800.00, 'issued', NULL),
	(567, 158, 'INV-0158-1', '2024-07-28', '2024-08-27', 82000.00, 'issued', NULL),
	(568, 159, 'INV-0159-1', '2025-01-19', '2025-02-18', 72000.00, 'issued', NULL),
	(569, 160, 'INV-0160-1', '2025-10-18', '2025-11-17', 145500.00, 'paid', NULL),
	(570, 160, 'INV-0160-2', '2025-12-06', '2026-01-05', 145500.00, 'paid', NULL),
	(571, 161, 'INV-0161-1', '2026-08-01', '2026-08-31', 16200.00, 'paid', NULL),
	(572, 161, 'INV-0161-2', '2026-09-01', '2026-10-01', 18600.00, 'partial', NULL),
	(573, 161, 'INV-0161-3', '2026-10-01', '2026-10-31', 13800.00, 'partial', NULL),
	(574, 161, 'INV-0161-4', '2026-10-18', '2026-11-17', 13200.00, 'issued', NULL),
	(575, 162, 'INV-0162-1', '2024-02-12', '2024-03-13', 15000.00, 'issued', NULL),
	(576, 162, 'INV-0162-2', '2024-05-23', '2024-06-22', 20000.00, 'paid', NULL),
	(577, 162, 'INV-0162-3', '2024-09-01', '2024-10-01', 15000.00, 'paid', NULL),
	(578, 163, 'INV-0163-1', '2024-10-24', '2024-11-23', 33000.00, 'paid', NULL),
	(579, 164, 'INV-0164-1', '2024-04-08', '2024-05-08', 55500.00, 'paid', NULL),
	(580, 164, 'INV-0164-2', '2024-05-26', '2024-06-25', 74000.00, 'paid', NULL),
	(581, 164, 'INV-0164-3', '2024-07-13', '2024-08-12', 55500.00, 'paid', NULL),
	(582, 165, 'INV-0165-1', '2024-05-01', '2024-05-31', 4500.00, 'paid', NULL),
	(583, 165, 'INV-0165-2', '2024-06-01', '2024-07-01', 13500.00, 'paid', NULL),
	(584, 166, 'INV-0166-1', '2025-12-07', '2026-01-06', 111600.00, 'paid', NULL),
	(585, 166, 'INV-0166-2', '2026-01-20', '2026-02-19', 148800.00, 'paid', NULL),
	(586, 166, 'INV-0166-3', '2026-03-06', '2026-04-05', 111600.00, 'paid', NULL),
	(587, 167, 'INV-0167-1', '2026-03-16', '2026-04-15', 180000.00, 'paid', NULL),
	(588, 168, 'INV-0168-1', '2026-10-08', '2026-11-07', 30500.00, 'paid', NULL),
	(589, 168, 'INV-0168-2', '2026-10-14', '2026-11-13', 30500.00, 'issued', NULL),
	(590, 169, 'INV-0169-1', '2026-06-01', '2026-07-01', 25200.00, 'paid', NULL),
	(591, 169, 'INV-0169-2', '2026-07-01', '2026-07-31', 12600.00, 'paid', NULL),
	(592, 169, 'INV-0169-3', '2026-08-01', '2026-08-31', 28800.00, 'paid', NULL),
	(593, 169, 'INV-0169-4', '2026-09-01', '2026-10-01', 8100.00, 'issued', NULL),
	(594, 169, 'INV-0169-5', '2026-10-01', '2026-10-31', 12600.00, 'issued', NULL),
	(595, 169, 'INV-0169-6', '2026-10-18', '2026-11-17', 32400.00, 'issued', NULL),
	(596, 170, 'INV-0170-1', '2025-07-01', '2025-07-31', 45300.00, 'paid', NULL),
	(597, 170, 'INV-0170-2', '2025-08-01', '2025-08-31', 20700.00, 'paid', NULL),
	(598, 170, 'INV-0170-3', '2025-09-01', '2025-10-01', 27300.00, 'partial', NULL),
	(599, 170, 'INV-0170-4', '2025-10-01', '2025-10-31', 27900.00, 'partial', NULL),
	(600, 170, 'INV-0170-5', '2025-11-01', '2025-12-01', 35700.00, 'paid', NULL);
INSERT INTO public.invoice VALUES
	(601, 170, 'INV-0170-6', '2025-12-01', '2025-12-31', 49200.00, 'paid', NULL),
	(602, 170, 'INV-0170-7', '2026-01-01', '2026-01-31', 21600.00, 'paid', NULL),
	(603, 170, 'INV-0170-8', '2026-02-01', '2026-03-03', 29100.00, 'paid', NULL),
	(604, 170, 'INV-0170-9', '2026-03-01', '2026-03-31', 52800.00, 'paid', NULL),
	(605, 170, 'INV-0170-10', '2026-04-01', '2026-05-01', 36000.00, 'paid', NULL),
	(606, 170, 'INV-0170-11', '2026-05-01', '2026-05-31', 50100.00, 'paid', NULL),
	(607, 170, 'INV-0170-12', '2026-06-01', '2026-07-01', 41700.00, 'paid', NULL),
	(608, 170, 'INV-0170-13', '2026-07-01', '2026-07-31', 34200.00, 'paid', NULL),
	(609, 170, 'INV-0170-14', '2026-08-01', '2026-08-31', 35700.00, 'paid', NULL),
	(610, 170, 'INV-0170-15', '2026-09-01', '2026-10-01', 33900.00, 'issued', NULL),
	(611, 171, 'INV-0171-1', '2026-03-18', '2026-04-17', 353000.00, 'paid', NULL),
	(612, 171, 'INV-0171-2', '2026-06-23', '2026-07-23', 353000.00, 'paid', NULL),
	(613, 172, 'INV-0172-1', '2026-08-01', '2026-08-31', 20100.00, 'paid', NULL),
	(614, 172, 'INV-0172-2', '2026-09-01', '2026-10-01', 30600.00, 'paid', NULL),
	(615, 172, 'INV-0172-3', '2026-10-01', '2026-10-31', 43500.00, 'issued', NULL),
	(616, 172, 'INV-0172-4', '2026-10-18', '2026-11-17', 33900.00, 'issued', NULL),
	(617, 173, 'INV-0173-1', '2026-02-03', '2026-03-05', 36000.00, 'paid', NULL),
	(618, 174, 'INV-0174-1', '2025-08-19', '2025-09-18', 104700.00, 'paid', NULL),
	(619, 174, 'INV-0174-2', '2025-10-07', '2025-11-06', 139600.00, 'paid', NULL),
	(620, 174, 'INV-0174-3', '2025-11-25', '2025-12-25', 104700.00, 'paid', NULL),
	(621, 175, 'INV-0175-1', '2024-04-25', '2024-05-25', 26700.00, 'issued', NULL),
	(622, 175, 'INV-0175-2', '2024-05-13', '2024-06-12', 35600.00, 'paid', NULL),
	(623, 175, 'INV-0175-3', '2024-05-31', '2024-06-30', 26700.00, 'paid', NULL),
	(624, 176, 'INV-0176-1', '2024-12-09', '2025-01-08', 23000.00, 'paid', NULL),
	(625, 177, 'INV-0177-1', '2026-05-01', '2026-05-31', 1800.00, 'paid', NULL),
	(626, 177, 'INV-0177-2', '2026-06-01', '2026-07-01', 21600.00, 'paid', NULL),
	(627, 177, 'INV-0177-3', '2026-07-01', '2026-07-31', 6000.00, 'issued', NULL),
	(628, 177, 'INV-0177-4', '2026-08-01', '2026-08-31', 5400.00, 'paid', NULL),
	(629, 177, 'INV-0177-5', '2026-09-01', '2026-10-01', 12000.00, 'paid', NULL),
	(630, 177, 'INV-0177-6', '2026-10-01', '2026-10-31', 13800.00, 'partial', NULL),
	(631, 177, 'INV-0177-7', '2026-10-18', '2026-11-17', 19200.00, 'issued', NULL),
	(632, 178, 'INV-0178-1', '2026-03-01', '2026-03-31', 10800.00, 'partial', NULL),
	(633, 178, 'INV-0178-2', '2026-04-01', '2026-05-01', 10800.00, 'partial', NULL),
	(634, 178, 'INV-0178-3', '2026-05-01', '2026-05-31', 20700.00, 'paid', NULL),
	(635, 178, 'INV-0178-4', '2026-06-01', '2026-07-01', 12600.00, 'paid', NULL),
	(636, 178, 'INV-0178-5', '2026-07-01', '2026-07-31', 31500.00, 'paid', NULL),
	(637, 178, 'INV-0178-6', '2026-08-01', '2026-08-31', 26100.00, 'paid', NULL),
	(638, 179, 'INV-0179-1', '2026-06-25', '2026-07-25', 8400.00, 'paid', NULL),
	(639, 179, 'INV-0179-2', '2026-08-03', '2026-09-02', 11200.00, 'paid', NULL),
	(640, 179, 'INV-0179-3', '2026-09-11', '2026-10-11', 8400.00, 'issued', NULL),
	(641, 180, 'INV-0180-1', '2025-08-10', '2025-09-09', 110000.00, 'paid', NULL),
	(642, 180, 'INV-0180-2', '2026-03-16', '2026-04-15', 110000.00, 'paid', NULL),
	(643, 181, 'INV-0181-1', '2026-01-01', '2026-01-31', 18000.00, 'paid', NULL),
	(644, 181, 'INV-0181-2', '2026-02-01', '2026-03-03', 11400.00, 'paid', NULL),
	(645, 181, 'INV-0181-3', '2026-03-01', '2026-03-31', 14400.00, 'partial', NULL),
	(646, 181, 'INV-0181-4', '2026-04-01', '2026-05-01', 6000.00, 'paid', NULL),
	(647, 181, 'INV-0181-5', '2026-05-01', '2026-05-31', 7200.00, 'paid', NULL),
	(648, 181, 'INV-0181-6', '2026-06-01', '2026-07-01', 1200.00, 'paid', NULL),
	(649, 181, 'INV-0181-7', '2026-07-01', '2026-07-31', 11400.00, 'paid', NULL),
	(650, 181, 'INV-0181-8', '2026-08-01', '2026-08-31', 7200.00, 'paid', NULL),
	(651, 181, 'INV-0181-9', '2026-09-01', '2026-10-01', 15600.00, 'issued', NULL),
	(652, 181, 'INV-0181-10', '2026-10-01', '2026-10-31', 13800.00, 'issued', NULL),
	(653, 181, 'INV-0181-11', '2026-10-18', '2026-11-17', 3000.00, 'issued', NULL),
	(654, 182, 'INV-0182-1', '2025-04-05', '2025-05-05', 192500.00, 'paid', NULL),
	(655, 182, 'INV-0182-2', '2025-08-20', '2025-09-19', 192500.00, 'partial', NULL),
	(656, 183, 'INV-0183-1', '2026-08-01', '2026-08-31', 25200.00, 'paid', NULL),
	(657, 183, 'INV-0183-2', '2026-09-01', '2026-10-01', 8100.00, 'issued', NULL),
	(658, 183, 'INV-0183-3', '2026-10-01', '2026-10-31', 32400.00, 'paid', NULL),
	(659, 183, 'INV-0183-4', '2026-10-18', '2026-11-17', 12600.00, 'issued', NULL),
	(660, 184, 'INV-0184-1', '2025-10-22', '2025-11-21', 4200.00, 'issued', NULL),
	(661, 184, 'INV-0184-2', '2026-02-01', '2026-03-03', 5600.00, 'paid', NULL),
	(662, 184, 'INV-0184-3', '2026-05-14', '2026-06-13', 4200.00, 'paid', NULL),
	(663, 185, 'INV-0185-1', '2025-04-16', '2025-05-16', 81600.00, 'paid', NULL),
	(664, 185, 'INV-0185-2', '2025-05-12', '2025-06-11', 108800.00, 'paid', NULL),
	(665, 185, 'INV-0185-3', '2025-06-08', '2025-07-08', 81600.00, 'paid', NULL),
	(666, 186, 'INV-0186-1', '2026-01-18', '2026-02-17', 101000.00, 'paid', NULL),
	(667, 187, 'INV-0187-1', '2025-10-01', '2025-10-31', 17700.00, 'paid', NULL),
	(668, 187, 'INV-0187-2', '2025-11-01', '2025-12-01', 21600.00, 'issued', NULL),
	(669, 187, 'INV-0187-3', '2025-12-01', '2025-12-31', 57000.00, 'paid', NULL),
	(670, 187, 'INV-0187-4', '2026-01-01', '2026-01-31', 54000.00, 'paid', NULL),
	(671, 187, 'INV-0187-5', '2026-02-01', '2026-03-03', 27600.00, 'paid', NULL),
	(672, 187, 'INV-0187-6', '2026-03-01', '2026-03-31', 63600.00, 'paid', NULL),
	(673, 187, 'INV-0187-7', '2026-04-01', '2026-05-01', 37500.00, 'paid', NULL),
	(674, 187, 'INV-0187-8', '2026-05-01', '2026-05-31', 66900.00, 'paid', NULL),
	(675, 187, 'INV-0187-9', '2026-06-01', '2026-07-01', 58500.00, 'paid', NULL),
	(676, 187, 'INV-0187-10', '2026-07-01', '2026-07-31', 15300.00, 'paid', NULL),
	(677, 187, 'INV-0187-11', '2026-08-01', '2026-08-31', 58800.00, 'paid', NULL),
	(678, 187, 'INV-0187-12', '2026-09-01', '2026-10-01', 40200.00, 'paid', NULL),
	(679, 187, 'INV-0187-13', '2026-10-01', '2026-10-31', 26100.00, 'issued', NULL),
	(680, 187, 'INV-0187-14', '2026-10-18', '2026-11-17', 14700.00, 'issued', NULL),
	(681, 188, 'INV-0188-1', '2026-06-11', '2026-07-11', 325000.00, 'paid', NULL),
	(682, 188, 'INV-0188-2', '2026-08-16', '2026-09-15', 325000.00, 'paid', NULL),
	(683, 189, 'INV-0189-1', '2026-01-18', '2026-02-17', 172000.00, 'paid', NULL),
	(684, 189, 'INV-0189-2', '2026-06-05', '2026-07-05', 172000.00, 'paid', NULL),
	(685, 190, 'INV-0190-1', '2025-07-01', '2025-07-31', 1800.00, 'paid', NULL),
	(686, 190, 'INV-0190-2', '2025-08-01', '2025-08-31', 10200.00, 'paid', NULL),
	(687, 190, 'INV-0190-3', '2025-09-01', '2025-10-01', 9000.00, 'paid', NULL),
	(688, 190, 'INV-0190-4', '2025-10-01', '2025-10-31', 6000.00, 'paid', NULL),
	(689, 190, 'INV-0190-5', '2025-11-01', '2025-12-01', 16200.00, 'issued', NULL),
	(690, 190, 'INV-0190-6', '2025-12-01', '2025-12-31', 4200.00, 'paid', NULL),
	(691, 190, 'INV-0190-7', '2026-01-01', '2026-01-31', 13200.00, 'paid', NULL),
	(692, 190, 'INV-0190-8', '2026-02-01', '2026-03-03', 5400.00, 'paid', NULL),
	(693, 190, 'INV-0190-9', '2026-03-01', '2026-03-31', 10800.00, 'issued', NULL),
	(694, 191, 'INV-0191-1', '2024-04-11', '2024-05-11', 95500.00, 'paid', NULL),
	(695, 191, 'INV-0191-2', '2024-12-01', '2024-12-31', 95500.00, 'paid', NULL),
	(696, 192, 'INV-0192-1', '2025-07-01', '2025-07-31', 24300.00, 'paid', NULL),
	(697, 192, 'INV-0192-2', '2025-08-01', '2025-08-31', 20700.00, 'paid', NULL),
	(698, 193, 'INV-0193-1', '2024-11-30', '2024-12-30', 112500.00, 'issued', NULL),
	(699, 193, 'INV-0193-2', '2025-06-10', '2025-07-10', 112500.00, 'paid', NULL),
	(700, 194, 'INV-0194-1', '2025-03-27', '2025-04-26', 192000.00, 'paid', NULL),
	(701, 195, 'INV-0195-1', '2026-04-08', '2026-05-08', 410000.00, 'paid', NULL),
	(702, 196, 'INV-0196-1', '2026-09-01', '2026-10-01', 1200.00, 'issued', NULL),
	(703, 196, 'INV-0196-2', '2026-10-01', '2026-10-31', 6600.00, 'issued', NULL),
	(704, 196, 'INV-0196-3', '2026-10-18', '2026-11-17', 24600.00, 'issued', NULL),
	(705, 197, 'INV-0197-1', '2025-12-11', '2026-01-10', 108900.00, 'paid', NULL),
	(706, 197, 'INV-0197-2', '2025-12-31', '2026-01-30', 145200.00, 'paid', NULL),
	(707, 197, 'INV-0197-3', '2026-01-20', '2026-02-19', 108900.00, 'paid', NULL),
	(708, 200, 'INV-0200-1', '2025-06-26', '2025-07-26', 50700.00, 'paid', NULL),
	(709, 200, 'INV-0200-2', '2025-10-29', '2025-11-28', 67600.00, 'paid', NULL),
	(710, 200, 'INV-0200-3', '2026-03-04', '2026-04-03', 50700.00, 'paid', NULL),
	(711, 201, 'INV-0201-1', '2025-01-01', '2025-01-31', 12600.00, 'partial', NULL),
	(712, 201, 'INV-0201-2', '2025-02-01', '2025-03-03', 9600.00, 'paid', NULL),
	(713, 201, 'INV-0201-3', '2025-03-01', '2025-03-31', 6000.00, 'paid', NULL),
	(714, 201, 'INV-0201-4', '2025-04-01', '2025-05-01', 11400.00, 'paid', NULL),
	(715, 201, 'INV-0201-5', '2025-05-01', '2025-05-31', 11400.00, 'paid', NULL),
	(716, 201, 'INV-0201-6', '2025-06-01', '2025-07-01', 8400.00, 'paid', NULL),
	(717, 201, 'INV-0201-7', '2025-07-01', '2025-07-31', 5400.00, 'paid', NULL),
	(718, 201, 'INV-0201-8', '2025-08-01', '2025-08-31', 16200.00, 'paid', NULL),
	(719, 201, 'INV-0201-9', '2025-09-01', '2025-10-01', 12600.00, 'paid', NULL),
	(720, 201, 'INV-0201-10', '2025-10-01', '2025-10-31', 16200.00, 'paid', NULL),
	(721, 201, 'INV-0201-11', '2025-11-01', '2025-12-01', 22800.00, 'paid', NULL),
	(722, 201, 'INV-0201-12', '2025-12-01', '2025-12-31', 16200.00, 'paid', NULL),
	(723, 201, 'INV-0201-13', '2026-01-01', '2026-01-31', 12000.00, 'issued', NULL),
	(724, 202, 'INV-0202-1', '2025-02-01', '2025-03-03', 31500.00, 'paid', NULL),
	(725, 202, 'INV-0202-2', '2025-03-01', '2025-03-31', 27900.00, 'paid', NULL),
	(726, 202, 'INV-0202-3', '2025-04-01', '2025-05-01', 50400.00, 'paid', NULL),
	(727, 202, 'INV-0202-4', '2025-05-01', '2025-05-31', 68100.00, 'paid', NULL),
	(728, 202, 'INV-0202-5', '2025-06-01', '2025-07-01', 9900.00, 'paid', NULL),
	(729, 202, 'INV-0202-6', '2025-07-01', '2025-07-31', 52800.00, 'paid', NULL),
	(730, 202, 'INV-0202-7', '2025-08-01', '2025-08-31', 43800.00, 'partial', NULL),
	(731, 202, 'INV-0202-8', '2025-09-01', '2025-10-01', 30000.00, 'paid', NULL),
	(732, 202, 'INV-0202-9', '2025-10-01', '2025-10-31', 45300.00, 'paid', NULL),
	(733, 202, 'INV-0202-10', '2025-11-01', '2025-12-01', 66600.00, 'paid', NULL),
	(734, 202, 'INV-0202-11', '2025-12-01', '2025-12-31', 26400.00, 'paid', NULL),
	(735, 202, 'INV-0202-12', '2026-01-01', '2026-01-31', 18900.00, 'paid', NULL),
	(736, 202, 'INV-0202-13', '2026-02-01', '2026-03-03', 42000.00, 'paid', NULL),
	(737, 202, 'INV-0202-14', '2026-03-01', '2026-03-31', 72900.00, 'paid', NULL),
	(738, 203, 'INV-0203-1', '2025-05-15', '2025-06-14', 384000.00, 'partial', NULL),
	(739, 204, 'INV-0204-1', '2026-02-03', '2026-03-05', 328000.00, 'paid', NULL),
	(740, 205, 'INV-0205-1', '2025-07-25', '2025-08-24', 255000.00, 'paid', NULL),
	(741, 206, 'INV-0206-1', '2025-07-01', '2025-07-31', 18600.00, 'paid', NULL),
	(742, 206, 'INV-0206-2', '2025-08-01', '2025-08-31', 1200.00, 'paid', NULL),
	(743, 207, 'INV-0207-1', '2026-08-01', '2026-08-31', 7200.00, 'paid', NULL),
	(744, 207, 'INV-0207-2', '2026-09-01', '2026-10-01', 23400.00, 'paid', NULL),
	(745, 207, 'INV-0207-3', '2026-10-01', '2026-10-31', 21600.00, 'issued', NULL),
	(746, 207, 'INV-0207-4', '2026-10-18', '2026-11-17', 24300.00, 'issued', NULL),
	(747, 208, 'INV-0208-1', '2026-04-20', '2026-05-20', 135500.00, 'paid', NULL),
	(748, 208, 'INV-0208-2', '2026-07-21', '2026-08-20', 135500.00, 'paid', NULL),
	(749, 209, 'INV-0209-1', '2025-02-05', '2025-03-07', 167000.00, 'paid', NULL),
	(750, 210, 'INV-0210-1', '2026-04-30', '2026-05-30', 329000.00, 'paid', NULL),
	(751, 211, 'INV-0211-1', '2024-11-01', '2024-12-01', 36000.00, 'paid', NULL),
	(752, 211, 'INV-0211-2', '2024-12-01', '2024-12-31', 33000.00, 'paid', NULL),
	(753, 211, 'INV-0211-3', '2025-01-01', '2025-01-31', 29700.00, 'paid', NULL),
	(754, 211, 'INV-0211-4', '2025-02-01', '2025-03-03', 51900.00, 'paid', NULL),
	(755, 211, 'INV-0211-5', '2025-03-01', '2025-03-31', 38100.00, 'paid', NULL),
	(756, 211, 'INV-0211-6', '2025-04-01', '2025-05-01', 21600.00, 'paid', NULL),
	(757, 211, 'INV-0211-7', '2025-05-01', '2025-05-31', 60000.00, 'paid', NULL),
	(758, 211, 'INV-0211-8', '2025-06-01', '2025-07-01', 33300.00, 'paid', NULL),
	(759, 212, 'INV-0212-1', '2025-04-19', '2025-05-19', 102000.00, 'paid', NULL),
	(760, 213, 'INV-0213-1', '2024-09-12', '2024-10-12', 17000.00, 'paid', NULL),
	(761, 213, 'INV-0213-2', '2024-11-12', '2024-12-12', 17000.00, 'paid', NULL),
	(762, 214, 'INV-0214-1', '2024-09-30', '2024-10-30', 66000.00, 'paid', NULL);


--
-- Data for Name: law_document; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.law_document VALUES
	(2, 'statute', '中华人民共和国公司法（2023修订）', '全国人民代表大会常务委员会', '2023-12-29', NULL, NULL, '{corporate}', NULL, NULL, '2026-10-18 19:23:26.224524+08'),
	(1, 'statute', '中华人民共和国民法典', '全国人民代表大会', '2020-05-28', NULL, '（演示摘录，请以官方文本为准）
第一百八十八条　向人民法院请求保护民事权利的诉讼时效期间为三年。法律另有规定的，依照其规定。诉讼时效期间自权利人知道或者应当知道权利受到损害以及义务人之日起计算。法律另有规定的，依照其规定。但是，自权利受到损害之日起超过二十年的，人民法院不予保护，有特殊情况的，人民法院可以根据权利人的申请决定延长。
第五百七十七条　当事人一方不履行合同义务或者履行合同义务不符合约定的，应当承担继续履行、采取补救措施或者赔偿损失等违约责任。
第五百八十五条　当事人可以约定一方违约时应当根据违约情况向对方支付一定数额的违约金，也可以约定因违约产生的损失赔偿额的计算方法。约定的违约金低于造成的损失的，人民法院或者仲裁机构可以根据当事人的请求予以增加；约定的违约金过分高于造成的损失的，人民法院或者仲裁机构可以根据当事人的请求予以适当减少。当事人就迟延履行约定违约金的，违约方支付违约金后，还应当履行债务。', '{civil}', NULL, NULL, '2026-10-18 19:23:26.224524+08'),
	(3, 'statute', '中华人民共和国劳动合同法（摘录）', '全国人民代表大会常务委员会', '2012-12-28', '2013-07-01', '（演示摘录，请以官方文本为准）
第四十七条　经济补偿按劳动者在本单位工作的年限，每满一年支付一个月工资的标准向劳动者支付。六个月以上不满一年的，按一年计算；不满六个月的，向劳动者支付半个月工资的经济补偿。劳动者月工资高于用人单位所在直辖市、设区的市级人民政府公布的本地区上年度职工月平均工资三倍的，向其支付经济补偿的标准按职工月平均工资三倍的数额支付，向其支付经济补偿的年限最高不超过十二年。本条所称月工资是指劳动者在劳动合同解除或者终止前十二个月的平均工资。
第八十七条　用人单位违反本法规定解除或者终止劳动合同的，应当依照本法第四十七条规定的经济补偿标准的二倍向劳动者支付赔偿金。', '{labor}', NULL, NULL, '2026-10-18 19:23:26.224524+08'),
	(4, 'statute', '中华人民共和国劳动争议调解仲裁法（摘录）', '全国人民代表大会常务委员会', '2007-12-29', '2008-05-01', '（演示摘录，请以官方文本为准）
第二十七条　劳动争议申请仲裁的时效期间为一年。仲裁时效期间从当事人知道或者应当知道其权利被侵害之日起计算。', '{labor}', NULL, NULL, '2026-10-18 19:23:26.224524+08');


--
-- Data for Name: payment; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.payment VALUES
	(1, 1, '2026-04-15', 120000.00, NULL, NULL),
	(2, 2, '2026-04-15', 80000.00, NULL, NULL),
	(3, 3, '2026-04-15', 300000.00, NULL, NULL),
	(4, 4, '2026-04-15', 30000.00, NULL, NULL),
	(5, 5, '2026-04-15', 200000.00, NULL, NULL),
	(6, 6, '2026-04-15', 150000.00, NULL, NULL),
	(7, 7, '2026-09-19', 159500.00, 'bank_transfer', NULL),
	(8, 9, '2024-04-10', 99600.00, 'bank_transfer', NULL),
	(9, 10, '2024-05-11', 132800.00, 'wechat_pay', NULL),
	(10, 11, '2024-06-24', 99600.00, 'wechat_pay', NULL),
	(11, 12, '2024-07-10', 29400.00, 'bank_transfer', NULL),
	(12, 13, '2024-08-14', 60000.00, 'wechat_pay', NULL),
	(13, 14, '2024-08-15', 76800.00, 'bank_transfer', NULL),
	(14, 15, '2024-09-20', 14700.00, 'alipay', NULL),
	(15, 16, '2024-10-13', 51000.00, 'bank_transfer', NULL),
	(16, 17, '2026-09-15', 179000.00, 'alipay', NULL),
	(17, 18, '2024-03-04', 91000.00, 'bank_transfer', NULL),
	(18, 19, '2024-09-29', 14700.00, 'bank_transfer', NULL),
	(19, 20, '2024-10-27', 47400.00, 'bank_transfer', NULL),
	(20, 23, '2025-10-23', 15000.00, 'bank_transfer', NULL),
	(21, 24, '2024-10-14', 60300.00, 'bank_transfer', NULL),
	(22, 25, '2025-02-04', 80400.00, 'bank_transfer', NULL),
	(23, 27, '2026-01-03', 41100.00, 'alipay', NULL),
	(24, 28, '2025-12-17', 16800.00, 'wechat_pay', NULL),
	(25, 29, '2026-02-02', 69300.00, 'bank_transfer', NULL),
	(26, 30, '2026-03-17', 41700.00, 'bank_transfer', NULL),
	(27, 31, '2026-05-02', 73800.00, 'wechat_pay', NULL),
	(28, 33, '2026-05-14', 30600.00, 'alipay', NULL),
	(29, 34, '2026-07-10', 13800.00, 'bank_transfer', NULL),
	(30, 35, '2026-07-17', 30600.00, 'bank_transfer', NULL),
	(31, 37, '2025-08-28', 204500.00, 'alipay', NULL),
	(32, 38, '2024-11-13', 25800.00, 'bank_transfer', NULL),
	(33, 39, '2024-12-18', 23100.00, 'bank_transfer', NULL),
	(34, 40, '2025-02-09', 14629.51, 'alipay', NULL),
	(35, 41, '2025-06-15', 18900.00, 'bank_transfer', NULL),
	(36, 43, '2025-06-17', 12600.00, 'alipay', NULL),
	(37, 44, '2025-08-05', 7200.00, 'bank_transfer', NULL),
	(38, 45, '2025-09-29', 22500.00, 'bank_transfer', NULL),
	(39, 46, '2025-11-12', 3600.00, 'bank_transfer', NULL),
	(40, 47, '2025-11-27', 18900.00, 'wechat_pay', NULL),
	(41, 48, '2025-12-29', 8100.00, 'bank_transfer', NULL),
	(42, 49, '2026-01-19', 22500.00, 'alipay', NULL),
	(43, 50, '2025-03-16', 160000.00, 'alipay', NULL),
	(44, 51, '2024-04-22', 98100.00, 'alipay', NULL),
	(45, 52, '2024-07-29', 130800.00, 'alipay', NULL),
	(46, 53, '2024-09-07', 98100.00, 'bank_transfer', NULL),
	(47, 54, '2024-10-15', 128000.00, 'wechat_pay', NULL),
	(48, 55, '2025-04-06', 10800.00, 'bank_transfer', NULL),
	(49, 56, '2025-03-29', 21600.00, 'bank_transfer', NULL),
	(50, 58, '2025-07-10', 4800.00, 'bank_transfer', NULL),
	(51, 59, '2025-06-22', 8400.00, 'bank_transfer', NULL),
	(52, 60, '2025-12-25', 25500.00, 'wechat_pay', NULL),
	(53, 61, '2026-04-05', 25500.00, 'bank_transfer', NULL),
	(54, 62, '2026-07-16', 19500.00, 'bank_transfer', NULL),
	(55, 63, '2026-08-10', 19500.00, 'bank_transfer', NULL),
	(56, 64, '2026-06-22', 563000.00, 'bank_transfer', NULL),
	(57, 65, '2025-03-08', 137000.00, 'alipay', NULL),
	(58, 66, '2026-06-06', 38000.00, 'bank_transfer', NULL),
	(59, 67, '2026-09-09', 4800.00, 'alipay', NULL),
	(60, 68, '2026-09-02', 8400.00, 'bank_transfer', NULL),
	(61, 70, '2024-08-09', 28800.00, 'wechat_pay', NULL),
	(62, 71, '2024-10-31', 43200.00, 'bank_transfer', NULL),
	(63, 72, '2024-10-29', 40500.00, 'bank_transfer', NULL),
	(64, 74, '2024-12-29', 10800.00, 'bank_transfer', NULL),
	(65, 75, '2025-04-16', 257500.00, 'alipay', NULL),
	(66, 77, '2025-05-30', 67200.00, 'bank_transfer', NULL),
	(67, 78, '2025-05-23', 89600.00, 'bank_transfer', NULL),
	(68, 79, '2025-08-21', 67200.00, 'bank_transfer', NULL),
	(69, 80, '2025-06-19', 6000.00, 'alipay', NULL),
	(70, 81, '2025-11-05', 8000.00, 'bank_transfer', NULL),
	(71, 82, '2026-02-13', 6000.00, 'bank_transfer', NULL),
	(72, 83, '2024-12-29', 15600.00, 'bank_transfer', NULL),
	(73, 84, '2025-03-11', 20800.00, 'bank_transfer', NULL),
	(74, 85, '2025-02-06', 15600.00, 'bank_transfer', NULL),
	(75, 86, '2025-12-31', 110000.00, 'wechat_pay', NULL),
	(76, 87, '2026-05-14', 110000.00, 'bank_transfer', NULL),
	(77, 88, '2025-10-25', 76000.00, 'bank_transfer', NULL),
	(78, 89, '2026-01-18', 76000.00, 'wechat_pay', NULL),
	(79, 90, '2025-05-05', 40200.00, 'bank_transfer', NULL),
	(80, 91, '2025-08-04', 53600.00, 'bank_transfer', NULL),
	(81, 92, '2025-12-14', 40200.00, 'wechat_pay', NULL),
	(82, 93, '2025-08-22', 13500.00, 'bank_transfer', NULL),
	(83, 94, '2025-09-19', 14400.00, 'bank_transfer', NULL),
	(84, 95, '2025-10-31', 12657.52, 'bank_transfer', NULL),
	(85, 96, '2025-11-10', 9900.00, 'wechat_pay', NULL),
	(86, 97, '2026-01-15', 10800.00, 'bank_transfer', NULL),
	(87, 98, '2026-07-20', 30500.00, 'bank_transfer', NULL),
	(88, 99, '2026-09-10', 30500.00, 'wechat_pay', NULL),
	(89, 100, '2024-11-27', 17400.00, 'bank_transfer', NULL),
	(90, 101, '2024-12-05', 14400.00, 'bank_transfer', NULL),
	(91, 102, '2025-02-12', 16200.00, 'bank_transfer', NULL),
	(92, 103, '2025-02-05', 7200.00, 'bank_transfer', NULL),
	(93, 104, '2025-03-02', 7200.00, 'bank_transfer', NULL),
	(94, 105, '2025-03-25', 6000.00, 'bank_transfer', NULL),
	(95, 107, '2025-06-12', 7200.00, 'bank_transfer', NULL),
	(96, 108, '2025-06-21', 16800.00, 'alipay', NULL),
	(97, 109, '2025-07-27', 3000.00, 'bank_transfer', NULL),
	(98, 111, '2025-11-11', 4800.00, 'alipay', NULL),
	(99, 112, '2025-10-25', 19800.00, 'alipay', NULL),
	(100, 113, '2025-11-28', 17400.00, 'bank_transfer', NULL),
	(101, 114, '2026-04-11', 74400.00, 'bank_transfer', NULL),
	(102, 115, '2026-06-01', 24300.00, 'bank_transfer', NULL),
	(103, 116, '2026-08-11', 15368.51, 'bank_transfer', NULL),
	(104, 117, '2026-08-27', 74700.00, 'bank_transfer', NULL),
	(105, 118, '2026-09-03', 18900.00, 'bank_transfer', NULL),
	(106, 119, '2026-09-23', 28200.00, 'alipay', NULL),
	(107, 122, '2024-12-16', 34500.00, 'alipay', NULL),
	(108, 123, '2025-03-01', 25727.12, 'wechat_pay', NULL),
	(109, 124, '2025-03-06', 48300.00, 'alipay', NULL),
	(110, 125, '2025-03-31', 31800.00, 'alipay', NULL),
	(111, 126, '2025-06-12', 35400.00, 'bank_transfer', NULL),
	(112, 127, '2025-06-25', 10800.00, 'alipay', NULL),
	(113, 128, '2025-07-29', 57900.00, 'bank_transfer', NULL),
	(114, 129, '2025-09-03', 36300.00, 'bank_transfer', NULL),
	(115, 130, '2025-09-14', 52200.00, 'wechat_pay', NULL),
	(116, 131, '2025-10-26', 64200.00, 'alipay', NULL),
	(117, 132, '2025-10-26', 50100.00, 'alipay', NULL),
	(118, 133, '2025-12-11', 32100.00, 'wechat_pay', NULL),
	(119, 134, '2026-01-19', 34200.00, 'wechat_pay', NULL),
	(120, 135, '2026-03-04', 16718.14, 'bank_transfer', NULL),
	(121, 137, '2025-04-09', 33900.00, 'bank_transfer', NULL),
	(122, 138, '2025-04-10', 30000.00, 'wechat_pay', NULL),
	(123, 139, '2025-04-15', 37800.00, 'wechat_pay', NULL),
	(124, 140, '2025-07-12', 45300.00, 'bank_transfer', NULL),
	(125, 141, '2026-03-09', 6600.00, 'wechat_pay', NULL),
	(126, 142, '2026-03-31', 4200.00, 'bank_transfer', NULL),
	(127, 143, '2026-04-20', 13200.00, 'bank_transfer', NULL),
	(128, 144, '2026-04-10', 14400.00, 'wechat_pay', NULL),
	(129, 145, '2026-06-11', 13200.00, 'bank_transfer', NULL),
	(130, 146, '2026-06-09', 4200.00, 'bank_transfer', NULL),
	(131, 147, '2026-07-16', 4821.67, 'wechat_pay', NULL),
	(132, 148, '2026-08-28', 6000.00, 'alipay', NULL),
	(133, 149, '2026-10-05', 9000.00, 'wechat_pay', NULL),
	(134, 151, '2026-04-19', 14400.00, 'wechat_pay', NULL),
	(135, 152, '2026-05-11', 9900.00, 'wechat_pay', NULL),
	(136, 153, '2026-07-04', 17100.00, 'bank_transfer', NULL),
	(137, 154, '2026-08-25', 8100.00, 'alipay', NULL),
	(138, 155, '2026-08-13', 16200.00, 'bank_transfer', NULL),
	(139, 160, '2025-05-16', 27000.00, 'bank_transfer', NULL),
	(140, 161, '2025-08-06', 12600.00, 'alipay', NULL),
	(141, 162, '2025-07-30', 26100.00, 'wechat_pay', NULL),
	(142, 163, '2025-08-25', 17100.00, 'alipay', NULL),
	(143, 164, '2025-09-30', 8100.00, 'wechat_pay', NULL),
	(144, 165, '2025-10-18', 12600.00, 'wechat_pay', NULL),
	(145, 166, '2025-03-14', 23100.00, 'bank_transfer', NULL),
	(146, 167, '2025-06-08', 15000.00, 'wechat_pay', NULL),
	(147, 168, '2025-06-30', 6900.00, 'bank_transfer', NULL),
	(148, 169, '2025-08-09', 42600.00, 'wechat_pay', NULL),
	(149, 170, '2025-09-10', 15300.00, 'alipay', NULL),
	(150, 171, '2025-09-30', 12600.00, 'alipay', NULL),
	(151, 172, '2025-10-07', 27900.00, 'alipay', NULL),
	(152, 173, '2025-07-10', 48008.66, 'bank_transfer', NULL),
	(153, 174, '2025-08-31', 48600.00, 'alipay', NULL),
	(154, 175, '2025-11-14', 45000.00, 'alipay', NULL),
	(155, 176, '2025-12-15', 46200.00, 'alipay', NULL),
	(156, 177, '2025-11-12', 52800.00, 'bank_transfer', NULL),
	(157, 178, '2026-01-23', 55500.00, 'alipay', NULL),
	(158, 179, '2026-08-30', 14000.00, 'bank_transfer', NULL),
	(159, 180, '2026-10-09', 14000.00, 'wechat_pay', NULL),
	(160, 182, '2024-06-07', 9670.55, 'wechat_pay', NULL),
	(161, 183, '2025-04-03', 17439.84, 'alipay', NULL),
	(162, 185, '2024-07-19', 5131.11, 'bank_transfer', NULL),
	(163, 186, '2024-09-15', 14400.00, 'wechat_pay', NULL),
	(164, 187, '2026-07-04', 8550.64, 'alipay', NULL),
	(165, 188, '2026-08-07', 6000.00, 'bank_transfer', NULL),
	(166, 189, '2026-09-02', 8400.00, 'alipay', NULL),
	(167, 190, '2026-09-14', 11400.00, 'bank_transfer', NULL),
	(168, 191, '2026-09-20', 6000.00, 'alipay', NULL),
	(169, 194, '2025-09-23', 27857.29, 'alipay', NULL),
	(170, 195, '2025-10-17', 80000.00, 'bank_transfer', NULL),
	(171, 196, '2026-03-08', 387000.00, 'alipay', NULL),
	(172, 197, '2026-10-12', 49500.00, 'bank_transfer', NULL),
	(173, 199, '2025-10-21', 9000.00, 'wechat_pay', NULL),
	(174, 202, '2026-01-16', 16200.00, 'bank_transfer', NULL),
	(175, 203, '2026-02-19', 25500.00, 'bank_transfer', NULL),
	(176, 204, '2026-05-01', 44700.00, 'alipay', NULL),
	(177, 205, '2024-05-20', 15600.00, 'wechat_pay', NULL),
	(178, 206, '2024-05-22', 20800.00, 'alipay', NULL),
	(179, 207, '2024-07-13', 15600.00, 'alipay', NULL),
	(180, 209, '2025-03-26', 58400.00, 'alipay', NULL),
	(181, 210, '2025-08-07', 43800.00, 'bank_transfer', NULL),
	(182, 211, '2026-01-02', 29000.00, 'bank_transfer', NULL),
	(183, 212, '2026-05-18', 29000.00, 'alipay', NULL),
	(184, 216, '2024-12-08', 18900.00, 'bank_transfer', NULL),
	(185, 217, '2024-12-25', 11700.00, 'wechat_pay', NULL),
	(186, 218, '2025-01-09', 21600.00, 'alipay', NULL),
	(187, 219, '2025-03-29', 17100.00, 'bank_transfer', NULL),
	(188, 221, '2025-05-21', 7200.00, 'bank_transfer', NULL),
	(189, 222, '2025-07-02', 34200.00, 'bank_transfer', NULL),
	(190, 223, '2025-10-14', 6000.00, 'wechat_pay', NULL),
	(191, 224, '2025-10-15', 3000.00, 'bank_transfer', NULL),
	(192, 225, '2025-12-13', 10800.00, 'bank_transfer', NULL),
	(193, 226, '2025-11-19', 14400.00, 'alipay', NULL),
	(194, 227, '2026-01-30', 6600.00, 'alipay', NULL),
	(195, 228, '2026-02-13', 12600.00, 'alipay', NULL),
	(196, 229, '2026-02-22', 12000.00, 'bank_transfer', NULL),
	(197, 230, '2026-03-18', 12000.00, 'alipay', NULL),
	(198, 231, '2026-05-07', 16200.00, 'alipay', NULL),
	(199, 232, '2026-07-14', 8400.00, 'alipay', NULL),
	(200, 233, '2026-06-10', 1200.00, 'alipay', NULL);
INSERT INTO public.payment VALUES
	(201, 234, '2026-08-08', 7800.00, 'wechat_pay', NULL),
	(202, 235, '2026-08-19', 7800.00, 'bank_transfer', NULL),
	(203, 236, '2026-09-26', 4800.00, 'alipay', NULL),
	(204, 238, '2024-11-14', 103000.00, 'bank_transfer', NULL),
	(205, 239, '2025-05-05', 103000.00, 'alipay', NULL),
	(206, 240, '2025-03-07', 39600.00, 'wechat_pay', NULL),
	(207, 241, '2025-06-07', 52800.00, 'wechat_pay', NULL),
	(208, 242, '2025-12-08', 39600.00, 'wechat_pay', NULL),
	(209, 246, '2026-07-27', 18300.00, 'bank_transfer', NULL),
	(210, 254, '2025-01-18', 246000.00, 'bank_transfer', NULL),
	(211, 256, '2025-09-21', 269102.38, 'wechat_pay', NULL),
	(212, 257, '2025-04-01', 33600.00, 'bank_transfer', NULL),
	(213, 258, '2025-03-25', 44800.00, 'bank_transfer', NULL),
	(214, 259, '2025-05-05', 33600.00, 'wechat_pay', NULL),
	(215, 260, '2025-05-15', 102000.00, 'alipay', NULL),
	(216, 261, '2025-10-02', 99000.00, 'alipay', NULL),
	(217, 262, '2026-02-19', 27000.00, 'bank_transfer', NULL),
	(218, 263, '2026-03-18', 26100.00, 'bank_transfer', NULL),
	(219, 264, '2026-03-16', 6300.00, 'bank_transfer', NULL),
	(220, 265, '2026-06-10', 9000.00, 'alipay', NULL),
	(221, 266, '2026-05-13', 20700.00, 'wechat_pay', NULL),
	(222, 267, '2026-07-11', 7200.00, 'wechat_pay', NULL),
	(223, 268, '2026-08-17', 36900.00, 'wechat_pay', NULL),
	(224, 269, '2026-08-17', 14400.00, 'bank_transfer', NULL),
	(225, 273, '2024-10-09', 8578.82, 'bank_transfer', NULL),
	(226, 274, '2024-10-15', 10800.00, 'bank_transfer', NULL),
	(227, 275, '2024-12-13', 23400.00, 'wechat_pay', NULL),
	(228, 276, '2025-01-06', 11700.00, 'alipay', NULL),
	(229, 277, '2025-03-06', 27900.00, 'wechat_pay', NULL),
	(230, 278, '2025-03-02', 7200.00, 'alipay', NULL),
	(231, 279, '2025-03-21', 4348.91, 'alipay', NULL),
	(232, 280, '2025-05-23', 23400.00, 'alipay', NULL),
	(233, 281, '2025-05-26', 12600.00, 'bank_transfer', NULL),
	(234, 282, '2025-08-04', 17100.00, 'alipay', NULL),
	(235, 283, '2025-07-14', 21600.00, 'alipay', NULL),
	(236, 284, '2025-08-11', 17100.00, 'wechat_pay', NULL),
	(237, 285, '2025-09-24', 13500.00, 'wechat_pay', NULL),
	(238, 286, '2025-10-09', 21600.00, 'bank_transfer', NULL),
	(239, 287, '2026-01-03', 18000.00, 'bank_transfer', NULL),
	(240, 289, '2026-03-06', 15300.00, 'alipay', NULL),
	(241, 290, '2026-03-22', 10800.00, 'wechat_pay', NULL),
	(242, 291, '2025-11-28', 220000.00, 'alipay', NULL),
	(243, 292, '2025-11-01', 22200.00, 'wechat_pay', NULL),
	(244, 293, '2025-10-22', 30600.00, 'wechat_pay', NULL),
	(245, 294, '2025-12-10', 17400.00, 'wechat_pay', NULL),
	(246, 296, '2026-02-18', 24000.00, 'bank_transfer', NULL),
	(247, 297, '2026-03-11', 36600.00, 'alipay', NULL),
	(248, 298, '2026-03-12', 15600.00, 'alipay', NULL),
	(249, 299, '2026-05-15', 27000.00, 'alipay', NULL),
	(250, 300, '2026-06-20', 9000.00, 'bank_transfer', NULL),
	(251, 301, '2026-07-29', 10800.00, 'alipay', NULL),
	(252, 302, '2026-09-01', 16200.00, 'alipay', NULL),
	(253, 303, '2026-08-16', 24000.00, 'alipay', NULL),
	(254, 305, '2026-10-16', 15886.62, 'bank_transfer', NULL),
	(255, 308, '2025-01-12', 16800.00, 'bank_transfer', NULL),
	(256, 309, '2025-02-27', 4800.00, 'bank_transfer', NULL),
	(257, 310, '2024-10-10', 30500.00, 'alipay', NULL),
	(258, 311, '2025-01-03', 30500.00, 'bank_transfer', NULL),
	(259, 312, '2026-09-14', 105500.00, 'bank_transfer', NULL),
	(260, 314, '2025-01-05', 27000.00, 'bank_transfer', NULL),
	(261, 315, '2025-05-11', 73500.00, 'bank_transfer', NULL),
	(262, 316, '2025-07-22', 98000.00, 'wechat_pay', NULL),
	(263, 317, '2026-01-06', 73500.00, 'bank_transfer', NULL),
	(264, 318, '2025-11-24', 183000.00, 'bank_transfer', NULL),
	(265, 319, '2026-01-06', 93026.02, 'bank_transfer', NULL),
	(266, 320, '2025-12-12', 183000.00, 'bank_transfer', NULL),
	(267, 321, '2026-04-14', 17100.00, 'bank_transfer', NULL),
	(268, 322, '2026-06-08', 10800.00, 'bank_transfer', NULL),
	(269, 323, '2026-07-19', 10800.00, 'wechat_pay', NULL),
	(270, 324, '2026-08-27', 5400.00, 'wechat_pay', NULL),
	(271, 325, '2026-08-10', 2700.00, 'alipay', NULL),
	(272, 326, '2026-02-14', 204000.00, 'bank_transfer', NULL),
	(273, 327, '2025-01-19', 44100.00, 'bank_transfer', NULL),
	(274, 328, '2025-02-09', 34500.00, 'bank_transfer', NULL),
	(275, 329, '2025-02-28', 38400.00, 'wechat_pay', NULL),
	(276, 330, '2025-03-15', 63000.00, 'alipay', NULL),
	(277, 331, '2025-04-26', 40200.00, 'wechat_pay', NULL),
	(278, 332, '2025-05-31', 48000.00, 'wechat_pay', NULL),
	(279, 333, '2025-08-14', 31500.00, 'wechat_pay', NULL),
	(280, 334, '2025-08-15', 26700.00, 'alipay', NULL),
	(281, 335, '2025-09-09', 33000.00, 'bank_transfer', NULL),
	(282, 336, '2025-09-19', 63000.00, 'bank_transfer', NULL),
	(283, 337, '2024-11-21', 18000.00, 'bank_transfer', NULL),
	(284, 338, '2025-02-24', 189500.00, 'bank_transfer', NULL),
	(285, 339, '2025-08-25', 189500.00, 'bank_transfer', NULL),
	(286, 340, '2026-04-18', 40500.00, 'bank_transfer', NULL),
	(287, 341, '2026-08-09', 54000.00, 'alipay', NULL),
	(288, 344, '2024-09-18', 119000.00, 'bank_transfer', NULL),
	(289, 345, '2025-12-09', 151000.00, 'bank_transfer', NULL),
	(290, 346, '2026-05-07', 151000.00, 'bank_transfer', NULL),
	(291, 347, '2026-04-09', 16500.00, 'alipay', NULL),
	(292, 348, '2026-05-26', 22000.00, 'alipay', NULL),
	(293, 349, '2026-06-15', 16500.00, 'bank_transfer', NULL),
	(294, 351, '2025-02-08', 24300.00, 'bank_transfer', NULL),
	(295, 352, '2025-02-21', 16200.00, 'wechat_pay', NULL),
	(296, 353, '2025-04-26', 12600.00, 'wechat_pay', NULL),
	(297, 354, '2024-10-19', 174000.00, 'alipay', NULL),
	(298, 355, '2025-02-26', 174000.00, 'wechat_pay', NULL),
	(299, 356, '2024-06-16', 24300.00, 'bank_transfer', NULL),
	(300, 357, '2024-07-10', 45000.00, 'wechat_pay', NULL),
	(301, 358, '2024-09-06', 41100.00, 'bank_transfer', NULL),
	(302, 359, '2024-09-16', 37800.00, 'bank_transfer', NULL),
	(303, 360, '2024-09-30', 58800.00, 'alipay', NULL),
	(304, 361, '2024-11-15', 15641.38, 'wechat_pay', NULL),
	(305, 362, '2025-01-15', 25500.00, 'alipay', NULL),
	(306, 363, '2025-01-25', 43200.00, 'wechat_pay', NULL),
	(307, 364, '2025-02-05', 31800.00, 'alipay', NULL),
	(308, 365, '2025-03-21', 27600.00, 'bank_transfer', NULL),
	(309, 366, '2025-03-09', 58500.00, 'bank_transfer', NULL),
	(310, 367, '2026-06-22', 19500.00, 'bank_transfer', NULL),
	(311, 368, '2026-09-15', 26000.00, 'alipay', NULL),
	(312, 369, '2026-09-28', 19500.00, 'bank_transfer', NULL),
	(313, 370, '2025-02-16', 81300.00, 'wechat_pay', NULL),
	(314, 371, '2025-07-20', 108400.00, 'bank_transfer', NULL),
	(315, 372, '2025-10-22', 81300.00, 'bank_transfer', NULL),
	(316, 373, '2026-04-28', 219000.00, 'bank_transfer', NULL),
	(317, 376, '2026-09-10', 34200.00, 'bank_transfer', NULL),
	(318, 377, '2026-09-08', 33300.00, 'bank_transfer', NULL),
	(319, 380, '2026-09-13', 95000.00, 'bank_transfer', NULL),
	(320, 381, '2026-10-05', 95000.00, 'alipay', NULL),
	(321, 382, '2024-09-15', 18298.21, 'bank_transfer', NULL),
	(322, 383, '2024-11-04', 17700.00, 'wechat_pay', NULL),
	(323, 384, '2024-11-28', 25500.00, 'bank_transfer', NULL),
	(324, 385, '2024-12-03', 41700.00, 'bank_transfer', NULL),
	(325, 386, '2025-01-09', 36600.00, 'alipay', NULL),
	(326, 387, '2025-01-09', 19500.00, 'wechat_pay', NULL),
	(327, 388, '2025-03-16', 54000.00, 'bank_transfer', NULL),
	(328, 389, '2025-04-20', 23400.00, 'wechat_pay', NULL),
	(329, 390, '2025-05-26', 18600.00, 'wechat_pay', NULL),
	(330, 391, '2025-05-11', 16200.00, 'alipay', NULL),
	(331, 393, '2026-06-15', 189000.00, 'bank_transfer', NULL),
	(332, 394, '2024-12-05', 67000.00, 'alipay', NULL),
	(333, 395, '2025-02-26', 182000.00, 'bank_transfer', NULL),
	(334, 397, '2025-08-12', 288000.00, 'wechat_pay', NULL),
	(335, 398, '2026-06-12', 30300.00, 'bank_transfer', NULL),
	(336, 399, '2026-06-13', 14400.00, 'alipay', NULL),
	(337, 400, '2026-07-12', 17805.43, 'bank_transfer', NULL),
	(338, 401, '2026-08-29', 39900.00, 'wechat_pay', NULL),
	(339, 402, '2026-09-18', 11782.65, 'bank_transfer', NULL),
	(340, 403, '2026-09-27', 24900.00, 'wechat_pay', NULL),
	(341, 406, '2025-04-21', 11000.00, 'bank_transfer', NULL),
	(342, 407, '2025-07-29', 11000.00, 'bank_transfer', NULL),
	(343, 408, '2026-07-11', 457000.00, 'alipay', NULL),
	(344, 409, '2024-12-01', 16200.00, 'alipay', NULL),
	(345, 410, '2024-11-23', 9000.00, 'bank_transfer', NULL),
	(346, 411, '2025-01-19', 9000.00, 'bank_transfer', NULL),
	(347, 412, '2025-03-16', 17100.00, 'wechat_pay', NULL),
	(348, 413, '2025-03-03', 2700.00, 'bank_transfer', NULL),
	(349, 414, '2025-03-18', 26100.00, 'bank_transfer', NULL),
	(350, 415, '2025-06-09', 6300.00, 'wechat_pay', NULL),
	(351, 416, '2025-05-17', 21600.00, 'wechat_pay', NULL),
	(352, 417, '2025-08-13', 17100.00, 'bank_transfer', NULL),
	(353, 418, '2025-08-02', 1800.00, 'wechat_pay', NULL),
	(354, 419, '2025-09-19', 14400.00, 'bank_transfer', NULL),
	(355, 420, '2025-10-22', 9000.00, 'bank_transfer', NULL),
	(356, 421, '2025-10-23', 6300.00, 'alipay', NULL),
	(357, 422, '2025-12-31', 11700.00, 'bank_transfer', NULL),
	(358, 423, '2026-01-20', 8100.00, 'alipay', NULL),
	(359, 424, '2025-06-03', 18000.00, 'wechat_pay', NULL),
	(360, 425, '2025-06-24', 14400.00, 'bank_transfer', NULL),
	(361, 426, '2025-07-01', 18000.00, 'bank_transfer', NULL),
	(362, 427, '2025-07-10', 6300.00, 'alipay', NULL),
	(363, 428, '2025-09-06', 12600.00, 'bank_transfer', NULL),
	(364, 429, '2025-10-11', 27000.00, 'wechat_pay', NULL),
	(365, 430, '2025-10-18', 12600.00, 'bank_transfer', NULL),
	(366, 431, '2025-11-25', 3600.00, 'bank_transfer', NULL),
	(367, 432, '2025-12-30', 11700.00, 'alipay', NULL),
	(368, 433, '2026-01-17', 23400.00, 'wechat_pay', NULL),
	(369, 434, '2026-03-27', 20700.00, 'alipay', NULL),
	(370, 435, '2026-03-17', 9900.00, 'bank_transfer', NULL),
	(371, 437, '2026-07-09', 12600.00, 'bank_transfer', NULL),
	(372, 438, '2026-07-06', 12600.00, 'bank_transfer', NULL),
	(373, 439, '2025-08-19', 69000.00, 'alipay', NULL),
	(374, 440, '2025-10-10', 64800.00, 'bank_transfer', NULL),
	(375, 441, '2025-10-06', 50100.00, 'wechat_pay', NULL),
	(376, 443, '2025-11-25', 62100.00, 'alipay', NULL),
	(377, 444, '2026-01-01', 71400.00, 'alipay', NULL),
	(378, 445, '2026-03-04', 54900.00, 'bank_transfer', NULL),
	(379, 446, '2026-03-27', 29400.00, 'wechat_pay', NULL),
	(380, 447, '2026-03-23', 51300.00, 'alipay', NULL),
	(381, 448, '2026-05-04', 57900.00, 'wechat_pay', NULL),
	(382, 449, '2026-06-15', 41100.00, 'wechat_pay', NULL),
	(383, 450, '2026-06-29', 10200.00, 'alipay', NULL),
	(384, 451, '2026-08-24', 67800.00, 'wechat_pay', NULL),
	(385, 452, '2026-09-30', 32400.00, 'bank_transfer', NULL),
	(386, 456, '2026-02-09', 44100.00, 'wechat_pay', NULL),
	(387, 457, '2026-06-01', 58800.00, 'bank_transfer', NULL),
	(388, 458, '2026-08-27', 44100.00, 'alipay', NULL),
	(389, 459, '2025-02-15', 82000.00, 'alipay', NULL),
	(390, 460, '2025-08-21', 82000.00, 'alipay', NULL),
	(391, 461, '2026-01-18', 259000.00, 'alipay', NULL),
	(392, 462, '2025-02-13', 27900.00, 'alipay', NULL),
	(393, 463, '2025-04-06', 10500.00, 'bank_transfer', NULL),
	(394, 464, '2025-04-03', 60600.00, 'bank_transfer', NULL),
	(395, 465, '2025-06-06', 45300.00, 'wechat_pay', NULL),
	(396, 466, '2025-05-31', 41100.00, 'bank_transfer', NULL),
	(397, 467, '2025-09-29', 59500.00, 'wechat_pay', NULL),
	(398, 468, '2026-04-09', 59500.00, 'alipay', NULL),
	(399, 469, '2026-04-20', 276000.00, 'bank_transfer', NULL),
	(400, 470, '2024-05-15', 306000.00, 'bank_transfer', NULL);
INSERT INTO public.payment VALUES
	(401, 473, '2024-03-09', 5696.18, 'bank_transfer', NULL),
	(402, 474, '2024-04-21', 8926.72, 'bank_transfer', NULL),
	(403, 475, '2024-04-23', 5400.00, 'bank_transfer', NULL),
	(404, 476, '2024-11-13', 44000.00, 'bank_transfer', NULL),
	(405, 477, '2026-04-05', 177000.00, 'wechat_pay', NULL),
	(406, 478, '2025-07-01', 25200.00, 'alipay', NULL),
	(407, 480, '2025-07-09', 19800.00, 'wechat_pay', NULL),
	(408, 481, '2024-12-12', 94308.32, 'wechat_pay', NULL),
	(409, 482, '2024-12-18', 128669.25, 'bank_transfer', NULL),
	(410, 483, '2025-03-02', 686000.00, 'bank_transfer', NULL),
	(411, 484, '2024-06-19', 13200.00, 'bank_transfer', NULL),
	(412, 485, '2025-01-26', 17600.00, 'bank_transfer', NULL),
	(413, 486, '2025-07-03', 8747.09, 'bank_transfer', NULL),
	(414, 487, '2025-02-17', 30000.00, 'wechat_pay', NULL),
	(415, 488, '2025-05-16', 30000.00, 'bank_transfer', NULL),
	(416, 489, '2024-04-23', 63000.00, 'wechat_pay', NULL),
	(417, 490, '2024-11-27', 63000.00, 'bank_transfer', NULL),
	(418, 491, '2024-05-11', 5700.00, 'alipay', NULL),
	(419, 492, '2024-10-06', 7600.00, 'bank_transfer', NULL),
	(420, 493, '2025-02-16', 5700.00, 'bank_transfer', NULL),
	(421, 494, '2024-07-20', 3600.00, 'alipay', NULL),
	(422, 495, '2024-09-18', 17100.00, 'bank_transfer', NULL),
	(423, 497, '2024-11-11', 16200.00, 'bank_transfer', NULL),
	(424, 498, '2024-11-10', 27000.00, 'wechat_pay', NULL),
	(425, 499, '2025-01-10', 32400.00, 'alipay', NULL),
	(426, 500, '2025-02-27', 19800.00, 'bank_transfer', NULL),
	(427, 501, '2025-03-26', 30600.00, 'bank_transfer', NULL),
	(428, 502, '2025-05-03', 23400.00, 'wechat_pay', NULL),
	(429, 503, '2025-06-01', 9000.00, 'bank_transfer', NULL),
	(430, 504, '2025-05-26', 18000.00, 'bank_transfer', NULL),
	(431, 505, '2025-07-18', 15300.00, 'bank_transfer', NULL),
	(432, 506, '2024-12-02', 171500.00, 'bank_transfer', NULL),
	(433, 507, '2025-02-18', 171500.00, 'wechat_pay', NULL),
	(434, 508, '2025-03-30', 37500.00, 'bank_transfer', NULL),
	(435, 509, '2025-06-07', 44100.00, 'bank_transfer', NULL),
	(436, 510, '2025-07-02', 18000.00, 'bank_transfer', NULL),
	(437, 511, '2025-08-11', 37200.00, 'bank_transfer', NULL),
	(438, 512, '2025-07-12', 64500.00, 'alipay', NULL),
	(439, 513, '2025-08-18', 12300.00, 'alipay', NULL),
	(440, 514, '2024-03-06', 70200.00, 'bank_transfer', NULL),
	(441, 515, '2024-04-22', 93600.00, 'alipay', NULL),
	(442, 516, '2024-05-24', 28382.89, 'wechat_pay', NULL),
	(443, 517, '2025-03-19', 200000.00, 'alipay', NULL),
	(444, 518, '2025-07-04', 200000.00, 'bank_transfer', NULL),
	(445, 519, '2026-06-04', 8400.00, 'alipay', NULL),
	(446, 520, '2026-07-09', 14400.00, 'bank_transfer', NULL),
	(447, 523, '2026-07-06', 284000.00, 'bank_transfer', NULL),
	(448, 526, '2024-04-27', 102275.55, 'bank_transfer', NULL),
	(449, 527, '2024-12-17', 148000.00, 'bank_transfer', NULL),
	(450, 528, '2025-11-25', 17100.00, 'alipay', NULL),
	(451, 529, '2025-11-12', 3733.39, 'bank_transfer', NULL),
	(452, 531, '2026-02-23', 13500.00, 'bank_transfer', NULL),
	(453, 532, '2026-04-08', 31500.00, 'bank_transfer', NULL),
	(454, 533, '2026-05-01', 6169.21, 'wechat_pay', NULL),
	(455, 534, '2026-06-02', 24300.00, 'bank_transfer', NULL),
	(456, 535, '2026-06-23', 4517.78, 'bank_transfer', NULL),
	(457, 536, '2026-06-26', 20700.00, 'bank_transfer', NULL),
	(458, 537, '2026-08-17', 24300.00, 'alipay', NULL),
	(459, 538, '2026-09-02', 17100.00, 'alipay', NULL),
	(460, 539, '2026-10-08', 2700.00, 'bank_transfer', NULL),
	(461, 543, '2024-04-14', 15000.00, 'wechat_pay', NULL),
	(462, 544, '2024-04-12', 4800.00, 'wechat_pay', NULL),
	(463, 545, '2024-10-29', 209000.00, 'alipay', NULL),
	(464, 546, '2025-10-09', 58500.00, 'bank_transfer', NULL),
	(465, 547, '2025-12-02', 49500.00, 'wechat_pay', NULL),
	(466, 548, '2025-12-28', 42300.00, 'bank_transfer', NULL),
	(467, 550, '2026-03-03', 50400.00, 'alipay', NULL),
	(468, 551, '2026-01-11', 29700.00, 'bank_transfer', NULL),
	(469, 553, '2026-01-08', 36300.00, 'bank_transfer', NULL),
	(470, 554, '2026-03-09', 66300.00, 'wechat_pay', NULL),
	(471, 555, '2026-04-15', 16800.00, 'alipay', NULL),
	(472, 556, '2026-05-27', 34800.00, 'wechat_pay', NULL),
	(473, 557, '2026-06-13', 50400.00, 'alipay', NULL),
	(474, 558, '2026-07-04', 21600.00, 'bank_transfer', NULL),
	(475, 560, '2026-08-18', 21900.00, 'alipay', NULL),
	(476, 562, '2026-10-12', 12600.00, 'bank_transfer', NULL),
	(477, 569, '2025-11-09', 145500.00, 'bank_transfer', NULL),
	(478, 570, '2026-02-17', 145500.00, 'bank_transfer', NULL),
	(479, 571, '2026-09-15', 16200.00, 'bank_transfer', NULL),
	(480, 572, '2026-10-14', 11898.76, 'alipay', NULL),
	(481, 573, '2026-10-13', 6409.60, 'alipay', NULL),
	(482, 576, '2024-07-05', 20000.00, 'alipay', NULL),
	(483, 577, '2024-09-20', 15000.00, 'bank_transfer', NULL),
	(484, 578, '2024-11-16', 33000.00, 'alipay', NULL),
	(485, 579, '2024-04-21', 55500.00, 'wechat_pay', NULL),
	(486, 580, '2024-06-16', 74000.00, 'wechat_pay', NULL),
	(487, 581, '2024-08-28', 55500.00, 'alipay', NULL),
	(488, 582, '2024-07-03', 4500.00, 'bank_transfer', NULL),
	(489, 583, '2024-08-12', 13500.00, 'alipay', NULL),
	(490, 584, '2026-01-19', 111600.00, 'alipay', NULL),
	(491, 585, '2026-03-19', 148800.00, 'bank_transfer', NULL),
	(492, 586, '2026-03-14', 111600.00, 'wechat_pay', NULL),
	(493, 587, '2026-05-19', 180000.00, 'wechat_pay', NULL),
	(494, 588, '2026-10-17', 30500.00, 'wechat_pay', NULL),
	(495, 590, '2026-06-14', 25200.00, 'bank_transfer', NULL),
	(496, 591, '2026-07-21', 12600.00, 'wechat_pay', NULL),
	(497, 592, '2026-09-30', 28800.00, 'alipay', NULL),
	(498, 596, '2025-08-09', 45300.00, 'bank_transfer', NULL),
	(499, 597, '2025-09-04', 20700.00, 'wechat_pay', NULL),
	(500, 598, '2025-10-04', 16737.41, 'wechat_pay', NULL),
	(501, 599, '2025-11-07', 13674.50, 'bank_transfer', NULL),
	(502, 600, '2026-01-06', 35700.00, 'bank_transfer', NULL),
	(503, 601, '2025-12-08', 49200.00, 'bank_transfer', NULL),
	(504, 602, '2026-02-24', 21600.00, 'wechat_pay', NULL),
	(505, 603, '2026-03-07', 29100.00, 'bank_transfer', NULL),
	(506, 604, '2026-03-25', 52800.00, 'bank_transfer', NULL),
	(507, 605, '2026-05-04', 36000.00, 'bank_transfer', NULL),
	(508, 606, '2026-05-15', 50100.00, 'wechat_pay', NULL),
	(509, 607, '2026-07-09', 41700.00, 'wechat_pay', NULL),
	(510, 608, '2026-09-02', 34200.00, 'bank_transfer', NULL),
	(511, 609, '2026-08-30', 35700.00, 'wechat_pay', NULL),
	(512, 611, '2026-04-14', 353000.00, 'bank_transfer', NULL),
	(513, 612, '2026-08-15', 353000.00, 'bank_transfer', NULL),
	(514, 613, '2026-10-10', 20100.00, 'bank_transfer', NULL),
	(515, 614, '2026-09-17', 30600.00, 'alipay', NULL),
	(516, 617, '2026-03-07', 36000.00, 'bank_transfer', NULL),
	(517, 618, '2025-10-16', 104700.00, 'alipay', NULL),
	(518, 619, '2025-10-28', 139600.00, 'bank_transfer', NULL),
	(519, 620, '2025-12-30', 104700.00, 'alipay', NULL),
	(520, 622, '2024-07-17', 35600.00, 'wechat_pay', NULL),
	(521, 623, '2024-07-16', 26700.00, 'bank_transfer', NULL),
	(522, 624, '2025-01-02', 23000.00, 'alipay', NULL),
	(523, 625, '2026-06-28', 1800.00, 'wechat_pay', NULL),
	(524, 626, '2026-06-20', 21600.00, 'alipay', NULL),
	(525, 628, '2026-10-02', 5400.00, 'bank_transfer', NULL),
	(526, 629, '2026-09-29', 12000.00, 'alipay', NULL),
	(527, 630, '2026-10-15', 6032.46, 'bank_transfer', NULL),
	(528, 632, '2026-04-28', 3753.06, 'bank_transfer', NULL),
	(529, 633, '2026-05-29', 6656.65, 'alipay', NULL),
	(530, 634, '2026-05-28', 20700.00, 'alipay', NULL),
	(531, 635, '2026-08-11', 12600.00, 'bank_transfer', NULL),
	(532, 636, '2026-08-04', 31500.00, 'wechat_pay', NULL),
	(533, 637, '2026-09-17', 26100.00, 'wechat_pay', NULL),
	(534, 638, '2026-08-19', 8400.00, 'alipay', NULL),
	(535, 639, '2026-10-05', 11200.00, 'wechat_pay', NULL),
	(536, 641, '2025-08-22', 110000.00, 'wechat_pay', NULL),
	(537, 642, '2026-04-22', 110000.00, 'bank_transfer', NULL),
	(538, 643, '2026-02-19', 18000.00, 'bank_transfer', NULL),
	(539, 644, '2026-04-11', 11400.00, 'wechat_pay', NULL),
	(540, 645, '2026-03-29', 6491.80, 'bank_transfer', NULL),
	(541, 646, '2026-05-17', 6000.00, 'bank_transfer', NULL),
	(542, 647, '2026-06-23', 7200.00, 'wechat_pay', NULL),
	(543, 648, '2026-07-05', 1200.00, 'wechat_pay', NULL),
	(544, 649, '2026-07-16', 11400.00, 'wechat_pay', NULL),
	(545, 650, '2026-09-10', 7200.00, 'bank_transfer', NULL),
	(546, 654, '2025-04-30', 192500.00, 'bank_transfer', NULL),
	(547, 655, '2025-10-11', 108266.59, 'bank_transfer', NULL),
	(548, 656, '2026-08-18', 25200.00, 'wechat_pay', NULL),
	(549, 658, '2026-10-14', 32400.00, 'bank_transfer', NULL),
	(550, 661, '2026-03-05', 5600.00, 'bank_transfer', NULL),
	(551, 662, '2026-07-09', 4200.00, 'alipay', NULL),
	(552, 663, '2025-04-23', 81600.00, 'wechat_pay', NULL),
	(553, 664, '2025-06-06', 108800.00, 'alipay', NULL),
	(554, 665, '2025-07-01', 81600.00, 'wechat_pay', NULL),
	(555, 666, '2026-01-29', 101000.00, 'alipay', NULL),
	(556, 667, '2025-12-05', 17700.00, 'wechat_pay', NULL),
	(557, 669, '2026-01-18', 57000.00, 'bank_transfer', NULL),
	(558, 670, '2026-02-04', 54000.00, 'bank_transfer', NULL),
	(559, 671, '2026-03-25', 27600.00, 'wechat_pay', NULL),
	(560, 672, '2026-04-08', 63600.00, 'wechat_pay', NULL),
	(561, 673, '2026-04-25', 37500.00, 'bank_transfer', NULL),
	(562, 674, '2026-06-15', 66900.00, 'bank_transfer', NULL),
	(563, 675, '2026-07-07', 58500.00, 'bank_transfer', NULL),
	(564, 676, '2026-08-13', 15300.00, 'wechat_pay', NULL),
	(565, 677, '2026-08-13', 58800.00, 'bank_transfer', NULL),
	(566, 678, '2026-10-16', 40200.00, 'bank_transfer', NULL),
	(567, 681, '2026-08-08', 325000.00, 'bank_transfer', NULL),
	(568, 682, '2026-09-02', 325000.00, 'bank_transfer', NULL),
	(569, 683, '2026-02-08', 172000.00, 'wechat_pay', NULL),
	(570, 684, '2026-08-16', 172000.00, 'bank_transfer', NULL),
	(571, 685, '2025-08-12', 1800.00, 'bank_transfer', NULL),
	(572, 686, '2025-10-15', 10200.00, 'bank_transfer', NULL),
	(573, 687, '2025-11-15', 9000.00, 'alipay', NULL),
	(574, 688, '2025-10-19', 6000.00, 'alipay', NULL),
	(575, 690, '2026-01-09', 4200.00, 'bank_transfer', NULL),
	(576, 691, '2026-01-17', 13200.00, 'bank_transfer', NULL),
	(577, 692, '2026-03-06', 5400.00, 'bank_transfer', NULL),
	(578, 694, '2024-06-11', 95500.00, 'bank_transfer', NULL),
	(579, 695, '2024-12-29', 95500.00, 'alipay', NULL),
	(580, 696, '2025-08-22', 24300.00, 'bank_transfer', NULL),
	(581, 697, '2025-08-27', 20700.00, 'bank_transfer', NULL),
	(582, 699, '2025-08-22', 112500.00, 'wechat_pay', NULL),
	(583, 700, '2025-05-27', 192000.00, 'alipay', NULL),
	(584, 701, '2026-06-01', 410000.00, 'bank_transfer', NULL),
	(585, 705, '2026-01-12', 108900.00, 'wechat_pay', NULL),
	(586, 706, '2026-01-20', 145200.00, 'wechat_pay', NULL),
	(587, 707, '2026-04-04', 108900.00, 'bank_transfer', NULL),
	(588, 708, '2025-07-07', 50700.00, 'bank_transfer', NULL),
	(589, 709, '2025-11-05', 67600.00, 'wechat_pay', NULL),
	(590, 710, '2026-04-16', 50700.00, 'alipay', NULL),
	(591, 711, '2025-01-21', 7332.71, 'bank_transfer', NULL),
	(592, 712, '2025-03-05', 9600.00, 'wechat_pay', NULL),
	(593, 713, '2025-03-14', 6000.00, 'alipay', NULL),
	(594, 714, '2025-04-29', 11400.00, 'bank_transfer', NULL),
	(595, 715, '2025-05-08', 11400.00, 'wechat_pay', NULL),
	(596, 716, '2025-06-26', 8400.00, 'wechat_pay', NULL),
	(597, 717, '2025-08-08', 5400.00, 'bank_transfer', NULL),
	(598, 718, '2025-08-19', 16200.00, 'bank_transfer', NULL),
	(599, 719, '2025-10-31', 12600.00, 'bank_transfer', NULL),
	(600, 720, '2025-11-23', 16200.00, 'bank_transfer', NULL);
INSERT INTO public.payment VALUES
	(601, 721, '2025-11-18', 22800.00, 'wechat_pay', NULL),
	(602, 722, '2026-01-18', 16200.00, 'bank_transfer', NULL),
	(603, 724, '2025-02-25', 31500.00, 'wechat_pay', NULL),
	(604, 725, '2025-04-06', 27900.00, 'alipay', NULL),
	(605, 726, '2025-05-24', 50400.00, 'bank_transfer', NULL),
	(606, 727, '2025-06-06', 68100.00, 'bank_transfer', NULL),
	(607, 728, '2025-07-12', 9900.00, 'alipay', NULL),
	(608, 729, '2025-07-29', 52800.00, 'bank_transfer', NULL),
	(609, 730, '2025-09-30', 29432.59, 'alipay', NULL),
	(610, 731, '2025-09-27', 30000.00, 'bank_transfer', NULL),
	(611, 732, '2025-10-30', 45300.00, 'bank_transfer', NULL),
	(612, 733, '2026-01-05', 66600.00, 'bank_transfer', NULL),
	(613, 734, '2025-12-12', 26400.00, 'bank_transfer', NULL),
	(614, 735, '2026-02-15', 18900.00, 'wechat_pay', NULL),
	(615, 736, '2026-04-04', 42000.00, 'alipay', NULL),
	(616, 737, '2026-04-07', 72900.00, 'bank_transfer', NULL),
	(617, 738, '2025-06-25', 266657.42, 'alipay', NULL),
	(618, 739, '2026-04-17', 328000.00, 'wechat_pay', NULL),
	(619, 740, '2025-09-19', 255000.00, 'bank_transfer', NULL),
	(620, 741, '2025-09-06', 18600.00, 'alipay', NULL),
	(621, 742, '2025-09-25', 1200.00, 'bank_transfer', NULL),
	(622, 743, '2026-10-15', 7200.00, 'bank_transfer', NULL),
	(623, 744, '2026-10-10', 23400.00, 'bank_transfer', NULL),
	(624, 747, '2026-05-02', 135500.00, 'wechat_pay', NULL),
	(625, 748, '2026-09-15', 135500.00, 'wechat_pay', NULL),
	(626, 749, '2025-03-24', 167000.00, 'bank_transfer', NULL),
	(627, 750, '2026-06-03', 329000.00, 'wechat_pay', NULL),
	(628, 751, '2024-12-30', 36000.00, 'alipay', NULL),
	(629, 752, '2025-02-06', 33000.00, 'bank_transfer', NULL),
	(630, 753, '2025-02-24', 29700.00, 'bank_transfer', NULL),
	(631, 754, '2025-04-13', 51900.00, 'bank_transfer', NULL),
	(632, 755, '2025-03-22', 38100.00, 'bank_transfer', NULL),
	(633, 756, '2025-05-24', 21600.00, 'bank_transfer', NULL),
	(634, 757, '2025-05-31', 60000.00, 'alipay', NULL),
	(635, 758, '2025-08-08', 33300.00, 'wechat_pay', NULL),
	(636, 759, '2025-05-16', 102000.00, 'wechat_pay', NULL),
	(637, 760, '2024-10-28', 17000.00, 'bank_transfer', NULL),
	(638, 761, '2024-12-05', 17000.00, 'alipay', NULL),
	(639, 762, '2024-10-08', 66000.00, 'alipay', NULL);


--
-- Data for Name: permission_catalog; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.permission_catalog VALUES
	('case', 'read', 'View cases (public cases are visible to anyone with any case:read scope)'),
	('case', 'write', 'Create and edit cases, events and assignments'),
	('case', 'publish', 'Flag cases as public'),
	('case', 'delete', 'Delete cases'),
	('client', 'read', 'View client records'),
	('client', 'write', 'Create and edit client records'),
	('client', 'delete', 'Delete client records'),
	('law_info', 'read', 'Browse the law library'),
	('law_info', 'write', 'Add and edit law library documents'),
	('employee', 'read', 'View employee profiles'),
	('employee', 'write', 'Create and edit employees, departments and reporting lines'),
	('salary', 'read', 'View salary and HR data'),
	('salary', 'write', 'Edit salary and HR data'),
	('billing', 'read', 'View fee agreements, invoices and payments'),
	('billing', 'write', 'Edit fee agreements, invoices and payments'),
	('timesheet', 'read', 'View time entries'),
	('timesheet', 'write', 'Log time entries'),
	('agent', 'use', 'Use the data science agent (always limited to the user''s own data scope)'),
	('agent', 'monitor', 'Review all users'' agent conversations'),
	('user', 'manage', 'Create users, roles and grant permissions'),
	('audit', 'read', 'Read the audit log'),
	('system', 'update', 'Install system updates and manage firm settings');


--
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.role VALUES
	(1, 'lawyer', '律师 Lawyer', '本人案件与客户、公开案件、法律资料库 · Own cases and clients, public cases, law library', true, '2026-10-18 19:23:26.064428+08'),
	(2, 'partner', '合伙人 Partner', '下属律师及所负责部门的全部案件与客户 · Everything of their team and the departments they head', true, '2026-10-18 19:23:26.064428+08'),
	(3, 'admin', '管理员 Admin', '全部数据，用户与权限管理 · Full access, user and permission management', true, '2026-10-18 19:23:26.064428+08'),
	(4, 'guest', '访客测试 Guest', '公开试用账号：可查看全所演示数据并使用智能助手，不能修改任何数据 · Public test account: read-only, can use the assistant', true, '2026-10-18 20:31:31.120665+08');


--
-- Data for Name: role_permission; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.role_permission VALUES
	(1, 'agent', 'use', 'own'),
	(1, 'timesheet', 'write', 'own'),
	(1, 'timesheet', 'read', 'own'),
	(1, 'billing', 'read', 'own'),
	(1, 'salary', 'read', 'own'),
	(1, 'employee', 'read', 'own'),
	(1, 'law_info', 'read', 'all'),
	(1, 'client', 'write', 'own'),
	(1, 'client', 'read', 'own'),
	(1, 'case', 'write', 'own'),
	(1, 'case', 'read', 'own'),
	(2, 'agent', 'use', 'own'),
	(2, 'timesheet', 'write', 'own'),
	(2, 'timesheet', 'read', 'department'),
	(2, 'billing', 'write', 'department'),
	(2, 'billing', 'read', 'department'),
	(2, 'salary', 'read', 'own'),
	(2, 'employee', 'read', 'department'),
	(2, 'law_info', 'read', 'all'),
	(2, 'client', 'write', 'department'),
	(2, 'client', 'read', 'department'),
	(2, 'case', 'publish', 'department'),
	(2, 'case', 'write', 'department'),
	(2, 'case', 'read', 'department'),
	(3, 'audit', 'read', 'all'),
	(3, 'user', 'manage', 'all'),
	(3, 'agent', 'monitor', 'all'),
	(3, 'agent', 'use', 'all'),
	(3, 'timesheet', 'write', 'all'),
	(3, 'timesheet', 'read', 'all'),
	(3, 'billing', 'write', 'all'),
	(3, 'billing', 'read', 'all'),
	(3, 'salary', 'write', 'all'),
	(3, 'salary', 'read', 'all'),
	(3, 'employee', 'write', 'all'),
	(3, 'employee', 'read', 'all'),
	(3, 'law_info', 'write', 'all'),
	(3, 'law_info', 'read', 'all'),
	(3, 'client', 'delete', 'all'),
	(3, 'client', 'write', 'all'),
	(3, 'client', 'read', 'all'),
	(3, 'case', 'delete', 'all'),
	(3, 'case', 'publish', 'all'),
	(3, 'case', 'write', 'all'),
	(3, 'case', 'read', 'all'),
	(3, 'system', 'update', 'all'),
	(4, 'case', 'read', 'all'),
	(4, 'client', 'read', 'all'),
	(4, 'law_info', 'read', 'all'),
	(4, 'employee', 'read', 'all'),
	(4, 'billing', 'read', 'all'),
	(4, 'timesheet', 'read', 'all'),
	(4, 'agent', 'use', 'own');


--
-- Data for Name: time_entry; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.time_entry VALUES
	(1, 7, 11, '2026-08-04', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2, 7, 11, '2026-08-25', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(3, 7, 3, '2026-08-16', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(4, 7, 3, '2026-08-14', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(5, 7, 3, '2026-08-23', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(6, 7, 11, '2026-09-07', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(7, 7, 3, '2026-09-04', 3.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(8, 7, 3, '2026-09-02', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(9, 7, 3, '2026-09-23', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(10, 7, 11, '2026-10-03', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(11, 7, 11, '2026-10-05', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(12, 7, 11, '2026-10-17', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(13, 7, 3, '2026-10-07', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(14, 7, 3, '2026-10-18', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(15, 7, 3, '2026-10-18', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(16, 8, 11, '2024-03-09', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(17, 8, 11, '2024-03-31', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(18, 8, 11, '2024-04-14', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(19, 8, 11, '2024-03-22', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(20, 8, 11, '2024-03-23', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(21, 8, 11, '2024-04-23', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(22, 9, 5, '2024-05-13', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(23, 9, 5, '2024-05-09', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(24, 9, 5, '2024-05-09', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(25, 9, 2, '2024-05-05', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(26, 9, 5, '2024-06-22', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(27, 9, 5, '2024-06-19', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(28, 9, 5, '2024-06-25', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(29, 9, 2, '2024-06-24', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(30, 9, 2, '2024-06-13', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(31, 9, 5, '2024-07-06', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(32, 9, 5, '2024-07-07', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(33, 9, 5, '2024-07-28', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(34, 9, 2, '2024-07-23', 7.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(35, 9, 2, '2024-07-05', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(36, 9, 2, '2024-07-01', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(37, 9, 5, '2024-08-04', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(38, 9, 2, '2024-08-04', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(39, 9, 5, '2024-09-24', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(40, 9, 5, '2024-09-12', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(41, 9, 2, '2024-09-01', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(42, 9, 2, '2024-09-19', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(43, 10, 5, '2026-08-07', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(44, 10, 5, '2026-07-19', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(45, 10, 5, '2026-07-10', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(46, 10, 5, '2026-07-27', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(47, 10, 5, '2026-07-26', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(48, 10, 5, '2026-08-22', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(49, 11, 14, '2024-01-15', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(50, 11, 14, '2024-01-16', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(51, 11, 14, '2024-01-20', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(52, 11, 14, '2024-02-14', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(53, 11, 14, '2024-03-11', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(54, 11, 14, '2024-03-02', 1.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(55, 11, 14, '2024-04-25', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(56, 11, 14, '2024-04-06', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(57, 11, 14, '2024-05-01', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(58, 11, 14, '2024-05-05', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(59, 11, 14, '2024-05-25', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(60, 11, 14, '2024-06-26', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(61, 11, 14, '2024-07-06', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(62, 11, 14, '2024-08-08', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(63, 11, 14, '2024-08-28', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(64, 11, 14, '2024-09-05', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(65, 11, 14, '2024-10-28', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(66, 11, 14, '2024-10-21', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(67, 11, 14, '2024-10-28', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(68, 11, 14, '2024-11-28', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(69, 11, 14, '2024-12-28', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(70, 11, 14, '2025-01-13', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(71, 11, 14, '2025-01-17', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(72, 11, 14, '2025-02-28', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(73, 11, 14, '2025-02-28', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(74, 11, 14, '2025-02-06', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(75, 11, 14, '2025-03-14', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(76, 11, 14, '2025-04-28', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(77, 12, 11, '2024-08-28', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(78, 12, 6, '2024-08-11', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(79, 12, 6, '2024-08-08', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(80, 12, 11, '2024-09-23', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(81, 12, 11, '2024-09-27', 6.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(82, 12, 11, '2024-09-15', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(83, 12, 6, '2024-09-23', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(84, 12, 6, '2024-09-04', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(85, 12, 6, '2024-09-20', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(86, 13, 11, '2025-06-23', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(87, 13, 11, '2025-06-07', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(88, 13, 11, '2025-06-15', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(89, 13, 11, '2025-07-01', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(90, 13, 11, '2025-07-28', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(91, 13, 11, '2025-07-22', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(92, 13, 11, '2025-08-25', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(93, 13, 11, '2025-08-13', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(94, 13, 11, '2025-08-20', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(95, 14, 13, '2025-04-04', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(96, 14, 13, '2025-02-26', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(97, 15, 4, '2025-10-09', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(98, 15, 4, '2025-10-28', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(99, 15, 2, '2025-10-04', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(100, 15, 4, '2025-11-03', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(101, 15, 2, '2025-11-06', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(102, 15, 4, '2025-12-20', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(103, 15, 4, '2025-12-01', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(104, 15, 2, '2025-12-22', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(105, 15, 2, '2025-12-10', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(106, 15, 2, '2025-12-23', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(107, 15, 4, '2026-01-14', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(108, 15, 2, '2026-01-05', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(652, 59, 9, '2026-04-15', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(109, 15, 2, '2026-01-17', 5.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(110, 15, 2, '2026-01-24', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(111, 15, 4, '2026-02-15', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(112, 15, 4, '2026-02-15', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(113, 15, 2, '2026-02-28', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(114, 15, 2, '2026-02-04', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(115, 15, 2, '2026-02-04', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(116, 16, 7, '2026-02-01', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(117, 16, 9, '2026-02-22', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(118, 16, 7, '2026-03-01', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(119, 16, 7, '2026-03-06', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(120, 16, 9, '2026-03-08', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(121, 16, 9, '2026-03-05', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(122, 16, 9, '2026-03-28', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(123, 16, 7, '2026-04-28', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(124, 16, 9, '2026-04-02', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(125, 16, 7, '2026-05-06', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(126, 16, 7, '2026-05-11', 4.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(127, 16, 9, '2026-05-23', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(128, 16, 9, '2026-05-02', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(129, 16, 9, '2026-05-07', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(130, 17, 5, '2025-08-01', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(131, 17, 5, '2025-08-10', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(132, 17, 5, '2025-07-23', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(133, 17, 5, '2025-05-03', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(134, 17, 5, '2025-06-25', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(135, 17, 5, '2025-04-29', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(136, 18, 12, '2024-10-22', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(137, 18, 11, '2024-10-10', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(138, 18, 11, '2024-10-24', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(139, 18, 11, '2024-10-07', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(140, 18, 12, '2024-11-13', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(141, 18, 12, '2024-11-19', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(142, 18, 12, '2024-11-14', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(143, 18, 11, '2024-11-27', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(144, 18, 12, '2024-12-06', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(145, 18, 12, '2024-12-18', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(146, 18, 11, '2024-12-23', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(147, 18, 11, '2024-12-06', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(148, 18, 11, '2024-12-10', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(149, 19, 13, '2025-03-03', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(150, 19, 13, '2025-03-13', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(151, 19, 13, '2025-04-23', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(152, 19, 13, '2025-05-26', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(153, 19, 13, '2025-06-27', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(154, 19, 13, '2025-06-13', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(155, 19, 13, '2025-07-02', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(156, 19, 13, '2025-07-12', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(157, 19, 13, '2025-07-16', 1.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(158, 19, 13, '2025-08-14', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(159, 19, 13, '2025-09-07', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(160, 19, 13, '2025-09-21', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(161, 19, 13, '2025-10-09', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(162, 19, 13, '2025-11-27', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(163, 19, 13, '2025-11-15', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(164, 20, 7, '2024-03-04', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(165, 20, 7, '2024-09-19', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(166, 20, 7, '2024-10-07', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(167, 20, 7, '2024-11-16', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(168, 21, 12, '2024-04-15', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(169, 21, 12, '2024-03-30', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(170, 21, 12, '2024-08-29', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(171, 21, 12, '2024-05-24', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(172, 22, 14, '2024-09-06', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(173, 22, 14, '2024-11-13', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(174, 22, 14, '2024-09-28', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(175, 22, 14, '2024-12-03', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(176, 22, 14, '2024-10-16', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(177, 22, 14, '2024-11-14', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(178, 23, 14, '2025-01-05', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(179, 23, 14, '2025-01-14', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(180, 23, 14, '2025-02-23', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(181, 23, 14, '2025-02-22', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(182, 23, 14, '2025-02-28', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(183, 23, 14, '2025-03-09', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(184, 23, 14, '2025-04-03', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(185, 23, 14, '2025-04-12', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(186, 23, 14, '2025-05-10', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(187, 24, 7, '2026-10-08', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(188, 24, 7, '2026-10-09', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(189, 24, 7, '2026-10-09', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(190, 25, 13, '2026-03-10', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(191, 25, 13, '2026-04-26', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(192, 26, 7, '2026-06-28', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(193, 26, 7, '2026-06-18', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(194, 26, 7, '2026-06-25', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(195, 27, 4, '2026-06-19', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(196, 27, 4, '2026-07-10', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(197, 27, 4, '2026-01-13', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(198, 27, 4, '2026-04-22', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(199, 27, 4, '2026-01-19', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(200, 27, 4, '2026-02-18', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(201, 28, 4, '2026-07-22', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(202, 28, 4, '2026-08-19', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(203, 28, 4, '2026-06-20', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(204, 28, 4, '2026-07-08', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(205, 28, 4, '2026-09-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(206, 29, 4, '2025-03-03', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(207, 29, 4, '2025-02-17', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(208, 29, 4, '2025-03-15', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(209, 30, 5, '2025-11-18', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(210, 30, 5, '2026-03-20', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(211, 31, 7, '2026-06-09', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(212, 31, 7, '2026-07-25', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(213, 31, 7, '2026-07-05', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(214, 31, 7, '2026-08-02', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(215, 32, 11, '2024-07-11', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(216, 32, 11, '2024-07-09', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(217, 32, 11, '2024-07-08', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(218, 32, 12, '2024-07-25', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(219, 32, 12, '2024-07-02', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(220, 32, 11, '2024-08-04', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(221, 32, 12, '2024-08-25', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(222, 32, 12, '2024-08-05', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(223, 32, 12, '2024-08-09', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(224, 32, 11, '2024-09-04', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(225, 32, 11, '2024-09-08', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(226, 32, 11, '2024-09-14', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(227, 32, 12, '2024-09-01', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(228, 32, 12, '2024-09-25', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(229, 32, 12, '2024-09-07', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(230, 32, 11, '2024-10-13', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(231, 32, 11, '2024-10-27', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(232, 32, 12, '2024-10-14', 2.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(233, 32, 12, '2024-10-27', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(234, 32, 12, '2024-10-28', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(235, 32, 11, '2024-11-22', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(236, 32, 12, '2024-11-21', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(237, 33, 11, '2025-03-27', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(238, 33, 11, '2025-07-21', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(239, 33, 11, '2025-06-22', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(240, 33, 11, '2025-03-01', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(241, 33, 11, '2025-07-20', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(242, 33, 11, '2025-06-30', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(243, 34, 14, '2025-06-27', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(244, 34, 14, '2025-06-10', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(245, 34, 14, '2025-05-05', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(246, 34, 14, '2025-04-20', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(247, 35, 5, '2025-05-26', 4.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(248, 35, 5, '2025-05-24', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(249, 35, 5, '2025-06-19', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(250, 35, 5, '2025-06-25', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(251, 35, 5, '2025-07-01', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(252, 35, 5, '2025-07-28', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(253, 35, 5, '2025-08-16', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(254, 35, 5, '2025-08-07', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(255, 35, 5, '2025-08-22', 3.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(256, 35, 5, '2025-09-27', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(257, 35, 5, '2025-10-20', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(258, 35, 5, '2025-10-23', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(259, 35, 5, '2025-11-05', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(260, 35, 5, '2025-12-03', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(261, 35, 5, '2025-12-06', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(262, 35, 5, '2026-01-25', 1.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(263, 35, 5, '2026-01-07', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(264, 35, 5, '2026-02-22', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(265, 35, 5, '2026-03-11', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(266, 35, 5, '2026-03-23', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(267, 35, 5, '2026-04-27', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(268, 35, 5, '2026-04-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(269, 35, 5, '2026-05-15', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(270, 36, 4, '2025-02-07', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(271, 36, 4, '2024-12-19', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(272, 37, 10, '2026-03-25', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(273, 37, 10, '2026-07-17', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(274, 38, 12, '2025-10-16', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(275, 38, 12, '2025-11-07', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(276, 38, 12, '2025-10-19', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(277, 39, 4, '2025-12-01', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(278, 39, 4, '2025-06-08', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(279, 39, 4, '2025-11-29', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(280, 40, 4, '2025-06-28', 7.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(281, 40, 4, '2025-07-11', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(282, 40, 4, '2025-07-12', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(283, 40, 4, '2025-08-28', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(284, 40, 4, '2025-08-09', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(285, 40, 4, '2025-08-14', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(286, 40, 4, '2025-09-03', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(287, 40, 4, '2025-10-08', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(288, 41, 4, '2026-07-23', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(289, 41, 9, '2026-07-03', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(290, 41, 9, '2026-07-24', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(291, 41, 9, '2026-07-11', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(292, 41, 4, '2026-08-19', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(293, 41, 9, '2026-08-03', 7.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(294, 41, 4, '2026-09-16', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(295, 41, 4, '2026-09-05', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(296, 41, 4, '2026-09-14', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(297, 41, 9, '2026-09-19', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(298, 41, 4, '2026-10-18', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(299, 41, 9, '2026-10-07', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(300, 42, 10, '2024-09-17', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(301, 42, 10, '2024-09-27', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(302, 42, 10, '2024-09-16', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(303, 42, 10, '2024-10-18', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(304, 42, 10, '2024-10-24', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(305, 42, 10, '2024-10-07', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(306, 42, 10, '2024-11-16', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(307, 42, 10, '2024-11-04', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(308, 42, 10, '2024-12-28', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(309, 42, 10, '2024-12-01', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(310, 42, 10, '2025-01-03', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(311, 42, 10, '2025-02-22', 4.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(312, 42, 10, '2025-02-26', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(313, 42, 10, '2025-03-20', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(314, 42, 10, '2025-03-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(315, 42, 10, '2025-03-17', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(316, 42, 10, '2025-04-17', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(317, 42, 10, '2025-04-22', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(318, 42, 10, '2025-05-06', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(319, 42, 10, '2025-05-18', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(320, 42, 10, '2025-06-12', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(321, 42, 10, '2025-07-15', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(322, 42, 10, '2025-07-11', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(323, 42, 10, '2025-07-05', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(324, 42, 10, '2025-08-08', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(325, 42, 10, '2025-09-22', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(326, 42, 10, '2025-09-14', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(327, 42, 10, '2025-09-19', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(328, 42, 10, '2025-10-08', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(329, 42, 10, '2025-10-03', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(330, 42, 10, '2025-10-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(331, 43, 7, '2026-03-05', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(332, 43, 7, '2026-03-21', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(333, 43, 7, '2026-03-23', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(334, 43, 2, '2026-03-21', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(335, 43, 2, '2026-03-01', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(336, 43, 2, '2026-03-08', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(337, 43, 7, '2026-04-08', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(338, 43, 7, '2026-04-28', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(339, 43, 2, '2026-04-19', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(340, 43, 2, '2026-04-19', 1.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(341, 43, 7, '2026-05-21', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(342, 43, 2, '2026-05-07', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(343, 43, 2, '2026-05-07', 7.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(344, 43, 7, '2026-06-12', 6.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(345, 43, 2, '2026-06-04', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(346, 43, 2, '2026-06-21', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(347, 43, 2, '2026-06-04', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(348, 43, 7, '2026-07-12', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(349, 43, 2, '2026-07-09', 5.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(350, 43, 7, '2026-08-13', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(351, 43, 7, '2026-08-13', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(352, 43, 2, '2026-08-17', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(353, 43, 7, '2026-09-19', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(354, 43, 2, '2026-09-22', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(355, 43, 7, '2026-10-18', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(356, 43, 7, '2026-10-07', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(357, 43, 7, '2026-10-03', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(358, 43, 2, '2026-10-03', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(359, 43, 2, '2026-10-15', 4.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(360, 44, 10, '2024-11-27', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(361, 44, 10, '2024-11-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(362, 44, 10, '2024-11-25', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(363, 44, 2, '2024-11-22', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(364, 44, 10, '2024-12-14', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(365, 44, 10, '2024-12-03', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(366, 44, 10, '2024-12-09', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(367, 44, 2, '2024-12-13', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(368, 44, 2, '2024-12-15', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(369, 44, 2, '2024-12-01', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(370, 44, 10, '2025-01-10', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(371, 44, 10, '2025-01-14', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(372, 44, 10, '2025-01-07', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(373, 44, 2, '2025-01-09', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(374, 44, 2, '2025-01-23', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(375, 44, 10, '2025-02-04', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(376, 44, 2, '2025-02-06', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(377, 44, 2, '2025-02-15', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(378, 44, 2, '2025-02-17', 2.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(379, 44, 10, '2025-03-02', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(380, 44, 10, '2025-03-18', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(381, 44, 10, '2025-03-01', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(382, 44, 2, '2025-03-24', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(383, 44, 10, '2025-04-26', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(384, 44, 2, '2025-04-11', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(385, 44, 10, '2025-05-24', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(386, 44, 10, '2025-05-23', 6.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(387, 44, 2, '2025-05-24', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(388, 44, 2, '2025-05-01', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(389, 44, 2, '2025-05-11', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(390, 44, 10, '2025-06-14', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(391, 44, 10, '2025-06-16', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(392, 44, 10, '2025-06-03', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(393, 44, 2, '2025-06-23', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(394, 44, 2, '2025-06-09', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(395, 44, 10, '2025-07-23', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(396, 44, 2, '2025-07-03', 5.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(397, 44, 2, '2025-07-16', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(398, 44, 2, '2025-07-16', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(399, 44, 10, '2025-08-13', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(400, 44, 10, '2025-08-11', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(401, 44, 10, '2025-08-15', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(402, 44, 2, '2025-08-10', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(403, 44, 2, '2025-08-19', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(404, 44, 2, '2025-08-14', 4.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(405, 44, 10, '2025-09-10', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(406, 44, 10, '2025-09-12', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(407, 44, 2, '2025-09-07', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(408, 44, 2, '2025-09-08', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(409, 44, 2, '2025-09-13', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(410, 44, 10, '2025-10-25', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(411, 44, 10, '2025-10-26', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(412, 44, 10, '2025-10-02', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(413, 44, 2, '2025-10-19', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(414, 44, 2, '2025-10-12', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(415, 44, 10, '2025-11-06', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(416, 44, 10, '2025-11-05', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(417, 44, 10, '2025-11-27', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(418, 44, 2, '2025-11-16', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(419, 44, 10, '2025-12-12', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(420, 44, 10, '2025-12-14', 6.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(421, 44, 10, '2025-12-14', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(422, 44, 2, '2025-12-14', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(423, 45, 4, '2026-10-12', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(424, 45, 4, '2026-10-14', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(425, 46, 11, '2025-01-22', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(426, 46, 11, '2025-01-28', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(427, 46, 3, '2025-01-11', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(428, 46, 3, '2025-01-09', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(429, 46, 3, '2025-01-22', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(430, 46, 11, '2025-02-01', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(431, 46, 11, '2025-02-06', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(432, 46, 3, '2025-02-18', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(433, 46, 3, '2025-02-05', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(434, 46, 11, '2025-03-28', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(435, 46, 11, '2025-03-28', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(436, 46, 3, '2025-03-21', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(437, 46, 3, '2025-03-03', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(438, 46, 3, '2025-03-07', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(439, 46, 11, '2025-04-02', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(440, 46, 11, '2025-04-13', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(441, 46, 3, '2025-04-05', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(442, 46, 3, '2025-04-16', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(443, 47, 10, '2025-12-15', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(444, 47, 10, '2025-12-04', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(445, 47, 10, '2026-01-09', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(446, 47, 10, '2026-02-04', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(447, 47, 10, '2026-02-07', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(448, 47, 10, '2026-03-06', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(449, 47, 10, '2026-03-21', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(450, 47, 10, '2026-04-15', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(451, 47, 10, '2026-04-08', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(452, 47, 10, '2026-05-11', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(453, 47, 10, '2026-06-19', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(454, 47, 10, '2026-07-27', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(455, 47, 10, '2026-07-09', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(456, 47, 10, '2026-08-10', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(457, 47, 10, '2026-08-10', 4.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(458, 47, 10, '2026-08-11', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(459, 47, 10, '2026-09-09', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(460, 47, 10, '2026-09-23', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(461, 47, 10, '2026-09-14', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(462, 48, 9, '2026-03-22', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(463, 48, 9, '2026-03-19', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(464, 48, 9, '2026-04-18', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(465, 48, 9, '2026-05-09', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(466, 48, 9, '2026-05-11', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(467, 48, 9, '2026-05-06', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(468, 48, 9, '2026-06-17', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(469, 48, 9, '2026-07-20', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(470, 48, 9, '2026-07-10', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(471, 48, 9, '2026-08-24', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(472, 48, 9, '2026-09-12', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(473, 48, 9, '2026-10-18', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(474, 48, 9, '2026-10-09', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(475, 49, 14, '2026-10-17', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(476, 49, 14, '2026-10-05', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(477, 49, 14, '2026-10-14', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(478, 49, 8, '2026-10-11', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(479, 49, 8, '2026-10-18', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(480, 49, 8, '2026-10-02', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(481, 50, 6, '2025-04-25', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(482, 50, 6, '2025-04-16', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(483, 50, 6, '2025-05-03', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(484, 50, 6, '2025-06-17', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(485, 50, 6, '2025-06-10', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(486, 50, 6, '2025-07-27', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(487, 50, 6, '2025-07-13', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(488, 50, 6, '2025-07-01', 3.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(489, 50, 6, '2025-08-23', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(490, 50, 6, '2025-09-16', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(491, 50, 6, '2025-09-08', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(492, 51, 5, '2025-02-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(493, 51, 5, '2025-02-12', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(494, 51, 4, '2025-02-07', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(495, 51, 4, '2025-02-21', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(496, 51, 5, '2025-03-10', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(497, 51, 5, '2025-03-04', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(498, 51, 4, '2025-03-15', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(499, 51, 5, '2025-04-17', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(500, 51, 4, '2025-04-06', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(501, 51, 5, '2025-05-20', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(502, 51, 5, '2025-05-03', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(503, 51, 5, '2025-05-27', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(504, 51, 4, '2025-05-03', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(505, 51, 4, '2025-05-09', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(506, 51, 4, '2025-05-06', 7.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(507, 51, 5, '2025-06-13', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(508, 51, 4, '2025-06-10', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(509, 51, 5, '2025-07-03', 3.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(510, 51, 4, '2025-07-15', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(511, 51, 5, '2025-08-14', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(512, 51, 4, '2025-08-11', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(513, 51, 4, '2025-08-21', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(514, 51, 4, '2025-08-05', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(515, 52, 11, '2025-06-06', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(516, 52, 3, '2025-06-04', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(517, 52, 3, '2025-06-24', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(518, 52, 3, '2025-06-17', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(519, 52, 11, '2025-07-17', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(520, 52, 11, '2025-07-18', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(521, 52, 11, '2025-07-17', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(522, 52, 3, '2025-07-24', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(523, 52, 3, '2025-07-27', 6.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(524, 52, 11, '2025-08-20', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(525, 52, 3, '2025-08-15', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(526, 52, 3, '2025-08-15', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(527, 52, 3, '2025-08-01', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(528, 52, 11, '2025-09-19', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(529, 52, 11, '2025-09-01', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(530, 52, 11, '2025-09-19', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(531, 52, 3, '2025-09-07', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(532, 52, 3, '2025-09-12', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(533, 52, 11, '2025-10-03', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(534, 52, 3, '2025-10-20', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(535, 52, 3, '2025-10-20', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(536, 52, 3, '2025-10-15', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(537, 52, 11, '2025-11-12', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(538, 52, 11, '2025-11-25', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(539, 52, 11, '2025-11-26', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(540, 52, 3, '2025-11-28', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(541, 52, 3, '2025-11-16', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(542, 52, 3, '2025-11-22', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(543, 53, 10, '2026-07-20', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(544, 53, 10, '2026-07-26', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(545, 53, 10, '2026-07-22', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(546, 53, 10, '2026-08-11', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(547, 53, 10, '2026-08-25', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(548, 53, 10, '2026-08-25', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(549, 53, 10, '2026-09-10', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(550, 53, 10, '2026-09-10', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(551, 53, 10, '2026-10-16', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(552, 54, 7, '2026-10-16', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(553, 54, 7, '2026-10-18', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(554, 55, 10, '2024-05-08', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(555, 55, 10, '2024-05-15', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(556, 55, 2, '2024-05-21', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(557, 55, 2, '2024-05-07', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(558, 55, 2, '2024-05-20', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(559, 55, 10, '2024-06-23', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(560, 55, 10, '2024-06-26', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(561, 55, 2, '2024-06-26', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(562, 55, 2, '2024-06-28', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(563, 55, 2, '2024-06-13', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(564, 55, 10, '2024-07-03', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(565, 55, 10, '2024-07-27', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(566, 55, 10, '2024-07-11', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(567, 55, 2, '2024-07-19', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(568, 55, 10, '2024-08-19', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(569, 55, 2, '2024-08-08', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(570, 55, 2, '2024-08-06', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(571, 55, 2, '2024-08-01', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(572, 55, 10, '2024-09-04', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(573, 55, 10, '2024-09-28', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(574, 55, 2, '2024-09-15', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(575, 55, 2, '2024-09-27', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(576, 55, 10, '2024-10-01', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(577, 55, 2, '2024-10-15', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(578, 55, 2, '2024-10-09', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(579, 55, 2, '2024-10-12', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(580, 55, 10, '2024-11-25', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(581, 55, 10, '2024-11-16', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(582, 55, 10, '2024-11-25', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(583, 55, 2, '2024-11-22', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(584, 55, 10, '2024-12-27', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(585, 55, 10, '2024-12-06', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(586, 55, 10, '2024-12-03', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(587, 55, 2, '2024-12-17', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(588, 55, 2, '2024-12-26', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(589, 55, 2, '2024-12-02', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(590, 55, 10, '2025-01-28', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(591, 55, 10, '2025-01-06', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(592, 55, 10, '2025-01-26', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(593, 55, 2, '2025-01-28', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(594, 55, 10, '2025-02-28', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(595, 55, 10, '2025-02-19', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(596, 55, 2, '2025-02-05', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(597, 55, 2, '2025-02-01', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(598, 55, 10, '2025-03-01', 3.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(599, 55, 2, '2025-03-05', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(600, 55, 10, '2025-04-03', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(601, 55, 10, '2025-04-23', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(602, 55, 2, '2025-04-16', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(603, 55, 10, '2025-05-04', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(604, 55, 10, '2025-05-08', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(605, 55, 2, '2025-05-20', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(606, 55, 10, '2025-06-17', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(607, 55, 2, '2025-06-06', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(608, 55, 2, '2025-06-19', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(609, 55, 2, '2025-06-22', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(610, 55, 10, '2025-07-26', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(611, 55, 2, '2025-07-12', 4.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(612, 55, 2, '2025-07-19', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(613, 55, 10, '2025-08-09', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(614, 55, 10, '2025-08-16', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(615, 55, 2, '2025-08-04', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(616, 55, 10, '2025-09-15', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(617, 55, 2, '2025-09-10', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(618, 55, 2, '2025-09-13', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(619, 55, 2, '2025-09-12', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(620, 55, 10, '2025-10-18', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(621, 55, 10, '2025-10-09', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(622, 55, 2, '2025-10-23', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(623, 55, 2, '2025-10-24', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(624, 55, 10, '2025-11-16', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(625, 55, 10, '2025-11-08', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(626, 55, 10, '2025-11-11', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(627, 55, 2, '2025-11-19', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(628, 56, 6, '2024-05-10', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(629, 56, 6, '2024-06-04', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(630, 56, 6, '2024-06-06', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(631, 56, 6, '2024-07-02', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(632, 57, 14, '2026-04-10', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(633, 57, 14, '2026-04-26', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(634, 57, 14, '2026-05-14', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(635, 57, 14, '2026-06-05', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(636, 57, 14, '2026-07-17', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(637, 57, 14, '2026-07-03', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(638, 57, 14, '2026-08-22', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(639, 57, 14, '2026-09-23', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(640, 57, 14, '2026-09-07', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(641, 57, 14, '2026-10-09', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(642, 57, 14, '2026-10-18', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(643, 57, 14, '2026-10-18', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(644, 58, 7, '2025-08-11', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(645, 58, 7, '2025-07-29', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(646, 58, 7, '2025-08-13', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(647, 58, 7, '2025-08-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(648, 59, 9, '2026-02-19', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(649, 59, 9, '2026-03-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(650, 59, 9, '2026-05-04', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(651, 59, 9, '2026-03-11', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(653, 60, 5, '2026-08-12', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(654, 60, 5, '2026-05-12', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(655, 61, 9, '2026-09-17', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(656, 61, 2, '2026-09-04', 5.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(657, 61, 2, '2026-09-25', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(658, 61, 2, '2026-09-08', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(659, 61, 9, '2026-10-18', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(660, 61, 9, '2026-10-18', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(661, 61, 2, '2026-10-03', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(662, 62, 4, '2025-09-24', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(663, 62, 7, '2025-09-15', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(664, 62, 4, '2025-10-14', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(665, 62, 4, '2025-10-04', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(666, 62, 4, '2025-10-18', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(667, 62, 7, '2025-10-25', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(668, 62, 7, '2025-10-01', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(669, 62, 7, '2025-10-02', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(670, 62, 4, '2025-11-04', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(671, 62, 7, '2025-11-09', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(672, 62, 4, '2025-12-23', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(673, 62, 7, '2025-12-23', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(674, 62, 4, '2026-01-12', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(675, 62, 4, '2026-01-10', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(676, 62, 7, '2026-01-23', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(677, 62, 4, '2026-02-11', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(678, 62, 4, '2026-02-18', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(679, 62, 4, '2026-02-10', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(680, 62, 7, '2026-02-18', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(681, 62, 7, '2026-02-18', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(682, 63, 4, '2024-03-12', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(683, 63, 4, '2024-05-19', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(684, 63, 4, '2024-04-03', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(685, 63, 4, '2024-05-21', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(686, 63, 4, '2024-05-28', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(687, 64, 7, '2025-05-07', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(688, 64, 7, '2025-03-11', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(689, 64, 7, '2025-04-09', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(690, 64, 7, '2025-08-22', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(691, 65, 13, '2026-03-01', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(692, 65, 13, '2026-05-12', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(693, 65, 13, '2026-07-06', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(694, 65, 13, '2026-07-20', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(695, 65, 13, '2026-06-03', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(696, 66, 14, '2026-08-11', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(697, 66, 14, '2026-09-13', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(698, 66, 14, '2026-09-25', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(699, 66, 14, '2026-09-27', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(700, 66, 14, '2026-10-18', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(701, 66, 14, '2026-10-13', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(702, 67, 13, '2024-10-10', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(703, 67, 13, '2024-10-26', 5.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(704, 67, 13, '2024-11-26', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(705, 67, 13, '2024-12-21', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(706, 67, 13, '2024-12-15', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(707, 67, 13, '2024-12-05', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(708, 67, 13, '2025-01-17', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(709, 67, 13, '2025-01-07', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(710, 67, 13, '2025-02-05', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(711, 67, 13, '2025-02-12', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(712, 67, 13, '2025-03-11', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(713, 67, 13, '2025-04-05', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(714, 67, 13, '2025-04-10', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(715, 67, 13, '2025-04-15', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(716, 68, 5, '2025-07-10', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(717, 68, 5, '2025-08-18', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(718, 68, 5, '2025-08-03', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(719, 68, 5, '2025-09-12', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(720, 68, 5, '2025-09-17', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(721, 68, 5, '2025-09-27', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(722, 68, 5, '2025-10-08', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(723, 68, 5, '2025-10-10', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(724, 68, 5, '2025-11-15', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(725, 68, 5, '2025-12-05', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(726, 68, 5, '2025-12-28', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(727, 68, 5, '2026-01-01', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(728, 68, 5, '2026-01-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(729, 68, 5, '2026-01-10', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(730, 68, 5, '2026-02-02', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(731, 68, 5, '2026-02-24', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(732, 68, 5, '2026-02-20', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(733, 68, 5, '2026-03-22', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(734, 68, 5, '2026-03-11', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(735, 68, 5, '2026-03-24', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(736, 68, 5, '2026-04-19', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(737, 68, 5, '2026-05-03', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(738, 68, 5, '2026-06-17', 4.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(739, 68, 5, '2026-06-11', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(740, 68, 5, '2026-07-18', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(741, 68, 5, '2026-08-20', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(742, 68, 5, '2026-09-15', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(743, 68, 5, '2026-09-08', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(744, 69, 9, '2024-12-22', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(745, 69, 9, '2025-02-07', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(746, 69, 9, '2025-07-30', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(747, 69, 9, '2025-01-18', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(748, 69, 9, '2025-08-16', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(749, 70, 13, '2025-09-23', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(750, 70, 13, '2025-08-07', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(751, 70, 13, '2025-04-10', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(752, 71, 9, '2026-08-19', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(753, 71, 9, '2026-08-26', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(754, 71, 9, '2026-08-23', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(755, 71, 2, '2026-08-01', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(756, 71, 2, '2026-08-08', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(757, 71, 2, '2026-08-06', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(758, 71, 9, '2026-09-28', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(759, 71, 2, '2026-09-08', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(760, 71, 2, '2026-09-10', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(761, 71, 2, '2026-09-16', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(762, 71, 9, '2026-10-09', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(763, 71, 9, '2026-10-05', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(764, 71, 2, '2026-10-18', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(765, 72, 4, '2026-06-18', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(766, 72, 4, '2026-06-08', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(767, 72, 2, '2026-06-11', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(768, 72, 4, '2026-07-24', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(769, 72, 4, '2026-07-11', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(770, 72, 2, '2026-07-15', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(771, 72, 2, '2026-07-08', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(772, 72, 2, '2026-07-28', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(773, 72, 4, '2026-08-12', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(774, 72, 4, '2026-08-26', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(775, 72, 2, '2026-08-04', 1.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(776, 72, 4, '2026-09-25', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(777, 72, 4, '2026-09-15', 4.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(778, 72, 4, '2026-09-02', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(779, 72, 2, '2026-09-14', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(780, 72, 4, '2026-10-18', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(781, 72, 4, '2026-10-18', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(782, 72, 2, '2026-10-18', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(783, 72, 2, '2026-10-18', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(784, 72, 2, '2026-10-02', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(785, 73, 9, '2026-10-06', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(786, 73, 9, '2026-10-15', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(787, 73, 9, '2026-10-01', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(788, 73, 9, '2026-10-10', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(789, 74, 11, '2024-11-06', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(790, 74, 11, '2024-11-02', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(791, 74, 11, '2024-12-15', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(792, 74, 11, '2025-01-04', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(793, 74, 11, '2025-01-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(794, 74, 11, '2025-01-26', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(795, 74, 11, '2025-02-09', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(796, 74, 11, '2025-03-01', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(797, 74, 11, '2025-03-22', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(798, 74, 11, '2025-04-25', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(799, 74, 11, '2025-04-04', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(800, 74, 11, '2025-05-09', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(801, 74, 11, '2025-05-25', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(802, 74, 11, '2025-06-18', 8.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(803, 74, 11, '2025-06-16', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(804, 74, 11, '2025-06-22', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(805, 75, 6, '2025-10-21', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(806, 75, 6, '2025-08-29', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(807, 75, 6, '2025-11-10', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(808, 76, 6, '2025-03-10', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(809, 76, 6, '2025-03-14', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(810, 76, 6, '2025-03-05', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(811, 76, 6, '2025-03-11', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(812, 76, 6, '2025-03-15', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(813, 76, 6, '2025-03-17', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(814, 77, 9, '2025-08-10', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(815, 77, 9, '2025-09-06', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(816, 77, 9, '2026-04-16', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(817, 77, 9, '2026-05-24', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(818, 78, 9, '2026-01-05', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(819, 78, 9, '2026-04-19', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(820, 78, 9, '2026-05-06', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(821, 78, 9, '2025-11-21', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(822, 78, 9, '2026-10-03', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(823, 79, 9, '2025-12-17', 2.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(824, 79, 9, '2025-12-12', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(825, 79, 9, '2025-12-17', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(826, 79, 9, '2026-01-12', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(827, 79, 9, '2026-01-05', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(828, 79, 9, '2026-01-20', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(829, 79, 9, '2026-02-14', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(830, 79, 9, '2026-02-19', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(831, 79, 9, '2026-03-06', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(832, 79, 9, '2026-04-05', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(833, 79, 9, '2026-04-21', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(834, 79, 9, '2026-04-25', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(835, 79, 9, '2026-05-12', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(836, 79, 9, '2026-06-08', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(837, 79, 9, '2026-06-17', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(838, 79, 9, '2026-06-19', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(839, 79, 9, '2026-07-09', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(840, 79, 9, '2026-07-06', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(841, 79, 9, '2026-08-14', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(842, 79, 9, '2026-08-24', 2.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(843, 79, 9, '2026-09-18', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(844, 79, 9, '2026-09-12', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(845, 79, 9, '2026-10-05', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(846, 80, 4, '2024-08-12', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(847, 80, 4, '2024-09-02', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(848, 80, 4, '2024-10-13', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(849, 80, 4, '2024-10-10', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(850, 80, 4, '2024-10-03', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(851, 80, 4, '2024-11-13', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(852, 80, 4, '2024-11-22', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(853, 80, 4, '2024-12-10', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(854, 80, 4, '2024-12-19', 8.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(855, 80, 4, '2025-01-18', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(856, 80, 4, '2025-02-05', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(857, 80, 4, '2025-02-14', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(858, 80, 4, '2025-03-25', 4.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(859, 80, 4, '2025-03-28', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(860, 80, 4, '2025-03-20', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(861, 80, 4, '2025-04-10', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(862, 80, 4, '2025-05-05', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(863, 80, 4, '2025-05-10', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(864, 80, 4, '2025-05-06', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(865, 80, 4, '2025-06-08', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(866, 80, 4, '2025-06-21', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(867, 80, 4, '2025-07-22', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(868, 80, 4, '2025-07-17', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(869, 80, 4, '2025-08-15', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(870, 80, 4, '2025-08-24', 1.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(871, 80, 4, '2025-08-01', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(872, 80, 4, '2025-09-06', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(873, 80, 4, '2025-09-21', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(874, 80, 4, '2025-09-25', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(875, 80, 4, '2025-10-08', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(876, 80, 4, '2025-10-24', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(877, 80, 4, '2025-11-21', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(878, 80, 4, '2025-11-28', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(879, 80, 4, '2025-11-14', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(880, 80, 4, '2025-12-11', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(881, 80, 4, '2025-12-07', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(882, 80, 4, '2026-01-16', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(883, 81, 13, '2026-01-23', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(884, 81, 13, '2026-04-14', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(885, 81, 13, '2026-03-12', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(886, 81, 13, '2025-12-05', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(887, 81, 13, '2026-02-01', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(888, 82, 7, '2025-08-02', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(889, 82, 5, '2025-08-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(890, 82, 5, '2025-08-05', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(891, 82, 5, '2025-08-07', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(892, 82, 7, '2025-09-09', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(893, 82, 7, '2025-09-12', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(894, 82, 7, '2025-09-05', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(895, 82, 5, '2025-09-26', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(896, 82, 5, '2025-09-08', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(897, 82, 5, '2025-09-06', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(898, 82, 7, '2025-10-02', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(899, 82, 5, '2025-10-13', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(900, 82, 5, '2025-10-28', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(901, 82, 5, '2025-10-10', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(902, 82, 7, '2025-11-26', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(903, 82, 7, '2025-11-09', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(904, 82, 5, '2025-11-27', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(905, 82, 5, '2025-11-21', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(906, 82, 7, '2025-12-06', 1.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(907, 82, 7, '2025-12-18', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(908, 82, 7, '2025-12-04', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(909, 82, 5, '2025-12-05', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(910, 82, 7, '2026-01-08', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(911, 82, 7, '2026-01-07', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(912, 82, 5, '2026-01-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(913, 82, 5, '2026-01-14', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(914, 82, 5, '2026-01-07', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(915, 82, 7, '2026-02-06', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(916, 82, 5, '2026-02-05', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(917, 82, 5, '2026-02-03', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(918, 82, 5, '2026-02-13', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(919, 82, 7, '2026-03-09', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(920, 82, 7, '2026-03-16', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(921, 82, 7, '2026-03-13', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(922, 82, 5, '2026-03-18', 4.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(923, 82, 5, '2026-03-01', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(924, 82, 5, '2026-03-06', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(925, 82, 7, '2026-04-08', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(926, 82, 5, '2026-04-05', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(927, 82, 7, '2026-05-14', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(928, 82, 5, '2026-05-09', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(929, 82, 7, '2026-06-04', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(930, 82, 7, '2026-06-06', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(931, 82, 5, '2026-06-20', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(932, 82, 7, '2026-07-26', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(933, 82, 5, '2026-07-13', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(934, 82, 5, '2026-07-26', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(935, 82, 5, '2026-07-16', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(936, 82, 7, '2026-08-26', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(937, 82, 5, '2026-08-18', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(938, 82, 7, '2026-09-13', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(939, 82, 7, '2026-09-24', 4.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(940, 82, 7, '2026-09-12', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(941, 82, 5, '2026-09-10', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(942, 82, 5, '2026-09-17', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(943, 82, 5, '2026-09-11', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(944, 82, 7, '2026-10-14', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(945, 82, 7, '2026-10-18', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(946, 82, 5, '2026-10-10', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(947, 83, 11, '2024-11-17', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(948, 83, 11, '2024-12-17', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(949, 83, 11, '2024-12-13', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(950, 83, 11, '2024-12-04', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(951, 83, 11, '2025-01-19', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(952, 84, 5, '2025-03-22', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(953, 84, 5, '2024-12-05', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(954, 84, 5, '2024-10-20', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(955, 84, 5, '2024-12-12', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(956, 84, 5, '2024-10-20', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(957, 84, 5, '2025-02-04', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(958, 85, 10, '2026-09-07', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(959, 85, 10, '2026-10-03', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(960, 85, 10, '2026-07-12', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(961, 85, 10, '2026-09-02', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(962, 85, 10, '2026-07-25', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(963, 85, 10, '2026-08-01', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(964, 86, 10, '2024-12-22', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(965, 86, 10, '2024-12-19', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(966, 86, 2, '2024-12-06', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(967, 86, 10, '2025-01-21', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(968, 86, 10, '2025-01-15', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(969, 86, 10, '2025-01-27', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(970, 86, 2, '2025-01-07', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(971, 86, 2, '2025-01-11', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(972, 86, 10, '2025-02-09', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(973, 86, 10, '2025-02-01', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(974, 86, 2, '2025-02-13', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(975, 86, 2, '2025-02-02', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(976, 87, 10, '2025-03-19', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(977, 87, 10, '2025-09-22', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(978, 87, 10, '2025-10-11', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(979, 87, 10, '2025-05-16', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(980, 87, 10, '2025-12-13', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(981, 88, 6, '2025-11-05', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(982, 88, 6, '2025-11-18', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(983, 88, 6, '2025-11-14', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(984, 88, 6, '2025-11-19', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(985, 88, 6, '2025-11-02', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(986, 88, 6, '2025-11-15', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(987, 89, 6, '2026-03-22', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(988, 89, 6, '2026-03-01', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(989, 89, 6, '2026-04-02', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(990, 89, 6, '2026-05-15', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(991, 89, 6, '2026-06-04', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(992, 89, 6, '2026-07-02', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(993, 90, 4, '2026-08-27', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(994, 90, 4, '2026-03-23', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(995, 90, 4, '2026-08-12', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(996, 90, 4, '2026-07-03', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(997, 91, 14, '2024-11-09', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(998, 91, 14, '2024-11-18', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(999, 91, 8, '2024-11-21', 4.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1000, 91, 8, '2024-11-13', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(1001, 91, 8, '2024-11-02', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1002, 91, 14, '2024-12-24', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1003, 91, 14, '2024-12-21', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1004, 91, 8, '2024-12-10', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1005, 91, 8, '2024-12-12', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1006, 91, 14, '2025-01-16', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1007, 91, 14, '2025-01-20', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1008, 91, 14, '2025-01-11', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1009, 91, 8, '2025-01-24', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1010, 91, 14, '2025-02-11', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1011, 91, 8, '2025-02-02', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1012, 91, 8, '2025-02-05', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1013, 91, 8, '2025-02-05', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1014, 91, 14, '2025-03-02', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1015, 91, 14, '2025-03-21', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1016, 91, 14, '2025-03-02', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1017, 91, 8, '2025-03-18', 8.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1018, 91, 14, '2025-04-08', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1019, 91, 14, '2025-04-26', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1020, 91, 8, '2025-04-13', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1021, 91, 8, '2025-04-19', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1022, 91, 14, '2025-05-03', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1023, 91, 14, '2025-05-20', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1024, 91, 14, '2025-05-04', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1025, 91, 8, '2025-05-19', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1026, 91, 8, '2025-05-09', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1027, 91, 14, '2025-06-06', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1028, 91, 8, '2025-06-25', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1029, 91, 8, '2025-06-04', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1030, 91, 14, '2025-07-27', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1031, 91, 14, '2025-07-21', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1032, 91, 14, '2025-07-23', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1033, 91, 8, '2025-07-17', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1034, 91, 14, '2025-08-19', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1035, 91, 8, '2025-08-07', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1036, 91, 8, '2025-08-17', 6.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1037, 91, 8, '2025-08-25', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1038, 92, 7, '2024-06-29', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1039, 92, 7, '2024-06-18', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1040, 92, 7, '2024-06-10', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1041, 92, 7, '2024-05-30', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1042, 92, 7, '2024-06-08', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1043, 93, 10, '2025-01-02', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1044, 93, 10, '2024-09-28', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1045, 93, 10, '2024-11-21', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1046, 93, 10, '2025-01-30', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1047, 93, 10, '2024-11-02', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1048, 93, 10, '2025-01-29', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1049, 94, 7, '2025-11-21', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1050, 94, 7, '2025-03-20', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1051, 95, 12, '2026-08-09', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1052, 95, 12, '2026-09-22', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1053, 95, 12, '2026-04-08', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1054, 95, 12, '2026-09-26', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1055, 95, 12, '2026-10-09', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1056, 96, 13, '2026-08-23', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1057, 96, 13, '2026-09-18', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1058, 96, 13, '2026-10-18', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1059, 96, 13, '2026-10-11', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1060, 96, 13, '2026-10-16', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1061, 97, 11, '2024-09-02', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1062, 97, 11, '2024-11-17', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1063, 97, 11, '2024-10-13', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1064, 98, 14, '2026-02-25', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1065, 98, 14, '2026-03-22', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1066, 98, 14, '2025-12-13', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1067, 98, 14, '2026-01-15', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1068, 98, 14, '2026-06-23', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1069, 98, 14, '2026-05-03', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1070, 99, 13, '2026-04-24', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1071, 99, 13, '2026-04-13', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1072, 99, 13, '2026-05-06', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1073, 99, 13, '2026-04-27', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1074, 99, 13, '2026-05-08', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1075, 100, 4, '2025-03-11', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1076, 100, 4, '2024-09-14', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1077, 100, 4, '2025-03-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1078, 100, 4, '2024-09-02', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1079, 100, 4, '2024-09-08', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1080, 100, 4, '2025-01-01', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1081, 101, 6, '2024-12-01', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1082, 101, 6, '2024-12-23', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1083, 101, 6, '2024-12-15', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1084, 101, 6, '2025-01-24', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1085, 101, 6, '2025-01-10', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1086, 101, 6, '2025-02-21', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1087, 101, 6, '2025-02-20', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1088, 102, 9, '2024-10-18', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1089, 102, 9, '2024-09-01', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1090, 103, 5, '2024-04-11', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1091, 103, 5, '2024-04-12', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1092, 103, 5, '2024-04-03', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1093, 103, 2, '2024-04-04', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1094, 103, 5, '2024-05-26', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1095, 103, 5, '2024-05-09', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1096, 103, 5, '2024-05-11', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1097, 103, 2, '2024-05-21', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1098, 103, 2, '2024-05-22', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1099, 103, 2, '2024-05-09', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1100, 103, 5, '2024-06-04', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1101, 103, 5, '2024-06-25', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1102, 103, 5, '2024-06-22', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1103, 103, 2, '2024-06-07', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1104, 103, 2, '2024-06-08', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1105, 103, 5, '2024-07-11', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1106, 103, 5, '2024-07-23', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1107, 103, 2, '2024-07-05', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1108, 103, 5, '2024-08-20', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1109, 103, 5, '2024-08-10', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1110, 103, 2, '2024-08-13', 4.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1111, 103, 2, '2024-08-01', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1112, 103, 2, '2024-08-17', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1113, 103, 5, '2024-09-09', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1114, 103, 2, '2024-09-16', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1115, 103, 2, '2024-09-14', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1116, 103, 5, '2024-10-16', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1117, 103, 2, '2024-10-19', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1118, 103, 5, '2024-11-14', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1119, 103, 2, '2024-11-05', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1120, 103, 2, '2024-11-02', 7.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1121, 103, 2, '2024-11-09', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1122, 103, 5, '2024-12-16', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1123, 103, 5, '2024-12-02', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1124, 103, 5, '2024-12-23', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1125, 103, 2, '2024-12-28', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1126, 103, 5, '2025-01-09', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1127, 103, 5, '2025-01-19', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1128, 103, 2, '2025-01-28', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1129, 103, 2, '2025-01-05', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1130, 103, 5, '2025-02-02', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1131, 103, 5, '2025-02-23', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1132, 103, 2, '2025-02-20', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1133, 103, 2, '2025-02-11', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1134, 103, 2, '2025-02-08', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1135, 104, 10, '2026-09-05', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1136, 104, 10, '2026-10-04', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1137, 104, 10, '2026-09-05', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1138, 104, 10, '2026-06-24', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1139, 105, 13, '2025-05-10', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1140, 105, 13, '2025-07-24', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1141, 105, 13, '2025-11-12', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1142, 105, 13, '2025-07-16', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1143, 105, 13, '2025-03-02', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1144, 106, 9, '2026-04-25', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1145, 106, 9, '2026-03-03', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1146, 106, 9, '2026-02-25', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1147, 106, 9, '2026-03-17', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1148, 107, 11, '2026-09-03', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1149, 107, 11, '2026-09-24', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1150, 107, 11, '2026-09-02', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1151, 107, 3, '2026-09-23', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1152, 107, 3, '2026-09-09', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1153, 107, 3, '2026-09-10', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1154, 107, 11, '2026-10-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1155, 107, 3, '2026-10-16', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1156, 107, 3, '2026-10-18', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1157, 107, 3, '2026-10-18', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1158, 108, 4, '2026-07-13', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1159, 108, 2, '2026-07-04', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1160, 108, 4, '2026-08-12', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1161, 108, 4, '2026-08-06', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1162, 108, 4, '2026-08-07', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1163, 108, 2, '2026-08-18', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1164, 108, 4, '2026-09-06', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1165, 108, 4, '2026-09-10', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1166, 108, 4, '2026-09-28', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1167, 108, 2, '2026-09-11', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1168, 108, 2, '2026-09-12', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1169, 108, 2, '2026-09-12', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1170, 108, 4, '2026-10-01', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1171, 108, 4, '2026-10-04', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1172, 108, 4, '2026-10-08', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1173, 108, 2, '2026-10-18', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1174, 109, 7, '2026-08-30', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1175, 109, 7, '2026-09-22', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1176, 110, 9, '2024-07-02', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1177, 110, 9, '2024-07-26', 1.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1178, 110, 9, '2024-07-14', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1179, 110, 5, '2024-07-22', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1180, 110, 5, '2024-07-17', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1181, 110, 5, '2024-07-23', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1182, 110, 9, '2024-08-26', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1183, 110, 5, '2024-08-22', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1184, 110, 9, '2024-09-23', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1185, 110, 9, '2024-09-03', 2.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1186, 110, 5, '2024-09-03', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1187, 110, 5, '2024-09-01', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1188, 110, 9, '2024-10-15', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1189, 110, 9, '2024-10-24', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1190, 110, 9, '2024-10-09', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1191, 110, 5, '2024-10-01', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1192, 110, 5, '2024-10-21', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1193, 110, 5, '2024-10-19', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1194, 110, 9, '2024-11-22', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1195, 110, 9, '2024-11-24', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1196, 110, 9, '2024-11-05', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1197, 110, 5, '2024-11-09', 6.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1198, 110, 5, '2024-11-17', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1199, 110, 9, '2024-12-02', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1200, 110, 9, '2024-12-04', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(1201, 110, 5, '2024-12-17', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1202, 110, 5, '2024-12-26', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1203, 110, 9, '2025-01-18', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1204, 110, 9, '2025-01-28', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1205, 110, 9, '2025-01-10', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1206, 110, 5, '2025-01-03', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1207, 110, 5, '2025-01-25', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1208, 110, 5, '2025-01-21', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1209, 110, 9, '2025-02-10', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1210, 110, 5, '2025-02-12', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1211, 110, 5, '2025-02-22', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1212, 110, 5, '2025-02-13', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1213, 110, 9, '2025-03-22', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1214, 110, 5, '2025-03-22', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1215, 110, 9, '2025-04-27', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1216, 110, 5, '2025-04-11', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1217, 110, 9, '2025-05-11', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1218, 110, 9, '2025-05-09', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1219, 110, 9, '2025-05-02', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1220, 110, 5, '2025-05-01', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1221, 110, 5, '2025-05-28', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1222, 111, 12, '2026-05-24', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1223, 111, 12, '2026-06-27', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1224, 111, 12, '2026-06-08', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1225, 111, 12, '2026-06-06', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1226, 111, 12, '2026-05-23', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1227, 111, 12, '2026-06-26', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1228, 112, 9, '2024-12-11', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1229, 112, 9, '2025-04-02', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1230, 112, 9, '2025-01-15', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1231, 112, 9, '2025-01-12', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1232, 112, 9, '2024-12-11', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1233, 113, 12, '2025-02-13', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1234, 113, 12, '2025-04-07', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1235, 113, 12, '2025-02-10', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1236, 113, 12, '2025-03-10', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1237, 114, 6, '2025-10-31', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1238, 114, 6, '2025-08-23', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1239, 114, 6, '2025-08-14', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1240, 114, 6, '2025-05-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1241, 115, 5, '2026-03-22', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1242, 115, 5, '2026-03-10', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1243, 115, 5, '2026-03-03', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1244, 115, 2, '2026-03-18', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1245, 115, 2, '2026-03-20', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1246, 115, 2, '2026-03-16', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1247, 115, 5, '2026-04-07', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1248, 115, 2, '2026-04-26', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1249, 115, 5, '2026-05-02', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1250, 115, 5, '2026-05-15', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1251, 115, 5, '2026-05-20', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1252, 115, 2, '2026-05-11', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1253, 115, 2, '2026-05-12', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1254, 115, 5, '2026-06-27', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1255, 115, 2, '2026-06-07', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1256, 115, 2, '2026-06-14', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1257, 115, 5, '2026-07-27', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1258, 115, 5, '2026-07-17', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1259, 115, 2, '2026-07-27', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1260, 115, 5, '2026-08-15', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1261, 115, 2, '2026-08-21', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1262, 115, 5, '2026-09-25', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1263, 115, 2, '2026-09-02', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1264, 115, 5, '2026-10-18', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1265, 115, 2, '2026-10-08', 3.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1266, 116, 5, '2025-05-19', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1267, 116, 5, '2025-05-02', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1268, 116, 5, '2025-06-22', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1269, 117, 12, '2026-09-14', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1270, 117, 12, '2026-09-15', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1271, 118, 9, '2024-09-28', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1272, 118, 9, '2024-09-12', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1273, 118, 9, '2024-10-17', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1274, 118, 9, '2024-11-04', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1275, 118, 9, '2024-12-24', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1276, 118, 9, '2024-12-07', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1277, 118, 9, '2025-01-14', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1278, 118, 9, '2025-02-04', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1279, 118, 9, '2025-02-03', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1280, 118, 9, '2025-03-05', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1281, 118, 9, '2025-04-26', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1282, 118, 9, '2025-04-13', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1283, 118, 9, '2025-05-07', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1284, 118, 9, '2025-05-20', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1285, 118, 9, '2025-05-13', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1286, 118, 9, '2025-06-02', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1287, 118, 9, '2025-07-02', 8.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1288, 118, 9, '2025-08-14', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1289, 118, 9, '2025-08-28', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1290, 118, 9, '2025-08-14', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1291, 118, 9, '2025-09-14', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1292, 118, 9, '2025-10-19', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1293, 118, 9, '2025-10-22', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1294, 118, 9, '2025-11-15', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1295, 119, 4, '2025-03-21', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1296, 119, 4, '2025-03-02', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1297, 119, 4, '2025-04-11', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1298, 119, 4, '2025-05-13', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1299, 119, 4, '2025-05-01', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1300, 119, 4, '2025-05-18', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1301, 119, 4, '2025-06-22', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1302, 119, 4, '2025-07-17', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1303, 119, 4, '2025-08-16', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1304, 119, 4, '2025-08-04', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1305, 119, 4, '2025-08-26', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1306, 119, 4, '2025-09-12', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1307, 119, 4, '2025-09-28', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1308, 119, 4, '2025-10-23', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1309, 119, 4, '2025-11-14', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1310, 119, 4, '2025-12-24', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1311, 119, 4, '2025-12-24', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1312, 119, 4, '2025-12-01', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1313, 119, 4, '2026-01-05', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1314, 119, 4, '2026-01-17', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1315, 119, 4, '2026-01-09', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1316, 119, 4, '2026-02-23', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1317, 119, 4, '2026-03-27', 1.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1318, 119, 4, '2026-04-14', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1319, 119, 4, '2026-05-02', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1320, 120, 4, '2025-06-26', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1321, 120, 2, '2025-06-23', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1322, 120, 2, '2025-06-02', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1323, 120, 2, '2025-06-20', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1324, 120, 4, '2025-07-02', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1325, 120, 4, '2025-07-19', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1326, 120, 4, '2025-07-09', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1327, 120, 2, '2025-07-03', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1328, 120, 2, '2025-07-05', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1329, 120, 4, '2025-08-22', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1330, 120, 4, '2025-08-19', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1331, 120, 4, '2025-08-22', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1332, 120, 2, '2025-08-27', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1333, 120, 2, '2025-08-24', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1334, 120, 2, '2025-08-07', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1335, 120, 4, '2025-09-23', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1336, 120, 4, '2025-09-24', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1337, 120, 4, '2025-09-25', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1338, 120, 2, '2025-09-03', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1339, 120, 4, '2025-10-22', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1340, 120, 4, '2025-10-04', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1341, 120, 2, '2025-10-22', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1342, 120, 2, '2025-10-19', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1343, 120, 2, '2025-10-20', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1344, 120, 4, '2025-11-27', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1345, 120, 4, '2025-11-28', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1346, 120, 4, '2025-11-11', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1347, 120, 2, '2025-11-09', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1348, 120, 2, '2025-11-13', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1349, 120, 4, '2025-12-24', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1350, 120, 2, '2025-12-13', 1.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1351, 120, 2, '2025-12-02', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1352, 120, 2, '2025-12-20', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1353, 120, 4, '2026-01-01', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1354, 120, 4, '2026-01-04', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1355, 120, 2, '2026-01-11', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1356, 120, 4, '2026-02-07', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1357, 120, 4, '2026-02-16', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1358, 120, 4, '2026-02-19', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1359, 120, 2, '2026-02-21', 5.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1360, 120, 2, '2026-02-20', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1361, 120, 4, '2026-03-14', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1362, 120, 4, '2026-03-22', 4.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1363, 120, 2, '2026-03-15', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1364, 120, 2, '2026-03-23', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1365, 120, 2, '2026-03-22', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1366, 120, 4, '2026-04-19', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1367, 120, 4, '2026-04-25', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1368, 120, 4, '2026-04-02', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1369, 120, 2, '2026-04-11', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1370, 120, 4, '2026-05-03', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1371, 120, 2, '2026-05-14', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1372, 120, 4, '2026-06-11', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1373, 120, 2, '2026-06-07', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1374, 120, 2, '2026-06-21', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1375, 120, 2, '2026-06-21', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1376, 120, 4, '2026-07-18', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1377, 120, 2, '2026-07-21', 2.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1378, 120, 2, '2026-07-09', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1379, 120, 4, '2026-08-27', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1380, 120, 4, '2026-08-28', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1381, 120, 4, '2026-08-06', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1382, 120, 2, '2026-08-10', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1383, 120, 2, '2026-08-28', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1384, 120, 2, '2026-08-21', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1385, 120, 4, '2026-09-09', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1386, 120, 4, '2026-09-01', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1387, 120, 4, '2026-09-23', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1388, 120, 2, '2026-09-14', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1389, 120, 2, '2026-09-15', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1390, 120, 4, '2026-10-06', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1391, 120, 4, '2026-10-11', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1392, 120, 2, '2026-10-18', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1393, 120, 2, '2026-10-11', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1394, 121, 7, '2026-09-24', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1395, 121, 7, '2026-05-30', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1396, 121, 7, '2026-10-17', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1397, 122, 9, '2025-10-01', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1398, 122, 9, '2026-02-07', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1399, 122, 9, '2025-08-17', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1400, 122, 9, '2025-06-08', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(1401, 123, 9, '2025-11-14', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1402, 123, 9, '2025-11-05', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1403, 123, 9, '2025-11-14', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1404, 123, 9, '2025-12-27', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1405, 123, 9, '2025-12-05', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1406, 123, 9, '2026-01-01', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1407, 123, 9, '2026-02-03', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1408, 123, 9, '2026-02-25', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1409, 123, 9, '2026-02-21', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1410, 123, 9, '2026-03-25', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1411, 123, 9, '2026-04-13', 3.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1412, 123, 9, '2026-04-22', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1413, 123, 9, '2026-05-15', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1414, 123, 9, '2026-05-05', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1415, 123, 9, '2026-06-20', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1416, 123, 9, '2026-07-21', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1417, 123, 9, '2026-07-08', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1418, 123, 9, '2026-08-14', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1419, 123, 9, '2026-09-24', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1420, 123, 9, '2026-09-14', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1421, 123, 9, '2026-10-15', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1422, 123, 9, '2026-10-13', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1423, 124, 4, '2026-10-08', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1424, 124, 4, '2026-09-07', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1425, 124, 4, '2026-09-14', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1426, 124, 4, '2026-09-24', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1427, 124, 4, '2026-10-02', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1428, 124, 4, '2026-10-09', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1429, 125, 11, '2024-12-14', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1430, 125, 3, '2024-12-02', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1431, 125, 11, '2025-01-08', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1432, 125, 11, '2025-01-22', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1433, 125, 3, '2025-01-02', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1434, 125, 11, '2025-02-03', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1435, 125, 11, '2025-02-13', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1436, 125, 11, '2025-02-05', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1437, 125, 3, '2025-02-26', 7.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1438, 125, 3, '2025-02-02', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1439, 125, 3, '2025-02-26', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1440, 125, 11, '2025-03-07', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1441, 125, 11, '2025-03-02', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1442, 125, 3, '2025-03-12', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1443, 125, 3, '2025-03-22', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1444, 125, 3, '2025-03-25', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1445, 125, 11, '2025-04-24', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1446, 125, 11, '2025-04-20', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1447, 125, 11, '2025-04-07', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1448, 125, 3, '2025-04-01', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1449, 125, 3, '2025-04-27', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1450, 125, 3, '2025-04-02', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1451, 126, 13, '2026-07-26', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1452, 126, 13, '2026-04-17', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1453, 127, 12, '2026-04-09', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1454, 127, 12, '2026-05-20', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1455, 127, 12, '2026-05-14', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1456, 128, 10, '2024-09-23', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1457, 128, 10, '2024-12-13', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1458, 128, 10, '2025-01-07', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1459, 128, 10, '2024-11-24', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1460, 128, 10, '2024-04-25', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1461, 128, 10, '2024-11-10', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1462, 129, 5, '2026-09-19', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1463, 129, 5, '2026-09-06', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1464, 129, 5, '2026-09-28', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1465, 129, 5, '2026-10-03', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1466, 129, 5, '2026-10-18', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1467, 129, 5, '2026-10-12', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1468, 130, 6, '2024-01-26', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1469, 130, 6, '2024-01-22', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1470, 130, 6, '2024-02-24', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1471, 130, 6, '2024-02-08', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1472, 130, 6, '2024-02-08', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1473, 130, 6, '2024-03-16', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1474, 131, 7, '2024-09-05', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1475, 131, 7, '2024-09-24', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1476, 131, 7, '2024-10-23', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1477, 131, 7, '2024-10-13', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1478, 131, 7, '2024-10-11', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1479, 131, 7, '2024-11-22', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1480, 131, 7, '2024-11-21', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1481, 131, 7, '2024-11-26', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1482, 132, 7, '2026-04-03', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1483, 132, 7, '2026-06-14', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1484, 133, 9, '2025-04-07', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1485, 133, 9, '2025-04-20', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1486, 133, 9, '2025-05-13', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1487, 133, 9, '2025-05-12', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1488, 133, 9, '2025-06-18', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1489, 133, 9, '2025-06-12', 3.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1490, 134, 11, '2024-12-11', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1491, 134, 11, '2025-01-10', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1492, 134, 11, '2024-11-24', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1493, 134, 11, '2024-11-10', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1494, 134, 11, '2024-10-24', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1495, 134, 11, '2024-11-29', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1496, 135, 11, '2025-07-22', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1497, 135, 11, '2025-07-26', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1498, 135, 11, '2025-03-08', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1499, 135, 11, '2025-07-18', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1500, 136, 10, '2025-06-11', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1501, 136, 10, '2024-12-08', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1502, 136, 10, '2025-02-03', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1503, 136, 10, '2025-06-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1504, 136, 10, '2025-08-30', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1505, 136, 10, '2025-05-05', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1506, 137, 6, '2024-12-31', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1507, 137, 6, '2024-12-30', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1508, 137, 6, '2025-04-19', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1509, 137, 6, '2025-04-03', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1510, 137, 6, '2025-06-22', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1511, 137, 6, '2025-02-10', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1512, 138, 7, '2025-03-07', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1513, 138, 7, '2025-01-21', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1514, 138, 7, '2024-12-18', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1515, 138, 7, '2024-06-26', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1516, 138, 7, '2024-05-17', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1517, 139, 10, '2025-01-02', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1518, 139, 10, '2024-05-07', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1519, 139, 10, '2025-04-29', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1520, 140, 9, '2024-06-06', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1521, 140, 9, '2024-07-11', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1522, 140, 9, '2024-07-15', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1523, 140, 9, '2024-07-19', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1524, 140, 9, '2024-08-04', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1525, 140, 9, '2024-09-07', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1526, 140, 9, '2024-09-11', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1527, 140, 9, '2024-10-23', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1528, 140, 9, '2024-10-07', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1529, 140, 9, '2024-10-14', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1530, 140, 9, '2024-11-06', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1531, 140, 9, '2024-11-13', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1532, 140, 9, '2024-11-02', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1533, 140, 9, '2024-12-13', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1534, 140, 9, '2024-12-07', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1535, 140, 9, '2024-12-04', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1536, 140, 9, '2025-01-15', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1537, 140, 9, '2025-01-25', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1538, 140, 9, '2025-01-20', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1539, 140, 9, '2025-02-02', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1540, 140, 9, '2025-02-21', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1541, 140, 9, '2025-02-10', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1542, 140, 9, '2025-03-25', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1543, 140, 9, '2025-04-22', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1544, 140, 9, '2025-04-18', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1545, 140, 9, '2025-04-02', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1546, 140, 9, '2025-05-12', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1547, 140, 9, '2025-05-08', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1548, 141, 6, '2025-01-14', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1549, 141, 6, '2024-11-07', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1550, 141, 6, '2024-11-02', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1551, 141, 6, '2024-10-25', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1552, 141, 6, '2025-03-20', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1553, 142, 9, '2025-02-16', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1554, 142, 2, '2025-02-13', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1555, 142, 2, '2025-02-19', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1556, 142, 9, '2025-03-28', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1557, 142, 9, '2025-03-16', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1558, 142, 2, '2025-03-17', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1559, 142, 2, '2025-03-09', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1560, 142, 2, '2025-03-19', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1561, 142, 9, '2025-04-28', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1562, 142, 2, '2025-04-11', 1.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1563, 142, 9, '2025-05-27', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1564, 142, 9, '2025-05-04', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1565, 142, 9, '2025-05-04', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1566, 142, 2, '2025-05-27', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1567, 142, 9, '2025-06-10', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1568, 142, 9, '2025-06-01', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1569, 142, 9, '2025-06-19', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1570, 142, 2, '2025-06-07', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1571, 142, 2, '2025-06-15', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1572, 142, 2, '2025-06-23', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1573, 142, 9, '2025-07-18', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1574, 142, 2, '2025-07-05', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1575, 143, 7, '2024-01-16', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1576, 143, 7, '2024-01-04', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1577, 143, 2, '2024-01-04', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1578, 143, 7, '2024-02-17', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1579, 143, 7, '2024-02-07', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1580, 143, 7, '2024-02-04', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1581, 143, 2, '2024-02-23', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1582, 143, 2, '2024-02-09', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1583, 143, 7, '2024-03-20', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1584, 143, 2, '2024-03-10', 8.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1585, 143, 2, '2024-03-04', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1586, 143, 2, '2024-03-10', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1587, 143, 7, '2024-04-09', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1588, 143, 7, '2024-04-11', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1589, 143, 2, '2024-04-25', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1590, 144, 11, '2025-08-04', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1591, 144, 11, '2025-07-13', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1592, 144, 11, '2025-08-18', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1593, 144, 11, '2025-02-11', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1594, 144, 11, '2025-08-15', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1595, 145, 7, '2026-04-26', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1596, 145, 7, '2026-04-13', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1597, 145, 7, '2026-04-18', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1598, 145, 7, '2026-05-22', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1599, 145, 7, '2026-05-07', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1600, 145, 7, '2026-05-25', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(1601, 146, 11, '2026-10-04', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1602, 146, 11, '2026-10-16', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1603, 146, 11, '2026-10-04', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1604, 146, 11, '2026-10-10', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1605, 146, 11, '2026-10-08', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1606, 146, 11, '2026-10-15', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1607, 147, 11, '2026-06-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1608, 147, 11, '2026-09-16', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1609, 147, 11, '2026-09-30', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1610, 147, 11, '2026-07-08', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1611, 148, 13, '2026-09-16', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1612, 148, 8, '2026-09-08', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1613, 148, 8, '2026-09-10', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1614, 148, 13, '2026-10-18', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1615, 148, 8, '2026-10-11', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1616, 148, 8, '2026-10-02', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1617, 148, 8, '2026-10-18', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1618, 149, 11, '2024-07-24', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1619, 149, 11, '2024-06-22', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1620, 149, 11, '2024-07-05', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1621, 150, 9, '2024-11-15', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1622, 150, 9, '2024-10-10', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1623, 150, 9, '2024-11-04', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1624, 150, 9, '2024-11-10', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1625, 150, 9, '2024-10-08', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1626, 150, 9, '2024-10-11', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1627, 151, 9, '2025-09-12', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1628, 151, 9, '2025-09-15', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1629, 151, 9, '2025-10-24', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1630, 151, 9, '2025-11-06', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1631, 151, 9, '2025-12-07', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1632, 151, 9, '2025-12-09', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1633, 151, 9, '2026-01-13', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1634, 151, 9, '2026-01-05', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1635, 151, 9, '2026-01-25', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1636, 151, 9, '2026-02-21', 2.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1637, 151, 9, '2026-02-19', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1638, 151, 9, '2026-03-10', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1639, 151, 9, '2026-03-23', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1640, 151, 9, '2026-03-03', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1641, 151, 9, '2026-04-09', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1642, 151, 9, '2026-04-27', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1643, 151, 9, '2026-05-13', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1644, 151, 9, '2026-05-14', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1645, 151, 9, '2026-05-19', 4.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1646, 151, 9, '2026-06-25', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1647, 151, 9, '2026-06-02', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1648, 151, 9, '2026-06-25', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1649, 151, 9, '2026-07-20', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1650, 151, 9, '2026-07-12', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1651, 151, 9, '2026-07-03', 2.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1652, 151, 9, '2026-08-02', 1.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1653, 152, 13, '2026-08-25', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1654, 152, 13, '2026-09-10', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1655, 152, 13, '2026-09-01', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1656, 152, 13, '2026-10-17', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1657, 153, 5, '2024-02-20', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1658, 153, 5, '2024-02-16', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1659, 153, 5, '2024-02-12', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1660, 153, 5, '2024-03-24', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1661, 154, 4, '2025-03-15', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1662, 154, 4, '2025-04-11', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1663, 154, 4, '2025-04-13', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1664, 154, 4, '2024-12-26', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1665, 154, 4, '2025-07-09', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1666, 154, 4, '2024-11-07', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1667, 155, 6, '2025-08-21', 8.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1668, 155, 6, '2025-08-13', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1669, 155, 6, '2025-08-13', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1670, 155, 12, '2025-08-23', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1671, 155, 12, '2025-08-07', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1672, 155, 6, '2025-09-11', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1673, 155, 6, '2025-09-03', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1674, 155, 6, '2025-09-09', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1675, 155, 12, '2025-09-20', 4.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1676, 155, 12, '2025-09-22', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1677, 155, 12, '2025-09-15', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1678, 155, 6, '2025-10-07', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1679, 155, 6, '2025-10-25', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1680, 155, 12, '2025-10-15', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1681, 155, 12, '2025-10-03', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1682, 155, 12, '2025-10-02', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1683, 155, 6, '2025-11-10', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1684, 155, 6, '2025-11-10', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1685, 155, 12, '2025-11-20', 8.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1686, 155, 6, '2025-12-19', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1687, 155, 6, '2025-12-16', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1688, 155, 6, '2025-12-15', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1689, 155, 12, '2025-12-22', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1690, 155, 12, '2025-12-07', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1691, 156, 14, '2025-10-22', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1692, 156, 14, '2025-10-19', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1693, 156, 14, '2025-10-02', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1694, 156, 8, '2025-10-17', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1695, 156, 14, '2025-11-11', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1696, 156, 14, '2025-11-03', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1697, 156, 8, '2025-11-02', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1698, 156, 14, '2025-12-14', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1699, 156, 14, '2025-12-10', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1700, 156, 14, '2025-12-13', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1701, 156, 8, '2025-12-17', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1702, 156, 8, '2025-12-10', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1703, 156, 14, '2026-01-19', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1704, 156, 14, '2026-01-17', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1705, 156, 8, '2026-01-01', 6.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1706, 156, 8, '2026-01-09', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1707, 156, 8, '2026-01-13', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1708, 156, 14, '2026-02-03', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1709, 156, 8, '2026-02-02', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1710, 156, 14, '2026-03-22', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1711, 156, 14, '2026-03-10', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1712, 156, 14, '2026-03-11', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1713, 156, 8, '2026-03-07', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1714, 156, 8, '2026-03-15', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1715, 156, 14, '2026-04-02', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1716, 156, 8, '2026-04-16', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1717, 156, 8, '2026-04-19', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1718, 156, 14, '2026-05-24', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1719, 156, 14, '2026-05-12', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1720, 156, 14, '2026-05-22', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1721, 156, 8, '2026-05-02', 3.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1722, 156, 14, '2026-06-28', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1723, 156, 14, '2026-06-28', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1724, 156, 8, '2026-06-23', 8.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1725, 156, 14, '2026-07-11', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1726, 156, 14, '2026-07-18', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1727, 156, 8, '2026-07-06', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1728, 156, 14, '2026-08-11', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1729, 156, 14, '2026-08-16', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1730, 156, 8, '2026-08-04', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1731, 156, 8, '2026-08-03', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1732, 156, 14, '2026-09-10', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1733, 156, 14, '2026-09-10', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1734, 156, 8, '2026-09-07', 3.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1735, 156, 14, '2026-10-09', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1736, 156, 8, '2026-10-12', 1.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1737, 157, 11, '2026-08-11', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1738, 157, 11, '2026-08-24', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1739, 157, 11, '2026-09-26', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1740, 157, 11, '2026-09-27', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1741, 157, 11, '2026-09-16', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1742, 157, 11, '2026-10-04', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1743, 157, 11, '2026-10-18', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1744, 157, 11, '2026-10-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1745, 158, 7, '2024-08-30', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1746, 158, 7, '2024-08-21', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1747, 158, 7, '2024-08-07', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1748, 158, 7, '2024-09-05', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1749, 159, 7, '2025-01-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1750, 159, 7, '2025-03-15', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1751, 159, 7, '2025-02-23', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1752, 159, 7, '2025-01-27', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1753, 160, 11, '2025-12-29', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1754, 160, 11, '2025-10-27', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1755, 160, 11, '2025-11-18', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1756, 160, 11, '2025-11-10', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1757, 160, 11, '2025-10-26', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1758, 161, 11, '2026-07-11', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1759, 161, 11, '2026-07-19', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1760, 161, 11, '2026-07-07', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1761, 161, 11, '2026-08-06', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1762, 161, 11, '2026-08-24', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1763, 161, 11, '2026-08-03', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1764, 161, 11, '2026-09-20', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1765, 161, 11, '2026-09-19', 4.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1766, 161, 11, '2026-10-18', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1767, 161, 11, '2026-10-13', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1768, 161, 11, '2026-10-18', 6.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1769, 162, 5, '2024-05-21', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1770, 162, 5, '2024-02-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1771, 162, 5, '2024-08-27', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1772, 162, 5, '2024-10-12', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1773, 162, 5, '2024-02-21', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1774, 162, 5, '2024-11-12', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1775, 163, 13, '2025-02-23', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1776, 163, 13, '2025-04-26', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1777, 163, 13, '2024-11-13', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1778, 163, 13, '2025-03-14', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1779, 163, 13, '2025-04-23', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1780, 164, 4, '2024-08-21', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1781, 164, 4, '2024-04-26', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1782, 164, 4, '2024-04-23', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1783, 164, 4, '2024-05-17', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1784, 164, 4, '2024-04-12', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1785, 164, 4, '2024-04-06', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1786, 165, 4, '2024-04-04', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1787, 165, 4, '2024-05-25', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1788, 166, 11, '2025-12-05', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1789, 166, 11, '2026-03-06', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1790, 166, 11, '2026-02-10', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1791, 166, 11, '2026-04-11', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1792, 166, 11, '2026-03-28', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1793, 166, 11, '2025-12-11', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1794, 167, 11, '2026-03-25', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1795, 167, 11, '2026-03-26', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1796, 167, 3, '2026-03-15', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1797, 167, 3, '2026-03-27', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1798, 167, 11, '2026-04-24', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1799, 167, 11, '2026-04-12', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1800, 167, 11, '2026-04-01', 4.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(1801, 167, 3, '2026-04-26', 5.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1802, 167, 3, '2026-04-03', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1803, 168, 10, '2026-10-10', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1804, 168, 10, '2026-10-05', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1805, 169, 9, '2026-05-14', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1806, 169, 9, '2026-05-23', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1807, 169, 9, '2026-06-06', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1808, 169, 9, '2026-07-19', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1809, 169, 9, '2026-07-18', 6.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1810, 169, 9, '2026-07-06', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1811, 169, 9, '2026-08-03', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1812, 169, 9, '2026-08-26', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1813, 169, 9, '2026-09-27', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1814, 169, 9, '2026-10-18', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1815, 169, 9, '2026-10-12', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1816, 169, 9, '2026-10-05', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1817, 170, 14, '2025-06-02', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1818, 170, 14, '2025-06-23', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1819, 170, 13, '2025-06-07', 7.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1820, 170, 13, '2025-06-26', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1821, 170, 13, '2025-06-25', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1822, 170, 14, '2025-07-20', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1823, 170, 13, '2025-07-21', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1824, 170, 13, '2025-07-11', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1825, 170, 14, '2025-08-06', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1826, 170, 14, '2025-08-01', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1827, 170, 13, '2025-08-20', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1828, 170, 14, '2025-09-13', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1829, 170, 14, '2025-09-11', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1830, 170, 14, '2025-09-07', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1831, 170, 13, '2025-09-15', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1832, 170, 13, '2025-09-08', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1833, 170, 14, '2025-10-07', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1834, 170, 14, '2025-10-04', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1835, 170, 13, '2025-10-18', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1836, 170, 13, '2025-10-19', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1837, 170, 13, '2025-10-07', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1838, 170, 14, '2025-11-21', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1839, 170, 14, '2025-11-22', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1840, 170, 14, '2025-11-23', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1841, 170, 13, '2025-11-12', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1842, 170, 13, '2025-11-19', 7.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1843, 170, 13, '2025-11-21', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1844, 170, 14, '2025-12-10', 1.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1845, 170, 14, '2025-12-20', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1846, 170, 14, '2025-12-04', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1847, 170, 13, '2025-12-10', 2.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1848, 170, 13, '2025-12-01', 1.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1849, 170, 13, '2025-12-09', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1850, 170, 14, '2026-01-05', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1851, 170, 13, '2026-01-09', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1852, 170, 13, '2026-01-16', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1853, 170, 13, '2026-01-19', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1854, 170, 14, '2026-02-28', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1855, 170, 14, '2026-02-11', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1856, 170, 14, '2026-02-05', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1857, 170, 13, '2026-02-02', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1858, 170, 13, '2026-02-18', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1859, 170, 13, '2026-02-05', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2297, 210, 5, '2026-04-13', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1860, 170, 14, '2026-03-19', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1861, 170, 14, '2026-03-12', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1862, 170, 13, '2026-03-28', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1863, 170, 13, '2026-03-18', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1864, 170, 14, '2026-04-10', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1865, 170, 14, '2026-04-25', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1866, 170, 14, '2026-04-23', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1867, 170, 13, '2026-04-23', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1868, 170, 13, '2026-04-22', 1.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1869, 170, 13, '2026-04-11', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1870, 170, 14, '2026-05-23', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1871, 170, 14, '2026-05-06', 5.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1872, 170, 14, '2026-05-08', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1873, 170, 13, '2026-05-24', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1874, 170, 13, '2026-05-21', 3.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1875, 170, 13, '2026-05-14', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1876, 170, 14, '2026-06-01', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1877, 170, 14, '2026-06-02', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1878, 170, 14, '2026-06-20', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1879, 170, 13, '2026-06-12', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1880, 170, 13, '2026-06-05', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1881, 170, 14, '2026-07-01', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1882, 170, 14, '2026-07-19', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1883, 170, 13, '2026-07-18', 1.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1884, 170, 13, '2026-07-28', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1885, 170, 13, '2026-07-12', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1886, 170, 14, '2026-08-16', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1887, 170, 13, '2026-08-05', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1888, 170, 13, '2026-08-08', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1889, 171, 11, '2026-04-27', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1890, 171, 11, '2026-05-20', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1891, 171, 11, '2026-04-25', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1892, 171, 11, '2026-04-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1893, 171, 11, '2026-06-16', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1894, 171, 11, '2026-08-28', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1895, 172, 4, '2026-07-14', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1896, 172, 4, '2026-07-21', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1897, 172, 2, '2026-07-16', 4.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1898, 172, 4, '2026-08-06', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1899, 172, 2, '2026-08-07', 4.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1900, 172, 2, '2026-08-16', 2.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1901, 172, 4, '2026-09-13', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1902, 172, 2, '2026-09-03', 3.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1903, 172, 2, '2026-09-09', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1904, 172, 4, '2026-10-17', 6.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1905, 172, 4, '2026-10-18', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1906, 172, 2, '2026-10-18', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1907, 173, 10, '2026-01-03', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1908, 173, 10, '2026-01-12', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1909, 173, 10, '2026-02-23', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1910, 173, 10, '2026-03-10', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1911, 173, 10, '2026-03-10', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1912, 173, 10, '2026-04-07', 6.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1913, 173, 10, '2026-04-17', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1914, 173, 10, '2026-05-19', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1915, 173, 10, '2026-05-22', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1916, 173, 10, '2026-05-16', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1917, 173, 10, '2026-06-14', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1918, 173, 10, '2026-06-06', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1919, 173, 10, '2026-07-07', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1920, 173, 10, '2026-07-18', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1921, 173, 10, '2026-07-13', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1922, 173, 10, '2026-08-02', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1923, 174, 4, '2025-10-08', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1924, 174, 4, '2025-10-13', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1925, 175, 13, '2024-05-26', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1926, 175, 13, '2024-05-09', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1927, 176, 5, '2024-11-05', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1928, 176, 5, '2024-11-26', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1929, 176, 5, '2024-10-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1930, 176, 5, '2024-11-21', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1931, 176, 5, '2024-12-03', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1932, 176, 5, '2024-10-30', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1933, 177, 5, '2026-04-07', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1934, 177, 5, '2026-05-19', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1935, 177, 5, '2026-05-24', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1936, 177, 5, '2026-05-20', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1937, 177, 5, '2026-06-14', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1938, 177, 5, '2026-07-20', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1939, 177, 5, '2026-08-26', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1940, 177, 5, '2026-08-18', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1941, 177, 5, '2026-09-17', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1942, 177, 5, '2026-09-19', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1943, 177, 5, '2026-09-07', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1944, 177, 5, '2026-10-17', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1945, 177, 5, '2026-10-05', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1946, 177, 5, '2026-10-08', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1947, 178, 6, '2026-02-20', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1948, 178, 6, '2026-03-07', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1949, 178, 6, '2026-04-08', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1950, 178, 6, '2026-04-21', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1951, 178, 6, '2026-04-03', 3.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1952, 178, 6, '2026-05-12', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1953, 178, 6, '2026-05-01', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1954, 178, 6, '2026-06-17', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1955, 178, 6, '2026-06-02', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1956, 178, 6, '2026-06-20', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1957, 178, 6, '2026-07-26', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1958, 178, 6, '2026-07-24', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1959, 178, 6, '2026-07-05', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1960, 179, 5, '2026-06-06', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1961, 179, 5, '2026-06-18', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1962, 179, 5, '2026-06-01', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1963, 179, 2, '2026-06-06', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1964, 179, 5, '2026-07-21', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1965, 179, 5, '2026-07-14', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1966, 179, 2, '2026-07-06', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1967, 179, 5, '2026-08-03', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1968, 179, 5, '2026-08-15', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1969, 179, 2, '2026-08-04', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1970, 179, 5, '2026-09-22', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1971, 179, 2, '2026-09-11', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1972, 179, 5, '2026-10-13', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1973, 179, 5, '2026-10-02', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1974, 179, 5, '2026-10-10', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1975, 179, 2, '2026-10-09', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1976, 179, 2, '2026-10-02', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1977, 179, 2, '2026-10-05', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1978, 180, 4, '2025-10-04', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1979, 180, 4, '2025-12-20', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1980, 180, 4, '2026-06-17', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1981, 180, 4, '2025-11-27', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1982, 181, 7, '2025-12-03', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1983, 181, 7, '2025-12-01', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1984, 181, 7, '2025-12-25', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1985, 181, 7, '2026-01-11', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1986, 181, 7, '2026-01-05', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1987, 181, 7, '2026-02-09', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1988, 181, 7, '2026-02-25', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1989, 181, 7, '2026-02-15', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1990, 181, 7, '2026-03-10', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1991, 181, 7, '2026-04-28', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1992, 181, 7, '2026-05-13', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1993, 181, 7, '2026-06-25', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1994, 181, 7, '2026-06-07', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1995, 181, 7, '2026-06-12', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(1996, 181, 7, '2026-07-05', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1997, 181, 7, '2026-08-28', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1998, 181, 7, '2026-08-09', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(1999, 181, 7, '2026-09-07', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(2000, 181, 7, '2026-09-02', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2001, 181, 7, '2026-09-21', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2002, 181, 7, '2026-10-18', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2003, 182, 10, '2025-06-20', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2004, 182, 10, '2025-07-22', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2005, 182, 10, '2025-07-01', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2006, 183, 6, '2026-07-17', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2007, 183, 6, '2026-07-11', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2008, 183, 6, '2026-07-06', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2009, 183, 6, '2026-08-27', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2010, 183, 6, '2026-09-13', 4.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2011, 183, 6, '2026-09-15', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2012, 183, 6, '2026-09-11', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2013, 183, 6, '2026-10-08', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2014, 183, 6, '2026-10-12', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2015, 184, 5, '2026-01-28', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2016, 184, 5, '2026-05-17', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2017, 184, 5, '2026-06-09', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2018, 184, 5, '2026-05-11', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2019, 185, 14, '2025-06-02', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2020, 185, 14, '2025-05-25', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2021, 185, 14, '2025-04-29', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2022, 185, 14, '2025-05-05', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2023, 185, 14, '2025-05-24', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2024, 185, 14, '2025-05-06', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2025, 186, 10, '2025-11-03', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2026, 186, 10, '2024-11-24', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2027, 186, 10, '2025-03-08', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2028, 186, 10, '2024-10-25', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2029, 186, 10, '2025-05-21', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2030, 186, 10, '2024-09-08', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2031, 187, 7, '2025-09-04', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2032, 187, 7, '2025-09-20', 1.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2033, 187, 2, '2025-09-01', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2034, 187, 7, '2025-10-17', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2035, 187, 2, '2025-10-20', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2036, 187, 7, '2025-11-23', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2037, 187, 2, '2025-11-22', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2038, 187, 2, '2025-11-24', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2039, 187, 2, '2025-11-22', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2040, 187, 7, '2025-12-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2041, 187, 7, '2025-12-19', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2042, 187, 2, '2025-12-13', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2043, 187, 2, '2025-12-18', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2044, 187, 2, '2025-12-15', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2045, 187, 7, '2026-01-21', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2046, 187, 2, '2026-01-25', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2047, 187, 2, '2026-01-21', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2048, 187, 7, '2026-02-12', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2049, 187, 7, '2026-02-12', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2050, 187, 2, '2026-02-26', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2051, 187, 2, '2026-02-17', 6.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2052, 187, 2, '2026-02-17', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2053, 187, 7, '2026-03-26', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2054, 187, 2, '2026-03-13', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2055, 187, 2, '2026-03-19', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2056, 187, 7, '2026-04-09', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2057, 187, 7, '2026-04-17', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2058, 187, 2, '2026-04-10', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2059, 187, 2, '2026-04-13', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2060, 187, 2, '2026-04-19', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2061, 187, 7, '2026-05-19', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2062, 187, 7, '2026-05-27', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2063, 187, 2, '2026-05-24', 8.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2064, 187, 2, '2026-05-08', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2065, 187, 2, '2026-05-16', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2066, 187, 7, '2026-06-14', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2067, 187, 2, '2026-06-02', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2068, 187, 7, '2026-07-06', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2069, 187, 2, '2026-07-26', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2070, 187, 2, '2026-07-06', 2.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2071, 187, 2, '2026-07-12', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2072, 187, 7, '2026-08-21', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2073, 187, 7, '2026-08-06', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2074, 187, 7, '2026-08-12', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2075, 187, 2, '2026-08-01', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2076, 187, 2, '2026-08-22', 4.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2077, 187, 7, '2026-09-14', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2298, 210, 5, '2026-04-02', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2078, 187, 2, '2026-09-25', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2079, 187, 2, '2026-09-15', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2080, 187, 7, '2026-10-18', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2081, 187, 2, '2026-10-08', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2082, 188, 6, '2026-09-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2083, 188, 6, '2026-07-05', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2084, 188, 6, '2026-06-27', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2085, 189, 9, '2026-01-21', 1.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2086, 189, 2, '2026-01-25', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2087, 189, 2, '2026-01-28', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2088, 189, 9, '2026-02-21', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2089, 189, 2, '2026-02-27', 7.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2090, 189, 9, '2026-03-23', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2091, 189, 9, '2026-03-09', 4.50, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2092, 189, 9, '2026-03-27', 7.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2093, 189, 2, '2026-03-11', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2094, 189, 2, '2026-03-22', 2.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2095, 189, 9, '2026-04-04', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2096, 189, 9, '2026-04-25', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2097, 189, 2, '2026-04-01', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2098, 189, 9, '2026-05-14', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2099, 189, 9, '2026-05-18', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2100, 189, 9, '2026-05-09', 8.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2101, 189, 2, '2026-05-01', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2102, 189, 2, '2026-05-13', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2103, 189, 9, '2026-06-18', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2104, 189, 9, '2026-06-14', 5.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2105, 189, 2, '2026-06-24', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2106, 189, 2, '2026-06-01', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2107, 189, 9, '2026-07-15', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2108, 189, 2, '2026-07-25', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2109, 189, 2, '2026-07-26', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2110, 189, 9, '2026-08-21', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2111, 189, 2, '2026-08-12', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2112, 189, 2, '2026-08-18', 6.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2113, 189, 2, '2026-08-20', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2114, 189, 9, '2026-09-19', 6.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2115, 189, 2, '2026-09-14', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2116, 189, 2, '2026-09-09', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2117, 189, 9, '2026-10-18', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2118, 189, 2, '2026-10-18', 1.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2119, 189, 2, '2026-10-06', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2120, 190, 5, '2025-06-06', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2121, 190, 5, '2025-07-09', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2122, 190, 5, '2025-07-16', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2123, 190, 5, '2025-07-19', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2124, 190, 5, '2025-08-18', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2125, 190, 5, '2025-08-13', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2126, 190, 5, '2025-09-28', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2127, 190, 5, '2025-10-04', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2128, 190, 5, '2025-10-27', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2129, 190, 5, '2025-11-20', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2130, 190, 5, '2025-12-22', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2131, 190, 5, '2025-12-11', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2132, 190, 5, '2025-12-11', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2133, 190, 5, '2026-01-18', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2134, 190, 5, '2026-02-14', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2135, 190, 5, '2026-02-10', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2136, 191, 9, '2024-10-05', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2137, 191, 9, '2024-10-16', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2138, 191, 9, '2024-11-25', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2139, 191, 9, '2025-03-18', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2140, 191, 9, '2024-08-20', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2141, 191, 9, '2024-07-08', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2142, 192, 6, '2025-06-26', 5.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2143, 192, 6, '2025-06-08', 3.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2144, 192, 6, '2025-06-10', 5.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2145, 192, 6, '2025-07-03', 1.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2146, 192, 6, '2025-07-23', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2147, 192, 6, '2025-07-19', 3.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2148, 193, 14, '2025-03-03', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2149, 193, 14, '2025-04-02', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2150, 193, 14, '2025-07-04', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2151, 194, 14, '2025-04-24', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2152, 194, 14, '2025-04-29', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2153, 194, 14, '2026-03-16', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2154, 194, 14, '2025-10-09', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2155, 194, 14, '2025-09-06', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2156, 194, 14, '2026-01-10', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2157, 195, 7, '2026-08-26', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2158, 195, 7, '2026-10-04', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2159, 196, 5, '2026-08-15', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2160, 196, 5, '2026-09-14', 2.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2161, 196, 5, '2026-09-26', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2162, 196, 5, '2026-10-02', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2163, 196, 5, '2026-10-18', 4.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2164, 196, 5, '2026-10-18', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2165, 197, 12, '2026-01-27', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2166, 197, 12, '2026-01-14', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2167, 198, 10, '2024-10-22', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2168, 198, 10, '2024-03-29', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2169, 198, 10, '2024-10-12', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2170, 199, 10, '2025-05-08', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2171, 199, 10, '2025-03-17', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2172, 199, 10, '2025-06-02', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2173, 199, 10, '2025-08-10', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2174, 200, 9, '2026-01-28', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2175, 200, 9, '2025-08-12', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2176, 201, 5, '2024-12-21', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2177, 201, 5, '2024-12-04', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2178, 201, 5, '2025-01-26', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2179, 201, 5, '2025-01-04', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2180, 201, 5, '2025-02-01', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2181, 201, 5, '2025-02-15', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2182, 201, 5, '2025-03-23', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2183, 201, 5, '2025-03-20', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2184, 201, 5, '2025-03-28', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2185, 201, 5, '2025-04-08', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2186, 201, 5, '2025-04-03', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2187, 201, 5, '2025-04-04', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2188, 201, 5, '2025-05-24', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2189, 201, 5, '2025-06-17', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2190, 201, 5, '2025-06-04', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2191, 201, 5, '2025-07-22', 3.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2192, 201, 5, '2025-07-25', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2193, 201, 5, '2025-07-02', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2194, 201, 5, '2025-08-07', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2195, 201, 5, '2025-08-28', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2196, 201, 5, '2025-08-15', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2197, 201, 5, '2025-09-07', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2198, 201, 5, '2025-09-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08');
INSERT INTO public.time_entry VALUES
	(2199, 201, 5, '2025-10-23', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2200, 201, 5, '2025-10-28', 8.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2201, 201, 5, '2025-10-15', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2202, 201, 5, '2025-11-24', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2203, 201, 5, '2025-11-25', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2204, 201, 5, '2025-11-09', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2205, 201, 5, '2025-12-18', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2206, 201, 5, '2025-12-20', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2207, 201, 5, '2025-12-19', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2208, 202, 7, '2025-01-27', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2209, 202, 2, '2025-01-14', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2210, 202, 2, '2025-01-23', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2211, 202, 7, '2025-02-09', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2212, 202, 2, '2025-02-21', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2213, 202, 2, '2025-02-21', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2214, 202, 2, '2025-02-15', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2215, 202, 7, '2025-03-10', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2216, 202, 7, '2025-03-05', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2217, 202, 2, '2025-03-21', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2218, 202, 2, '2025-03-13', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2219, 202, 7, '2025-04-20', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2220, 202, 7, '2025-04-13', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2221, 202, 7, '2025-04-07', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2222, 202, 2, '2025-04-02', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2223, 202, 2, '2025-04-13', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2224, 202, 2, '2025-04-03', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2225, 202, 7, '2025-05-15', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2226, 202, 2, '2025-05-19', 1.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2227, 202, 7, '2025-06-21', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2228, 202, 7, '2025-06-06', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2229, 202, 7, '2025-06-24', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2230, 202, 2, '2025-06-23', 7.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2231, 202, 2, '2025-06-25', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2232, 202, 2, '2025-06-23', 2.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2233, 202, 7, '2025-07-05', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2234, 202, 2, '2025-07-25', 8.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2235, 202, 2, '2025-07-24', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2236, 202, 2, '2025-07-21', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2237, 202, 7, '2025-08-26', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2238, 202, 7, '2025-08-23', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2239, 202, 2, '2025-08-19', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2240, 202, 7, '2025-09-23', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2241, 202, 7, '2025-09-15', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2242, 202, 7, '2025-09-05', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2243, 202, 2, '2025-09-18', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2244, 202, 2, '2025-09-07', 3.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2245, 202, 7, '2025-10-19', 7.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2246, 202, 7, '2025-10-04', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2247, 202, 7, '2025-10-12', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2248, 202, 2, '2025-10-04', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2249, 202, 2, '2025-10-06', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2250, 202, 2, '2025-10-23', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2251, 202, 7, '2025-11-26', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2252, 202, 2, '2025-11-21', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2253, 202, 2, '2025-11-14', 2.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2254, 202, 7, '2025-12-16', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2255, 202, 2, '2025-12-06', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2256, 202, 7, '2026-01-27', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2257, 202, 7, '2026-01-05', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2258, 202, 2, '2026-01-23', 3.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2259, 202, 2, '2026-01-20', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2260, 202, 7, '2026-02-11', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2261, 202, 7, '2026-02-28', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2262, 202, 7, '2026-02-08', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2263, 202, 2, '2026-02-08', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2264, 202, 2, '2026-02-16', 5.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2265, 202, 2, '2026-02-12', 5.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2266, 203, 7, '2025-06-13', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2267, 203, 7, '2025-07-03', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2268, 204, 4, '2025-10-31', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2269, 204, 4, '2025-10-12', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2270, 204, 4, '2025-10-21', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2271, 204, 4, '2025-09-26', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2272, 204, 4, '2025-08-19', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2273, 205, 4, '2025-11-19', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2274, 205, 4, '2026-04-16', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2275, 205, 4, '2026-02-18', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2276, 206, 5, '2025-06-12', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2277, 206, 5, '2025-06-23', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2278, 206, 5, '2025-06-25', 5.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2279, 206, 5, '2025-07-09', 1.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2280, 207, 9, '2026-07-23', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2281, 207, 9, '2026-08-04', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2282, 207, 9, '2026-08-18', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2283, 207, 9, '2026-09-11', 3.00, 1800.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2284, 207, 9, '2026-09-11', 2.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2285, 207, 9, '2026-09-03', 7.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2286, 207, 9, '2026-10-18', 6.50, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2287, 207, 9, '2026-10-04', 4.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2288, 207, 9, '2026-10-18', 3.00, 1800.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2289, 208, 4, '2026-06-30', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2290, 208, 4, '2026-07-12', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2291, 209, 14, '2025-07-20', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2292, 209, 14, '2025-06-05', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2293, 209, 14, '2025-05-14', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2294, 209, 14, '2025-04-06', 5.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2295, 210, 5, '2026-04-18', 6.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2296, 210, 5, '2026-04-11', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2299, 210, 5, '2026-04-06', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2300, 210, 5, '2026-04-14', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2301, 211, 11, '2024-10-26', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2302, 211, 3, '2024-10-23', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2303, 211, 3, '2024-10-07', 8.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2304, 211, 11, '2024-11-25', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2305, 211, 11, '2024-11-20', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2306, 211, 11, '2024-11-05', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2307, 211, 3, '2024-11-22', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2308, 211, 3, '2024-11-25', 2.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2309, 211, 11, '2024-12-03', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2310, 211, 11, '2024-12-24', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2311, 211, 11, '2024-12-14', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2312, 211, 3, '2024-12-27', 4.50, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2313, 211, 11, '2025-01-19', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2314, 211, 11, '2025-01-01', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2315, 211, 3, '2025-01-23', 6.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2316, 211, 3, '2025-01-06', 7.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2317, 211, 11, '2025-02-08', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2318, 211, 11, '2025-02-10', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2319, 211, 11, '2025-02-10', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2320, 211, 3, '2025-02-15', 3.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2321, 211, 3, '2025-02-03', 4.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2322, 211, 11, '2025-03-09', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2323, 211, 11, '2025-03-14', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2324, 211, 3, '2025-03-01', 2.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2325, 211, 11, '2025-04-24', 5.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2326, 211, 11, '2025-04-06', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2327, 211, 11, '2025-04-28', 6.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2328, 211, 3, '2025-04-18', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2329, 211, 3, '2025-04-15', 3.00, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2330, 211, 3, '2025-04-26', 5.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2331, 211, 11, '2025-05-02', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2332, 211, 3, '2025-05-04', 4.00, 3000.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2333, 211, 3, '2025-05-17', 4.50, 3000.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2334, 212, 14, '2025-04-26', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2335, 212, 14, '2025-04-15', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2336, 212, 14, '2025-05-16', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2337, 212, 14, '2025-05-24', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2338, 212, 14, '2025-06-01', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2339, 212, 14, '2025-06-07', 2.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2340, 212, 14, '2025-06-22', 7.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2341, 212, 14, '2025-07-08', 7.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2342, 212, 14, '2025-07-25', 2.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2343, 212, 14, '2025-07-06', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2344, 212, 14, '2025-08-17', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2345, 212, 14, '2025-08-27', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2346, 212, 14, '2025-08-23', 6.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2347, 212, 14, '2025-09-17', 7.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2348, 212, 14, '2025-10-08', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2349, 212, 14, '2025-10-08', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2350, 212, 14, '2025-10-14', 3.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2351, 212, 14, '2025-11-02', 1.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2352, 212, 14, '2025-11-17', 3.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2353, 212, 14, '2025-12-22', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2354, 212, 14, '2025-12-14', 2.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2355, 212, 14, '2026-01-26', 4.00, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2356, 212, 14, '2026-01-17', 3.50, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2357, 212, 14, '2026-01-05', 5.00, 1200.00, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2358, 212, 14, '2026-02-10', 4.50, 1200.00, true, NULL, '2026-10-18 19:23:26.224524+08'),
	(2359, 213, 13, '2024-09-19', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2360, 213, 13, '2024-10-17', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2361, 213, 13, '2024-12-22', 2.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2362, 213, 13, '2024-11-02', 3.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2363, 213, 13, '2024-10-06', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2364, 214, 10, '2024-11-19', 4.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2365, 214, 10, '2024-10-14', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08'),
	(2366, 214, 10, '2025-01-03', 1.00, NULL, false, NULL, '2026-10-18 19:23:26.224524+08');


--
-- Data for Name: user_permission_override; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: user_role; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.user_role VALUES
	(1, 3),
	(2, 2),
	(3, 2),
	(4, 1),
	(5, 1),
	(6, 1),
	(7, 1),
	(8, 2),
	(9, 1),
	(10, 1),
	(11, 1),
	(12, 1),
	(13, 1),
	(14, 1),
	(15, 4);


--
-- Name: agent_conversation_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.agent_conversation_id_seq', 58, true);


--
-- Name: agent_message_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.agent_message_id_seq', 631, true);


--
-- Name: agent_report_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.agent_report_id_seq', 29, true);


--
-- Name: app_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.app_user_id_seq', 15, true);


--
-- Name: audit_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.audit_log_id_seq', 5100, true);


--
-- Name: case_event_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.case_event_id_seq', 1, false);


--
-- Name: client_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.client_id_seq', 155, true);


--
-- Name: department_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.department_id_seq', 3, true);


--
-- Name: employee_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.employee_id_seq', 14, true);


--
-- Name: fee_agreement_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.fee_agreement_id_seq', 214, true);


--
-- Name: invoice_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.invoice_id_seq', 762, true);


--
-- Name: law_document_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.law_document_id_seq', 4, true);


--
-- Name: legal_case_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.legal_case_id_seq', 214, true);


--
-- Name: payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.payment_id_seq', 639, true);


--
-- Name: role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.role_id_seq', 4, true);


--
-- Name: time_entry_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.time_entry_id_seq', 2366, true);


--
-- PostgreSQL database dump complete
--


--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Homebrew)
-- Dumped by pg_dump version 16.15 (Homebrew)

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

SET default_tablespace = '';

--
-- Name: agent_conversation agent_conversation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_conversation
    ADD CONSTRAINT agent_conversation_pkey PRIMARY KEY (id);


--
-- Name: agent_message agent_message_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_message
    ADD CONSTRAINT agent_message_pkey PRIMARY KEY (id);


--
-- Name: agent_report agent_report_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report
    ADD CONSTRAINT agent_report_pkey PRIMARY KEY (id);


--
-- Name: agent_report_share agent_report_share_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report_share
    ADD CONSTRAINT agent_report_share_pkey PRIMARY KEY (report_id, user_id);


--
-- Name: app_setting app_setting_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_setting
    ADD CONSTRAINT app_setting_pkey PRIMARY KEY (key);


--
-- Name: app_user app_user_employee_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_employee_id_key UNIQUE (employee_id);


--
-- Name: app_user app_user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_pkey PRIMARY KEY (id);


--
-- Name: app_user app_user_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_username_key UNIQUE (username);


--
-- Name: app_user app_user_wechat_openid_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_wechat_openid_key UNIQUE (wechat_openid);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: case_assignment case_assignment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_assignment
    ADD CONSTRAINT case_assignment_pkey PRIMARY KEY (case_id, employee_id);


--
-- Name: case_event case_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_event
    ADD CONSTRAINT case_event_pkey PRIMARY KEY (id);


--
-- Name: client client_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_pkey PRIMARY KEY (id);


--
-- Name: department_head department_head_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department_head
    ADD CONSTRAINT department_head_pkey PRIMARY KEY (department_id, employee_id);


--
-- Name: department department_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_name_key UNIQUE (name);


--
-- Name: department department_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_pkey PRIMARY KEY (id);


--
-- Name: employee_hr employee_hr_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_hr
    ADD CONSTRAINT employee_hr_pkey PRIMARY KEY (employee_id);


--
-- Name: employee employee_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_pkey PRIMARY KEY (id);


--
-- Name: fee_agreement fee_agreement_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fee_agreement
    ADD CONSTRAINT fee_agreement_pkey PRIMARY KEY (id);


--
-- Name: invoice invoice_invoice_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_invoice_no_key UNIQUE (invoice_no);


--
-- Name: invoice invoice_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_pkey PRIMARY KEY (id);


--
-- Name: law_document law_document_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.law_document
    ADD CONSTRAINT law_document_pkey PRIMARY KEY (id);


--
-- Name: legal_case legal_case_case_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_case
    ADD CONSTRAINT legal_case_case_number_key UNIQUE (case_number);


--
-- Name: legal_case legal_case_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_case
    ADD CONSTRAINT legal_case_pkey PRIMARY KEY (id);


--
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (id);


--
-- Name: permission_catalog permission_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_catalog
    ADD CONSTRAINT permission_catalog_pkey PRIMARY KEY (resource, action);


--
-- Name: role role_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_code_key UNIQUE (code);


--
-- Name: role_permission role_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT role_permission_pkey PRIMARY KEY (role_id, resource, action);


--
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (name);


--
-- Name: time_entry time_entry_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_entry
    ADD CONSTRAINT time_entry_pkey PRIMARY KEY (id);


--
-- Name: user_permission_override user_permission_override_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_override
    ADD CONSTRAINT user_permission_override_pkey PRIMARY KEY (user_id, resource, action);


--
-- Name: user_role user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, role_id);


--
-- Name: agent_conversation_user_id_updated_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_conversation_user_id_updated_at_idx ON public.agent_conversation USING btree (user_id, updated_at DESC);


--
-- Name: agent_message_conversation_id_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_message_conversation_id_id_idx ON public.agent_message USING btree (conversation_id, id);


--
-- Name: agent_report_user_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_report_user_id_created_at_idx ON public.agent_report USING btree (user_id, created_at DESC);


--
-- Name: audit_log_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_at_idx ON public.audit_log USING btree (at);


--
-- Name: audit_log_user_id_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_log_user_id_at_idx ON public.audit_log USING btree (user_id, at);


--
-- Name: case_assignment_employee_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_assignment_employee_id_idx ON public.case_assignment USING btree (employee_id);


--
-- Name: case_event_case_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX case_event_case_id_idx ON public.case_event USING btree (case_id);


--
-- Name: client_originating_lawyer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX client_originating_lawyer_id_idx ON public.client USING btree (originating_lawyer_id);


--
-- Name: employee_department_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX employee_department_id_idx ON public.employee USING btree (department_id);


--
-- Name: employee_supervisor_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX employee_supervisor_id_idx ON public.employee USING btree (supervisor_id);


--
-- Name: fee_agreement_case_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fee_agreement_case_id_idx ON public.fee_agreement USING btree (case_id);


--
-- Name: invoice_case_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoice_case_id_idx ON public.invoice USING btree (case_id);


--
-- Name: legal_case_client_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX legal_case_client_id_idx ON public.legal_case USING btree (client_id);


--
-- Name: legal_case_is_public_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX legal_case_is_public_idx ON public.legal_case USING btree (is_public) WHERE is_public;


--
-- Name: payment_invoice_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payment_invoice_id_idx ON public.payment USING btree (invoice_id);


--
-- Name: time_entry_case_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX time_entry_case_id_idx ON public.time_entry USING btree (case_id);


--
-- Name: time_entry_employee_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX time_entry_employee_id_idx ON public.time_entry USING btree (employee_id);


--
-- Name: agent_report_share agent_report_share_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_report_share_audit AFTER INSERT OR DELETE OR UPDATE ON public.agent_report_share FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: app_setting app_setting_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER app_setting_audit AFTER INSERT OR DELETE OR UPDATE ON public.app_setting FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: app_user app_user_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER app_user_audit AFTER INSERT OR DELETE OR UPDATE ON public.app_user FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: case_assignment case_assignment_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER case_assignment_audit AFTER INSERT OR DELETE OR UPDATE ON public.case_assignment FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: case_event case_event_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER case_event_audit AFTER INSERT OR DELETE OR UPDATE ON public.case_event FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: client client_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER client_audit AFTER INSERT OR DELETE OR UPDATE ON public.client FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: department department_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER department_audit AFTER INSERT OR DELETE OR UPDATE ON public.department FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: department_head department_head_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER department_head_audit AFTER INSERT OR DELETE OR UPDATE ON public.department_head FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: employee employee_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER employee_audit AFTER INSERT OR DELETE OR UPDATE ON public.employee FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: employee_hr employee_hr_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER employee_hr_audit AFTER INSERT OR DELETE OR UPDATE ON public.employee_hr FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: employee_hr employee_hr_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER employee_hr_touch BEFORE UPDATE ON public.employee_hr FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: fee_agreement fee_agreement_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER fee_agreement_audit AFTER INSERT OR DELETE OR UPDATE ON public.fee_agreement FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: invoice invoice_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER invoice_audit AFTER INSERT OR DELETE OR UPDATE ON public.invoice FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: law_document law_document_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER law_document_audit AFTER INSERT OR DELETE OR UPDATE ON public.law_document FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: legal_case legal_case_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER legal_case_audit AFTER INSERT OR DELETE OR UPDATE ON public.legal_case FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: legal_case legal_case_publish_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER legal_case_publish_guard BEFORE UPDATE ON public.legal_case FOR EACH ROW EXECUTE FUNCTION public.guard_case_publish();


--
-- Name: legal_case legal_case_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER legal_case_touch BEFORE UPDATE ON public.legal_case FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: payment payment_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payment_audit AFTER INSERT OR DELETE OR UPDATE ON public.payment FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: role role_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER role_audit AFTER INSERT OR DELETE OR UPDATE ON public.role FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: role_permission role_permission_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER role_permission_audit AFTER INSERT OR DELETE OR UPDATE ON public.role_permission FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: time_entry time_entry_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER time_entry_audit AFTER INSERT OR DELETE OR UPDATE ON public.time_entry FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: user_permission_override user_permission_override_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_permission_override_audit AFTER INSERT OR DELETE OR UPDATE ON public.user_permission_override FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: user_role user_role_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_role_audit AFTER INSERT OR DELETE OR UPDATE ON public.user_role FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();


--
-- Name: agent_conversation agent_conversation_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_conversation
    ADD CONSTRAINT agent_conversation_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_user(id) ON DELETE CASCADE;


--
-- Name: agent_message agent_message_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_message
    ADD CONSTRAINT agent_message_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.agent_conversation(id) ON DELETE CASCADE;


--
-- Name: agent_report agent_report_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report
    ADD CONSTRAINT agent_report_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.agent_conversation(id) ON DELETE SET NULL;


--
-- Name: agent_report_share agent_report_share_report_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report_share
    ADD CONSTRAINT agent_report_share_report_id_fkey FOREIGN KEY (report_id) REFERENCES public.agent_report(id) ON DELETE CASCADE;


--
-- Name: agent_report_share agent_report_share_shared_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report_share
    ADD CONSTRAINT agent_report_share_shared_by_fkey FOREIGN KEY (shared_by) REFERENCES public.app_user(id);


--
-- Name: agent_report_share agent_report_share_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report_share
    ADD CONSTRAINT agent_report_share_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_user(id) ON DELETE CASCADE;


--
-- Name: agent_report agent_report_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_report
    ADD CONSTRAINT agent_report_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_user(id) ON DELETE CASCADE;


--
-- Name: app_user app_user_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user
    ADD CONSTRAINT app_user_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id);


--
-- Name: case_assignment case_assignment_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_assignment
    ADD CONSTRAINT case_assignment_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.legal_case(id) ON DELETE CASCADE;


--
-- Name: case_assignment case_assignment_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_assignment
    ADD CONSTRAINT case_assignment_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id);


--
-- Name: case_event case_event_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_event
    ADD CONSTRAINT case_event_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.legal_case(id) ON DELETE CASCADE;


--
-- Name: case_event case_event_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.case_event
    ADD CONSTRAINT case_event_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.employee(id);


--
-- Name: client client_originating_lawyer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client
    ADD CONSTRAINT client_originating_lawyer_id_fkey FOREIGN KEY (originating_lawyer_id) REFERENCES public.employee(id);


--
-- Name: department_head department_head_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department_head
    ADD CONSTRAINT department_head_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.department(id) ON DELETE CASCADE;


--
-- Name: department_head department_head_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.department_head
    ADD CONSTRAINT department_head_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id) ON DELETE CASCADE;


--
-- Name: employee employee_department_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_department_id_fkey FOREIGN KEY (department_id) REFERENCES public.department(id);


--
-- Name: employee_hr employee_hr_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee_hr
    ADD CONSTRAINT employee_hr_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id) ON DELETE CASCADE;


--
-- Name: employee employee_supervisor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_supervisor_id_fkey FOREIGN KEY (supervisor_id) REFERENCES public.employee(id);


--
-- Name: fee_agreement fee_agreement_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fee_agreement
    ADD CONSTRAINT fee_agreement_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.legal_case(id) ON DELETE CASCADE;


--
-- Name: invoice invoice_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.legal_case(id) ON DELETE CASCADE;


--
-- Name: law_document law_document_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.law_document
    ADD CONSTRAINT law_document_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.employee(id);


--
-- Name: legal_case legal_case_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_case
    ADD CONSTRAINT legal_case_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.client(id);


--
-- Name: legal_case legal_case_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_case
    ADD CONSTRAINT legal_case_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.employee(id);


--
-- Name: payment payment_invoice_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment
    ADD CONSTRAINT payment_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoice(id) ON DELETE CASCADE;


--
-- Name: role_permission role_permission_resource_action_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT role_permission_resource_action_fkey FOREIGN KEY (resource, action) REFERENCES public.permission_catalog(resource, action);


--
-- Name: role_permission role_permission_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT role_permission_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(id) ON DELETE CASCADE;


--
-- Name: time_entry time_entry_case_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_entry
    ADD CONSTRAINT time_entry_case_id_fkey FOREIGN KEY (case_id) REFERENCES public.legal_case(id) ON DELETE CASCADE;


--
-- Name: time_entry time_entry_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.time_entry
    ADD CONSTRAINT time_entry_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(id);


--
-- Name: user_permission_override user_permission_override_resource_action_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_override
    ADD CONSTRAINT user_permission_override_resource_action_fkey FOREIGN KEY (resource, action) REFERENCES public.permission_catalog(resource, action);


--
-- Name: user_permission_override user_permission_override_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_permission_override
    ADD CONSTRAINT user_permission_override_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_user(id) ON DELETE CASCADE;


--
-- Name: user_role user_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.role(id) ON DELETE CASCADE;


--
-- Name: user_role user_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_user(id) ON DELETE CASCADE;


--
-- Name: agent_conversation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_conversation ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_message; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_message ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_report; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_report ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_report_share; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agent_report_share ENABLE ROW LEVEL SECURITY;

--
-- Name: app_setting; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_setting ENABLE ROW LEVEL SECURITY;

--
-- Name: app_user; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_user ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: case_assignment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.case_assignment ENABLE ROW LEVEL SECURITY;

--
-- Name: case_event; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.case_event ENABLE ROW LEVEL SECURITY;

--
-- Name: client; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.client ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_report_share del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY del ON public.agent_report_share FOR DELETE USING ((report_id IN ( SELECT public.my_report_ids() AS my_report_ids)));


--
-- Name: case_assignment del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY del ON public.case_assignment FOR DELETE USING (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR ((case_id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids)) AND (employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)))));


--
-- Name: client del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY del ON public.client FOR DELETE USING ((( SELECT public.has_scope('client'::text, 'delete'::text) AS has_scope) = 'all'::public.perm_scope));


--
-- Name: legal_case del; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY del ON public.legal_case FOR DELETE USING (((( SELECT public.has_scope('case'::text, 'delete'::text) AS has_scope) = 'all'::public.perm_scope) OR (id IN ( SELECT public.accessible_case_ids('case'::text, 'delete'::text) AS accessible_case_ids))));


--
-- Name: department; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.department ENABLE ROW LEVEL SECURITY;

--
-- Name: department_head; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.department_head ENABLE ROW LEVEL SECURITY;

--
-- Name: employee; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.employee ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_hr; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.employee_hr ENABLE ROW LEVEL SECURITY;

--
-- Name: fee_agreement; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fee_agreement ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_message ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ins ON public.agent_message FOR INSERT WITH CHECK ((conversation_id IN ( SELECT agent_conversation.id
   FROM public.agent_conversation
  WHERE (agent_conversation.user_id = public.app_uid()))));


--
-- Name: agent_report_share ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ins ON public.agent_report_share FOR INSERT WITH CHECK (((shared_by = public.app_uid()) AND (report_id IN ( SELECT public.my_report_ids() AS my_report_ids))));


--
-- Name: case_assignment ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ins ON public.case_assignment FOR INSERT WITH CHECK (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR ((case_id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids)) AND (employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)))));


--
-- Name: client ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ins ON public.client FOR INSERT WITH CHECK (((( SELECT public.has_scope('client'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (originating_lawyer_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('client'::text, 'write'::text) AS has_scope)) AS scope_employee_ids))));


--
-- Name: legal_case ins; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ins ON public.legal_case FOR INSERT WITH CHECK ((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope));


--
-- Name: invoice; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invoice ENABLE ROW LEVEL SECURITY;

--
-- Name: law_document; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.law_document ENABLE ROW LEVEL SECURITY;

--
-- Name: legal_case; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.legal_case ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_conversation mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.agent_conversation USING ((user_id = public.app_uid())) WITH CHECK ((user_id = public.app_uid()));


--
-- Name: agent_report mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.agent_report USING ((user_id = public.app_uid())) WITH CHECK ((user_id = public.app_uid()));


--
-- Name: app_setting mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.app_setting USING (( SELECT public.is_user_admin() AS is_user_admin)) WITH CHECK (( SELECT public.is_user_admin() AS is_user_admin));


--
-- Name: app_user mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.app_user USING (( SELECT public.is_user_admin() AS is_user_admin)) WITH CHECK (( SELECT public.is_user_admin() AS is_user_admin));


--
-- Name: case_event mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.case_event USING (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids)))) WITH CHECK (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids))));


--
-- Name: department mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.department USING ((( SELECT public.has_scope('employee'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope)) WITH CHECK ((( SELECT public.has_scope('employee'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope));


--
-- Name: department_head mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.department_head USING ((( SELECT public.has_scope('employee'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope)) WITH CHECK ((( SELECT public.has_scope('employee'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope));


--
-- Name: employee mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.employee USING ((( SELECT public.has_scope('employee'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope)) WITH CHECK ((( SELECT public.has_scope('employee'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope));


--
-- Name: employee_hr mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.employee_hr USING ((employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('salary'::text, 'write'::text) AS has_scope)) AS scope_employee_ids))) WITH CHECK ((employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('salary'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)));


--
-- Name: fee_agreement mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.fee_agreement USING (((( SELECT public.has_scope('billing'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'write'::text) AS accessible_case_ids)))) WITH CHECK (((( SELECT public.has_scope('billing'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'write'::text) AS accessible_case_ids))));


--
-- Name: invoice mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.invoice USING (((( SELECT public.has_scope('billing'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'write'::text) AS accessible_case_ids)))) WITH CHECK (((( SELECT public.has_scope('billing'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'write'::text) AS accessible_case_ids))));


--
-- Name: law_document mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.law_document USING (((( SELECT public.has_scope('law_info'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR ((( SELECT public.has_scope('law_info'::text, 'write'::text) AS has_scope) > 'none'::public.perm_scope) AND (created_by = public.app_eid())))) WITH CHECK (((( SELECT public.has_scope('law_info'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR ((( SELECT public.has_scope('law_info'::text, 'write'::text) AS has_scope) > 'none'::public.perm_scope) AND (created_by = public.app_eid()))));


--
-- Name: payment mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.payment USING (((( SELECT public.has_scope('billing'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (invoice_id IN ( SELECT i.id
   FROM public.invoice i
  WHERE (i.case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'write'::text) AS accessible_case_ids)))))) WITH CHECK (((( SELECT public.has_scope('billing'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (invoice_id IN ( SELECT i.id
   FROM public.invoice i
  WHERE (i.case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'write'::text) AS accessible_case_ids))))));


--
-- Name: role mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.role USING (( SELECT public.is_user_admin() AS is_user_admin)) WITH CHECK (( SELECT public.is_user_admin() AS is_user_admin));


--
-- Name: role_permission mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.role_permission USING (( SELECT public.is_user_admin() AS is_user_admin)) WITH CHECK (( SELECT public.is_user_admin() AS is_user_admin));


--
-- Name: time_entry mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.time_entry USING ((employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('timesheet'::text, 'write'::text) AS has_scope)) AS scope_employee_ids))) WITH CHECK (((employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('timesheet'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)) AND ((( SELECT public.has_scope('case'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('case'::text, 'read'::text) AS accessible_case_ids)))));


--
-- Name: user_permission_override mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.user_permission_override USING (( SELECT public.is_user_admin() AS is_user_admin)) WITH CHECK (( SELECT public.is_user_admin() AS is_user_admin));


--
-- Name: user_role mod; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY mod ON public.user_role USING (( SELECT public.is_user_admin() AS is_user_admin)) WITH CHECK (( SELECT public.is_user_admin() AS is_user_admin));


--
-- Name: payment; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payment ENABLE ROW LEVEL SECURITY;

--
-- Name: permission_catalog; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permission_catalog ENABLE ROW LEVEL SECURITY;

--
-- Name: role; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permission; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_permission ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_conversation sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.agent_conversation FOR SELECT USING (((user_id = public.app_uid()) OR (( SELECT public.has_scope('agent'::text, 'monitor'::text) AS has_scope) = 'all'::public.perm_scope)));


--
-- Name: agent_message sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.agent_message FOR SELECT USING (((( SELECT public.has_scope('agent'::text, 'monitor'::text) AS has_scope) = 'all'::public.perm_scope) OR (conversation_id IN ( SELECT agent_conversation.id
   FROM public.agent_conversation
  WHERE (agent_conversation.user_id = public.app_uid())))));


--
-- Name: agent_report sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.agent_report FOR SELECT USING (((user_id = public.app_uid()) OR (id IN ( SELECT public.reports_shared_with_me() AS reports_shared_with_me)) OR (( SELECT public.has_scope('agent'::text, 'monitor'::text) AS has_scope) = 'all'::public.perm_scope)));


--
-- Name: agent_report_share sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.agent_report_share FOR SELECT USING (((user_id = public.app_uid()) OR (report_id IN ( SELECT public.my_report_ids() AS my_report_ids)) OR (( SELECT public.has_scope('agent'::text, 'monitor'::text) AS has_scope) = 'all'::public.perm_scope)));


--
-- Name: app_setting sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.app_setting FOR SELECT USING ((public.app_uid() IS NOT NULL));


--
-- Name: app_user sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.app_user FOR SELECT USING (((id = public.app_uid()) OR ( SELECT public.is_user_admin() AS is_user_admin)));


--
-- Name: audit_log sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.audit_log FOR SELECT USING ((( SELECT public.has_scope('audit'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope));


--
-- Name: case_assignment sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.case_assignment FOR SELECT USING (((( SELECT public.has_scope('case'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('case'::text, 'read'::text) AS accessible_case_ids))));


--
-- Name: case_event sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.case_event FOR SELECT USING (((( SELECT public.has_scope('case'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('case'::text, 'read'::text) AS accessible_case_ids)) OR (case_id IN ( SELECT legal_case.id
   FROM public.legal_case
  WHERE legal_case.is_public))));


--
-- Name: client sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.client FOR SELECT USING (((( SELECT public.has_scope('client'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (originating_lawyer_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('client'::text, 'read'::text) AS has_scope)) AS scope_employee_ids)) OR (id IN ( SELECT public.client_ids_via_cases('read'::text) AS client_ids_via_cases))));


--
-- Name: department sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.department FOR SELECT USING ((public.app_uid() IS NOT NULL));


--
-- Name: department_head sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.department_head FOR SELECT USING ((public.app_uid() IS NOT NULL));


--
-- Name: employee sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.employee FOR SELECT USING ((id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('employee'::text, 'read'::text) AS has_scope)) AS scope_employee_ids)));


--
-- Name: employee_hr sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.employee_hr FOR SELECT USING ((employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('salary'::text, 'read'::text) AS has_scope)) AS scope_employee_ids)));


--
-- Name: fee_agreement sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.fee_agreement FOR SELECT USING (((( SELECT public.has_scope('billing'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'read'::text) AS accessible_case_ids))));


--
-- Name: invoice sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.invoice FOR SELECT USING (((( SELECT public.has_scope('billing'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'read'::text) AS accessible_case_ids))));


--
-- Name: law_document sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.law_document FOR SELECT USING ((( SELECT public.has_scope('law_info'::text, 'read'::text) AS has_scope) > 'none'::public.perm_scope));


--
-- Name: legal_case sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.legal_case FOR SELECT USING (((( SELECT public.has_scope('case'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (id IN ( SELECT public.accessible_case_ids('case'::text, 'read'::text) AS accessible_case_ids)) OR (is_public AND (( SELECT public.has_scope('case'::text, 'read'::text) AS has_scope) > 'none'::public.perm_scope))));


--
-- Name: payment sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.payment FOR SELECT USING (((( SELECT public.has_scope('billing'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (invoice_id IN ( SELECT i.id
   FROM public.invoice i
  WHERE (i.case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'read'::text) AS accessible_case_ids))))));


--
-- Name: permission_catalog sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.permission_catalog FOR SELECT USING ((public.app_uid() IS NOT NULL));


--
-- Name: role sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.role FOR SELECT USING ((public.app_uid() IS NOT NULL));


--
-- Name: role_permission sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.role_permission FOR SELECT USING ((public.app_uid() IS NOT NULL));


--
-- Name: time_entry sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.time_entry FOR SELECT USING (((( SELECT public.has_scope('billing'::text, 'read'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('billing'::text, 'read'::text) AS accessible_case_ids)) OR (employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('timesheet'::text, 'read'::text) AS has_scope)) AS scope_employee_ids))));


--
-- Name: user_permission_override sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.user_permission_override FOR SELECT USING (((user_id = public.app_uid()) OR ( SELECT public.is_user_admin() AS is_user_admin)));


--
-- Name: user_role sel; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sel ON public.user_role FOR SELECT USING (((user_id = public.app_uid()) OR ( SELECT public.is_user_admin() AS is_user_admin)));


--
-- Name: time_entry; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.time_entry ENABLE ROW LEVEL SECURITY;

--
-- Name: case_assignment upd; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY upd ON public.case_assignment FOR UPDATE USING (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (case_id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids)))) WITH CHECK (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR ((case_id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids)) AND (employee_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)))));


--
-- Name: client upd; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY upd ON public.client FOR UPDATE USING (((( SELECT public.has_scope('client'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (originating_lawyer_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('client'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)) OR (id IN ( SELECT public.client_ids_via_cases('write'::text) AS client_ids_via_cases)))) WITH CHECK (((( SELECT public.has_scope('client'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (originating_lawyer_id IN ( SELECT public.scope_employee_ids(( SELECT public.has_scope('client'::text, 'write'::text) AS has_scope)) AS scope_employee_ids)) OR (id IN ( SELECT public.client_ids_via_cases('write'::text) AS client_ids_via_cases))));


--
-- Name: legal_case upd; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY upd ON public.legal_case FOR UPDATE USING (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids)))) WITH CHECK (((( SELECT public.has_scope('case'::text, 'write'::text) AS has_scope) = 'all'::public.perm_scope) OR (id IN ( SELECT public.accessible_case_ids('case'::text, 'write'::text) AS accessible_case_ids))));


--
-- Name: user_permission_override; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_permission_override ENABLE ROW LEVEL SECURITY;

--
-- Name: user_role; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_role ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--


RESET ALL; SET search_path = public; SET row_security = on;
