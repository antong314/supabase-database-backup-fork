
\restrict UvS4uKvD8YgWFFPlhKyYBRB9xPBk0jdxaXqgal7QYw410xhMxZCicX4fP0gMGGi

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

ALTER ROLE "anon" SET "statement_timeout" TO '3s';

ALTER ROLE "authenticated" SET "statement_timeout" TO '8s';

ALTER ROLE "authenticator" SET "statement_timeout" TO '8s';

\unrestrict UvS4uKvD8YgWFFPlhKyYBRB9xPBk0jdxaXqgal7QYw410xhMxZCicX4fP0gMGGi

RESET ALL;
