
\restrict ZM1e8lgxUm34wAECGCd06T9Rm29kIwfTUJEANTL6rpf6fpKCcndWPxhkkx8QMdW

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict ZM1e8lgxUm34wAECGCd06T9Rm29kIwfTUJEANTL6rpf6fpKCcndWPxhkkx8QMdW

RESET ALL;
