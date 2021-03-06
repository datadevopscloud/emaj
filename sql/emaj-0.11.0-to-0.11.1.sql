--
-- E-Maj: upgrade from 0.11.0 to 0.11.1
-- 
-- This software is distributed under the GNU General Public License.
--
-- This script upgrades an existing installation of E-Maj extension.
-- If version 0.11.0 has not been yet installed, simply use emaj.sql script. 
--

\set ON_ERROR_STOP ON
\set QUIET ON
SET client_min_messages TO WARNING;
--SET client_min_messages TO NOTICE;
\echo 'E-maj upgrade from version 0.11.0 to version 0.11.1'
\echo 'Checking...'
------------------------------------
--                                --
-- checks                         --
--                                --
------------------------------------
-- Creation of a specific function to check the upgrade conditions are met.
-- The function generates an exception if at least one condition is not met.
CREATE or REPLACE FUNCTION emaj.tmp() 
RETURNS VOID LANGUAGE plpgsql AS
$tmp$
  DECLARE
    v_emajVersion        TEXT;
  BEGIN
-- the emaj version registered in emaj_param must be '0.10.1'
    SELECT param_value_text INTO v_emajVersion FROM emaj.emaj_param WHERE param_key = 'emaj_version';
    IF v_emajVersion <> '0.11.0' THEN
      RAISE EXCEPTION 'The current E-Maj version (%) is not 0.11.0',v_emajVersion;
    END IF;
-- check the current role is a superuser
    PERFORM 0 FROM pg_roles WHERE rolname = current_user AND rolsuper;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'E-Maj installation: the current user (%) is not a superuser.', current_user;
    END IF;
--
    RETURN;
  END;
$tmp$;
SELECT emaj.tmp();
DROP FUNCTION emaj.tmp();

-- OK, upgrade...
\echo '... OK, upgrade start...'

BEGIN TRANSACTION;

-- lock emaj_group table to avoid any concurrent E-Maj activity
LOCK TABLE emaj.emaj_group IN EXCLUSIVE MODE;

CREATE or REPLACE FUNCTION emaj.tmp() 
RETURNS VOID LANGUAGE plpgsql AS
$tmp$
  DECLARE
  BEGIN
-- if tspemaj tablespace exists, (actualy, it should exist at that time!)
--   use it as default_tablespace for emaj tables creation
--   and grant the create rights on it to emaj_adm
    PERFORM 0 FROM pg_tablespace WHERE spcname = 'tspemaj';
    IF FOUND THEN
      SET LOCAL default_tablespace TO tspemaj;
      GRANT CREATE ON TABLESPACE tspemaj TO emaj_adm;
    END IF;
    RETURN;
  END;
$tmp$;
SELECT emaj.tmp();
DROP FUNCTION emaj.tmp();

\echo 'Updating E-Maj internal objects ...'

------------------------------------
--                                --
-- emaj tables and sequences      --
--                                --
------------------------------------
DROP TABLE emaj.emaj_fk;
CREATE TABLE emaj.emaj_fk (
    fk_groups                TEXT[]      NOT NULL,       -- groups for which the rollback operation is performed
    fk_session               INT         NOT NULL,       -- session number (for parallel rollback purpose)
    fk_name                  TEXT        NOT NULL,       -- foreign key name
    fk_schema                TEXT        NOT NULL,       -- schema name of the table that owns the foreign key
    fk_table                 TEXT        NOT NULL,       -- name of the table that owns the foreign key
    fk_action                TEXT        NOT NULL,       -- action to perform at the end of the rollback operation
                                                         --   can contain 'create_fk' or 'set_fk_immediate"
    fk_def                   TEXT        ,               -- foreign key definition as reported by pg_get_constraintdef
    PRIMARY KEY (fk_groups, fk_name, fk_schema, fk_table)
    );
COMMENT ON TABLE emaj.emaj_fk IS
$$Contains temporary description of foreign keys suppressed by E-Maj rollback operations.$$;

-- move indexes of internal emaj tables to the tablespace tspemaj
ALTER INDEX emaj.emaj_fk_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_group_def_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_group_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_hist_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_mark_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_param_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_relation_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_rlbk_stat_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_seq_hole_pkey SET TABLESPACE tspemaj;
ALTER INDEX emaj.emaj_sequence_pkey SET TABLESPACE tspemaj;

------------------------------------
--                                --
-- emaj functions                 --
--                                --
------------------------------------
CREATE or REPLACE FUNCTION emaj._create_tbl(v_schemaName TEXT, v_tableName TEXT, v_isRollbackable BOOLEAN) 
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS 
$_create_tbl$
-- This function creates all what is needed to manage the log and rollback operations for an application table
-- Input: schema name (mandatory even for the 'public' schema), table name, boolean indicating whether the table belongs to a rollbackable group
-- Are created: 
--    - the associated log table, with its own sequence
--    - the function that logs the tables updates, defined as a trigger
--    - the rollback function (one per table)
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
-- variables for the name of tables, functions, triggers,...
    v_fullTableName         TEXT;
    v_emajSchema            TEXT := 'emaj';
    v_dataTblSpace          TEXT;
    v_idxTblSpace           TEXT;
    v_logTableName          TEXT;
    v_logIdxName            TEXT;
    v_logFnctName           TEXT;
    v_rlbkFnctName          TEXT;
    v_exceptionRlbkFnctName TEXT;
    v_logTriggerName        TEXT;
    v_truncTriggerName      TEXT;
    v_sequenceName          TEXT;
-- variables to hold pieces of SQL
    v_pkCondList            TEXT;
    v_colList               TEXT;
    v_valList               TEXT;
    v_setList               TEXT;
-- other variables
    v_attname               TEXT;
    v_relhaspkey            BOOLEAN;
    v_pgVersion             TEXT := emaj._pg_version();
    v_stmt                  TEXT := '';
    v_triggerList           TEXT := '';
    r_column                RECORD;
    r_trigger               RECORD;
-- cursor to retrieve all columns of the application table
    col1_curs CURSOR (tbl regclass) FOR 
      SELECT attname FROM pg_attribute 
        WHERE attrelid = tbl 
          AND attnum > 0
          AND attisdropped = false
      ORDER BY attnum;
-- cursor to retrieve all columns of table's primary key
-- (taking column names in pg_attribute from the table's definition instead of index definition is mandatory 
--  starting from pg9.0, joining tables with indkey instead of indexrelid)
    col2_curs CURSOR (tbl regclass) FOR 
      SELECT attname FROM pg_attribute, pg_index 
        WHERE pg_attribute.attrelid = pg_index.indrelid
          AND attnum = ANY (indkey) 
          AND indrelid = tbl AND indisprimary
          AND attnum > 0 AND attisdropped = false;
  BEGIN
-- check the table has a primary key
    SELECT true INTO v_relhaspkey FROM pg_class, pg_namespace, pg_constraint WHERE 
        relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid AND
        contype = 'p' AND nspname = v_schemaName AND relname = v_tableName;
    IF NOT FOUND THEN
      v_relhaspkey = false;
    END IF;
    IF v_isRollbackable AND v_relhaspkey = FALSE THEN
      RAISE EXCEPTION '_create_tbl: table % has no PRIMARY KEY.', v_tableName;
    END IF;
-- if tspemaj tablespace exists, use it for the log table and its index
    PERFORM 0 FROM pg_tablespace WHERE spcname = 'tspemaj';
    IF FOUND THEN
      v_dataTblSpace = 'TABLESPACE tspemaj '; v_idxTblSpace = 'TABLESPACE tspemaj ';
    ELSE
      v_dataTblSpace = ''; v_idxTblSpace = '';
    END IF;

-- build the different name for table, trigger, functions,...
    v_fullTableName    := quote_ident(v_schemaName) || '.' || quote_ident(v_tableName);
    v_logTableName     := quote_ident(v_emajSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log');
    v_logIdxName       := quote_ident(v_schemaName || '_' || v_tableName || '_log_idx');
    v_logFnctName      := quote_ident(v_emajSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log_fnct');
    v_rlbkFnctName     := quote_ident(v_emajSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_rlbk_fnct');
    v_exceptionRlbkFnctName=substring(quote_literal(v_rlbkFnctName) FROM '^(.*).$');   -- suppress last character
    v_logTriggerName   := quote_ident(v_schemaName || '_' || v_tableName || '_emaj_log_trg');
    v_truncTriggerName := quote_ident(v_schemaName || '_' || v_tableName || '_emaj_trunc_trg');
    v_sequenceName     := quote_ident(v_emajSchema) || '.' || quote_ident(emaj._build_log_seq_name(v_schemaName, v_tableName));
-- creation of the log table: the log table looks like the application table, with some additional technical columns
    EXECUTE 'DROP TABLE IF EXISTS ' || v_logTableName;
    EXECUTE 'CREATE TABLE ' || v_logTableName
         || ' ( LIKE ' || v_fullTableName || ') ' || v_dataTblSpace;
    EXECUTE 'ALTER TABLE ' || v_logTableName
         || ' ADD COLUMN emaj_verb    VARCHAR(3),'
         || ' ADD COLUMN emaj_tuple   VARCHAR(3),'
         || ' ADD COLUMN emaj_gid     BIGINT      NOT NULL   DEFAULT nextval(''emaj.emaj_global_seq''),'
         || ' ADD COLUMN emaj_changed TIMESTAMPTZ DEFAULT clock_timestamp(),'
         || ' ADD COLUMN emaj_txid    BIGINT      DEFAULT emaj._txid_current(),'
         || ' ADD COLUMN emaj_user    VARCHAR(32) DEFAULT session_user,'
         || ' ADD COLUMN emaj_user_ip INET        DEFAULT inet_client_addr()';
-- creation of the index on the log table
    IF v_pgVersion >= '8.3' THEN
      EXECUTE 'CREATE UNIQUE INDEX ' || v_logIdxName || ' ON ' 
           ||  v_logTableName || ' (emaj_gid, emaj_tuple DESC) ' || v_idxTblSpace;
    ELSE
--   in 8.2, DESC clause doesn't exist. So the index cannot be used at rollback time. 
--   It only enforces the uniqueness of (emaj_gid, emaj_tuple)
      EXECUTE 'CREATE UNIQUE INDEX ' || v_logIdxName || ' ON ' 
           ||  v_logTableName || ' (emaj_gid, emaj_tuple) ' || v_idxTblSpace;
    END IF;
-- remove the NOT NULL constraints of application columns. 
--   They are useless and blocking to store truncate event for tables belonging to audit_only tables
    FOR r_column IN
      SELECT ' ALTER COLUMN ' || quote_ident(attname) || ' DROP NOT NULL' AS action 
        FROM pg_attribute, pg_class, pg_namespace 
        WHERE relnamespace = pg_namespace.oid AND attrelid = pg_class.oid 
          AND nspname = v_emajSchema AND relname = v_schemaName || '_' || v_tableName || '_log' 
          AND attnum > 0 AND attnotnull AND attisdropped = false AND attname NOT LIKE E'emaj\\_%'
    LOOP
      IF v_stmt = '' THEN
        v_stmt = v_stmt || r_column.action;
      ELSE
        v_stmt = v_stmt || ',' || r_column.action;
      END IF;
    END LOOP;
    IF v_stmt <> '' THEN
      EXECUTE 'ALTER TABLE ' || v_logTableName || v_stmt;
    END IF;
-- create the sequence associated to the log table
    EXECUTE 'CREATE SEQUENCE ' || v_sequenceName;
-- creation of the log fonction that will be mapped to the log trigger later
-- The new row is logged for each INSERT, the old row is logged for each DELETE 
-- and the old and the new rows are logged for each UPDATE.
    EXECUTE 'CREATE or REPLACE FUNCTION ' || v_logFnctName || '() RETURNS trigger AS $logfnct$'
         || 'BEGIN'
-- The sequence associated to the log table is incremented at the beginning of the function ...
         || '  PERFORM NEXTVAL(' || quote_literal(v_sequenceName) || ');'
-- ... and the global id sequence is incremented by the first/only INSERT into the log table.
         || '  IF (TG_OP = ''DELETE'') THEN'
         || '    INSERT INTO ' || v_logTableName || ' SELECT OLD.*, ''DEL'', ''OLD'';'
         || '    RETURN OLD;'
         || '  ELSIF (TG_OP = ''UPDATE'') THEN'
         || '    INSERT INTO ' || v_logTableName || ' SELECT OLD.*, ''UPD'', ''OLD'';'
         || '    INSERT INTO ' || v_logTableName || ' SELECT NEW.*, ''UPD'', ''NEW'', lastval();'
         || '    RETURN NEW;'
         || '  ELSIF (TG_OP = ''INSERT'') THEN'
         || '    INSERT INTO ' || v_logTableName || ' SELECT NEW.*, ''INS'', ''NEW'';'
         || '    RETURN NEW;'
         || '  END IF;'
         || '  RETURN NULL;'
         || 'END;'
         || '$logfnct$ LANGUAGE plpgsql SECURITY DEFINER;';
-- creation of the log trigger on the application table, using the previously created log function 
-- But the trigger is not immediately activated (it will be at emaj_start_group time)
    EXECUTE 'DROP TRIGGER IF EXISTS ' || v_logTriggerName || ' ON ' || v_fullTableName;
    EXECUTE 'CREATE TRIGGER ' || v_logTriggerName
         || ' AFTER INSERT OR UPDATE OR DELETE ON ' || v_fullTableName
         || '  FOR EACH ROW EXECUTE PROCEDURE ' || v_logFnctName || '()';
    EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_logTriggerName;
-- creation of the trigger that manage any TRUNCATE on the application table
-- But the trigger is not immediately activated (it will be at emaj_start_group time)
    IF v_pgVersion >= '8.4' THEN
      EXECUTE 'DROP TRIGGER IF EXISTS ' || v_truncTriggerName || ' ON ' || v_fullTableName;
      IF v_isRollbackable THEN
-- For rollbackable groups, use the common _forbid_truncate_fnct() function that blocks the operation
        EXECUTE 'CREATE TRIGGER ' || v_truncTriggerName
             || ' BEFORE TRUNCATE ON ' || v_fullTableName
             || '  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._forbid_truncate_fnct()';
      ELSE
-- For audit_only groups, use the common _log_truncate_fnct() function that records the operation into the log table
        EXECUTE 'CREATE TRIGGER ' || v_truncTriggerName
             || ' BEFORE TRUNCATE ON ' || v_fullTableName
             || '  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._log_truncate_fnct()';
      END IF;
      EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_truncTriggerName;
    END IF;
--
-- create the rollback function, if the table belongs to a rollbackable group 
--
    IF v_isRollbackable THEN
-- First build some pieces of the CREATE FUNCTION statement
--   build the tables's columns list
--     and the SET clause for the UPDATE, from the same columns list
      v_colList := '';
      v_valList := '';
      v_setList := '';
      OPEN col1_curs (v_fullTableName);
      LOOP
        FETCH col1_curs INTO v_attname;
        EXIT WHEN NOT FOUND;
        IF v_colList = '' THEN
           v_colList := quote_ident(v_attname);
           v_valList := 'rec_log.' || quote_ident(v_attname);
           v_setList := quote_ident(v_attname) || ' = rec_old_log.' || quote_ident(v_attname);
        ELSE
           v_colList := v_colList || ', ' || quote_ident(v_attname);
           v_valList := v_valList || ', rec_log.' || quote_ident(v_attname);
           v_setList := v_setList || ', ' || quote_ident(v_attname) || ' = rec_old_log.' || quote_ident(v_attname);
        END IF;
      END LOOP;
      CLOSE col1_curs;
--   build "equality on the primary key" conditions, from the list of the primary key's columns
      v_pkCondList := '';
      OPEN col2_curs (v_fullTableName);
      LOOP
        FETCH col2_curs INTO v_attname;
        EXIT WHEN NOT FOUND;
        IF v_pkCondList = '' THEN
           v_pkCondList := quote_ident(v_attname) || ' = rec_log.' || quote_ident(v_attname);
        ELSE
           v_pkCondList := v_pkCondList || ' AND ' || quote_ident(v_attname) || ' = rec_log.' || quote_ident(v_attname);
        END IF;
      END LOOP;
      CLOSE col2_curs;
-- Then create the rollback function associated to the table
-- At execution, it will loop on each row from the log table in reverse order
--  It will insert the old deleted rows, delete the new inserted row 
--  and update the new rows by setting back the old rows
-- The function returns the number of rollbacked elementary operations or rows
-- All these functions will be called by the emaj_rlbk_tbl function, which is activated by the
--  emaj_rollback_group function
      EXECUTE 'CREATE or REPLACE FUNCTION ' || v_rlbkFnctName || ' (v_lastGlobalSeq BIGINT)'
           || ' RETURNS BIGINT AS $rlbkfnct$'
           || '  DECLARE'
           || '    v_nb_rows       BIGINT := 0;'
           || '    v_nb_proc_rows  INTEGER;'
           || '    rec_log     ' || v_logTableName || '%ROWTYPE;'
           || '    rec_old_log ' || v_logTableName || '%ROWTYPE;'
           || '    log_curs CURSOR FOR '
           || '      SELECT * FROM ' || v_logTableName
           || '        WHERE emaj_gid > v_lastGlobalSeq '
           || '        ORDER BY emaj_gid DESC, emaj_tuple;'
           || '  BEGIN'
           || '    OPEN log_curs;'
           || '    LOOP '
           || '      FETCH log_curs INTO rec_log;'
           || '      EXIT WHEN NOT FOUND;'
           || '      IF rec_log.emaj_verb = ''INS'' THEN'
--         || '          RAISE NOTICE ''emaj_gid = % ; INS'', rec_log.emaj_gid;'
           || '          DELETE FROM ' || v_fullTableName || ' WHERE ' || v_pkCondList || ';'
           || '      ELSIF rec_log.emaj_verb = ''UPD'' THEN'
--         || '          RAISE NOTICE ''emaj_gid = % ; UPD ; %'', rec_log.emaj_gid,rec_log.emaj_tuple;'
           || '          FETCH log_curs into rec_old_log;'
--         || '          RAISE NOTICE ''emaj_gid = % ; UPD ; %'', rec_old_log.emaj_gid,rec_old_log.emaj_tuple;'
           || '          UPDATE ' || v_fullTableName || ' SET ' || v_setList || ' WHERE ' || v_pkCondList || ';'
           || '      ELSIF rec_log.emaj_verb = ''DEL'' THEN'
--         || '          RAISE NOTICE ''emaj_gid = % ; DEL'', rec_log.emaj_gid;'
           || '          INSERT INTO ' || v_fullTableName || ' (' || v_colList || ') VALUES (' || v_valList || ');'
           || '      ELSE'
           || '          RAISE EXCEPTION ' || v_exceptionRlbkFnctName || ': internal error - emaj_verb = % is unknown, emaj_gid = %.'','
           || '            rec_log.emaj_verb, rec_log.emaj_gid;' 
           || '      END IF;'
           || '      GET DIAGNOSTICS v_nb_proc_rows = ROW_COUNT;'
           || '      IF v_nb_proc_rows <> 1 THEN'
           || '        RAISE EXCEPTION ' || v_exceptionRlbkFnctName || ': internal error - emaj_verb = %, emaj_gid = %, # processed rows = % .'''
           || '           ,rec_log.emaj_verb, rec_log.emaj_gid, v_nb_proc_rows;' 
           || '      END IF;'
           || '      v_nb_rows := v_nb_rows + 1;'
           || '    END LOOP;'
           || '    CLOSE log_curs;'
--         || '    RAISE NOTICE ''Table ' || v_fullTableName || ' -> % rollbacked rows.'', v_nb_rows;'
           || '    RETURN v_nb_rows;'
           || '  END;'
           || '$rlbkfnct$ LANGUAGE plpgsql;';
      END IF;
-- check if the table has (neither internal - ie. created for fk - nor previously created by emaj) trigger,
-- This check is not done for postgres 8.2 because column tgconstraint doesn't exist
    IF v_pgVersion >= '8.3' THEN
      FOR r_trigger IN 
        SELECT tgname FROM pg_trigger WHERE tgrelid = v_fullTableName::regclass AND tgconstraint = 0 AND tgname NOT LIKE E'%emaj\\_%\\_trg'
      LOOP
        IF v_triggerList = '' THEN
          v_triggerList = v_triggerList || r_trigger.tgname;
        ELSE
          v_triggerList = v_triggerList || ', ' || r_trigger.tgname;
        END IF;
      END LOOP;
-- if yes, issue a warning (if a trigger updates another table in the same table group or outside) it could generate problem at rollback time)
      IF v_triggerList <> '' THEN
        RAISE WARNING '_create_tbl: table % has triggers (%). Verify the compatibility with emaj rollback operations (in particular if triggers update one or several other tables). Triggers may have to be manualy disabled before rollback.', v_fullTableName, v_triggerList;
      END IF;
    END IF;
-- grant appropriate rights to both emaj roles
    EXECUTE 'GRANT SELECT ON TABLE ' || v_logTableName || ' TO emaj_viewer';
    EXECUTE 'GRANT ALL PRIVILEGES ON TABLE ' || v_logTableName || ' TO emaj_adm';
    EXECUTE 'GRANT SELECT ON SEQUENCE ' || v_sequenceName || ' TO emaj_viewer';
    EXECUTE 'GRANT ALL PRIVILEGES ON SEQUENCE ' || v_sequenceName || ' TO emaj_adm';
    RETURN;
  END;
$_create_tbl$;

DROP FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_disableTrigger BOOLEAN, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT);
CREATE or REPLACE FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS 
$_rlbk_tbl$
-- This function rollbacks one table to a given timestamp
-- The function is called by emaj._rlbk_groups_step5()
-- Input: schema name and table name, global sequence value limit for rollback, mark timestamp, 
--        flag to specify if rollbacked log rows must be deleted,
--        last sequence and last hole identifiers to keep (greater ones being to be deleted)
-- The v_deleteLog flag must be set to true for common (unlogged) rollback and false for logged rollback
-- For unlogged rollback, the log triggers have been disabled previously and will be enabled later.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_emajSchema     TEXT := 'emaj';
    v_fullTableName  TEXT;
    v_logTableName   TEXT;
    v_rlbkFnctName   TEXT;
    v_seqName        TEXT;
    v_fullSeqName    TEXT;
    v_nb_rows        BIGINT;
    v_tsrlbk_start   TIMESTAMP;
    v_tsrlbk_end     TIMESTAMP;
    v_tsdel_start    TIMESTAMP;
    v_tsdel_end      TIMESTAMP;
  BEGIN
    v_fullTableName  := quote_ident(v_schemaName) || '.' || quote_ident(v_tableName);
    v_logTableName   := quote_ident(v_emajSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log');
    v_rlbkFnctName   := quote_ident(v_emajSchema) || '.' || 
                        quote_ident(v_schemaName || '_' || v_tableName || '_rlbk_fnct');
    v_seqName        := emaj._build_log_seq_name(v_schemaName, v_tableName);
    v_fullSeqName    := quote_ident(v_emajSchema) || '.' || quote_ident(v_seqName);
-- insert begin event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('ROLLBACK_TABLE', 'BEGIN', v_fullTableName, 'All log rows with emaj_gid > ' || v_lastGlobalSeq);
-- record the time at the rollback start
    SELECT clock_timestamp() INTO v_tsrlbk_start;
-- rollback the table
    EXECUTE 'SELECT ' || v_rlbkFnctName || '(' || v_lastGlobalSeq || ')' INTO v_nb_rows;
-- record the time at the rollback
    SELECT clock_timestamp() INTO v_tsrlbk_end;
-- insert rollback duration into the emaj_rlbk_stat table, if at least 1 row has been processed
    IF v_nb_rows > 0 THEN
      INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration) 
         VALUES ('rlbk', v_schemaName, v_tableName, v_tsrlbk_start, v_nb_rows, v_tsrlbk_end - v_tsrlbk_start);
    END IF;
-- if the caller requires it, suppress the rollbacked log part 
    IF v_deleteLog THEN
-- record the time at the delete start
      SELECT clock_timestamp() INTO v_tsdel_start;
-- delete obsolete log rows
      EXECUTE 'DELETE FROM ' || v_logTableName || ' WHERE emaj_gid > ' || v_lastGlobalSeq;
-- ... and suppress from emaj_sequence table the rows regarding the emaj log sequence for this application table
--     corresponding to potential later intermediate marks that disappear with the rollback operation
      DELETE FROM emaj.emaj_sequence
        WHERE sequ_schema = v_emajSchema AND sequ_name = v_seqName AND sequ_id > v_lastSequenceId;
-- record the sequence holes generated by the delete operation 
-- this is due to the fact that log sequences are not rollbacked, this information will be used by the emaj_log_stat_group
--   function (and indirectly by emaj_estimate_rollback_duration())
-- first delete, if exist, sequence holes that have disappeared with the rollback
      DELETE FROM emaj.emaj_seq_hole
        WHERE sqhl_schema = v_schemaName AND sqhl_table = v_tableName AND sqhl_id > v_lastSeqHoleId;
-- and then insert the new sequence hole
      EXECUTE 'INSERT INTO emaj.emaj_seq_hole (sqhl_schema, sqhl_table, sqhl_hole_size) VALUES (' 
        || quote_literal(v_schemaName) || ',' || quote_literal(v_tableName) || ', ('
        || ' SELECT CASE WHEN is_called THEN last_value + increment_by ELSE last_value END FROM ' || v_fullSeqName 
        || ')-('
        || ' SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END FROM '
        || ' emaj.emaj_sequence WHERE'
        || ' sequ_schema = ''' || v_emajSchema 
        || ''' AND sequ_name = ' || quote_literal(v_seqName) 
        || ' AND sequ_datetime = ' || quote_literal(v_timestamp) || '))';
-- record the time at the delete
      SELECT clock_timestamp() INTO v_tsdel_end;
-- insert delete duration into the emaj_rlbk_stat table, if at least 1 row has been processed
      IF v_nb_rows > 0 THEN
        INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration) 
           VALUES ('del_log', v_schemaName, v_tableName, v_tsrlbk_start, v_nb_rows, v_tsdel_end - v_tsdel_start);
      END IF;
    END IF;
-- insert end event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('ROLLBACK_TABLE', 'END', v_fullTableName, v_nb_rows || ' rollbacked rows');
    RETURN;
  END;
$_rlbk_tbl$;

CREATE or REPLACE FUNCTION emaj._stop_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN) 
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS 
$_stop_groups$
-- This function effectively de-activates the log triggers of all the tables for a group. 
-- Input: array of group names, a mark name to set, and a boolean indicating if the function is called by a multi group function
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables and sequences.
  DECLARE
    v_pgVersion        TEXT := emaj._pg_version();
    v_validGroupNames  TEXT[];
    v_i                INT;
    v_groupState       TEXT;
    v_nbTb             INT := 0;
    v_markName         TEXT;
    v_fullTableName    TEXT;
    v_logTriggerName   TEXT;
    v_truncTriggerName TEXT;
    r_tblsq            RECORD;
  BEGIN
-- if the group names array is null, immediately return 0
    IF v_groupNames IS NULL THEN
      RETURN 0;
    END IF;
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object) 
      VALUES (CASE WHEN v_multiGroup THEN 'STOP_GROUPS' ELSE 'STOP_GROUP' END, 'BEGIN', 
              array_to_string(v_groupNames,','));
-- for each group of the array,
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
-- ... check that the group is recorded in emaj_group table
      SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupNames[v_i] FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION '_stop_group: group % has not been created.', v_groupNames[v_i];
      END IF;
-- ... check that the group is in LOGGING state
      IF v_groupState <> 'LOGGING' THEN
        RAISE WARNING '_stop_group: Group % cannot be stopped because it is not in logging state.', v_groupNames[v_i];
      ELSE
-- ... if OK, add the group into the array of groups to process
        v_validGroupNames = v_validGroupNames || array[v_groupNames[v_i]];
      END IF;
    END LOOP;
-- check and process the supplied mark name
    SELECT emaj._check_new_mark(v_mark, v_groupNames) INTO v_markName;
--
    IF v_validGroupNames IS NOT NULL THEN
-- OK (no error detected and at least one group in logging state)
-- lock all tables to get a stable point ...
-- (the ALTER TABLE statements will also set EXCLUSIVE locks, but doing this for all tables at the beginning of the operation decreases the risk for deadlock)
      PERFORM emaj._lock_groups(v_validGroupNames,'',v_multiGroup);
-- for each relation of the groups to process,
      FOR r_tblsq IN
          SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation 
            WHERE rel_group = ANY (v_validGroupNames) ORDER BY rel_priority, rel_schema, rel_tblseq
          LOOP
        IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, disable the emaj log and truncate triggers
          v_fullTableName  := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
          v_logTriggerName := quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_emaj_log_trg');
          v_truncTriggerName := quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_emaj_trunc_trg');
          EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_logTriggerName;
          IF v_pgVersion >= '8.4' THEN
            EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_truncTriggerName;
          END IF;
          ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, nothing to do
        END IF;
        v_nbTb = v_nbTb + 1;
      END LOOP;
-- record the number of log rows for the old last mark of each group
      UPDATE emaj.emaj_mark m SET mark_log_rows_before_next = 
        (SELECT sum(stat_rows) FROM emaj.emaj_log_stat_group(m.mark_group,'EMAJ_LAST_MARK',NULL))
        WHERE mark_group = ANY (v_groupNames) 
          AND (mark_group, mark_id) IN                        -- select only last mark of each concerned group
              (SELECT mark_group, MAX(mark_id) FROM emaj.emaj_mark 
               WHERE mark_group = ANY (v_groupNames) AND mark_state = 'ACTIVE' GROUP BY mark_group);
-- Set the stop mark for each group
      PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, true);
-- set all marks for the groups from the emaj_mark table in 'DELETED' state to avoid any further rollback
      UPDATE emaj.emaj_mark SET mark_state = 'DELETED' WHERE mark_group = ANY (v_validGroupNames) AND mark_state <> 'DELETED';
-- update the state of the groups rows from the emaj_group table
      UPDATE emaj.emaj_group SET group_state = 'IDLE' WHERE group_name = ANY (v_validGroupNames);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES (CASE WHEN v_multiGroup THEN 'STOP_GROUPS' ELSE 'STOP_GROUP' END, 'END', 
              array_to_string(v_groupNames,','), v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$_stop_groups$;

CREATE or REPLACE FUNCTION emaj.emaj_delete_mark_group(v_groupName TEXT, v_mark TEXT) 
RETURNS integer LANGUAGE plpgsql AS
$emaj_delete_mark_group$
-- This function deletes all traces from a previous set_mark_group(s) function. 
-- Then, any rollback on the deleted mark will not be possible.
-- It deletes rows corresponding to the mark to delete from emaj_mark and emaj_sequence 
-- If this mark is the first mark, it also deletes rows from all concerned log tables and holes from emaj_seq_hole.
-- The statistical mark_log_rows_before_next column's content of the previous mark is also maintained
-- At least one mark must remain after the operation (otherwise it is not worth having a group in LOGGING state !).
-- Input: group name, mark to delete
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to delete to specify the last set mark.
-- Output: number of deleted marks, i.e. 1
  DECLARE
    v_groupState     TEXT;
    v_realMark       TEXT;
    v_markId         BIGINT;
    v_datetimeMark   TIMESTAMPTZ;
    v_idNewMin       BIGINT;
    v_markNewMin     TEXT;
    v_datetimeNewMin TIMESTAMPTZ;
    v_cpt            INT;
    v_previousMark   TEXT;
    v_nextMark       TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('DELETE_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_delete_mark_group: group % has not been created.', v_groupName;
    END IF;
-- retrieve and check the mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_delete_mark_group: % is not a known mark for group %.', v_mark, v_groupName;
    END IF;
-- count the number of mark in the group
    SELECT count(*) INTO v_cpt FROM emaj.emaj_mark WHERE mark_group = v_groupName;
-- and check there are at least 2 marks for the group
    IF v_cpt < 2 THEN
       RAISE EXCEPTION 'emaj_delete_mark_group: % is the only mark. It cannot be deleted.', v_mark;
    END IF;
-- OK, now get the id and timestamp of the mark to delete
    SELECT mark_id, mark_datetime INTO v_markId, v_datetimeMark
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark;
-- ... and the id and timestamp of the future first mark
    SELECT mark_id, mark_name, mark_datetime INTO v_idNewMin, v_markNewMin, v_datetimeNewMin 
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name <> v_realMark ORDER BY mark_id LIMIT 1;
    IF v_markId < v_idNewMin THEN
-- if the mark to delete is the first one, 
--   ... process its deletion with _delete_before_mark_group(), as the first rows of log tables become useless
      PERFORM emaj._delete_before_mark_group(v_groupName, v_markNewMin);
    ELSE
-- otherwise, 
--   ... the sequences related to the mark to delete can be suppressed
--         Delete first application sequences related data for the group
      DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation 
        WHERE sequ_mark = v_realMark AND sequ_datetime = v_datetimeMark
          AND rel_group = v_groupName AND rel_kind = 'S'
          AND sequ_schema = rel_schema AND sequ_name = rel_tblseq;
--         Delete then emaj sequences related data for the group
      DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation 
        WHERE sequ_mark = v_realMark AND sequ_datetime = v_datetimeMark
          AND rel_group = v_groupName AND rel_kind = 'r'
          AND sequ_schema = 'emaj' AND sequ_name = emaj._build_log_seq_name(rel_schema,rel_tblseq);
--   ... the mark to delete can be physicaly deleted
      DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark;
--   ... adjust the mark_log_rows_before_next column of the previous mark
--       get the name of the mark immediately preceeding the mark to delete
      SELECT mark_name INTO v_previousMark FROM emaj.emaj_mark
        WHERE mark_group = v_groupName AND mark_id < v_markId ORDER BY mark_id DESC LIMIT 1;
--       get the name of the first mark succeeding the mark to delete
      SELECT mark_name INTO v_nextMark FROM emaj.emaj_mark 
        WHERE mark_group = v_groupName AND mark_id > v_markId ORDER BY mark_id LIMIT 1;
      IF NOT FOUND THEN
--       no next mark, so update the previous mark with NULL
         UPDATE emaj.emaj_mark SET mark_log_rows_before_next = NULL 
           WHERE mark_group = v_groupName AND mark_name = v_previousMark;
      ELSE
--       update the previous mark with the emaj_log_stat_group() call's result
         UPDATE emaj.emaj_mark SET mark_log_rows_before_next = 
             (SELECT sum(stat_rows) FROM emaj.emaj_log_stat_group(v_groupName, v_previousMark, v_nextMark))
           WHERE mark_group = v_groupName AND mark_name = v_previousMark;
      END IF;
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('DELETE_MARK_GROUP', 'END', v_groupName, v_realMark);
    RETURN 1;
  END;
$emaj_delete_mark_group$;
COMMENT ON FUNCTION emaj.emaj_delete_mark_group(TEXT,TEXT) IS
$$Deletes a mark for an E-Maj group.$$;

CREATE or REPLACE FUNCTION emaj.emaj_delete_before_mark_group(v_groupName TEXT, v_mark TEXT) 
RETURNS integer LANGUAGE plpgsql AS
$emaj_delete_before_mark_group$
-- This function deletes all marks set before a given mark. 
-- Then, any rollback on the deleted marks will not be possible.
-- It deletes rows corresponding to the marks to delete from emaj_mark, emaj_sequence, emaj_seq_hole.  
-- It also deletes rows from all concerned log tables.
-- Input: group name, name of the new first mark
--   The keyword 'EMAJ_LAST_MARK' can be used as mark name.
-- Output: number of deleted marks
--   or NULL if the provided mark name is NULL
  DECLARE
    v_groupState     TEXT;
    v_realMark       TEXT;
    v_markId         BIGINT;
    v_datetimeMark   TIMESTAMPTZ;
    v_nbMark         INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('DELETE_BEFORE_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_delete_before_mark_group: group % has not been created.', v_groupName;
    END IF;
-- return NULL if mark name is NULL
    IF v_mark IS NULL THEN
      RETURN NULL;
    END IF;
-- retrieve and check the mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_delete_before_mark_group: % is not a known mark for group %.', v_mark, v_groupName;
    END IF;
-- effectively delete all marks before the supplied mark
    SELECT emaj._delete_before_mark_group(v_groupName, v_realMark) INTO v_nbMark;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('DELETE_BEFORE_MARK_GROUP', 'END', v_groupName,  v_nbMark || ' marks deleted ; ' || v_realMark || ' is now the initial mark' );
    RETURN v_nbMark;
  END;
$emaj_delete_before_mark_group$;
COMMENT ON FUNCTION emaj.emaj_delete_before_mark_group(TEXT,TEXT) IS
$$Deletes all marks preceeding a given mark for an E-Maj group.$$;

CREATE or REPLACE FUNCTION emaj.emaj_rename_mark_group(v_groupName TEXT, v_mark TEXT, v_newName TEXT)
RETURNS void LANGUAGE plpgsql AS
$emaj_rename_mark_group$
-- This function renames an existing mark.
-- The group can be either in LOGGING or IDLE state.
-- Rows from emaj_mark and emaj_sequence tables are updated accordingly.
-- Input: group name, mark to rename, new name for the mark
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to rename to specify the last set mark.
  DECLARE
    v_realMark       TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('RENAME_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check that the group is recorded in emaj_group table
    PERFORM 1 FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_rename_mark_group: group % has not been created.', v_groupName;
    END IF;
-- retrieve and check the mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_rename_mark_group: mark % doesn''t exist for group %.', v_mark, v_groupName;
    END IF;
-- check the new mark name is not 'EMAJ_LAST_MARK' or NULL
    IF v_newName = 'EMAJ_LAST_MARK' OR v_newName IS NULL THEN
       RAISE EXCEPTION 'emaj_rename_mark_group: % is not an allowed name for a new mark.', v_newName;
    END IF;
-- check if the new mark name doesn't exist for the group 
    PERFORM 1 FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_name = v_newName LIMIT 1;
    IF FOUND THEN
       RAISE EXCEPTION 'emaj_rename_mark_group: a mark % already exists for group %.', v_newName, v_groupName;
    END IF;
-- OK, update the sequences table as well
    UPDATE emaj.emaj_sequence SET sequ_mark = v_newName 
      WHERE sequ_datetime = (SELECT mark_datetime FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark);
-- and then update the emaj_mark table
    UPDATE emaj.emaj_mark SET mark_name = v_newName
      WHERE mark_group = v_groupName AND mark_name = v_realMark;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('RENAME_MARK_GROUP', 'END', v_groupName, v_realMark || ' renamed ' || v_newName);
    RETURN;
  END;
$emaj_rename_mark_group$;
COMMENT ON FUNCTION emaj.emaj_rename_mark_group(TEXT,TEXT,TEXT) IS
$$Renames a mark for an E-Maj group.$$;

CREATE or REPLACE FUNCTION emaj._rlbk_groups(v_groupNames TEXT[], v_mark TEXT, v_unloggedRlbk BOOLEAN, v_deleteLog BOOLEAN, v_multiGroup BOOLEAN)
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_groups$
-- The function rollbacks all tables and sequences of a groups array up to a mark in the history.
-- It is called by emaj_rollback_group.
-- It effectively manages the rollback operation for each table or sequence, deleting rows from log tables 
-- only when asked by the calling functions.
-- Its activity is split into 6 smaller functions that are also called by the parallel restore php function
-- Input: group name, mark in the history, as it is inserted by emaj.emaj_set_mark_group
--        and a boolean saying if the log rows must be deleted from log table or not
-- Output: number of tables and sequences effectively processed
  DECLARE
    v_nbTbl             INT;
    v_nbTblInGroup      INT;
    v_nbSeq             INT;
  BEGIN
-- if the group names array is null, immediately return 0
    IF v_groupNames IS NULL THEN
      RETURN 0;
    END IF;
-- Step 1: prepare the rollback operation
    SELECT emaj._rlbk_groups_step1(v_groupNames, v_mark, v_unloggedRlbk, 1, v_multiGroup) INTO v_nbTblInGroup;
-- Step 2: lock all tables
    PERFORM emaj._rlbk_groups_step2(v_groupNames, 1, v_multiGroup);
-- Step 3: set a rollback start mark if logged rollback
    PERFORM emaj._rlbk_groups_step3(v_groupNames, v_mark, v_unloggedRlbk, v_multiGroup);
-- Step 4: record and drop foreign keys
    PERFORM emaj._rlbk_groups_step4(v_groupNames, 1, v_unloggedRlbk);
-- Step 5: effectively rollback tables
    SELECT emaj._rlbk_groups_step5(v_groupNames, v_mark, 1, v_unloggedRlbk, v_deleteLog) INTO v_nbTbl;
-- checks that we have the expected number of processed tables
    IF v_nbTbl <> v_nbTblInGroup THEN
       RAISE EXCEPTION '_rlbk_group: Internal error 1 (%,%).',v_nbTbl,v_nbTblInGroup;
    END IF;
-- Step 6: recreate foreign keys
    PERFORM emaj._rlbk_groups_step6(v_groupNames, 1, v_unloggedRlbk);
-- Step 7: process sequences and complete the rollback operation record
    SELECT emaj._rlbk_groups_step7(v_groupNames, v_mark, v_nbTbl, v_unloggedRlbk, v_deleteLog, v_multiGroup) INTO v_nbSeq;
    RETURN v_nbTbl + v_nbSeq;
  END;
$_rlbk_groups$;

CREATE or REPLACE FUNCTION emaj._rlbk_groups_step1(v_groupNames TEXT[], v_mark TEXT, v_unloggedRlbk BOOLEAN, v_nbSession INT, v_multiGroup BOOLEAN) 
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_groups_step1$
-- This is the first step of a rollback group processing.
-- It tests the environment, the supplied parameters and the foreign key constraints.
-- It builds the requested number of sessions with the list of tables to process, trying to spread the load over all sessions.
-- It finaly inserts into the history the event about the rollback start
  DECLARE
    v_i                   INT;
    v_groupState          TEXT;
    v_isRollbackable      BOOLEAN;
    v_markName            TEXT;
    v_markState           TEXT;
    v_cpt                 INT;
    v_nbTblInGroup        INT;
    v_nbUnchangedTbl      INT;
    v_timestampMark       TIMESTAMPTZ;
    v_session             INT;
    v_sessionLoad         INT [];
    v_minSession          INT;
    v_minRows             INT;
    v_fullTableName       TEXT;
    v_msg                 TEXT;
    r_tbl                 RECORD;
    r_tbl2                RECORD;
  BEGIN
-- check that each group ...
-- ...is recorded in emaj_group table
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
      SELECT group_state, group_is_rollbackable INTO v_groupState, v_isRollbackable FROM emaj.emaj_group WHERE group_name = v_groupNames[v_i] FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION '_rlbk_groups_step1: group % has not been created.', v_groupNames[v_i];
      END IF;
-- ... is in LOGGING state
      IF v_groupState <> 'LOGGING' THEN
        RAISE EXCEPTION '_rlbk_groups_step1: Group % cannot be rollbacked because it is not in logging state.', v_groupNames[v_i];
      END IF;
-- ... is ROLLBACKABLE
      IF NOT v_isRollbackable THEN
        RAISE EXCEPTION '_rlbk_groups_step1: Group % has been created for audit only purpose. It cannot be rollbacked.', v_groupNames[v_i];
      END IF;
-- ... is not damaged
      PERFORM 0 FROM emaj._verify_group(v_groupNames[v_i],true);
-- ... owns the requested mark
      SELECT emaj._get_mark_name(v_groupNames[v_i],v_mark) INTO v_markName;
      IF NOT FOUND OR v_markName IS NULL THEN
        RAISE EXCEPTION '_rlbk_groups_step1: No mark % exists for group %.', v_mark, v_groupNames[v_i];
      END IF;
-- ... and this mark is ACTIVE
      SELECT mark_state INTO v_markState FROM emaj.emaj_mark 
        WHERE mark_group = v_groupNames[v_i] AND mark_name = v_markName;
      IF v_markState <> 'ACTIVE' THEN
        RAISE EXCEPTION '_rlbk_groups_step1: mark % for group % is not in ACTIVE state.', v_markName, v_groupNames[v_i];
      END IF;
    END LOOP;
-- get the mark timestamp and check it is the same for all groups of the array
    SELECT count(distinct emaj._get_mark_datetime(group_name,v_mark)) INTO v_cpt FROM emaj.emaj_group
      WHERE group_name = ANY (v_groupNames);
    IF v_cpt > 1 THEN
      RAISE EXCEPTION '_rlbk_groups_step1: Mark % does not represent the same point in time for all groups.', v_mark;
    END IF;
-- get the mark timestamp for the 1st group (as we know this timestamp is the same for all groups of the array)
    SELECT emaj._get_mark_datetime(v_groupNames[1],v_mark) INTO v_timestampMark;
-- insert begin in the history
    IF v_unloggedRlbk THEN
      v_msg = 'Unlogged';
    ELSE
      v_msg = 'Logged';
    END IF;
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'BEGIN', 
              array_to_string(v_groupNames,','), v_msg || ' rollback to mark ' || v_markName || ' [' || v_timestampMark || ']');
-- get the total number of tables for these groups
    SELECT sum(group_nb_table) INTO v_nbTblInGroup FROM emaj.emaj_group WHERE group_name = ANY (v_groupNames) ;
-- issue warnings in case of foreign keys with tables outside the groups
    PERFORM emaj._check_fk_groups(v_groupNames);
-- create sessions, using the number of sessions requested by the caller
-- session id for sequences will remain NULL
--   initialisation
--     accumulated counters of number of log rows to rollback for each parallel session 
    FOR v_session IN 1 .. v_nbSession LOOP
      v_sessionLoad [v_session] = 0;
    END LOOP;
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
--     fkey table
      DELETE FROM emaj.emaj_fk WHERE v_groupNames[v_i] = ANY (fk_groups);
--     relation table: for each group, session set to NULL and 
--       numbers of log rows computed by emaj_log_stat_group function
      UPDATE emaj.emaj_relation SET rel_session = NULL, rel_rows = stat_rows 
        FROM emaj.emaj_log_stat_group (v_groupNames[v_i], v_mark, NULL) stat
        WHERE rel_group = v_groupNames[v_i]
          AND rel_group = stat_group AND rel_schema = stat_schema AND rel_tblseq = stat_table;
    END LOOP;
--   count the number of tables that have no update to rollback
    SELECT count(*) INTO v_nbUnchangedTbl FROM emaj.emaj_relation WHERE rel_group = ANY (v_groupNames) AND rel_rows = 0;
--   allocate tables with rows to rollback to sessions starting with the heaviest to rollback tables
--     as reported by emaj_log_stat_group function
    FOR r_tbl IN
        SELECT * FROM emaj.emaj_relation WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r' ORDER BY rel_rows DESC
        LOOP
--   is the table already allocated to a session (it may have been already allocated because of a fkey link) ?
      PERFORM 1 FROM emaj.emaj_relation 
        WHERE rel_group = ANY (v_groupNames) AND rel_schema = r_tbl.rel_schema AND rel_tblseq = r_tbl.rel_tblseq 
          AND rel_session IS NULL;
--   no, 
      IF FOUND THEN
--   compute the least loaded session
        v_minSession=1; v_minRows = v_sessionLoad [1];
        FOR v_session IN 2 .. v_nbSession LOOP
          IF v_sessionLoad [v_session] < v_minRows THEN
            v_minSession = v_session;
            v_minRows = v_sessionLoad [v_session];
          END IF;
        END LOOP;
--   allocate the table to the session, with all other tables linked by foreign key constraints
        v_sessionLoad [v_minSession] = v_sessionLoad [v_minSession] + 
                 emaj._rlbk_groups_set_session(v_groupNames, r_tbl.rel_schema, r_tbl.rel_tblseq, v_minSession, r_tbl.rel_rows);
      END IF;
    END LOOP;
    RETURN v_nbTblInGroup - v_nbUnchangedTbl;
  END;
$_rlbk_groups_step1$;

DROP FUNCTION emaj._rlbk_groups_step4(v_groupNames TEXT[], v_session INT);
CREATE or REPLACE FUNCTION emaj._rlbk_groups_step4(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN) 
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_rlbk_groups_step4$
-- This is the fourth step of a rollback group processing. 
-- If the rollback is unlogged, it disables log triggers for tables involved in the rollback session.
-- Then, it processes all foreign keys involved in the rollback session.
--   Non deferrable fkeys and deferrable fkeys with an action for UPDATE or DELETE other than 'no action' are dropped
--   Others are just set deferred if needed
--   For all fkeys, the action do be performed at step 6 is recorded in emaj_fk table (with either 'add_fk' or 'set_fk_immediate' action).
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables.
  DECLARE
    v_fullTableName     TEXT;
    v_logTriggerName    TEXT;
    r_tbl               RECORD;
    r_fk                RECORD;
  BEGIN
-- disable log triggers if unlogged rollback.
    IF v_unloggedRlbk THEN
      FOR r_tbl IN
        SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation 
          WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r' AND rel_rows > 0
          ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
        v_fullTableName  := quote_ident(r_tbl.rel_schema) || '.' || quote_ident(r_tbl.rel_tblseq);
        v_logTriggerName := quote_ident(r_tbl.rel_schema || '_' || r_tbl.rel_tblseq || '_emaj_log_trg');
        EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_logTriggerName;
      END LOOP;
    END IF;
-- select all foreign keys belonging to or referencing the session's tables of the group, if any
    FOR r_fk IN
      SELECT c.conname, n.nspname, t.relname, pg_get_constraintdef(c.oid) AS def, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_constraint c, pg_namespace n, pg_class t, emaj.emaj_relation r
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND r.rel_rows > 0                                             -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND n.nspname = r.rel_schema AND t.relname = r.rel_tblseq      -- join on groups table
          AND r.rel_group = ANY (v_groupNames) AND r.rel_session = v_session
      UNION
      SELECT c.conname, n.nspname, t.relname, pg_get_constraintdef(c.oid) AS def, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_constraint c, pg_namespace n, pg_class t, pg_namespace rn, pg_class rt, emaj.emaj_relation r
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND r.rel_rows > 0                                             -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace 
          AND rn.nspname = r.rel_schema AND rt.relname = r.rel_tblseq    -- join on groups table
          AND r.rel_group = ANY (v_groupNames) AND r.rel_session = v_session
      ORDER BY nspname, relname, conname
      LOOP
-- depending on the foreign key characteristics, drop it or set it deffered or just record it as 'to be reset immediate'
      IF NOT r_fk.condeferrable OR r_fk.confupdtype <> 'a' OR r_fk.confdeltype <> 'a' THEN
-- non deferrable fkeys and deferrable fkeys with an action for UPDATE or DELETE other than 'no action' need to be dropped
        EXECUTE 'ALTER TABLE ' || quote_ident(r_fk.nspname) || '.' || quote_ident(r_fk.relname) || ' DROP CONSTRAINT ' || quote_ident(r_fk.conname);
        INSERT INTO emaj.emaj_fk (fk_groups, fk_session, fk_name, fk_schema, fk_table, fk_action, fk_def)
          VALUES (v_groupNames, v_session, r_fk.conname, r_fk.nspname, r_fk.relname, 'add_fk', r_fk.def);
      ELSE
-- other deferrable but not deferred fkeys need to be set deferred
        IF NOT r_fk.condeferred THEN
          EXECUTE 'SET CONSTRAINTS ' || quote_ident(r_fk.nspname) || '.' || quote_ident(r_fk.conname) || ' DEFERRED';
        END IF;
-- deferrable fkeys are recorded as 'to be set immediate at the end of the rollback operation'
        INSERT INTO emaj.emaj_fk (fk_groups, fk_session, fk_name, fk_schema, fk_table, fk_action, fk_def)
          VALUES (v_groupNames, v_session, r_fk.conname, r_fk.nspname, r_fk.relname, 'set_fk_immediate', r_fk.def);
      END IF;
    END LOOP;
  END;
$_rlbk_groups_step4$;

CREATE or REPLACE FUNCTION emaj._rlbk_groups_step5(v_groupNames TEXT[], v_mark TEXT, v_session INT, v_unloggedRlbk BOOLEAN, v_deleteLog BOOLEAN)
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_groups_step5$
-- This is the fifth step of a rollback group processing. It performs the rollback of all tables of a session.
  DECLARE
    v_nbTbl             INT := 0;
    v_timestampMark     TIMESTAMPTZ;
    v_lastGlobalSeq     BIGINT;
    v_lastSequenceId    BIGINT;
    v_lastSeqHoleId     BIGINT;
  BEGIN
-- fetch the timestamp mark again
    SELECT emaj._get_mark_datetime(v_groupNames[1],v_mark) INTO v_timestampMark;
    IF v_timestampMark IS NULL THEN
      RAISE EXCEPTION '_rlbk_groups_step5: Internal error - mark % not found for group %.', v_mark, v_groupNames[1];
    END IF;
-- fetch the last global sequence and the last id values of emaj_sequence and emaj_seq_hole tables at set mark time
    SELECT mark_global_seq, mark_last_sequence_id, mark_last_seq_hole_id 
      INTO v_lastGlobalSeq, v_lastSequenceId, v_lastSeqHoleId FROM emaj.emaj_mark 
      WHERE mark_group = v_groupNames[1] AND mark_name = emaj._get_mark_name(v_groupNames[1],v_mark);
-- rollback all tables of the session, having rows to rollback, in priority order (sequences are processed later)
    PERFORM emaj._rlbk_tbl(rel_schema, rel_tblseq, v_lastGlobalSeq, v_timestampMark, v_deleteLog, v_lastSequenceId, v_lastSeqHoleId)
      FROM (SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation 
              WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r' AND rel_rows > 0
              ORDER BY rel_priority, rel_schema, rel_tblseq) as t;
-- and return the number of processed tables
    GET DIAGNOSTICS v_nbTbl = ROW_COUNT;
    RETURN v_nbTbl;
  END;
$_rlbk_groups_step5$;

DROP FUNCTION emaj._rlbk_groups_step6(v_groupNames TEXT[], v_session INT);
CREATE or REPLACE FUNCTION emaj._rlbk_groups_step6(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN) 
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_rlbk_groups_step6$
-- This is the sixth step of a rollback group processing. It recreates the previously deleted foreign keys and 'set immediate' the others.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables.
  DECLARE
    v_ts_start          TIMESTAMP;
    v_ts_end            TIMESTAMP;
    v_fullTableName     TEXT;
    v_logTriggerName    TEXT;
    v_rows              BIGINT;
    r_fk                RECORD;
    r_tbl               RECORD;
  BEGIN
-- set recorded foreign keys as IMMEDIATE
    FOR r_fk IN
-- get all recorded fk
      SELECT fk_schema, fk_table, fk_name
        FROM emaj.emaj_fk
        WHERE fk_action = 'set_fk_immediate' AND fk_groups = v_groupNames AND fk_session = v_session
        ORDER BY fk_schema, fk_table, fk_name
      LOOP
-- record the time at the alter table start
        SELECT clock_timestamp() INTO v_ts_start;
-- set the fkey constraint as immediate
        EXECUTE 'SET CONSTRAINTS ' || quote_ident(r_fk.fk_schema) || '.' || quote_ident(r_fk.fk_name) || ' IMMEDIATE';
-- record the time after the alter table and insert FK creation duration into the emaj_rlbk_stat table
        SELECT clock_timestamp() INTO v_ts_end;
-- compute the total number of fk that has been checked. 
-- (this is in fact overestimated because inserts in the referecing table and deletes in the referenced table should not be taken into account. But the required log table scan would be too costly).
        SELECT (
--   get the number of rollbacked rows in the referencing table
        SELECT rel_rows 
          FROM emaj.emaj_relation
          WHERE rel_schema = r_fk.fk_schema AND rel_tblseq = r_fk.fk_table
               ) + (
--   get the number of rollbacked rows in the referenced table
        SELECT rel_rows
          FROM pg_constraint c, pg_namespace n, pg_namespace rn, pg_class rt, emaj.emaj_relation r
          WHERE c.conname = r_fk.fk_name                                   -- constraint id (name + schema)
            AND c.connamespace = n.oid AND n.nspname = r_fk.fk_schema
            AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
            AND rn.nspname = r.rel_schema AND rt.relname = r.rel_tblseq    -- join on groups table
               ) INTO v_rows;
-- record the set_fk_immediate duration into the rollbacks statistics table
        INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration) 
           VALUES ('set_fk_immediate', r_fk.fk_schema, r_fk.fk_name, v_ts_start, v_rows, v_ts_end - v_ts_start);
    END LOOP;
-- process foreign key recreation
    FOR r_fk IN
-- get all recorded fk to recreate, plus the number of rows of the related table as estimated by postgres (pg_class.reltuples)
      SELECT fk_schema, fk_table, fk_name, fk_def, pg_class.reltuples 
        FROM emaj.emaj_fk, pg_namespace, pg_class
        WHERE fk_action = 'add_fk' AND
              fk_groups = v_groupNames AND fk_session = v_session AND                         -- restrictions
              pg_namespace.oid = relnamespace AND relname = fk_table AND nspname = fk_schema  -- joins
        ORDER BY fk_schema, fk_table, fk_name
      LOOP
-- record the time at the alter table start
        SELECT clock_timestamp() INTO v_ts_start;
-- ... recreate the foreign key
        EXECUTE 'ALTER TABLE ' || quote_ident(r_fk.fk_schema) || '.' || quote_ident(r_fk.fk_table) || ' ADD CONSTRAINT ' || quote_ident(r_fk.fk_name) || ' ' || r_fk.fk_def;
-- record the time after the alter table and insert FK creation duration into the emaj_rlbk_stat table
        SELECT clock_timestamp() INTO v_ts_end;
        INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration) 
           VALUES ('add_fk', r_fk.fk_schema, r_fk.fk_name, v_ts_start, r_fk.reltuples, v_ts_end - v_ts_start);
    END LOOP;
-- if unlogged rollback., enable log triggers that had been previously disabled 
    IF v_unloggedRlbk THEN
      FOR r_tbl IN
        SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation 
          WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r' AND rel_rows > 0
          ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
        v_fullTableName  := quote_ident(r_tbl.rel_schema) || '.' || quote_ident(r_tbl.rel_tblseq);
        v_logTriggerName := quote_ident(r_tbl.rel_schema || '_' || r_tbl.rel_tblseq || '_emaj_log_trg');
        EXECUTE 'ALTER TABLE ' || v_fullTableName || ' ENABLE TRIGGER ' || v_logTriggerName;
      END LOOP;
    END IF;
    RETURN;
  END;
$_rlbk_groups_step6$;

CREATE or REPLACE FUNCTION emaj.emaj_estimate_rollback_duration(v_groupName TEXT, v_mark TEXT) 
RETURNS interval LANGUAGE plpgsql AS 
$emaj_estimate_rollback_duration$
-- This function computes an approximate duration of a rollback to a predefined mark for a group.
-- It takes into account the content of emaj_rollback_stat table filled by previous rollback operations.
-- It also uses several parameters from emaj_param table.
-- "Logged" and "Unlogged" rollback durations are estimated with the same algorithm. (the cost of log insertion
-- for logged rollback balances the cost of log deletion of unlogged rollback) 
-- Input: group name, the mark name of the rollback operation
-- Output: the approximate duration that the rollback would need as time interval
  DECLARE
    v_nbTblSeq              INTEGER;
    v_markName              TEXT;
    v_markState             TEXT;
    v_estim_duration        INTERVAL;
    v_avg_row_rlbk          INTERVAL;
    v_avg_row_del_log       INTERVAL;
    v_avg_fkey_check        INTERVAL;
    v_fixed_table_rlbk      INTERVAL;
    v_fixed_table_with_rlbk INTERVAL;
    v_estim                 INTERVAL;
    v_checks                BIGINT;
    r_tblsq                 RECORD;
    r_fkey		            RECORD;
  BEGIN
-- check that the group is recorded in emaj_group table and get the number of tables and sequences
    SELECT group_nb_table + group_nb_sequence INTO v_nbTblSeq FROM emaj.emaj_group 
      WHERE group_name = v_groupName and group_state = 'LOGGING';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_estimate_rollback_duration: group % has not been created or is not in LOGGING state.', v_groupName;
    END IF;
-- check the mark exists
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_markName;
    IF NOT FOUND OR v_markName IS NULL THEN
      RAISE EXCEPTION 'emaj_estimate_rollback_duration: no mark % exists for group %.', v_mark, v_groupName;
    END IF;
-- check the mark is ACTIVE
    SELECT mark_state INTO v_markState FROM emaj.emaj_mark 
      WHERE mark_group = v_groupName AND mark_name = v_markName;
    IF v_markState <> 'ACTIVE' THEN
      RAISE EXCEPTION 'emaj_estimate_rollback_duration: mark % for group % is not in ACTIVE state.', v_markName, v_groupName;
    END IF;
-- get all needed duration parameters from emaj_param table, 
--   or get default values for rows that are not present in emaj_param table
    SELECT coalesce ((SELECT param_value_interval FROM emaj.emaj_param 
                        WHERE param_key = 'avg_row_rollback_duration'),'100 microsecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param 
                        WHERE param_key = 'avg_row_delete_log_duration'),'10 microsecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param 
                        WHERE param_key = 'avg_fkey_check_duration'),'20 microsecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param 
                        WHERE param_key = 'fixed_table_rollback_duration'),'5 millisecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param 
                        WHERE param_key = 'fixed_table_with_rollback_duration'),'2.5 millisecond'::interval)
           INTO v_avg_row_rlbk, v_avg_row_del_log, v_avg_fkey_check, v_fixed_table_rlbk, v_fixed_table_with_rlbk;
-- compute the fixed cost for the group
    v_estim_duration = v_nbTblSeq * v_fixed_table_rlbk;
--
-- walk through the list of tables with their number of rows to rollback as returned by the emaj_log_stat_group function
--
-- for each table with content to rollback
    FOR r_tblsq IN
        SELECT stat_schema, stat_table, stat_rows FROM emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) WHERE stat_rows > 0
        LOOP
--
-- compute the rollback duration estimate for the table
--
-- first look at the previous rollback durations for the table and with similar rollback volume (same order of magnitude)
      SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat 
        WHERE rlbk_operation = 'rlbk' AND rlbk_nb_rows > 0
          AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table
          AND rlbk_nb_rows / r_tblsq.stat_rows < 10 AND r_tblsq.stat_rows / rlbk_nb_rows < 10;
      IF v_estim IS NULL THEN
-- if there is no previous rollback operation with similar volume, take statistics for the table with all available volumes
        SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat 
          WHERE rlbk_operation = 'rlbk' AND rlbk_nb_rows > 0
            AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table;
        IF v_estim IS NULL THEN
-- if there is no previous rollback operation, use the avg_row_rollback_duration from the emaj_param table
          v_estim = v_avg_row_rlbk * r_tblsq.stat_rows;
        END IF;
      END IF;
      v_estim_duration = v_estim_duration + v_fixed_table_with_rlbk + v_estim;
--
-- compute the log rows delete duration for the table
--
-- first look at the previous rollback durations for the table and with similar rollback volume (same order of magnitude)
      SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat 
        WHERE rlbk_operation = 'del_log' AND rlbk_nb_rows > 0
          AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table
          AND rlbk_nb_rows / r_tblsq.stat_rows < 10 AND r_tblsq.stat_rows / rlbk_nb_rows < 10;
      IF v_estim IS NULL THEN
-- if there is no previous rollback operation with similar volume, take statistics for the table with all available volumes
        SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat 
          WHERE rlbk_operation = 'del_log' AND rlbk_nb_rows > 0 
            AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table;
        IF v_estim IS NULL THEN
-- if there is no previous rollback operation, use the avg_row_rollback_duration from the emaj_param table
          v_estim = v_avg_row_del_log * r_tblsq.stat_rows;
        END IF;
      END IF;
      v_estim_duration = v_estim_duration + v_estim;
    END LOOP;
--
-- walk through the list of foreign key constraints concerned by the estimated rollback
--
-- for each foreign key referencing tables that are concerned by the rollback operation
    FOR r_fkey IN
      SELECT c.conname, n.nspname, t.relname, t.reltuples, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_constraint c, pg_namespace n, pg_class t, emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND s.stat_rows > 0                                              -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND n.nspname = s.stat_schema AND t.relname = s.stat_table     -- join on log_stat results
      UNION
      SELECT c.conname, n.nspname, t.relname, t.reltuples, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_constraint c, pg_namespace n, pg_class t, pg_namespace rn, pg_class rt, emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND s.stat_rows > 0                                            -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace 
          AND rn.nspname = s.stat_schema AND rt.relname = s.stat_table   -- join on log_stat results
      ORDER BY nspname, relname, conname
        LOOP
      IF NOT r_fkey.condeferrable OR r_fkey.confupdtype <> 'a' OR r_fkey.confdeltype <> 'a' THEN
-- the fkey is non deferrable fkeys or has an action for UPDATE or DELETE other than 'no action'. 
-- So estimate its re-creation duration.
        IF r_fkey.reltuples = 0 THEN
-- empty table (or table not analyzed) => duration = 0
          v_estim = 0;
	    ELSE
-- non empty table and statistics (with at least one row) are available
          SELECT sum(rlbk_duration) * r_fkey.reltuples / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
            WHERE rlbk_operation = 'add_fk' AND rlbk_nb_rows > 0
              AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname;
          IF v_estim IS NULL THEN
-- non empty table, but no statistics with at least one row are available => take the last duration for this fkey, if any
            SELECT rlbk_duration INTO v_estim FROM emaj.emaj_rlbk_stat
              WHERE rlbk_operation = 'add_fk' AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname AND rlbk_datetime =
               (SELECT max(rlbk_datetime) FROM emaj.emaj_rlbk_stat
                  WHERE rlbk_operation = 'add_fk' AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname);
            IF v_estim IS NULL THEN
-- definitely no statistics available, compute with the avg_fkey_check_duration parameter
              v_estim = r_fkey.reltuples * v_avg_fkey_check;
            END IF;
          END IF;
        END IF;
      ELSE
-- the fkey is really deferrable. So estimate the keys checks duration.
-- compute the total number of fk that would be checked
-- (this is in fact overestimated because inserts in the referecing table and deletes in the referenced table should not be taken into account. But the required log table scan would be too costly).
        SELECT (
--   get the number of rollbacked rows in the referencing table
        SELECT s.stat_rows
          FROM pg_constraint c, pg_namespace n, pg_class r, emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
          WHERE c.conname = r_fkey.conname                                 -- constraint id (name + schema)
            AND c.connamespace = n.oid AND n.nspname = r_fkey.nspname
            AND c.conrelid  = r.oid AND r.relnamespace  = n.oid            -- joins for referencing table and namespace
            AND n.nspname = s.stat_schema AND r.relname = s.stat_table     -- join on groups table
               ) + (
--   get the number of rollbacked rows in the referenced table
        SELECT s.stat_rows
          FROM pg_constraint c, pg_namespace n, pg_namespace rn, pg_class rt, emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
          WHERE c.conname = r_fkey.conname                                 -- constraint id (name + schema)
            AND c.connamespace = n.oid AND n.nspname = r_fkey.nspname
            AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
            AND rn.nspname = s.stat_schema AND rt.relname = s.stat_table   -- join on groups table
               ) INTO v_checks;
        IF v_checks = 0 THEN
-- No check to perform
          RAISE EXCEPTION 'estimate_rollback_duration: no check to perform. One should not find this case !!!';
        ELSE
-- if fkey checks statistics are available for this fkey, compute an average cost
          SELECT sum(rlbk_duration) * v_checks / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
            WHERE rlbk_operation = 'set_fk_immediate' AND rlbk_nb_rows > 0
              AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname;
          IF v_estim IS NULL THEN
-- if no statistics are available for this fkey, use the avg_fkey_check parameter
            v_estim = v_checks * v_avg_fkey_check;
          END IF;
        END IF;
      END IF;
      v_estim_duration = v_estim_duration + v_estim;
    END LOOP;
    RETURN v_estim_duration;
  END;
$emaj_estimate_rollback_duration$;
COMMENT ON FUNCTION emaj.emaj_estimate_rollback_duration(TEXT,TEXT) IS
$$Estimates the duration of a potential rollback of an E-Maj group to a given mark.$$;

CREATE or REPLACE FUNCTION emaj.emaj_snap_group(v_groupName TEXT, v_dir TEXT, v_copyOptions TEXT) 
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS 
$emaj_snap_group$
-- This function creates a file for each table and sequence belonging to the group.
-- For tables, these files contain all rows sorted on primary key.
-- For sequences, they contain a single row describing the sequence.
-- To do its job, the function performs COPY TO statement, with all default parameters.
-- For table without primary key, rows are sorted on all columns.
-- There is no need for the group to be in IDLE state.
-- As all COPY statements are executed inside a single transaction:
--   - the function can be called while other transactions are running,
--   - the snap files will present a coherent state of tables.
-- It's users responsability :
--   - to create the directory (with proper permissions allowing the cluster to write into) before 
-- emaj_snap_group function call, and 
--   - maintain its content outside E-maj.
-- Input: group name, the absolute pathname of the directory where the files are to be created and the options to used in the COPY TO statements
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use.
  DECLARE
    v_pgVersion       TEXT := emaj._pg_version();
    v_emajSchema      TEXT := 'emaj';
    v_nbTb            INT := 0;
    r_tblsq           RECORD;
    v_fullTableName   TEXT;
    r_col             RECORD;
    v_colList         TEXT;
    v_fileName        TEXT;
    v_stmt            TEXT;
    v_seqCol          TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('SNAP_GROUP', 'BEGIN', v_groupName, v_dir);
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_snap_group: group % has not been created.', v_groupName;
    END IF;
-- check the supplied directory is not null
    IF v_dir IS NULL THEN
      RAISE EXCEPTION 'emaj_snap_group: directory parameter cannot be NULL';
    END IF;
-- check the copy options parameter doesn't contain unquoted ; that could be used for sql injection
    IF regexp_replace(v_copyOptions,'''.*''','') LIKE '%;%' THEN
      RAISE EXCEPTION 'emaj_snap_group: invalid COPY options parameter format';
    END IF;
-- for each table/sequence of the emaj_relation table
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation 
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      v_fileName := v_dir || '/' || r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '.snap';
      v_fullTableName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table,
--   first build the order by column list
        v_colList := '';
        PERFORM 0 FROM pg_class, pg_namespace, pg_constraint 
          WHERE relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid AND
                contype = 'p' AND nspname = r_tblsq.rel_schema AND relname = r_tblsq.rel_tblseq;
        IF FOUND THEN
--   the table has a pkey,
          FOR r_col IN
              SELECT attname FROM pg_attribute, pg_index 
                WHERE pg_attribute.attrelid = pg_index.indrelid 
                  AND attnum = ANY (indkey) 
                  AND indrelid = v_fullTableName::regclass AND indisprimary
                  AND attnum > 0 AND attisdropped = false
              LOOP
            IF v_colList = '' THEN
               v_colList := quote_ident(r_col.attname);
            ELSE
               v_colList := v_colList || ',' || quote_ident(r_col.attname);
            END IF;
          END LOOP;
        ELSE
--   the table has no pkey
          FOR r_col IN
              SELECT attname FROM pg_attribute
                WHERE attrelid = v_fullTableName::regclass
                  AND attnum > 0  AND attisdropped = false
              LOOP
            IF v_colList = '' THEN
               v_colList := quote_ident(r_col.attname);
            ELSE
               v_colList := v_colList || ',' || quote_ident(r_col.attname);
            END IF;
          END LOOP;
        END IF;
--   prepare the COPY statement
        v_stmt= 'COPY (SELECT * FROM ' || v_fullTableName || ' ORDER BY ' || v_colList || ') TO ' 
                || quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
        ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, the statement has no order by
        IF v_pgVersion <= '8.3' THEN
          v_seqCol = 'sequence_name, last_value, 0, increment_by, max_value, min_value, cache_value, is_cycled, is_called';
        ELSE
          v_seqCol = 'sequence_name, last_value, start_value, increment_by, max_value, min_value, cache_value, is_cycled, is_called';
        END IF;
        v_stmt= 'COPY (SELECT ' || v_seqCol || ' FROM ' || v_fullTableName || ') TO '
                || quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
      END IF;
-- and finaly perform the COPY
--    raise notice 'emaj_snap_group: Executing %',v_stmt;
      EXECUTE v_stmt;
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- create the _INFO file to keep general information about the snap operation
    EXECUTE 'COPY (SELECT ' || 
            quote_literal('E-Maj snap of tables group ' || v_groupName || 
            ' at ' || transaction_timestamp()) || 
            ') TO ' || quote_literal(v_dir || '/_INFO');
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('SNAP_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_snap_group$;
COMMENT ON FUNCTION emaj.emaj_snap_group(TEXT,TEXT,TEXT) IS
$$Snaps all application tables and sequences of an E-Maj group into a given directory.$$;

CREATE or REPLACE FUNCTION emaj.emaj_snap_log_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT, v_dir TEXT, v_copyOptions TEXT) 
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS 
$emaj_snap_log_group$
-- This function creates a file for each log table belonging to the group.
-- It also creates 2 files containing the state of sequences respectively at start mark and end mark
-- For log tables, files contain all rows related to the time frame, sorted on emaj_gid.
-- For sequences, files are names <group>_sequences_at_<mark>, or <group>_sequences_at_<time> if no 
--   end mark is specified. They contain one row per sequence.
-- To do its job, the function performs COPY TO statement, using the options provided by the caller.
-- There is no need for the group to be in IDLE state.
-- As all COPY statements are executed inside a single transaction:
--   - the function can be called while other transactions are running,
--   - the snap files will present a coherent state of tables.
-- It's users responsability :
--   - to create the directory (with proper permissions allowing the cluster to write into) before 
-- emaj_snap_log_group function call, and 
--   - maintain its content outside E-maj.
-- Input: group name, the 2 mark names defining a range, the absolute pathname of the directory where the files are to be created, options for COPY TO statements
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string can be used as last_mark indicating the current state
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark.
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use.
  DECLARE
    v_pgVersion       TEXT := emaj._pg_version();
    v_emajSchema      TEXT := 'emaj';
    v_nbTb            INT := 0;
    r_tblsq           RECORD;
    v_realFirstMark   TEXT;
    v_realLastMark    TEXT;
    v_firstMarkId     BIGINT;
    v_lastMarkId      BIGINT;
    v_firstEmajGid    BIGINT;
    v_lastEmajGid     BIGINT;
    v_tsFirstMark     TIMESTAMPTZ;
    v_tsLastMark      TIMESTAMPTZ;
    v_logTableName    TEXT;
    v_fileName        TEXT;
    v_stmt            TEXT;
    v_timestamp       TIMESTAMPTZ;
    v_pseudoMark      TEXT;
    v_fullSeqName     TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_LOG_GROUP', 'BEGIN', v_groupName, 
       CASE WHEN v_firstMark IS NULL OR v_firstMark = '' THEN 'From initial mark' ELSE 'From mark ' || v_firstMark END || 
       CASE WHEN v_lastMark IS NULL OR v_lastMark = '' THEN ' to current situation' ELSE ' to mark ' || v_lastMark END || ' towards ' 
       || v_dir);
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_snap_log_group: group % has not been created.', v_groupName;
    END IF;
-- check the copy options parameter doesn't contain unquoted ; that could be used for sql injection
    IF regexp_replace(v_copyOptions,'''.*''','') LIKE '%;%'  THEN
      RAISE EXCEPTION 'emaj_snap_log_group: invalid COPY options parameter format';
    END IF;
-- catch the global sequence value and the timestamp of the first mark
    IF v_firstMark IS NOT NULL AND v_firstMark <> '' THEN
-- check and retrieve the global sequence value and the timestamp of the start mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_firstMark) INTO v_realFirstMark;
      IF v_realFirstMark IS NULL THEN
          RAISE EXCEPTION 'emaj_snap_log_group: Start mark % is unknown for group %.', v_firstMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_firstMarkId, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realFirstMark;
    ELSE
      SELECT mark_name, mark_id, mark_global_seq, mark_datetime INTO v_realFirstMark, v_firstMarkId, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName ORDER BY mark_id LIMIT 1;
    END IF;
-- catch the global sequence value and timestamp of the last mark
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
-- else, check and retrieve the global sequence value and the timestamp of the end mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_lastMark) INTO v_realLastMark;
      IF v_realLastMark IS NULL THEN
        RAISE EXCEPTION 'emaj_snap_log_group: End mark % is unknown for group %.', v_lastMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_lastMarkId, v_lastEmajGid, v_tsLastMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realLastMark;
    ELSE
      v_lastMarkId = NULL;
      v_lastEmajGid = NULL;
      v_tsLastMark = NULL;
    END IF;
-- check that the first_mark < end_mark
    IF v_lastMarkId IS NOT NULL AND v_firstMarkId > v_lastMarkId THEN
      RAISE EXCEPTION 'emaj_snap_log_group: mark id for % (% = %) is greater than mark id for % (% = %).', v_realFirstMark, v_firstMarkId, v_tsFirstMark, v_realLastMark, v_lastMarkId, v_tsLastMark;
    END IF;
-- check the supplied directory is not null
    IF v_dir IS NULL THEN
      RAISE EXCEPTION 'emaj_snap_log_group: directory parameter cannot be NULL';
    END IF;
-- process all log tables of the emaj_relation table
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation 
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- process tables
-- compute names
        v_fileName     := v_dir || '/' || r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log.snap';
        v_logTableName := quote_ident(v_emajSchema) || '.' || quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log');
--   prepare the COPY statement
        v_stmt= 'COPY (SELECT * FROM ' || v_logTableName || ' WHERE TRUE';
        IF v_firstMark IS NOT NULL AND v_firstMark <> '' THEN 
          v_stmt = v_stmt || ' AND emaj_gid > '|| v_firstEmajGid;
        END IF;
        IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN 
          v_stmt = v_stmt || ' AND emaj_gid <= '|| v_lastEmajGid;
        END IF;
        v_stmt = v_stmt || ' ORDER BY emaj_gid ASC) TO ' || quote_literal(v_fileName) || ' ' 
                        || coalesce (v_copyOptions, '');
-- and finaly perform the COPY
        EXECUTE v_stmt;
      END IF;
-- for sequences, just adjust the counter
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- generate the file for sequences state at start mark
    v_fileName := v_dir || '/' || v_groupName || '_sequences_at_' || v_realFirstMark;
    v_stmt= 'COPY (SELECT emaj_sequence.*' ||
            ' FROM ' || v_emajSchema || '.emaj_sequence, ' || v_emajSchema || '.emaj_relation' ||
            ' WHERE sequ_mark = ' || quote_literal(v_realFirstMark) || ' AND ' || 
            ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
            ' sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
            ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' || 
            coalesce (v_copyOptions, '');
    EXECUTE v_stmt;
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN 
-- generate the file for sequences state at end mark, if specified
      v_fileName := v_dir || '/' || v_groupName || '_sequences_at_' || v_realLastMark;
      v_stmt= 'COPY (SELECT emaj_sequence.*' ||
              ' FROM ' || v_emajSchema || '.emaj_sequence, ' || v_emajSchema || '.emaj_relation' ||
              ' WHERE sequ_mark = ' || quote_literal(v_realLastMark) || ' AND ' || 
              ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
              ' sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
              ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' || 
              coalesce (v_copyOptions, '');
      EXECUTE v_stmt;
    ELSE
-- generate the file for sequences in their current state, if no end_mark is specified,
--   by using emaj_sequence table to create temporary rows as if a mark had been set
-- look at the clock to get the 'official' timestamp representing this point in time 
--   and build a pseudo mark name with it
      v_timestamp = clock_timestamp();
      v_pseudoMark = to_char(v_timestamp,'HH24.MI.SS.MS');
-- for each sequence of the groups, ...
      FOR r_tblsq IN
          SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation 
            WHERE rel_group = v_groupName AND rel_kind = 'S' ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
-- ... temporary record the sequence parameters in the emaj sequence table
        v_fullSeqName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
        v_stmt = 'INSERT INTO emaj.emaj_sequence (' ||
                 'sequ_schema, sequ_name, sequ_datetime, sequ_mark, sequ_last_val, sequ_start_val, ' || 
                 'sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called ' ||
                 ') SELECT ' || quote_literal(r_tblsq.rel_schema) || ', ' || 
                 quote_literal(r_tblsq.rel_tblseq) || ', ' || quote_literal(v_timestamp) || 
                 ', ' || quote_literal(v_pseudoMark) || ', last_value, ';
        IF v_pgVersion <= '8.3' THEN
           v_stmt = v_stmt || '0, ';
        ELSE
           v_stmt = v_stmt || 'start_value, ';
        END IF;
        v_stmt = v_stmt || 
                 'increment_by, max_value, min_value, cache_value, is_cycled, is_called ' ||
                 'FROM ' || v_fullSeqName;
        EXECUTE v_stmt;
      END LOOP;
-- generate the file for sequences current state
      v_fileName := v_dir || '/' || v_groupName || '_sequences_at_' || to_char(v_timestamp,'HH24.MI.SS.MS');
      v_stmt= 'COPY (SELECT emaj_sequence.*' ||
              ' FROM ' || v_emajSchema || '.emaj_sequence, ' || v_emajSchema || '.emaj_relation' ||
              ' WHERE sequ_mark = ' || quote_literal(v_pseudoMark) || ' AND ' || 
              ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
              ' sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
              ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' || 
              coalesce (v_copyOptions, '');
      EXECUTE v_stmt;
-- delete sequences state that have just been inserted into the emaj_sequence table.
      EXECUTE 'DELETE FROM ' || v_emajSchema || '.emaj_sequence' ||
              ' USING ' || v_emajSchema || '.emaj_relation' ||
              ' WHERE sequ_mark = ' || quote_literal(v_pseudoMark) || ' AND' || 
              ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
              ' sequ_schema = rel_schema AND sequ_name = rel_tblseq';
    END IF;
-- create the _INFO file to keep general information about the snap operation
    EXECUTE 'COPY (SELECT ' || 
            quote_literal('E-Maj log tables snap of group ' || v_groupName || 
            ' between marks ' || v_realFirstMark || ' and ' || 
            coalesce(v_realLastMark,'current state') || ' at ' || transaction_timestamp()) || 
            ') TO ' || quote_literal(v_dir || '/_INFO') || ' ' || coalesce (v_copyOptions, '');
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording) 
      VALUES ('SNAP_LOG_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_snap_log_group$;
COMMENT ON FUNCTION emaj.emaj_snap_log_group(TEXT,TEXT,TEXT,TEXT,TEXT) IS
$$Snaps all application tables and sequences of an E-Maj group into a given directory.$$;

-- Set comments for all internal functions, 
-- by directly inserting a row in the pg_description table for all emaj functions that do not have yet a recorded comment
INSERT INTO pg_description (objoid, classoid, objsubid, description)
  SELECT pg_proc.oid, pg_class.oid, 0 , 'E-Maj internal function'
    FROM pg_proc, pg_class
    WHERE pg_class.relname = 'pg_proc'
      AND pg_proc.oid IN               -- list all emaj functions that do not have yet a comment in pg_description
       (SELECT pg_proc.oid 
          FROM pg_proc
               JOIN pg_namespace ON (pronamespace=pg_namespace.oid)
               LEFT OUTER JOIN pg_description ON (pg_description.objoid = pg_proc.oid 
                                     AND classoid = (SELECT oid FROM pg_class WHERE relname = 'pg_proc')
                                     AND objsubid = 0)
          WHERE nspname = 'emaj' AND (proname LIKE E'emaj\\_%' OR proname LIKE E'\\_%')
            AND pg_description.description IS NULL
       );

------------------------------------
--                                --
-- emaj roles and rights          --
--                                --
------------------------------------
-- grants on tables
GRANT SELECT ON emaj.emaj_fk         TO emaj_viewer;
GRANT SELECT,INSERT,UPDATE,DELETE ON emaj.emaj_fk         TO emaj_adm;

-- revoke grants on all functions from PUBLIC
REVOKE ALL ON FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._rlbk_groups_step4(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN) FROM PUBLIC; 
REVOKE ALL ON FUNCTION emaj._rlbk_groups_step6(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN) FROM PUBLIC; 

-- and give appropriate rights on functions to emaj_adm role
GRANT EXECUTE ON FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._rlbk_groups_step4(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._rlbk_groups_step6(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN) TO emaj_adm; 

-- and give appropriate rights on functions to emaj_viewer role
--GRANT EXECUTE ON FUNCTION emaj._build_log_seq_name(TEXT, TEXT) TO emaj_viewer;

------------------------------------
--                                --
-- commit upgrade                 --
--                                --
------------------------------------

UPDATE emaj.emaj_param SET param_value_text = '0.11.1' WHERE param_key = 'emaj_version';

-- and insert the init record in the operation history
INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording) VALUES ('EMAJ_INSTALL','E-Maj 0.11.1', 'Upgrade from 0.11.0 completed');

COMMIT;

SET client_min_messages TO default;
\echo '>>> E-Maj successfully upgrated to 0.11.1'

