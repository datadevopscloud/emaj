-- instPsqlPrev.sql: Install previous version of E-Maj as simple psql script (for postgres version prior 9.1)
-- It installs E-Maj 0.11.0 for migration test.
--
------------------------------------------------------------
-- install dblink
------------------------------------------------------------
-- this 8.4.8 version seems compatible with 8.2 to 9.0 pg version
-- for future use...
--\i ~/postgresql-8.4.8/contrib/dblink/dblink.sql

-----------------------------
-- for postgres cluster 8.3 and 9.1, temporarily rename tspemaj tablespace to test both cases
-----------------------------
--CREATE or REPLACE FUNCTION public.emaj_tmp() 
--RETURNS VOID LANGUAGE plpgsql AS 
--$tmp$
--  DECLARE
--  BEGIN
--    IF substring (version() from E'PostgreSQL\\s(\\d+\\.\\d+)') IN ('8.3', '9.1') THEN
--      ALTER TABLESPACE tspemaj RENAME TO tspemaj_renamed;
--    END IF;
--    RETURN; 
--  END;
--$tmp$;
--SELECT public.emaj_tmp();
--DROP FUNCTION public.emaj_tmp();

-----------------------------
-- emaj installation with previous version
-----------------------------
\i ../../../emaj-0.11.0/sql/emaj.sql

-----------------------------
-- check installation
-----------------------------
-- check the emaj_param content
SELECT param_value_text FROM emaj.emaj_param WHERE param_key = 'emaj_version';

-- check history
select hist_id, hist_function, hist_event, hist_object, regexp_replace(regexp_replace(hist_wording,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'),E'\\[.+\\]','(timestamp)','g'), hist_user from 
  (select * from emaj.emaj_hist order by hist_id) as t;

