
\restrict K9k6JE3F9FhlHJYe8RmPpwo3xxpCYsRbDfcB97Oj1Tf2zUPlNC6aEhoAJwLzcxw

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict K9k6JE3F9FhlHJYe8RmPpwo3xxpCYsRbDfcB97Oj1Tf2zUPlNC6aEhoAJwLzcxw

RESET ALL;
