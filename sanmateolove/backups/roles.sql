
\restrict BXlBTPUWhsgDNiIhAD5TI7B3Y1V2sm0Ouh7f1N1nOPfQcdyfpIA43rRE6Cf4ZRL

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict BXlBTPUWhsgDNiIhAD5TI7B3Y1V2sm0Ouh7f1N1nOPfQcdyfpIA43rRE6Cf4ZRL

RESET ALL;
