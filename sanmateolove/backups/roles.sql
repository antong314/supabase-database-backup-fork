
\restrict GTCN7akXKFaa4Bbw2MoUh1RNWVv8Bmo1SzogfFgr5JYTwSRrzy8H3AhsORSTVOU

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict GTCN7akXKFaa4Bbw2MoUh1RNWVv8Bmo1SzogfFgr5JYTwSRrzy8H3AhsORSTVOU

RESET ALL;
