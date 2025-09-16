
\restrict qhnk2X4DTLN68ChUxbwf8NGMfvCpCz7uC4HF26j0yRMrVh85Uc4OqmCLX222b7g

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict qhnk2X4DTLN68ChUxbwf8NGMfvCpCz7uC4HF26j0yRMrVh85Uc4OqmCLX222b7g

RESET ALL;
