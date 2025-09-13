
\restrict XQfwpsrN0ewV57HeVViTqEi4cSz83KumxxscqBp4VfSKOV0ZglCxWmHAlTWYWcl

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict XQfwpsrN0ewV57HeVViTqEi4cSz83KumxxscqBp4VfSKOV0ZglCxWmHAlTWYWcl

RESET ALL;
