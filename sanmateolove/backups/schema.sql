
\restrict UEcNAW08e2NYkmdpVcigypYhZdzip94x0rgjx98LdHFrLiaEmBJy53AticgUAYL


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



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."handle_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_updated_at"() OWNER TO "postgres";


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
    "is_deleted" boolean DEFAULT false
);


ALTER TABLE "public"."contacts" OWNER TO "postgres";


COMMENT ON COLUMN "public"."contacts"."title" IS 'Name of the contact/business';



COMMENT ON COLUMN "public"."contacts"."category" IS 'Category assignment (single value)';



COMMENT ON COLUMN "public"."contacts"."subtitle" IS 'Short description or tagline';



COMMENT ON COLUMN "public"."contacts"."phone_number" IS 'Contact phone number';



COMMENT ON COLUMN "public"."contacts"."website_url" IS 'Link to website or social media';



COMMENT ON COLUMN "public"."contacts"."image_url" IS 'Public URL of the image stored in Supabase Storage';



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



ALTER TABLE ONLY "public"."wiki_pages"
    ADD CONSTRAINT "wiki_pages_pkey" PRIMARY KEY ("id", "version");



CREATE INDEX "wiki_pages_content_idx" ON "public"."wiki_pages" USING "gin" ("content");



CREATE INDEX "wiki_pages_content_tsv_idx" ON "public"."wiki_pages" USING "gin" ("content_tsv");



CREATE INDEX "wiki_pages_slug_idx" ON "public"."wiki_pages" USING "btree" ("slug");



CREATE INDEX "wiki_pages_title_idx" ON "public"."wiki_pages" USING "gin" ("to_tsvector"('"english"'::"regconfig", "title"));



CREATE OR REPLACE TRIGGER "on_contacts_updated" BEFORE UPDATE ON "public"."contacts" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "wiki_pages_tsv_update" BEFORE INSERT OR UPDATE ON "public"."wiki_pages" FOR EACH ROW EXECUTE FUNCTION "public"."update_wiki_content_tsv"();



CREATE POLICY "All access for All Users" ON "public"."contacts" USING (true);



CREATE POLICY "All access for All Users" ON "public"."wiki_pages" USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."wiki_pages" FOR SELECT USING (true);



ALTER TABLE "public"."contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."wiki_pages" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";




















































































































































































GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_wiki_content_tsv"() TO "service_role";


















GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."contacts" TO "anon";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."contacts" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE "public"."contacts" TO "service_role";



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






























\unrestrict UEcNAW08e2NYkmdpVcigypYhZdzip94x0rgjx98LdHFrLiaEmBJy53AticgUAYL

RESET ALL;
