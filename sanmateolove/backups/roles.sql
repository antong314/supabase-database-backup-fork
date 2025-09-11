
\restrict 2LlrVUJ4JNSUeJxf3HWrfaUmAP8wve4cilmfW4T6Bq9oH7l3O706d4VIe7iUKtT

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict 2LlrVUJ4JNSUeJxf3HWrfaUmAP8wve4cilmfW4T6Bq9oH7l3O706d4VIe7iUKtT

RESET ALL;
