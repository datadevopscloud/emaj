--
-- E-Maj : logs and rollbacks table changes : Version <devel>
--
-- This software is distributed under the GNU General Public License.
--
-- This script is automatically called by a "CREATE EXTENSION emaj CASCADE;" statement.
--
-- This script must be executed by a role having SUPERUSER privileges.
--
-- The E-Maj technical tables will be installed into the default tablespace.
-- The user executing the installation may set it to a particular value using a "set default_tablespace to <name>;" statement.
--
-- The emaj extension also installs the dblink and btree_gist extensions into the database if they are not already installed.

-- Complain if this script is executed in psql, rather than via a CREATE EXTENSION statement.
\echo Use "CREATE EXTENSION emaj" to install the E-Maj extension. \quit

-- Perform some checks and create emaj roles.
DO LANGUAGE plpgsql
$do$
  BEGIN
-- check the current role is a superuser
    PERFORM 0 FROM pg_catalog.pg_roles WHERE rolname = current_user AND rolsuper;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'E-Maj installation: The current user (%) is not a superuser.', current_user;
    END IF;
-- check postgres version is >= 9.5
    IF current_setting('server_version_num')::INT < 90500 THEN
      RAISE EXCEPTION 'E-Maj installation: The current postgres version (%) is too old for this E-Maj version. It should be at least 9.5.',
        current_setting('server_version');
    END IF;
-- create emaj roles (NOLOGIN), if they do not exist
-- does 'emaj_adm' already exist ?
    PERFORM 0 FROM pg_catalog.pg_roles WHERE rolname = 'emaj_adm';
-- if no, create it
    IF NOT FOUND THEN
      CREATE ROLE emaj_adm;
      COMMENT ON ROLE emaj_adm IS
        $$This role may be granted to other roles in charge of E-Maj administration.$$;
    END IF;
-- does 'emaj_viewer' already exist ?
    PERFORM 0 FROM pg_catalog.pg_roles WHERE rolname = 'emaj_viewer';
-- if no, create it
    IF NOT FOUND THEN
      CREATE ROLE emaj_viewer;
      COMMENT ON ROLE emaj_viewer IS
        $$This role may be granted to other roles allowed to view E-Maj objects content.$$;
    END IF;
--
    RETURN;
  END;
$do$;

COMMENT ON SCHEMA emaj IS
$$Contains all E-Maj related objects.$$;

------------------------------------------------
--                                            --
-- emaj enum types, sequences and tables      --
--                                            --
------------------------------------------------

-- Enum of the possible values for the alter groups steps.
-- The order of the values is important: all elementary steps are performed in this order.
CREATE TYPE emaj._alter_step_enum AS ENUM (
  'REMOVE_TBL',              -- remove a table from a group
  'REMOVE_SEQ',              -- remove a sequence from a group
  'REPAIR_TBL',              -- repair a damaged table
  'REPAIR_SEQ',              -- repair a damaged sequence
  'RESET_GROUP',             -- reset an idle group
  'CHANGE_TBL_LOG_SCHEMA',   -- change the log schema for a table
  'CHANGE_TBL_NAMES_PREFIX', -- change the E-Maj names prefix for a table
  'CHANGE_TBL_LOG_DATA_TSP', -- change the log data tablespace for a table
  'CHANGE_TBL_LOG_INDEX_TSP',-- change the log index tablespace for a table
  'MOVE_TBL',                -- move a table from one group to another
  'MOVE_SEQ',                -- move a sequence from one group to another
  'CHANGE_REL_PRIORITY',     -- change the priority level for a table
  'ADD_TBL',                 -- add a table to a group
  'ADD_SEQ'                  -- add a sequence to a group
  );

-- Enum of the possible values for the rollback status columns.
CREATE TYPE emaj._rlbk_status_enum AS ENUM (
  'PLANNING',                -- the emaj rollback is in the initial planning phase
  'LOCKING',                 -- the emaj rollback is acquiring locks on tables
  'EXECUTING',               -- the emaj rollback is in the main executing phase
  'COMPLETED',               -- the emaj rollback is completed but the status of its transaction is not yet known
  'COMMITTED',               -- the emaj rollback transaction is known as committed
  'ABORTED'                  -- the emaj rollback transaction is known as aborted
  );

-- Enum of the possible values for the rollback steps.
CREATE TYPE emaj._rlbk_step_enum AS ENUM (
  'LOCK_TABLE',              -- set a lock on a table
  'DIS_APP_TRG',             -- disable an application trigger
  'DIS_LOG_TRG',             -- disable a log trigger
  'DROP_FK',                 -- drop a foreign key
  'SET_FK_DEF',              -- set a foreign key deferred
  'RLBK_TABLE',              -- rollback a table
  'DELETE_LOG',              -- delete rows from a log table
  'SET_FK_IMM',              -- set a foreign key immediate
  'ADD_FK',                  -- recreate a foreign key
  'ENA_APP_TRG',             -- enable an application trigger
  'ENA_LOG_TRG',             -- enable a log trigger
  'CTRL+DBLINK',             -- pseudo step representing the periods between 2 steps execution, when dblink is used
  'CTRL-DBLINK'              -- pseudo step representing the periods between 2 steps execution, when dblink is not used
  );

-- The emaj_global_seq sequence provides a unique identifier for all rows inserted into all emaj log tables of the database.
-- It is used to order all these rows in insertion time order for rollback as well as other purposes.
-- (So this order is not based on system time that can be unsafe).
-- The sequence is created with the following  (default) characteristics:
-- - increment = 1
-- - no cache (to keep the delivered nextval value in time order)
-- - no cycle (would the end of the sequence be reached, no new log row would be accepted)
CREATE SEQUENCE emaj.emaj_global_seq;
COMMENT ON SEQUENCE emaj.emaj_global_seq IS
$$Global sequence to identifiy all rows of emaj log tables.$$;

-- Table containing E-maj parameters.
CREATE TABLE emaj.emaj_param (
  param_key                    TEXT        NOT NULL,       -- parameter key
  param_value_text             TEXT,                       -- value if type is text, otherwise NULL
  param_value_numeric          NUMERIC,                    -- value if type is numeric, otherwise NULL
  param_value_boolean          BOOLEAN,                    -- value if type is boolean, otherwise NULL
  param_value_interval         INTERVAL,                   -- value if type is interval, otherwise NULL
  PRIMARY KEY (param_key)
  );
COMMENT ON TABLE emaj.emaj_param IS
$$Contains E-Maj parameters.$$;

-- Table containing the history of all E-Maj events.
CREATE TABLE emaj.emaj_hist (
  hist_id                      BIGSERIAL   NOT NULL,       -- internal id
  hist_datetime                TIMESTAMPTZ NOT NULL
                               DEFAULT clock_timestamp(),  -- insertion time
  hist_function                TEXT        NOT NULL,       -- main E-Maj function generating the event
  hist_event                   TEXT,                       -- type of event (often BEGIN or END)
  hist_object                  TEXT,                       -- object supporting the event (often the group name)
  hist_wording                 TEXT,                       -- additional comment
  hist_user                    TEXT
                               DEFAULT session_user,       -- the user who call the E-Maj function
  hist_txid                    BIGINT
                               DEFAULT txid_current(),     -- and its tx_id
  PRIMARY KEY (hist_id)
  );
COMMENT ON TABLE emaj.emaj_hist IS
$$Contains E-Maj events history.$$;

-- Table containing the definition of groups' content. Filled and maintained by the user, it is used by emaj_create_group function.
CREATE TABLE emaj.emaj_group_def (
  grpdef_group                 TEXT        NOT NULL,       -- name of the group containing this table or sequence
  grpdef_schema                TEXT        NOT NULL,       -- schema name of this table or sequence
  grpdef_tblseq                TEXT        NOT NULL,       -- table or sequence name
  grpdef_priority              INTEGER,                    -- priority level (tables are processed in ascending
                                                           --   order, with NULL last)
  grpdef_log_dat_tsp           TEXT,                       -- tablespace for the log table (NULL to use default value)
  grpdef_log_idx_tsp           TEXT,                       -- tablespace for the log index (NULL to use default value)
  PRIMARY KEY (grpdef_group, grpdef_schema, grpdef_tblseq)
-- the group name is included in the pkey so that a table/sequence can be temporarily assigned to several groups
  );
COMMENT ON TABLE emaj.emaj_group_def IS
$$Contains E-Maj groups definition, supplied by the E-Maj administrator.$$;
-- Index on emaj_grpdef used to speedup alter groups operations on groups with large E-Maj configuration.
CREATE INDEX emaj_group_def_idx1 ON emaj.emaj_group_def (grpdef_schema, grpdef_tblseq);

-- Table containing the time stamps of major E-Maj events.
-- These stamps, used as time references in other internal tables, are insensitive to system time fluctuations and transaction wrapaound.
CREATE TABLE emaj.emaj_time_stamp (
  time_id                      BIGSERIAL   NOT NULL,       -- internal id
  time_clock_timestamp         TIMESTAMPTZ NOT NULL        -- insertion clock time
                               DEFAULT clock_timestamp(),
  time_stmt_timestamp          TIMESTAMPTZ NOT NULL        -- insertion statement start time
                               DEFAULT statement_timestamp(),
  time_tx_timestamp            TIMESTAMPTZ NOT NULL        -- insertion transaction start time
                               DEFAULT transaction_timestamp(),
  time_tx_id                   BIGINT                      -- id of the tx that has generated the time stamp
                               DEFAULT txid_current(),
  time_last_emaj_gid           BIGINT,                     -- last value of the E-Maj global sequence
  time_event                   CHAR(1),                    -- event type that has generated the time stamp
                                                           --   C(reate group), D(rop group), A(lter group),
                                                           --   M(ark setting), R(ollback), S(imple)
  PRIMARY KEY (time_id)
  );
COMMENT ON TABLE emaj.emaj_time_stamp IS
$$Contains the time stamps of major E-Maj events.$$;

-- Table containing the defined groups.
-- Rows are created at emaj_create_group time and deleted at emaj_drop_group time.
CREATE TABLE emaj.emaj_group (
  group_name                   TEXT        NOT NULL,
  group_is_rollbackable        BOOLEAN     NOT NULL,       -- false for 'AUDIT_ONLY' and true for 'ROLLBACKABLE' groups
  group_creation_time_id       BIGINT      NOT NULL,       -- time stamp of the group's creation
  group_pg_version             TEXT        NOT NULL        -- postgres version at emaj_create_group() time
                               DEFAULT substring (version() FROM E'PostgreSQL\\s([.,0-9,A-Z,a-z]*)'),
  group_last_alter_time_id     BIGINT,                     -- time stamp of the last group structure change
                                                           --   set to NULL at emaj_create_group() time
  group_has_waiting_changes    BOOLEAN     NOT NULL,       -- are there recent changes in emaj_group_def not yet applied in emaj_group ?
  group_is_logging             BOOLEAN     NOT NULL,       -- are log triggers activated ?
                                                           -- true between emaj_start_group(s) and emaj_stop_group(s)
                                                           -- false in other cases
  group_is_rlbk_protected      BOOLEAN     NOT NULL,       -- is the group currently protected against rollback ?
                                                           -- always true for AUDIT_ONLY groups
  group_nb_table               INT,                        -- number of tables at emaj_create_group time
  group_nb_sequence            INT,                        -- number of sequences at emaj_create_group time
  group_comment                TEXT,                       -- optional user comment
  PRIMARY KEY (group_name),
  FOREIGN KEY (group_creation_time_id) REFERENCES emaj.emaj_time_stamp (time_id),
  FOREIGN KEY (group_last_alter_time_id) REFERENCES emaj.emaj_time_stamp (time_id)
  );
COMMENT ON TABLE emaj.emaj_group IS
$$Contains created E-Maj groups.$$;

-- Table containing the emaj and log schemas.
CREATE TABLE emaj.emaj_schema (
  sch_name                     TEXT        NOT NULL,       -- schema name
  sch_datetime                 TIMESTAMPTZ NOT NULL DEFAULT transaction_timestamp(),
                                                           -- insertion time
  PRIMARY KEY (sch_name)
  );
COMMENT ON TABLE emaj.emaj_schema IS
$$Contains the schemas hosting log tables, sequences and functions.$$;

-- Table containing the relations (tables and sequences) of created tables groups.
CREATE TABLE emaj.emaj_relation (
  rel_schema                   TEXT        NOT NULL,       -- schema name containing the relation
  rel_tblseq                   TEXT        NOT NULL,       -- application table or sequence name
  rel_time_range               INT8RANGE   NOT NULL,       -- range of time id representing the validity time range
  rel_group                    TEXT        NOT NULL,       -- name of the group that owns the relation
  rel_kind                     TEXT,                       -- similar to the relkind column of pg_class table
                                                           --   ('r' = table, 'S' = sequence)
-- next columns are specific for tables and remain NULL for sequences
  rel_priority                 INTEGER,                    -- priority level of processing inside the group
  rel_log_schema               TEXT,                       -- schema for the log table, functions and sequence
  rel_log_table                TEXT,                       -- name of the log table associated
  rel_log_dat_tsp              TEXT,                       -- tablespace for the log table
  rel_log_index                TEXT,                       -- name of the index of the log table
  rel_log_idx_tsp              TEXT,                       -- tablespace for the log index
  rel_log_sequence             TEXT,                       -- name of the log sequence
  rel_log_function             TEXT,                       -- name of the function associated to the log trigger
                                                           -- created on the application table
  rel_emaj_verb_attnum         SMALLINT,                   -- column number (attnum) of the log table's emaj_verb column in the
                                                           --  pg_attribute table
  rel_has_always_ident_col     BOOLEAN,                    -- are there any "generated always as identity" column ?
  rel_sql_rlbk_columns         TEXT,                       -- piece of sql used to rollback: list of the columns
  rel_sql_rlbk_pk_columns      TEXT,                       -- piece of sql used to rollback: list of the pk columns
  rel_sql_rlbk_pk_conditions   TEXT,                       -- piece of sql used to rollback: equality conditions on the pk columns
  rel_sql_gen_ins_col          TEXT,                       -- piece of sql used for SQL generation: list of columns to insert
  rel_sql_gen_ins_val          TEXT,                       -- piece of sql used for SQL generation: list of column values to insert
  rel_sql_gen_upd_set          TEXT,                       -- piece of sql used for SQL generation: set clause for updates
  rel_sql_gen_pk_conditions    TEXT,                       -- piece of sql used for SQL generation: equality conditions on the pk columns
  rel_log_seq_last_value       BIGINT,                     -- last value of the log sequence when the table is removed from the group
                                                           -- (NULL otherwise)
  PRIMARY KEY (rel_schema, rel_tblseq, rel_time_range),
  FOREIGN KEY (rel_group) REFERENCES emaj.emaj_group (group_name),
  FOREIGN KEY (rel_log_schema) REFERENCES emaj.emaj_schema (sch_name),
  EXCLUDE USING gist (rel_schema WITH =, rel_tblseq WITH =, rel_time_range WITH &&)
  );
COMMENT ON TABLE emaj.emaj_relation IS
$$Contains the content (tables and sequences) of created E-Maj groups.$$;
-- Index on emaj_relation used to speedup most functions working on groups with large E-Maj configuration.
CREATE INDEX emaj_relation_idx1 ON emaj.emaj_relation (rel_group, rel_kind);
-- Index on emaj_relation used to speedup _verify_all_schemas() with large E-Maj configuration.
CREATE INDEX emaj_relation_idx2 ON emaj.emaj_relation (rel_log_schema);

-- Table containing the history of relations - groups relationship.
CREATE TABLE emaj.emaj_rel_hist (
  relh_schema                  TEXT        NOT NULL,       -- schema name containing the relation
  relh_tblseq                  TEXT        NOT NULL,       -- application table or sequence name
  relh_time_range              INT8RANGE   NOT NULL,       -- range of time id representing the validity time range
                                           CHECK (NOT upper_inf(relh_time_range)),
  relh_group                   TEXT        NOT NULL,       -- name of the group that owned the relation
                                                           --   (the group may not exist in emaj_group anymore)
  relh_kind                    TEXT,                       -- similar to the relkind column of pg_class table
                                                           --   ('r' = table, 'S' = sequence)
  PRIMARY KEY (relh_schema, relh_tblseq, relh_time_range),
  EXCLUDE USING gist (relh_schema WITH =, relh_tblseq WITH =, relh_time_range WITH &&)
  );
-- Functional index on emaj_rel_hist used to speedup the history purge function.
CREATE INDEX emaj_rel_hist_idx1 ON emaj.emaj_rel_hist ((upper(relh_time_range)));
COMMENT ON TABLE emaj.emaj_rel_hist IS
$$Contains the history of groups content.$$;

-- Table containing the marks.
CREATE TABLE emaj.emaj_mark (
  mark_group                   TEXT        NOT NULL,       -- group for which the mark has been set
  mark_name                    TEXT        NOT NULL,       -- mark name
  mark_time_id                 BIGINT      NOT NULL,       -- time stamp of the mark creation, used as a reference
                                                           --   for other tables like emaj_sequence and all log tables
  mark_is_deleted              BOOLEAN     NOT NULL,       -- boolean to indicate whether the mark is deleted
  mark_is_rlbk_protected       BOOLEAN     NOT NULL,       -- boolean to indicate whether the mark is protected against rollbacks (false
                                                           -- by default)
  mark_comment                 TEXT,                       -- optional user comment
  mark_log_rows_before_next    BIGINT,                     -- number of log rows recorded for the group between the mark
                                                           -- and the next one (NULL if last mark)
                                                           -- used to speedup marks list display in the Emaj_web client
  mark_logged_rlbk_target_mark TEXT,                       -- for marks generated by logged_rollback functions, name of the rollback target
                                                           -- mark
  PRIMARY KEY (mark_group, mark_name),
  FOREIGN KEY (mark_group) REFERENCES emaj.emaj_group (group_name) ON DELETE CASCADE,
  FOREIGN KEY (mark_time_id) REFERENCES emaj.emaj_time_stamp (time_id)
  );
COMMENT ON TABLE emaj.emaj_mark IS
$$Contains marks set on E-Maj tables groups.$$;
-- Index on emaj_mark used to speedup statistics functions, when many marks have been set
CREATE INDEX emaj_mark_idx1 ON emaj.emaj_mark (mark_time_id);

-- Table containing the sequences characteristics log
-- (to record at mark time the state of application sequences and sequences used by log tables).
CREATE TABLE emaj.emaj_sequence (
  sequ_schema                  TEXT        NOT NULL,       -- application or 'emaj' schema that owns the sequence
  sequ_name                    TEXT        NOT NULL,       -- application or emaj sequence name
  sequ_time_id                 BIGINT      NOT NULL,       -- time stamp when the sequence characteristics have been recorded
                                                           --   the same time stamp id as referenced in emaj_mark table
  sequ_last_val                BIGINT      NOT NULL,       -- sequence last value
  sequ_start_val               BIGINT      NOT NULL,       -- sequence start value
  sequ_increment               BIGINT      NOT NULL,       -- sequence increment
  sequ_max_val                 BIGINT      NOT NULL,       -- sequence max value
  sequ_min_val                 BIGINT      NOT NULL,       -- sequence min value
  sequ_cache_val               BIGINT      NOT NULL,       -- sequence cache value
  sequ_is_cycled               BOOLEAN     NOT NULL,       -- sequence flag 'is cycled ?'
  sequ_is_called               BOOLEAN     NOT NULL,       -- sequence flag 'is called ?'
  PRIMARY KEY (sequ_schema, sequ_name, sequ_time_id),
  FOREIGN KEY (sequ_time_id) REFERENCES emaj.emaj_time_stamp (time_id)
  );
COMMENT ON TABLE emaj.emaj_sequence IS
$$Contains values of sequences at E-Maj set_mark times.$$;

-- Table containing the holes in sequences log.
-- These holes are due to rollback operations or rollback consolidation that produce holes in log sequences.
-- They are recorded to give better results in functions that estimate the number of updates using the sequence values recorded at
--   set mark times.
CREATE TABLE emaj.emaj_seq_hole (
  sqhl_schema                  TEXT        NOT NULL,       -- schema that owns the application table
  sqhl_table                   TEXT        NOT NULL,       -- application table for which a sequence hole is recorded in the associated
                                                           -- log table
  sqhl_begin_time_id           BIGINT      NOT NULL,       -- time stamp id of the lower range limit of the hole
  sqhl_end_time_id             BIGINT      NOT NULL,       -- time stamp id of the upper range limit of the hole
  sqhl_hole_size               BIGINT      NOT NULL,       -- hole size computed as the difference of 2 sequence last-values
  PRIMARY KEY (sqhl_schema, sqhl_table, sqhl_begin_time_id),
  FOREIGN KEY (sqhl_begin_time_id) REFERENCES emaj.emaj_time_stamp (time_id),
  FOREIGN KEY (sqhl_end_time_id) REFERENCES emaj.emaj_time_stamp (time_id)
  );
COMMENT ON TABLE emaj.emaj_seq_hole IS
$$Contains description of holes in sequence values for E-Maj log tables.$$;

-- Table containing the elementary steps to perform alter_groups operations.
-- The steps concerning a relation are identified by the altr_schema and altr_tblseq columns.
-- The steps concerning a schema are identified by the altr_schema column.
-- The steps concerning a group are identified by the altr_group column.
CREATE TABLE emaj.emaj_alter_plan (
  altr_time_id                 BIGINT      NOT NULL,       -- time stamp id of the alter_groups operation
  altr_step                    emaj._alter_step_enum
                                           NOT NULL,       -- elementary step of the alter groups operation
  altr_schema                  TEXT        NOT NULL,       -- schema name, depending on the step ('' when meaningless)
  altr_tblseq                  TEXT        NOT NULL,       -- table or sequence name, depending on the step ('' when meaningless)
  altr_group                   TEXT        NOT NULL,       -- group that owns the table or the sequence ('' when meaningless)
  altr_priority                INT         ,               -- priority level, with the same meaning and representation than in
                                                           -- emaj_group_def
  altr_group_is_logging        BOOLEAN     ,               -- copy of the emaj_group.group_is_logging column at alter time
  altr_new_group               TEXT        ,               -- target group name, when the relation changes its group ownership
  altr_new_group_is_logging    BOOLEAN     ,               -- state of the target group, when the relation changes its group ownership
  altr_rlbk_id                 BIGINT      ,               -- rollback id if a rollback has already crossed over the alter step
  PRIMARY KEY (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group),
  FOREIGN KEY (altr_time_id) REFERENCES emaj.emaj_time_stamp (time_id)
  );
COMMENT ON TABLE emaj.emaj_alter_plan IS
$$Contains elementary steps of alter_groups operations.$$;

-- Table containing rollback events.
CREATE TABLE emaj.emaj_rlbk (
  rlbk_id                      SERIAL      NOT NULL,       -- rollback id
  rlbk_groups                  TEXT[]      NOT NULL,       -- groups array to rollback
  rlbk_mark                    TEXT        NOT NULL,       -- mark to rollback to (the original value at rollback time)
  rlbk_mark_time_id            BIGINT      NOT NULL,       -- time stamp id of the mark to rollback to
  rlbk_time_id                 BIGINT,                     -- time stamp id at the rollback start
  rlbk_is_logged               BOOLEAN     NOT NULL,       -- rollback type: true = logged rollback
  rlbk_is_alter_group_allowed  BOOLEAN,                    -- flag allowing to rollback to a mark set before alter group operations
                                                           -- (NULL with old rollback functions)
  rlbk_nb_session              INT         NOT NULL,       -- number of requested rollback sessions
  rlbk_nb_table                INT,                        -- total number of tables in groups
  rlbk_nb_sequence             INT,                        -- number of sequences to rollback
  rlbk_eff_nb_table            INT,                        -- number of tables with rows to rollback
  rlbk_status                  emaj._rlbk_status_enum,     -- rollback status
  rlbk_begin_hist_id           BIGINT,                     -- hist_id of the rollback BEGIN event in the emaj_hist
                                                           --   used to know if the rollback has been committed or not
  rlbk_dblink_schema           TEXT,                       -- schema that holds the dblink extension
  rlbk_is_dblink_used          BOOLEAN,                    -- boolean indicating whether dblink connection are used
  rlbk_end_datetime            TIMESTAMPTZ,                -- clock time the rollback has been completed,
                                                           --   NULL if rollback is in progress or aborted
  rlbk_messages                TEXT[],                     -- result messages array
  PRIMARY KEY (rlbk_id),
  FOREIGN KEY (rlbk_time_id) REFERENCES emaj.emaj_time_stamp (time_id),
  FOREIGN KEY (rlbk_mark_time_id) REFERENCES emaj.emaj_time_stamp (time_id)
  );
COMMENT ON TABLE emaj.emaj_rlbk IS
$$Contains description of rollback events.$$;
-- Partial index on emaj_rlbk targeting in progress rollbacks (not yet committed or marked as aborted).
CREATE INDEX emaj_rlbk_idx1 ON emaj.emaj_rlbk (rlbk_status)
    WHERE rlbk_status IN ('PLANNING', 'LOCKING', 'EXECUTING', 'COMPLETED');

-- Table containing rollback events sessions.
CREATE TABLE emaj.emaj_rlbk_session (
  rlbs_rlbk_id                 INT         NOT NULL,       -- rollback id
  rlbs_session                 INT         NOT NULL,       -- session number (from 1 to rlbk_nb_session)
  rlbs_txid                    BIGINT      NOT NULL,       -- id of the tx that executes this rollback session
  rlbs_start_datetime          TIMESTAMPTZ NOT NULL,       -- rollback session start timestamp
  rlbs_end_datetime            TIMESTAMPTZ,                -- clock time the rollback session has been completed,
                                                           --   NULL if rollback is in progress
  PRIMARY KEY (rlbs_rlbk_id, rlbs_session),
  FOREIGN KEY (rlbs_rlbk_id) REFERENCES emaj.emaj_rlbk (rlbk_id)
  );
COMMENT ON TABLE emaj.emaj_rlbk_session IS
$$Contains description of rollback events sessions.$$;

-- Table containing the elementary steps of rollback operations.
CREATE TABLE emaj.emaj_rlbk_plan (
  rlbp_rlbk_id                 INT         NOT NULL,       -- rollback id
  rlbp_step                    emaj._rlbk_step_enum
                                           NOT NULL,       -- kind of elementary step in the rollback processing
  rlbp_schema                  TEXT        NOT NULL,       -- schema object of the step
  rlbp_table                   TEXT        NOT NULL,       -- table name
  rlbp_object                  TEXT        NOT NULL,       -- foreign key name for step on foreign key, trigger name for step on trigger
                                                           -- or ''
  rlbp_batch_number            INT,                        -- identifies a set of tables linked by foreign keys
  rlbp_session                 INT,                        -- session number the step is affected to
  rlbp_object_def              TEXT,                       -- foreign key definition used to recreate it, or trigger type, or NULL
  rlbp_target_time_id          BIGINT,                     -- for RLBK_TABLE and DELETE_LOG, time_id to rollback to, or NULL
  rlbp_estimated_quantity      BIGINT,                     -- for RLBK_TABLE, estimated number of updates to rollback
                                                           -- for DELETE_LOG, estimated number of rows to delete
                                                           -- for fkeys, estimated number of keys to check
  rlbp_estimated_duration      INTERVAL,                   -- estimated elapse time for the step processing
  rlbp_estimate_method         INT,                        -- method used to compute the estimated duration
                                                           --  1: use rollback stats with volume in same order of magnitude
                                                           --  2: use all previous rollback stats
                                                           --  3: use only parameters (from emaj_param or default values)
  rlbp_start_datetime          TIMESTAMPTZ,                -- clock start time of the step, NULL is not yet started
  rlbp_quantity                BIGINT,                     -- for RLBK_TABLE, number of effectively rolled back updates
                                                           -- for DELETE_LOG, number of effectively deleted log rows
                                                           -- null for fkeys
  rlbp_duration                INTERVAL,                   -- real elapse time of the step, NULL is not yet completed
  PRIMARY KEY (rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object),
  FOREIGN KEY (rlbp_rlbk_id) REFERENCES emaj.emaj_rlbk (rlbk_id)
  );
COMMENT ON TABLE emaj.emaj_rlbk_plan IS
$$Contains description of elementary steps for rollback operations.$$;

-- Table containing statistics about previously executed rollback operations
-- and used to estimate rollback durations.
-- Depending on the step, it contains 1 row per elementary step (like 'RLBK_TABLE' or 'DELETE_LOG'),
-- or 1 row per type of step for 1 rollback operation (like 'DROP_FK', or 'DIS_LOG_TRG').
CREATE TABLE emaj.emaj_rlbk_stat (
  rlbt_step                    emaj._rlbk_step_enum
                                           NOT NULL,       -- kind of elementary step in the rollback processing
  rlbt_schema                  TEXT        NOT NULL,       -- schema object of the step
  rlbt_table                   TEXT        NOT NULL,       -- table name
  rlbt_object                  TEXT        NOT NULL,       -- foreign key name for step on foreign key, or trigger name for step on
                                                           -- triggers, or ''
  rlbt_rlbk_id                 INT         NOT NULL,       -- rollback id
  rlbt_quantity                BIGINT      NOT NULL,       -- depending on the step, either estimated quantity processed by the
                                                           -- elementary step or number of executed steps
  rlbt_duration                INTERVAL    NOT NULL,       -- duration or sum of durations of the elementary step(s)
  PRIMARY KEY (rlbt_step, rlbt_schema, rlbt_table, rlbt_object, rlbt_rlbk_id),
  FOREIGN KEY (rlbt_rlbk_id) REFERENCES emaj.emaj_rlbk (rlbk_id)
  );
COMMENT ON TABLE emaj.emaj_rlbk_stat IS
$$Contains statistics about previous E-Maj rollback durations.$$;

-- Table containing the list of appliction triggers on tables that should not be automatically disabled when launching a rollback
-- operation.
-- It is the administrator's responsibility to setup its content, using the emaj_ignore_app_trigger function.
CREATE TABLE emaj.emaj_ignored_app_trigger (
  trg_schema                   TEXT        NOT NULL,       -- application schema
  trg_table                    TEXT        NOT NULL,       -- application table
  trg_name                     TEXT        NOT NULL,       -- trigger name
  PRIMARY KEY (trg_schema, trg_table, trg_name)
  );
COMMENT ON TABLE emaj.emaj_ignored_app_trigger IS
$$Contains the triggers on application tables that do not need to be disabled when rollbacking.$$;

------------------------------------
--                                --
-- emaj composite types           --
--                                --
------------------------------------

-- Composite types usable by end-user.

CREATE TYPE emaj.emaj_log_stat_type AS (
  stat_group                   TEXT,                       -- group name owning the schema.table
  stat_schema                  TEXT,                       -- schema name
  stat_table                   TEXT,                       -- table name
  stat_first_mark              TEXT,                       -- mark representing the lower bound of the time range
  stat_first_mark_datetime     TIMESTAMPTZ,                -- clock timestamp of the mark representing the lower bound of the time range
  stat_last_mark               TEXT,                       -- mark representing the upper bound of the time range
  stat_last_mark_datetime      TIMESTAMPTZ,                -- clock timestamp of the mark representing the upper bound of the time range
  stat_rows                    BIGINT                      -- estimated number of update events recorded for this table
  );
COMMENT ON TYPE emaj.emaj_log_stat_type IS
$$Represents the structure of rows returned by the emaj_log_stat_group() function.$$;

CREATE TYPE emaj.emaj_detailed_log_stat_type AS (
  stat_group                   TEXT,                       -- group name owning the schema.table
  stat_schema                  TEXT,                       -- schema name
  stat_table                   TEXT,                       -- table name
  stat_first_mark              TEXT,                       -- mark representing the lower bound of the time range
  stat_first_mark_datetime     TIMESTAMPTZ,                -- clock timestamp of the mark representing the lower bound of the time range
  stat_last_mark               TEXT,                       -- mark representing the upper bound of the time range
  stat_last_mark_datetime      TIMESTAMPTZ,                -- clock timestamp of the mark representing the upper bound of the time range
  stat_role                    VARCHAR(32),                -- user having generated update events
  stat_verb                    VARCHAR(6),                 -- type of SQL statement (INSERT/UPDATE/DELETE)
  stat_rows                    BIGINT                      -- real number of update events recorded for this table
  );
COMMENT ON TYPE emaj.emaj_detailed_log_stat_type IS
$$Represents the structure of rows returned by the emaj_detailed_log_stat_group() function.$$;

CREATE TYPE emaj.emaj_rollback_activity_type AS (
  rlbk_id                      INT,                        -- rollback id
  rlbk_groups                  TEXT[],                     -- groups array to rollback
  rlbk_mark                    TEXT,                       -- mark to rollback to
  rlbk_mark_datetime           TIMESTAMPTZ,                -- timestamp of the mark as recorded into emaj_mark
  rlbk_is_logged               BOOLEAN,                    -- rollback type: true = logged rollback
  rlbk_is_alter_group_allowed  BOOLEAN,                    -- flag allowing to rollback to a mark set before alter group operations
  rlbk_nb_session              INT,                        -- number of requested sessions
  rlbk_nb_table                INT,                        -- total number of tables in groups
  rlbk_nb_sequence             INT,                        -- number of sequences to rollback
  rlbk_eff_nb_table            INT,                        -- number of tables with rows to rollback
  rlbk_status                  emaj._rlbk_status_enum,     -- rollback status
  rlbk_start_datetime          TIMESTAMPTZ,                -- clock timestamp of the rollback start recorded just after tables lock
  rlbk_elapse                  INTERVAL,                   -- elapse time since the begining of the execution
  rlbk_remaining               INTERVAL,                   -- estimated remaining time to complete the rollback
  rlbk_completion_pct          SMALLINT                    -- estimated percentage of the rollback operation
  );
COMMENT ON TYPE emaj.emaj_rollback_activity_type IS
$$Represents the structure of rows returned by the emaj_rollback_activity() function.$$;

CREATE TYPE emaj.emaj_consolidable_rollback_type AS (
  cons_group                   TEXT,                       -- group name
  cons_target_rlbk_mark_name   TEXT,                       -- name of the mark used as target of the logged rollback operation
  cons_target_rlbk_mark_time_id BIGINT,                    -- timestamp of the mark used as target of the logged rollback operation
  cons_end_rlbk_mark_name      TEXT,                       -- name of the mark set at the end of the logged rollback operation
  cons_end_rlbk_mark_time_id   BIGINT,                     -- timestamp of the mark set at the end of the logged rollback operation
  cons_rows                    BIGINT,                     -- estimated number of update events that can be consolidated for the rollback
  cons_marks                   INT                         -- number of marks that would be deleted by a consolidation
  );
COMMENT ON TYPE emaj.emaj_consolidable_rollback_type IS
$$Represents the structure of rows returned by the emaj_get_consolidable_rollbacks() function.$$;

-- composite types used by emaj internal functions or web clients.

CREATE TYPE emaj._verify_groups_type AS (                -- this type is not used by functions called by users
  ver_schema                   TEXT,
  ver_tblseq                   TEXT,
  ver_group                    TEXT,
  ver_msg                      TEXT
  );
COMMENT ON TYPE emaj._verify_groups_type IS
$$Represents the structure of rows returned by the internal _verify_groups() function.$$;

CREATE TYPE emaj._log_stat_type AS (
  stat_group                   TEXT,                       -- group name owning the schema.table
  stat_schema                  TEXT,                       -- schema name
  stat_table                   TEXT,                       -- table name
  stat_log_schema              TEXT,                       -- schema holding the log table
  stat_log_table               TEXT,                       -- log table
  stat_first_mark              TEXT,                       -- mark representing the lower bound of the time range
  stat_first_mark_datetime     TIMESTAMPTZ,                -- clock timestamp of the mark representing the lower bound of the time range
  stat_first_mark_gid          BIGINT,                     -- global sequence value at the lower bound of the time range
  stat_last_mark               TEXT,                       -- mark representing the upper bound of the time range
  stat_last_mark_datetime      TIMESTAMPTZ,                -- clock timestamp of the mark representing the upper bound of the time range
  stat_last_mark_gid           BIGINT,                     -- global sequence value at the upper bound of the time range
  stat_rows                    BIGINT                      -- estimated number of update events recorded for this table
  );
COMMENT ON TYPE emaj._log_stat_type IS
$$Represents the structure of rows returned by the _log_stat_groups() function.$$;

CREATE TYPE emaj._detailed_log_stat_type AS (
  stat_group                   TEXT,                       -- group name owning the schema.table
  stat_schema                  TEXT,                       -- schema name
  stat_table                   TEXT,                       -- table name
  stat_log_schema              TEXT,                       -- schema holding the log table
  stat_log_table               TEXT,                       -- log table
  stat_first_mark              TEXT,                       -- mark representing the lower bound of the time range
  stat_first_mark_datetime     TIMESTAMPTZ,                -- clock timestamp of the mark representing the lower bound of the time range
  stat_first_mark_gid          BIGINT,                     -- global sequence value at the lower bound of the time range
  stat_last_mark               TEXT,                       -- mark representing the upper bound of the time range
  stat_last_mark_datetime      TIMESTAMPTZ,                -- clock timestamp of the mark representing the upper bound of the time range
  stat_last_mark_gid           BIGINT,                     -- global sequence value at the upper bound of the time range
  stat_role                    VARCHAR(32),                -- user having generated update events
  stat_verb                    VARCHAR(6),                 -- type of SQL statement (INSERT/UPDATE/DELETE)
  stat_rows                    BIGINT                      -- real number of update events recorded for this table
  );
COMMENT ON TYPE emaj._detailed_log_stat_type IS
$$Represents the structure of rows returned by the _detailed_log_stat_groups() function.$$;

CREATE TYPE emaj._check_conf_groups_type AS (
  chk_msg_type                 INT,                        -- message number
  chk_severity                 INT,                        -- severity level: 1 = the error blocks any type group creation,
                                                           --                 2 = the error only blocks ROLLBACKABLE groups creation
  chk_group                    TEXT,                       -- group name
  chk_schema                   TEXT,                       -- schema name
  chk_tblseq                   TEXT,                       -- table or sequence name
  chk_extra_data               TEXT,                       -- additional piece of data that populates the error message, depending on the
                                                           -- message type
  chk_message                  TEXT                        -- the formatted error message
  );
COMMENT ON TYPE emaj._check_conf_groups_type IS
$$Represents the structure of rows returned by the _check_conf_groups() function.$$;

------------------------------------
--                                --
-- Parameters                     --
--                                --
------------------------------------
INSERT INTO emaj.emaj_param (param_key, param_value_text) VALUES ('emaj_version','<devel>');

-- Other parameters are optional. They may be set by E-Maj administrators if needed.

-- The dblink_user_password parameter defines the role and its associated password, if any, to establish a dblink
-- connection for the monitoring of rollback operations.
--   INSERT INTO emaj.emaj_param (param_key, param_value_text) VALUES ('dblink_user_password','user=<user> password=<password>');

-- The history_retention parameter defines the time interval when a row remains in the emaj history and rollback tables - default = 1 year.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('history_retention','1 year'::INTERVAL);

-- 6 parameters are used by the emaj_estimate_rollback_group(s) and the rollback functions as default values to compute the approximate
-- duration of a rollback operation.
-- The avg_row_rollback_duration parameter defines the average duration needed to rollback a row.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('avg_row_rollback_duration','100 microsecond'::INTERVAL);
-- The avg_row_delete_log_duration parameter defines the average duration needed to delete log rows.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('avg_row_delete_log_duration','10 microsecond'::INTERVAL);
-- The avg_fkey_check_duration parameter defines the average duration needed to check a foreign key.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('avg_fkey_check_duration','20 microsecond'::INTERVAL);
-- The fixed_step_rollback_duration parameter defines the fixed cost for any elementary rollback step.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('fixed_step_rollback_duration','2.5 millisecond'::INTERVAL);
-- The fixed_table_rollback_duration parameter defines the fixed rollback cost for any table or sequence belonging to a group.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('fixed_table_rollback_duration','1 millisecond'::INTERVAL);
-- The fixed_dblink_rollback_duration parameter defines the fixed cost of dblink use for any rollback step.
--   INSERT INTO emaj.emaj_param (param_key, param_value_interval) VALUES ('fixed_dblink_rollback_duration','4 millisecond'::INTERVAL);

-- A parameter allowing to adjust the log tables content by adding extra information column.
--   INSERT INTO emaj.emaj_param (param_key, param_value_text) VALUES ('alter_log_table',
--     'ADD COLUMN emaj_user_ip INET DEFAULT inet_client_addr(),
--      ADD COLUMN emaj_appname TEXT DEFAULT current_setting(''application_name'')');

-- view readable by emaj_viewer role. It hides the 'dblink_user_password' parameter's value
CREATE VIEW emaj.emaj_visible_param WITH (security_barrier) AS
  SELECT param_key,
         CASE WHEN param_key = 'dblink_user_password' THEN '<masked data>'
                                                      ELSE param_value_text END AS param_value_text,
         param_value_numeric, param_value_boolean, param_value_interval
  FROM emaj.emaj_param;

------------------------------------
--                                --
-- Triggers on internal tables    --
--                                --
------------------------------------

-- Triggers for changes and truncate on the emaj_group_def table.

CREATE OR REPLACE FUNCTION emaj._emaj_group_def_change_fnct()
RETURNS TRIGGER LANGUAGE plpgsql AS
$_emaj_group_def_change_fnct$
-- This function is associated to the emaj_emaj_group_def_change_trg trigger set on the emaj_group_def table.
-- It sets the group_has_waiting_changes boolean column of the emaj_group table to TRUE when a change is recorded into the emaj_group_def
--   table.
-- If the group doesn't exists (yet), the update statements will silently not update any row
  BEGIN
    IF (TG_OP = 'DELETE') THEN
      UPDATE emaj.emaj_group SET group_has_waiting_changes = TRUE
        WHERE group_name = OLD.grpdef_group;
      RETURN OLD;
    ELSIF (TG_OP = 'UPDATE') THEN
      UPDATE emaj.emaj_group SET group_has_waiting_changes = TRUE
        WHERE group_name = OLD.grpdef_group OR group_name = NEW.grpdef_group;
      RETURN NEW;
    ELSIF (TG_OP = 'INSERT') THEN
      UPDATE emaj.emaj_group SET group_has_waiting_changes = TRUE
        WHERE group_name = NEW.grpdef_group;
      RETURN NEW;
    ELSIF (TG_OP = 'TRUNCATE') THEN
      UPDATE emaj.emaj_group SET group_has_waiting_changes = TRUE;
      RETURN NULL;
    END IF;
    RETURN NULL;
  END;
$_emaj_group_def_change_fnct$;

CREATE TRIGGER emaj_group_def_change_trg
  AFTER INSERT OR UPDATE OR DELETE  ON emaj.emaj_group_def
  FOR EACH ROW EXECUTE PROCEDURE emaj._emaj_group_def_change_fnct();

CREATE TRIGGER emaj_group_def_truncate_trg
  AFTER TRUNCATE ON emaj.emaj_group_def
  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._emaj_group_def_change_fnct();

------------------------------------
--                                --
-- Low level Functions            --
--                                --
------------------------------------
CREATE OR REPLACE FUNCTION emaj._pg_version_num()
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS
$$
-- This function returns as an integer the current postgresql version.
SELECT current_setting('server_version_num')::INT;
$$;

CREATE OR REPLACE FUNCTION emaj._set_time_stamp(v_timeStampType CHAR(1))
RETURNS BIGINT LANGUAGE SQL AS
$$
-- This function inserts a new time stamp in the emaj_time_stamp table and returns the identifier of the new row.
INSERT INTO emaj.emaj_time_stamp (time_last_emaj_gid, time_event)
  SELECT CASE WHEN is_called THEN last_value ELSE last_value - 1 END, v_timeStampType FROM emaj.emaj_global_seq
  RETURNING time_id;
$$;

CREATE OR REPLACE FUNCTION emaj._dblink_open_cnx(v_cnxName TEXT, OUT v_status INT, OUT v_schema TEXT)
LANGUAGE plpgsql AS
$_dblink_open_cnx$
-- This function tries to open a named dblink connection.
-- It uses as target: the current cluster (port), the current database and a role defined in the emaj_param table.
-- This connection role must be defined in the emaj_param table with a row having:
--   - param_key = 'dblink_user_password',
--   - param_value_text = 'user=<user> password=<password>' with the rules that apply to usual libPQ connect strings.
-- The password can be omited if the connection doesn't require it.
-- The dblink_connect_u is used to open the connection so that emaj_adm but non superuser roles can access the
--    cluster even when no password is required to log on.
-- The function is directly called by Emaj_web.
-- Input:  connection name
-- Output: integer status return.
--           1 successful connection
--           0 already opened connection
--          -1 dblink is not installed
--          -2 dblink functions are not visible for the session (obsolete)
--          -3 dblink functions execution is not granted to the role
--          -4 the transaction isolation level is not READ COMMITTED
--          -5 no 'dblink_user_password' parameter is defined in the emaj_param table
--          -6 error at dblink_connect() call
--         name of the schema that holds the dblink extension (used later to schema qualify all calls to dblink functions)
  DECLARE
    v_nbCnx                  INT;
    v_UserPassword           TEXT;
    v_connectString          TEXT;
  BEGIN
-- look for the schema holding the dblink functions
--   (NULL if the dblink_connect_u function is not available, which should not happen)
    SELECT nspname INTO v_schema FROM pg_catalog.pg_proc, pg_catalog.pg_namespace
      WHERE pronamespace = pg_namespace.oid AND proname = 'dblink_connect_u'
      LIMIT 1;
    IF NOT FOUND THEN
      v_status = -1;                      -- dblink is not installed
    ELSIF NOT has_function_privilege(quote_ident(v_schema) || '.dblink_connect_u(text, text)', 'execute') THEN
      v_status = -3;                      -- current role has not the execute rights on dblink functions
    ELSIF substring(v_cnxName FROM 1 FOR 5) = 'rlbk#' AND
          current_setting('transaction_isolation') <> 'read committed' THEN
      v_status = -4;                      -- 'rlbk#*' connection (used for rollbacks) must only come from a
                                          --   READ COMMITTED transaction
    ELSE
      EXECUTE format('SELECT 0 WHERE %L = ANY (%I.dblink_get_connections())',
                     v_cnxName, v_schema);
      GET DIAGNOSTICS v_nbCnx = ROW_COUNT;
      IF v_nbCnx > 0 THEN
-- dblink is usable, so search the requested connection name in dblink connections list
        v_status = 0;                       -- the requested connection is already open
      ELSE
-- so, get the 'dblink_user_password' parameter if exists, from emaj_param
        SELECT param_value_text INTO v_UserPassword FROM emaj.emaj_param WHERE param_key = 'dblink_user_password';
        IF NOT FOUND THEN
          v_status = -5;                    -- no 'dblink_user_password' parameter is defined in the emaj_param table
        ELSE
-- ... build the connect string
          v_connectString = 'host=localhost port=' || current_setting('port') ||
                            ' dbname=' || current_database() || ' ' || v_userPassword;
-- ... and try to connect
          BEGIN
            EXECUTE format('SELECT %I.dblink_connect_u(%L ,%L)',
                           v_schema, v_cnxName, v_connectString);
            v_status = 1;                 -- the connection is successful
          EXCEPTION
            WHEN OTHERS THEN
              v_status = -6;              -- the connection attempt failed
          END;
        END IF;
      END IF;
    END IF;
-- for connections used for rollback operations, record the dblink connection attempt in the emaj_hist table
    IF substring(v_cnxName FROM 1 FOR 5) = 'rlbk#' THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
        VALUES ('DBLINK_OPEN_CNX', v_cnxName, 'Status = ' || v_status);
    END IF;
    RETURN;
  END;
$_dblink_open_cnx$;

CREATE OR REPLACE FUNCTION emaj._dblink_sql_exec(v_cnxName TEXT, v_stmt TEXT, v_dblinkSchema TEXT)
RETURNS BIGINT LANGUAGE plpgsql AS
$_dblink_sql_exec$
-- This function executes a SQL statement, either through an opened dblink connection when a schema name is provided or directly.
-- It returns a bigint value. Consequently, all SQL statements to execute must return an integer numeric value.
-- Input:  connection name
--         sql statement
--         name of the schema that holds the dblink extension
-- Output: the single return value
  DECLARE
    v_returnValue            BIGINT;
  BEGIN
    IF v_dblinkSchema IS NOT NULL THEN
-- a dblink schema is provided, so the connection name can be used to execute the requested SQL statement
      EXECUTE format('SELECT return_value FROM %I.dblink(%L, %L) AS (return_value BIGINT)',
                     v_dblinkSchema, v_cnxName, v_stmt)
        INTO v_returnValue;
    ELSE
-- the SQL statement has to be directly executed
      EXECUTE v_stmt INTO v_returnValue;
    END IF;
    RETURN v_returnValue;
  END;
$_dblink_sql_exec$;

CREATE OR REPLACE FUNCTION emaj._dblink_close_cnx(v_cnxName TEXT, v_dblinkSchema TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_dblink_close_cnx$
-- This function closes a named dblink connection.
-- The function is directly called by Emaj_web.
-- Input:  connection name
  DECLARE
    v_nbCnx                  INT;
  BEGIN
-- check the dblink connection exists
    EXECUTE format('SELECT 0 WHERE %L = ANY (%I.dblink_get_connections())',
                   v_cnxName, v_dblinkSchema);
    GET DIAGNOSTICS v_nbCnx = ROW_COUNT;
    IF v_nbCnx > 0 THEN
-- the connection exists, so disconnect
      EXECUTE format('SELECT %I.dblink_disconnect(%L)',
                     v_dblinkSchema, v_cnxName);
-- for connections used for rollback operations, record the dblink disconnection in the emaj_hist table
      IF substring(v_cnxName FROM 1 FOR 5) = 'rlbk#' THEN
        INSERT INTO emaj.emaj_hist (hist_function, hist_object)
          VALUES ('DBLINK_CLOSE_CNX', v_cnxName);
      END IF;
    END IF;
    RETURN;
  END;
$_dblink_close_cnx$;

CREATE OR REPLACE FUNCTION emaj._get_default_tablespace()
RETURNS TEXT LANGUAGE plpgsql AS
$_get_default_tablespace$
-- This function returns the name of a default tablespace to use when moving an existing log table or index.
-- Output: tablespace name
-- The function is called at alter group time.
  DECLARE
    v_tablespace             TEXT;
  BEGIN
-- get the default tablespace set for the current session or set for the entire instance by GUC
    SELECT setting INTO v_tablespace FROM pg_settings
      WHERE name = 'default_tablespace';
    IF v_tablespace = '' THEN
-- get the default tablespace for the current database (pg_default if no specific tablespace name has been set for the database)
      SELECT spcname INTO v_tablespace FROM pg_database, pg_tablespace
        WHERE dattablespace = pg_tablespace.oid AND datname = current_database();
    END IF;
    RETURN v_tablespace;
  END;
$_get_default_tablespace$;

CREATE OR REPLACE FUNCTION emaj._purge_hist()
RETURNS VOID LANGUAGE plpgsql AS
$_purge_hist$
-- This function purges the emaj history by deleting all rows prior the 'history_retention' parameter, but
--   not deleting event traces neither after the oldest active mark or after the oldest not committed or aborted rollback operation.
-- It also purges oldest rows from the maj_exec_plan, emaj_rlbk_session and emaj_rlbk_plan tables, using the same rules.
-- The function is called at start group time and when oldest marks are deleted.
  DECLARE
    v_datetimeLimit          TIMESTAMPTZ;
    v_maxTimeId              BIGINT;
    v_maxRlbkId              BIGINT;
    v_nbPurgedHist           BIGINT;
    v_nbPurgedRelHist        BIGINT;
    v_nbPurgedRlbk           BIGINT;
    v_nbPurgedAlter          BIGINT;
    v_wording                TEXT = '';
  BEGIN
-- compute the timestamp limit
    SELECT min(datetime) INTO v_datetimeLimit FROM
      (                                           -- compute the timestamp limit from the history_retention parameter
        (SELECT current_timestamp -
           coalesce((SELECT param_value_interval FROM emaj.emaj_param WHERE param_key = 'history_retention'),'1 YEAR'))
      UNION ALL                                   -- get the transaction timestamp of the oldest non deleted mark for all groups
        (SELECT min(time_tx_timestamp) FROM emaj.emaj_time_stamp, emaj.emaj_mark
           WHERE time_id = mark_time_id AND NOT mark_is_deleted)
      UNION ALL                                   -- get the transaction timestamp of the oldest non committed or aborted rollback
        (SELECT min(time_tx_timestamp) FROM emaj.emaj_time_stamp, emaj.emaj_rlbk
           WHERE time_id = rlbk_time_id AND rlbk_status IN ('PLANNING', 'LOCKING', 'EXECUTING', 'COMPLETED'))
      ) AS t(datetime);
-- get the greatest timestamp identifier corresponding to the timeframe to purge, if any
    SELECT max(time_id) INTO v_maxTimeId FROM emaj.emaj_time_stamp
      WHERE time_tx_timestamp < v_datetimeLimit;
-- delete oldest rows from emaj_hist
    DELETE FROM emaj.emaj_hist WHERE hist_datetime < v_datetimeLimit;
    GET DIAGNOSTICS v_nbPurgedHist = ROW_COUNT;
    IF v_nbPurgedHist > 0 THEN
      v_wording = v_nbPurgedHist || ' emaj_hist rows deleted';
    END IF;
-- delete oldest rows from emaj_rel_hist
    DELETE FROM emaj.emaj_rel_hist WHERE upper(relh_time_range) < v_maxTimeId;
    GET DIAGNOSTICS v_nbPurgedRelHist = ROW_COUNT;
    IF v_nbPurgedRelHist > 0 THEN
      v_wording = v_wording || ' ; ' || v_nbPurgedRelHist || ' relation history rows deleted';
    END IF;
-- purge the emaj_alter_plan table
    WITH deleted_alter AS (
      DELETE FROM emaj.emaj_alter_plan
        WHERE altr_time_id <= v_maxTimeId
        RETURNING altr_time_id
      )
      SELECT COUNT (DISTINCT altr_time_id) INTO v_nbPurgedAlter FROM deleted_alter;
    IF v_nbPurgedAlter > 0 THEN
      v_wording = v_wording || ' ; ' || v_nbPurgedAlter || ' alter groups events deleted';
    END IF;
-- get the greatest rollback identifier to purge
    SELECT max(rlbk_id) INTO v_maxRlbkId FROM emaj.emaj_rlbk
      WHERE rlbk_time_id <= v_maxTimeId;
-- and purge the emaj_rlbk_plan and emaj_rlbk_session tables
    IF v_maxRlbkId IS NOT NULL THEN
      DELETE FROM emaj.emaj_rlbk_plan WHERE rlbp_rlbk_id <= v_maxRlbkId;
      WITH deleted_rlbk AS (
        DELETE FROM emaj.emaj_rlbk_session
          WHERE rlbs_rlbk_id <= v_maxRlbkId
          RETURNING rlbs_rlbk_id
        )
        SELECT COUNT (DISTINCT rlbs_rlbk_id) INTO v_nbPurgedRlbk FROM deleted_rlbk;
      v_wording = v_wording || ' ; ' || v_nbPurgedRlbk || ' rollback events deleted';
    END IF;
-- record the purge into the history if there are significant data
    IF v_wording <> '' THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_wording)
        VALUES ('PURGE_HISTORY', v_wording);
    END IF;
    RETURN;
  END;
$_purge_hist$;

CREATE OR REPLACE FUNCTION emaj._check_group_names(v_groupNames TEXT[], v_mayBeNull BOOLEAN, v_lockGroups BOOLEAN, v_checkList TEXT)
RETURNS TEXT[] LANGUAGE plpgsql AS
$_check_group_names$
-- This function performs various checks on a group names array.
-- The NULL, empty strings and duplicate values are removed from the array. If the array is empty raise either an exception or a warning.
-- Checks are then perform to verify:
-- - that all groups exist,
-- - if requested are ROLLBACKABLE,
-- - if requested are in LOGGING or IDLE state,
-- - if requested are not PROTECTED against rollback operations.
-- A SELECT FOR UPDATE is executed if requested, to avoid other sensitive actions in parallel on the same groups.
-- Input: group names array,
--        a boolean that tells whether a NULL array only raise a WARNING,
--        a boolean that tells whether the groups have to be locked,
--        a string that lists the checks to perform, with the following possible values: IDLE, LOGGING, ROLLBACKABLE and UNPROTECTED.
-- Output: validated group names array
  DECLARE
    v_groupList              TEXT;
    v_count                  INT;
  BEGIN
-- remove duplicates values, NULL and empty strings from the supplied group names array
    SELECT array_agg(DISTINCT group_name) INTO v_groupNames FROM unnest(v_groupNames) AS group_name
      WHERE group_name IS NOT NULL AND group_name <> '';
-- process empty array
    IF v_groupNames IS NULL THEN
      IF v_mayBeNull THEN
        RAISE WARNING '_check_group_names: No group to process.';
        RETURN NULL;
      ELSE
        RAISE EXCEPTION '_check_group_names: No group to process.';
      END IF;
    END IF;
-- check that all groups exist
    SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM
      (SELECT unnest(v_groupNames) EXCEPT SELECT group_name FROM emaj.emaj_group) AS t(group_name);
    IF v_count > 0 THEN
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_group_names: The group "%" does not exist.', v_groupList;
      ELSE
        RAISE EXCEPTION '_check_group_names: The groups "%" do not exist.', v_groupList;
      END IF;
    END IF;
-- lock the groups if requested
    IF v_lockGroups THEN
      PERFORM 0 FROM emaj.emaj_group WHERE group_name = ANY(v_groupNames) FOR UPDATE;
    END IF;
-- checks ROLLBACKABLE type, if requested
    IF strpos(v_checkList,'ROLLBACKABLE') > 0 THEN
      SELECT string_agg(group_name,', '  ORDER BY group_name), count(*) INTO v_groupList, v_count FROM emaj.emaj_group
        WHERE group_name = ANY(v_groupNames) AND NOT group_is_rollbackable;
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_group_names: The group "%" has been created as AUDIT_ONLY.', v_groupList;
      END IF;
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_group_names: The groups "%" have been created as AUDIT_ONLY.', v_groupList;
      END IF;
    END IF;
-- checks IDLE state, if requested
    IF strpos(v_checkList,'IDLE') > 0 THEN
      SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM emaj.emaj_group
        WHERE group_name = ANY(v_groupNames) AND group_is_logging;
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_group_names: The group "%" is not in IDLE state.', v_groupList;
      END IF;
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_group_names: The groups "%" are not in IDLE state.', v_groupList;
      END IF;
    END IF;
-- checks LOGGING state, if requested
    IF strpos(v_checkList,'LOGGING') > 0 THEN
      SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM emaj.emaj_group
        WHERE group_name = ANY(v_groupNames) AND NOT group_is_logging;
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_group_names: The group "%" is not in LOGGING state.', v_groupList;
      END IF;
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_group_names: The groups "%" are not in LOGGING state.', v_groupList;
      END IF;
    END IF;
-- checks UNPROTECTED type, if requested
    IF strpos(v_checkList,'UNPROTECTED') > 0 THEN
      SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM emaj.emaj_group
        WHERE group_name = ANY(v_groupNames) AND group_is_rlbk_protected;
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_group_names: The group "%" is currently protected against rollback operations.', v_groupList;
      END IF;
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_group_names: The groups "%" are currently protected against rollback operations.', v_groupList;
      END IF;
    END IF;
    RETURN v_groupNames;
  END;
$_check_group_names$;

CREATE OR REPLACE FUNCTION emaj._check_conf_groups(v_groupNames TEXT[])
RETURNS SETOF emaj._check_conf_groups_type LANGUAGE plpgsql AS
$_check_conf_groups$
-- This function verifies that the content of tables group as defined into the emaj_group_def table is correct.
-- Any detected issue is reported as a message row. The caller defines what to do with them, depending on the tables group type.
-- It is called by the emaj_create_group() and _alter_groups() functions.
-- This function checks that the referenced application tables and sequences:
--  - exist,
--  - is not located into an E-Maj schema (to protect against an E-Maj recursive use),
--  - do not already belong to another tables group,
--  - will not generate conflicts on emaj objects to create (when emaj names prefix is not the default one)
-- It also checks that:
--  - tables are not TEMPORARY
--  - for rollbackable groups, tables are not UNLOGGED or WITH OIDS
--  - for rollbackable groups, all tables have a PRIMARY KEY
--  - for sequences, the tablespaces and emaj priority are all set to NULL
--  - for tables, configured tablespaces exist
-- The function is directly called by Emaj_web.
-- Input: name array of the tables groups to check
  BEGIN
-- check that all application tables and sequences listed for the group really exist
    RETURN QUERY
      SELECT 1, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, the table or sequence %s.%s does not exist.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def
        WHERE grpdef_group = ANY(v_groupNames)
          AND NOT EXISTS (
            SELECT 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace
              WHERE relnamespace = pg_namespace.oid
                AND grpdef_schema = nspname AND grpdef_tblseq = relname
                AND relkind IN ('r','S','p'));
---- check that no application table is a partitioned table (only elementary partitions can be managed by E-Maj)
    RETURN QUERY
      SELECT 2, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, the table %s.%s is a partitionned table (only elementary partitions are supported by E-Maj).',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid AND nspname = grpdef_schema AND relname = grpdef_tblseq
          AND grpdef_group = ANY(v_groupNames)
          AND relkind = 'p';
---- check no application schema listed for the group in the emaj_group_def table is an E-Maj schema
    RETURN QUERY
      SELECT 3, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, the table or sequence %s.%s belongs to an E-Maj schema.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, emaj.emaj_schema
        WHERE grpdef_group = ANY(v_groupNames)
          AND grpdef_schema = sch_name;
---- check that no table or sequence of the checked groups already belongs to other created groups
    RETURN QUERY
      SELECT 4, 1, grpdef_group, grpdef_schema, grpdef_tblseq, rel_group,
             format('in the group %s, the table or sequence %s.%s already belongs to the group %s.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq), quote_ident(rel_group))
        FROM emaj.emaj_group_def, emaj.emaj_relation
        WHERE grpdef_schema = rel_schema AND grpdef_tblseq = rel_tblseq
          AND upper_inf(rel_time_range) AND grpdef_group = ANY (v_groupNames) AND NOT rel_group = ANY (v_groupNames);
---- check no table is a TEMP table
    RETURN QUERY
      SELECT 5, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, the table %s.%s is a TEMPORARY table.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'r' AND relpersistence = 't';
---- check that a table is not assigned several time in the groups
    RETURN QUERY
      WITH dupl AS (
        SELECT grpdef_schema, grpdef_tblseq, count(*)
          FROM emaj.emaj_group_def
          WHERE grpdef_group = ANY (v_groupNames)
          GROUP BY 1,2 HAVING count(*) > 1)
      SELECT 10, 1, v_groupNames[1], grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('the table %s.%s is assigned several times.',
                    quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM dupl;
---- check that the log data tablespaces for tables exist
    RETURN QUERY
      SELECT 12, 1, grpdef_group, grpdef_schema, grpdef_tblseq, grpdef_log_dat_tsp,
             format('in the group %s, for the table %s.%s, the data log tablespace %s does not exist.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq), quote_ident(grpdef_log_dat_tsp))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'r' AND grpdef_log_dat_tsp IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname = grpdef_log_dat_tsp);
---- check that the log index tablespaces for tables exist
    RETURN QUERY
      SELECT 13, 1, grpdef_group, grpdef_schema, grpdef_tblseq, grpdef_log_idx_tsp,
             format('in the group %s, for the table %s.%s, the index log tablespace %s does not exist.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq), quote_ident(grpdef_log_idx_tsp))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'r' AND grpdef_log_idx_tsp IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname = grpdef_log_idx_tsp);
---- check no table is an unlogged table (blocking rollbackable groups only)
    RETURN QUERY
      SELECT 20, 2, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, the table %s.%s is an UNLOGGED table.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'r' AND relpersistence = 'u';
---- with PG11- check no table is a WITH OIDS table (blocking rollbackable groups only)
    IF emaj._pg_version_num() < 120000 THEN
      RETURN QUERY
        SELECT 21, 2, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
               format('in the group %s, the table %s.%s is declared WITH OIDS.',
                      quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
          FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
          WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
            AND grpdef_group = ANY (v_groupNames) AND relkind = 'r' AND relhasoids;
    END IF;
---- check every table has a primary key (blocking rollbackable groups only)
    RETURN QUERY
      SELECT 22, 2, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, the table %s.%s has no PRIMARY KEY.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'r'
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_constraint
                            WHERE relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid
                            AND contype = 'p' AND nspname = grpdef_schema AND relname = grpdef_tblseq);
---- all sequences described in emaj_group_def have their priority attribute set to NULL
    RETURN QUERY
      SELECT 31, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, for the sequence %s.%s, the priority is not NULL.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'S' AND grpdef_priority IS NOT NULL;
---- all sequences described in emaj_group_def have their data log tablespace attribute set to NULL
    RETURN QUERY
      SELECT 32, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, for the sequence %s.%s, the data log tablespace is not NULL.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'S' AND grpdef_log_dat_tsp IS NOT NULL;
---- all sequences described in emaj_group_def have their index log tablespace attribute set to NULL
    RETURN QUERY
      SELECT 33, 1, grpdef_group, grpdef_schema, grpdef_tblseq, NULL::TEXT,
             format('in the group %s, for the sequence %s.%s, the index log tablespace is not NULL.',
                    quote_ident(grpdef_group), quote_ident(grpdef_schema), quote_ident(grpdef_tblseq))
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_schema = nspname AND grpdef_tblseq = relname AND relnamespace = pg_namespace.oid
          AND grpdef_group = ANY (v_groupNames) AND relkind = 'S' AND grpdef_log_idx_tsp IS NOT NULL;
--
    RETURN;
  END;
$_check_conf_groups$;

CREATE OR REPLACE FUNCTION emaj._check_mark_name(v_groupNames TEXT[], v_mark TEXT, v_checkList TEXT)
RETURNS TEXT LANGUAGE plpgsql AS
$_check_mark_name$
-- This function verifies that a mark name exists for one or several groups.
-- It processes the EMAJ_LAST_MARK keyword.
-- When several groups are supplied, it checks that the mark represents the same point in time for all groups.
-- Input: array of group names, name of the mark to check, list of checks to perform (currently only 'ACTIVE')
-- Output: internal name of the mark
  DECLARE
    v_markName               TEXT = v_mark;
    v_groupList              TEXT;
    v_count                  INTEGER;
  BEGIN
-- process the 'EMAJ_LAST_MARK' keyword, if needed
    IF v_mark = 'EMAJ_LAST_MARK' THEN
-- detect groups that have no recorded mark
      SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM
        (SELECT unnest(v_groupNames) EXCEPT SELECT mark_group FROM emaj.emaj_mark) AS t(group_name);
      IF v_count > 0 THEN
        IF v_count = 1 THEN
          RAISE EXCEPTION '_check_mark_name: The group "%" has no mark.', v_groupList;
        ELSE
          RAISE EXCEPTION '_check_mark_name: The groups "%" have no mark.', v_groupList;
        END IF;
      END IF;
-- count the number of distinct lastest mark_time_id for all concerned groups
      SELECT count(DISTINCT mark_time_id) INTO v_count FROM
        (SELECT mark_group, max(mark_time_id) AS mark_time_id FROM emaj.emaj_mark
           WHERE mark_group = ANY (v_groupNames) GROUP BY 1) AS t;
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_mark_name: The EMAJ_LAST_MARK does not represent the same point in time for all groups.';
      END IF;
-- get the name of the last mark for the first group in the array, as we now know that all groups share the same last mark
      SELECT mark_name INTO v_markName FROM emaj.emaj_mark
        WHERE mark_group = v_groupNames[1] ORDER BY mark_time_id DESC LIMIT 1;
    ELSE
-- for usual mark name (i.e. not EMAJ_LAST_MARK)
-- check that the mark exists for all groups
      SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM
        (SELECT unnest(v_groupNames) EXCEPT SELECT mark_group FROM emaj.emaj_mark WHERE mark_name = v_markName) AS t(group_name);
      IF v_count > 0 THEN
        IF v_count = 1 THEN
          RAISE EXCEPTION '_check_mark_name: The mark "%" does not exist for the group "%".', v_markName, v_groupList;
        ELSE
          RAISE EXCEPTION '_check_mark_name: The mark "%" does not exist for the groups "%".', v_markName, v_groupList;
        END IF;
      END IF;
-- check that the mark represents the same point in time for all groups
      SELECT count(DISTINCT mark_time_id) INTO v_count FROM emaj.emaj_mark
        WHERE mark_name = v_markName AND mark_group = ANY (v_groupNames);
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_mark_name: The mark "%" does not represent the same point in time for all groups.', v_markName;
      END IF;
    END IF;
-- if requested, check the mark is active for all groups
    IF strpos(v_checkList,'ACTIVE') > 0 THEN
      SELECT string_agg(mark_group,', ' ORDER BY mark_group), count(*) INTO v_groupList, v_count FROM emaj.emaj_mark
        WHERE mark_name = v_markName AND mark_group = ANY(v_groupNames) AND mark_is_deleted;
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_mark_name: For the group "%", the mark "%" is DELETED.', v_groupList, v_markName;
      END IF;
      IF v_count > 1 THEN
        RAISE EXCEPTION '_check_mark_name: For the groups "%", the mark "%" is DELETED.', v_groupList, v_markName;
      END IF;
    END IF;
    RETURN v_markName;
  END;
$_check_mark_name$;

CREATE OR REPLACE FUNCTION emaj._check_new_mark(v_groupNames TEXT[], v_mark TEXT)
RETURNS TEXT LANGUAGE plpgsql AS
$_check_new_mark$
-- This function verifies that a new mark name supplied the user is valid.
-- It processes the possible NULL mark value and the replacement of % wild characters.
-- It also checks that the mark name do not already exist for any group.
-- Input: array of group names, name of the mark to set
-- Output: internal name of the mark
  DECLARE
    v_markName               TEXT = v_mark;
    v_groupList              TEXT;
    v_count                  INTEGER;
  BEGIN
-- check the mark name is not 'EMAJ_LAST_MARK'
    IF v_mark = 'EMAJ_LAST_MARK' THEN
       RAISE EXCEPTION '_check_new_mark: "%" is not an allowed name for a new mark.', v_mark;
    END IF;
-- process null or empty supplied mark name
    IF v_markName = '' OR v_markName IS NULL THEN
      v_markName = 'MARK_%';
    END IF;
-- process % wild characters in mark name
    v_markName = replace(v_markName, '%', substring(to_char(clock_timestamp(), 'HH24.MI.SS.US') from 1 for 13));
-- check that the mark does not exist for any groups
    SELECT string_agg(mark_group,', ' ORDER BY mark_group), count(*) INTO v_groupList, v_count
      FROM emaj.emaj_mark WHERE mark_name = v_markName AND mark_group = ANY(v_groupNames);
    IF v_count > 0 THEN
      IF v_count = 1 THEN
        RAISE EXCEPTION '_check_new_mark: The group "%" already contains a mark named "%".', v_groupList, v_markName;
      ELSE
        RAISE EXCEPTION '_check_new_mark: The groups "%" already contain a mark named "%".', v_groupList, v_markName;
      END IF;
    END IF;
    RETURN v_markName;
  END;
$_check_new_mark$;

CREATE OR REPLACE FUNCTION emaj._check_marks_range(v_groupNames TEXT[], INOUT v_firstMark TEXT, INOUT v_lastMark TEXT,
                                                   OUT v_firstMarkTimeId BIGINT, OUT v_lastMarkTimeId BIGINT)
LANGUAGE plpgsql AS
$_check_marks_range$
-- This function verifies that a marks range is valid for one or several groups.
-- It checks that both marks defining the bounds exist and are in chronological order.
-- It processes the EMAJ_LAST_MARK keyword.
-- If the first mark (lower bound) is NULL, find the first (deleted or not) mark known for each group.
-- A last mark (upper bound) set to NULL means "the current situation". In this case, no specific checks is performed.
-- When several groups are supplied, it checks that the marks represent the same point in time for all groups.
-- Input: array of group names, name of the first mark, name of the last mark
-- Output: internal name and time id of both marks
  DECLARE
    v_groupList              TEXT;
    v_count                  INTEGER;
    v_firstMarkTs            TIMESTAMPTZ;
    v_lastMarkTs             TIMESTAMPTZ;
  BEGIN
-- if the first mark is NULL or empty, look for the first known mark for the group
    IF v_firstMark IS NULL OR v_firstMark = '' THEN
-- detect groups that have no recorded mark
      SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM
        (SELECT unnest(v_groupNames) EXCEPT SELECT mark_group FROM emaj.emaj_mark) AS t(group_name);
      IF v_count > 0 THEN
        IF v_count <> array_length(v_groupNames, 1) THEN
-- some but not all groups have no mark
          IF v_count = 1 THEN
            RAISE EXCEPTION '_check_marks_range: The group "%" has no mark.', v_groupList;
          ELSE
            RAISE EXCEPTION '_check_marks_range: The groups "%" have no mark.', v_groupList;
          END IF;
        ELSE
-- all groups have no mark, force the first mark to NULL to be able to return statistics with 0 row
          v_firstMark = NULL;
        END IF;
      ELSE
-- all groups have at least 1 mark
-- count the number of distinct first mark_time_id for all concerned groups
        SELECT count(DISTINCT mark_time_id) INTO v_count FROM
          (SELECT mark_group, min(mark_time_id) AS mark_time_id FROM emaj.emaj_mark
             WHERE mark_group = ANY (v_groupNames) GROUP BY 1) AS t;
        IF v_count > 1 THEN
          RAISE EXCEPTION '_check_marks_range: The oldest marks of each group do not represent the same point in time.';
        END IF;
-- count the number of distinct first mark name for all concerned groups
        SELECT min(mark_time_id) INTO v_firstMarkTimeId
          FROM emaj.emaj_mark WHERE mark_group = v_groupNames[1];
        SELECT count(DISTINCT mark_name) INTO v_count
          FROM emaj.emaj_mark WHERE mark_group = ANY (v_groupNames) AND mark_time_id = v_firstMarkTimeId;
        IF v_count > 1 THEN
          RAISE EXCEPTION '_check_marks_range: The oldest marks of each group have not the same name.';
        END IF;
-- get the name of the first mark for the first group in the array, as we now know that all groups share the same first mark
        SELECT mark_name INTO v_firstMark FROM emaj.emaj_mark
          WHERE mark_group = v_groupNames[1] ORDER BY mark_time_id LIMIT 1;
      END IF;
    ELSE
-- checks the supplied first mark
      SELECT emaj._check_mark_name (v_groupNames := v_groupNames, v_mark := v_firstMark, v_checkList := '') INTO v_firstMark;
    END IF;
-- get some time data about the first mark (that may be NULL)
-- (use the first group of the array, as we are now sure that all groups share the same mark)
    SELECT mark_time_id, time_clock_timestamp INTO v_firstMarkTimeId, v_firstMarkTs
      FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupNames[1] AND mark_name = v_firstMark;
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
-- if the last mark is not NULL or empty, check it
      SELECT emaj._check_mark_name (v_groupNames := v_groupNames, v_mark := v_lastMark, v_checkList := '') INTO v_lastMark;
-- get some time data about the last mark (that may be NULL)
-- (use the first group of the array, as we are now sure that all groups share the same mark)
      SELECT mark_time_id, time_clock_timestamp INTO v_lastMarkTimeId, v_lastMarkTs
        FROM emaj.emaj_mark, emaj.emaj_time_stamp
        WHERE mark_time_id = time_id AND mark_group = v_groupNames[1] AND mark_name = v_lastMark;
-- and check that the last mark has been set after the first mark
      IF v_firstMarkTimeId > v_lastMarkTimeId THEN
        RAISE EXCEPTION '_check_marks_range: The start mark "%" (%) has been set after the end mark "%" (%).',
          v_firstMark, v_firstMarkTs, v_lastMark, v_lastMarkTs;
      END IF;
    END IF;
    RETURN;
  END;
$_check_marks_range$;

CREATE OR REPLACE FUNCTION emaj._forbid_truncate_fnct()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_forbid_truncate_fnct$
-- The function is triggered by the execution of TRUNCATE SQL verb on tables of a rollbackable group
-- in logging mode.
-- It can only be called with postgresql in a version greater or equal 8.4.
  BEGIN
    IF (TG_OP = 'TRUNCATE') THEN
      RAISE EXCEPTION 'emaj._forbid_truncate_fnct: TRUNCATE is not allowed while updates on this table (%.%) are currently protected'
                      ' by E-Maj. Consider stopping the group before issuing a TRUNCATE.', TG_TABLE_SCHEMA, TG_TABLE_NAME;
    END IF;
    RETURN NULL;
  END;
$_forbid_truncate_fnct$;

CREATE OR REPLACE FUNCTION emaj._log_truncate_fnct()
RETURNS TRIGGER  LANGUAGE plpgsql SECURITY DEFINER AS
$_log_truncate_fnct$
-- The function is triggered by the execution of TRUNCATE SQL verb on tables of an audit_only group in logging mode.
  DECLARE
    v_fullLogTableName       TEXT;
  BEGIN
    IF (TG_OP = 'TRUNCATE') THEN
      SELECT quote_ident(rel_log_schema)  || '.' || quote_ident(rel_log_table) INTO v_fullLogTableName FROM emaj.emaj_relation
        WHERE rel_schema = TG_TABLE_SCHEMA AND rel_tblseq = TG_TABLE_NAME AND upper_inf(rel_time_range);
      EXECUTE format('INSERT INTO %s (emaj_verb) VALUES (''TRU'')',
                    v_fullLogTableName);
    END IF;
    RETURN NULL;
  END;
$_log_truncate_fnct$;

CREATE OR REPLACE FUNCTION emaj._create_log_schemas(v_function TEXT, v_groupNames TEXT[])
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_create_log_schemas$
-- The function creates all log schemas that will be needed to create new log tables. It gives the appropriate rights to emaj users on
-- these schemas.
-- Input: calling function to record into the emaj_hist table,
--        array of group names
-- The function is created as SECURITY DEFINER so that log schemas can be owned by superuser
  DECLARE
    v_schemaPrefix           TEXT = 'emaj_';
    r_schema                 RECORD;
  BEGIN
    FOR r_schema IN
        SELECT DISTINCT v_schemaPrefix || grpdef_schema AS log_schema FROM emaj.emaj_group_def
          WHERE grpdef_group = ANY (v_groupNames)
            AND NOT EXISTS                                                                -- minus those already created
              (SELECT 0 FROM emaj.emaj_schema WHERE sch_name = v_schemaPrefix || grpdef_schema)
        ORDER BY 1
    LOOP
-- check that the schema doesn't already exist
      PERFORM 0 FROM pg_catalog.pg_namespace WHERE nspname = r_schema.log_schema;
      IF FOUND THEN
        RAISE EXCEPTION '_create_log_schemas: The schema "%" should not exist. Drop it manually.',r_schema.log_schema;
      END IF;
-- create the schema and give the appropriate rights
      EXECUTE format('CREATE SCHEMA %I',
                     r_schema.log_schema);
      EXECUTE format('GRANT ALL ON SCHEMA %I TO emaj_adm',
                     r_schema.log_schema);
      EXECUTE format('GRANT USAGE ON SCHEMA %I TO emaj_viewer',
                     r_schema.log_schema);
-- and record the schema creation into the emaj_schema and the emaj_hist tables
      INSERT INTO emaj.emaj_schema (sch_name) VALUES (r_schema.log_schema);
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
        VALUES (v_function, 'LOG_SCHEMA CREATED', quote_ident(r_schema.log_schema));
    END LOOP;
    RETURN;
  END;
$_create_log_schemas$;

CREATE OR REPLACE FUNCTION emaj._drop_log_schemas(v_function TEXT, v_isForced BOOLEAN)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_drop_log_schemas$
-- The function looks for log schemas to drop. Drop them if any.
-- Input: calling function to record into the emaj_hist table,
--        boolean telling whether the schema to drop may contain residual objects
-- The function is created as SECURITY DEFINER so that log schemas can be dropped in any case.
  DECLARE
    r_schema                 RECORD;
  BEGIN
-- For each log schema to drop,
    FOR r_schema IN
        SELECT sch_name AS log_schema FROM emaj.emaj_schema                           -- the existing schemas
          WHERE sch_name <> 'emaj'
          EXCEPT
        SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation                        -- the currently needed schemas (after tables drop)
          WHERE rel_kind = 'r' AND rel_log_schema <> 'emaj'
        ORDER BY 1
    LOOP
-- check that the schema really exists
      PERFORM 0 FROM pg_catalog.pg_namespace WHERE nspname = r_schema.log_schema;
      IF NOT FOUND THEN
        RAISE EXCEPTION '_drop_log_schemas: Internal error (the schema "%" does not exist).',r_schema.log_schema;
      END IF;
      IF v_isForced THEN
-- drop cascade when called by emaj_force_xxx_group()
        EXECUTE format('DROP SCHEMA %I CASCADE',
                       r_schema.log_schema);
      ELSE
-- otherwise, drop restrict with a trap on the potential error
        BEGIN
          EXECUTE format('DROP SCHEMA %I',
                         r_schema.log_schema);
          EXCEPTION
-- trap the 2BP01 exception to generate a more understandable error message
            WHEN DEPENDENT_OBJECTS_STILL_EXIST THEN         -- SQLSTATE '2BP01'
              RAISE EXCEPTION '_drop_log_schemas: Cannot drop the schema "%". It probably owns unattended objects.'
                              ' Use the emaj_verify_all() function to get details.', r_schema.log_schema;
        END;
      END IF;
-- remove the schema from the emaj_schema table
      DELETE FROM emaj.emaj_schema WHERE sch_name = r_schema.log_schema;
-- record the schema drop in emaj_hist table
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
        VALUES (v_function,'LOG_SCHEMA DROPPED',quote_ident(r_schema.log_schema));
    END LOOP;
    RETURN;
  END;
$_drop_log_schemas$;

---------------------------------------------------
--                                               --
-- Elementary functions for tables and sequences --
--                                               --
---------------------------------------------------

CREATE OR REPLACE FUNCTION emaj.emaj_assign_table(v_schema TEXT, v_table TEXT, v_group TEXT, v_properties JSONB DEFAULT NULL,
                                                  v_mark TEXT DEFAULT 'ASSIGN_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_assign_table$
-- The function assigns a table into a tables group.
-- Inputs: schema name, table name, assignment group name, assignment properties (optional),
--         mark name to set when logging groups (optional)
-- Outputs: number of tables effectively assigned to the tables group, ie. 1
  BEGIN
    RETURN emaj._assign_tables(v_schema, ARRAY[v_table], v_group, v_properties, v_mark, FALSE, FALSE);
  END;
$emaj_assign_table$;
COMMENT ON FUNCTION emaj.emaj_assign_table(TEXT,TEXT,TEXT,JSONB,TEXT) IS
$$Assign a table into a tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_assign_tables(v_schema TEXT, v_tables TEXT[], v_group TEXT, v_properties JSONB DEFAULT NULL,
                                                   v_mark TEXT DEFAULT 'ASSIGN_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_assign_tables$
-- The function assigns several tables at once into a tables group.
-- Inputs: schema, array of table names, assignment group name, assignment properties (optional),
--         mark name to set when logging groups (optional)
-- Outputs: number of tables effectively assigned to the tables group
  BEGIN
    RETURN emaj._assign_tables(v_schema, v_tables, v_group, v_properties, v_mark, TRUE, FALSE);
  END;
$emaj_assign_tables$;
COMMENT ON FUNCTION emaj.emaj_assign_tables(TEXT,TEXT[],TEXT,JSONB,TEXT) IS
$$Assign several tables into a tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_assign_tables(v_schema TEXT, v_tablesIncludeFilter TEXT, v_tablesExcludeFilter TEXT,
                                                    v_group TEXT, v_properties JSONB DEFAULT NULL, v_mark TEXT DEFAULT 'ASSIGN_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_assign_tables$
-- The function assigns tables on name regexp pattern into a tables group.
-- Inputs: schema name, 2 patterns to filter table names (one to include and another to exclude) , assignment group name,
--         assignment properties (optional), mark name to set when logging groups (optional)
-- Outputs: number of tables effectively assigned to the tables group
  DECLARE
    v_tables                 TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_tablesIncludeFilter = '' THEN NULL ELSE v_tablesIncludeFilter END,
           CASE WHEN v_tablesExcludeFilter = '' THEN NULL ELSE v_tablesExcludeFilter END
      INTO v_tablesIncludeFilter, v_tablesExcludeFilter;
-- Build the list of tables names satisfying the pattern
    SELECT array_agg(relname) INTO v_tables FROM (
      SELECT relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = v_schema
          AND relname ~ v_tablesIncludeFilter
          AND (v_tablesExcludeFilter IS NULL OR relname !~ v_tablesExcludeFilter)
          AND relkind IN ('r', 'p')
        ORDER BY relname) AS t;
-- call the _assign_tables() function for execution
    RETURN emaj._assign_tables(v_schema, v_tables, v_group, v_properties, v_mark, TRUE, TRUE);
  END;
$emaj_assign_tables$;
COMMENT ON FUNCTION emaj.emaj_assign_tables(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT) IS
$$Assign tables on name patterns into a tables group.$$;

CREATE OR REPLACE FUNCTION emaj._assign_tables(v_schema TEXT, v_tables TEXT[], v_group TEXT, v_properties JSONB, v_mark TEXT,
                                               v_multiTable BOOLEAN, v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_assign_tables$
-- The function effectively assigns tables into a tables group.
-- Inputs: schema, array of table names, group name, properties as JSON structure
--         mark to set for lonnging groups, a boolean indicating whether several tables need to be processed,
--         a boolean indicating whether the tables array has been built from regex filters
-- Outputs: number of tables effectively assigned to the tables group
-- The JSONB v_properties parameter has the following structure '{"priority":..., "log_data_tablespace":..., "log_index_tablespace":...}'
--   each properties being NULL by default
-- The function is created as SECURITY DEFINER so that log schemas can be owned by superuser
  DECLARE
    v_function               TEXT;
    v_groupIsRollbackable    BOOLEAN;
    v_groupIsLogging         BOOLEAN;
    v_priority               INT;
    v_logDatTsp              TEXT;
    v_logIdxTsp              TEXT;
    v_extraProperties        JSONB;
    v_list                   TEXT;
    v_array                  TEXT[];
    v_timeId                 BIGINT;
    v_markName               TEXT;
    v_schemaPrefix           TEXT = 'emaj_';
    v_logSchema              TEXT;
    v_eventTriggers          TEXT[];
    v_oneTable               TEXT;
    v_nbAssignedTbl          INT = 0;
  BEGIN
    v_function = CASE WHEN v_multiTable THEN 'ASSIGN_TABLES' ELSE 'ASSIGN_TABLE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check supplied parameters
-- check the group name and if ok, get some properties of the group
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_group], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
    SELECT group_is_rollbackable, group_is_logging INTO v_groupIsRollbackable, v_groupIsLogging
      FROM emaj.emaj_group WHERE group_name = v_group;
-- check the supplied schema exists and is not an E-Maj schema
    PERFORM 1 FROM pg_catalog.pg_namespace
      WHERE nspname = v_schema;
    IF NOT FOUND THEN
      RAISE EXCEPTION '_assign_tables: The schema "%" does not exist.', v_schema;
    END IF;
    PERFORM 1 FROM emaj.emaj_schema
      WHERE sch_name = v_schema;
    IF FOUND THEN
      RAISE EXCEPTION '_assign_tables: The schema "%" is an E-Maj schema.', v_schema;
    END IF;
-- check tables
    IF NOT v_arrayFromRegex THEN
-- from the tables array supplied by the user, remove duplicates values, NULL and empty strings from the supplied table names array
      SELECT array_agg(DISTINCT table_name) INTO v_tables FROM unnest(v_tables) AS table_name
        WHERE table_name IS NOT NULL AND table_name <> '';
-- check that application tables exist
      WITH tables AS (
        SELECT unnest(v_tables) AS table_name)
      SELECT string_agg(quote_ident(table_name), ', ') INTO v_list
        FROM (
          SELECT table_name FROM tables
          WHERE NOT EXISTS (
            SELECT 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace
              WHERE relnamespace = pg_namespace.oid
                AND nspname = v_schema AND relname = table_name
                AND relkind IN ('r','p'))
        ) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) do not exist.', quote_ident(v_schema), v_list;
      END IF;
    END IF;
-- check or discard partitioned application tables (only elementary partitions can be managed by E-Maj)
    SELECT string_agg(quote_ident(relname), ', '), array_agg(relname) INTO v_list, v_array
      FROM pg_catalog.pg_class, pg_catalog.pg_namespace
      WHERE relnamespace = pg_namespace.oid
        AND nspname = v_schema AND relname = ANY(v_tables)
        AND relkind = 'p';
    IF v_list IS NOT NULL THEN
      IF NOT v_arrayFromRegex THEN
        RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) are partitionned tables (only elementary partitions are supported'
                        ' by E-Maj).', quote_ident(v_schema), v_list;
      ELSE
        RAISE WARNING '_assign_tables: Some partitionned tables (%) are not selected.', v_list;
        -- remove these tables from the tables to process
        SELECT array_agg(remaining_table) INTO v_tables
          FROM (SELECT unnest(v_tables) EXCEPT SELECT unnest(v_array)) AS t(remaining_table);
      END IF;
    END IF;
-- check or discard TEMP tables
    SELECT string_agg(quote_ident(relname), ', '), array_agg(relname) INTO v_list, v_array
      FROM pg_catalog.pg_class, pg_catalog.pg_namespace
      WHERE relnamespace = pg_namespace.oid
        AND nspname = v_schema AND relname = ANY(v_tables)
        AND relkind = 'r' AND relpersistence = 't';
    IF v_list IS NOT NULL THEN
      IF NOT v_arrayFromRegex THEN
        RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) are TEMP tables.', quote_ident(v_schema), v_list;
      ELSE
        RAISE WARNING '_assign_tables: Some TEMP tables (%) are not selected.', v_list;
        -- remove these tables from the tables to process
        SELECT array_agg(remaining_table) INTO v_tables
          FROM (SELECT unnest(v_tables) EXCEPT SELECT unnest(v_array)) AS t(remaining_table);
      END IF;
    END IF;
-- check or discard UNLOGGED tables in rollbackable groups
    IF v_groupIsRollbackable THEN
      SELECT string_agg(quote_ident(relname), ', '), array_agg(relname) INTO v_list, v_array
        FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = v_schema AND relname = ANY(v_tables)
          AND relkind = 'r' AND relpersistence = 'u';
      IF v_list IS NOT NULL THEN
        IF NOT v_arrayFromRegex THEN
          RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) are UNLOGGED tables.', quote_ident(v_schema), v_list;
        ELSE
          RAISE WARNING '_assign_tables: Some UNLOGGED tables (%) are not selected.', v_list;
        -- remove these tables from the tables to process
        SELECT array_agg(remaining_table) INTO v_tables
          FROM (SELECT unnest(v_tables) EXCEPT SELECT unnest(v_array)) AS t(remaining_table);
        END IF;
      END IF;
    END IF;
-- with PG11-, check or discard WITH OIDS tables in rollbackable groups
    IF emaj._pg_version_num() < 120000 AND v_groupIsRollbackable THEN
      SELECT string_agg(quote_ident(relname), ', '), array_agg(relname) INTO v_list, v_array
        FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = v_schema AND relname = ANY(v_tables)
          AND relkind = 'r' AND relhasoids;
      IF v_list IS NOT NULL THEN
        IF NOT v_arrayFromRegex THEN
          RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) are declared WITH OIDS.', quote_ident(v_schema), v_list;
        ELSE
          RAISE WARNING '_assign_tables: Some WITH OIDS tables (%) are not selected.', v_list;
        -- remove these tables from the tables to process
        SELECT array_agg(remaining_table) INTO v_tables
          FROM (SELECT unnest(v_tables) EXCEPT SELECT unnest(v_array)) AS t(remaining_table);
        END IF;
      END IF;
    END IF;
-- check or discard tables whithout primary key in rollbackable groups
    IF v_groupIsRollbackable THEN
      SELECT string_agg(quote_ident(relname), ', '), array_agg(relname) INTO v_list, v_array
        FROM pg_catalog.pg_class t, pg_catalog.pg_namespace
        WHERE t.relnamespace = pg_namespace.oid
          AND nspname = v_schema AND t.relname = ANY(v_tables)
          AND relkind = 'r'
          AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c, pg_catalog.pg_namespace, pg_catalog.pg_constraint
                            WHERE c.relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = c.oid
                            AND contype = 'p' AND nspname = v_schema AND c.relname = t.relname);
      IF v_list IS NOT NULL THEN
        IF NOT v_arrayFromRegex THEN
          RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) have no PRIMARY KEY.', quote_ident(v_schema), v_list;
        ELSE
          RAISE WARNING '_assign_tables: Some tables without PRIMARY KEY (%) are not selected.', v_list;
        -- remove these tables from the tables to process
        SELECT array_agg(remaining_table) INTO v_tables
          FROM (SELECT unnest(v_tables) EXCEPT SELECT unnest(v_array)) AS t(remaining_table);
        END IF;
      END IF;
    END IF;
-- check or discard tables already assigned to a group
    SELECT string_agg(quote_ident(rel_tblseq), ', '), array_agg(rel_tblseq) INTO v_list, v_array
      FROM emaj.emaj_relation
      WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range);
    IF v_list IS NOT NULL THEN
      IF NOT v_arrayFromRegex THEN
        RAISE EXCEPTION '_assign_tables: In schema %, some tables (%) already belong to a group.', quote_ident(v_schema), v_list;
      ELSE
        RAISE WARNING '_assign_tables: Some tables already belonging to a group (%) are not selected.', v_list;
        -- remove these tables from the tables to process
        SELECT array_agg(remaining_table) INTO v_tables
          FROM (SELECT unnest(v_tables) EXCEPT SELECT unnest(v_array)) AS t(remaining_table);
      END IF;
    END IF;
-- check the priority is numeric
    BEGIN
      v_priority = (v_properties->>'priority')::INT;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RAISE EXCEPTION '_assign_tables: the "priority" property is not numeric.';
    END;
-- check that the tablespaces exist, if supplied
    v_logDatTsp = v_properties->>'log_data_tablespace';
    IF v_logDatTsp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname = v_logDatTsp) THEN
      RAISE EXCEPTION '_assign_tables: the log data tablespace "%" does not exists.', v_logDatTsp;
    END IF;
    v_logIdxTsp = v_properties->>'log_index_tablespace';
    IF v_logIdxTsp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname = v_logIdxTsp) THEN
      RAISE EXCEPTION '_assign_tables: the log index tablespace "%" does not exists.', v_logIdxTsp;
    END IF;
-- check no properties are unknown
    v_extraProperties = v_properties - 'priority' - 'log_data_tablespace' - 'log_index_tablespace';
    IF v_extraProperties IS NOT NULL AND v_extraProperties <> '{}' THEN
      RAISE EXCEPTION '_assign_tables: properties "%" are unknown.', v_extraProperties;
    END IF;
-- check the supplied mark
    SELECT emaj._check_new_mark(array[v_group], v_mark) INTO v_markName;
-- OK,
    IF v_tables IS NULL OR v_tables = '{}' THEN
-- when no tables are finaly selected, just warn
      RAISE WARNING '_assign_tables: No table to process.';
    ELSE
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_groupIsLogging THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(ARRAY[v_group], 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(ARRAY[v_group], v_markName, FALSE, TRUE, NULL, v_timeId);
      END IF;
-- create new log schemas if needed
      v_logSchema = v_schemaPrefix || v_schema;
      IF NOT EXISTS (SELECT 0 FROM emaj.emaj_schema WHERE sch_name = v_logSchema) THEN
-- check that the schema doesn't already exist
        PERFORM 0 FROM pg_catalog.pg_namespace WHERE nspname = v_logSchema;
        IF FOUND THEN
          RAISE EXCEPTION '_assign_tables: The schema "%" should not exist. Drop it manually.',v_logSchema;
        END IF;
-- create the schema and give the appropriate rights
        EXECUTE format('CREATE SCHEMA %I',
                       v_logSchema);
        EXECUTE format('GRANT ALL ON SCHEMA %I TO emaj_adm',
                       v_logSchema);
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO emaj_viewer',
                       v_logSchema);
-- and record the schema creation into the emaj_schema and the emaj_hist tables
        INSERT INTO emaj.emaj_schema (sch_name) VALUES (v_logSchema);
        INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
          VALUES (CASE WHEN v_multiTable THEN 'ASSIGN_TABLES' ELSE 'ASSIGN_TABLE' END, 'LOG_SCHEMA CREATED', quote_ident(v_logSchema));
      END IF;
-- disable event triggers that protect emaj components and keep in memory these triggers name
      SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- effectively create the log components for each table
      FOREACH v_oneTable IN ARRAY v_tables
      LOOP
-- create the table
        PERFORM emaj._add_tbl(v_schema, v_oneTable, v_group, v_priority, v_logDatTsp, v_logIdxTsp, v_groupIsLogging,
                              v_timeId, v_function);
-- insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
        INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging)
          VALUES (v_timeId, 'ADD_TBL', v_schema, v_oneTable, v_group, v_groupIsLogging);
        v_nbAssignedTbl = v_nbAssignedTbl + 1;
      END LOOP;
-- enable previously disabled event triggers
      PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- adjust the group characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId,
            group_nb_table = (SELECT count(*) FROM emaj.emaj_relation
                                WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'r')
        WHERE group_name = v_group;
-- if the group is logging, check foreign keys with tables outside the groups (otherwise the check will be done at the group start time)
      IF v_groupIsLogging THEN
        PERFORM emaj._check_fk_groups(array[v_group]);
      END IF;
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbAssignedTbl || ' tables assigned to the group ' || v_group);
    RETURN v_nbAssignedTbl;
  END;
$_assign_tables$;

CREATE OR REPLACE FUNCTION emaj.emaj_remove_table(v_schema TEXT, v_table TEXT, v_mark TEXT DEFAULT 'REMOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_remove_table$
-- The function removes a table from its tables group.
-- Inputs: schema name, table name, mark name to set when logging groups (optional)
-- Outputs: number of tables effectively removed to the tables group, ie. 1
  BEGIN
    RETURN emaj._remove_tables(v_schema, ARRAY[v_table], v_mark, FALSE, FALSE);
  END;
$emaj_remove_table$;
COMMENT ON FUNCTION emaj.emaj_remove_table(TEXT,TEXT,TEXT) IS
$$Remove a table from its tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_remove_tables(v_schema TEXT, v_tables TEXT[], v_mark TEXT DEFAULT 'REMOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_remove_tables$
-- The function removes several tables at once from their tables group.
-- Inputs: schema, array of table names, mark name to set when logging groups (optional)
-- Outputs: number of tables effectively removed from the tables group
  BEGIN
    RETURN emaj._remove_tables(v_schema, v_tables, v_mark, TRUE, FALSE);
  END;
$emaj_remove_tables$;
COMMENT ON FUNCTION emaj.emaj_remove_tables(TEXT,TEXT[],TEXT) IS
$$Remove several tables from their tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_remove_tables(v_schema TEXT, v_tablesIncludeFilter TEXT, v_tablesExcludeFilter TEXT,
                                                   v_mark TEXT DEFAULT 'REMOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_remove_tables$
-- The function removes tables on name patterns from their tables group.
-- Inputs: schema, 2 patterns to filter table names (one to include and another to exclude),
--         mark name to set when logging groups (optional)
-- Outputs: number of tables effectively removed from the tables group
  DECLARE
    v_tables                 TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_tablesIncludeFilter = '' THEN NULL ELSE v_tablesIncludeFilter END,
           CASE WHEN v_tablesExcludeFilter = '' THEN NULL ELSE v_tablesExcludeFilter END
      INTO v_tablesIncludeFilter, v_tablesExcludeFilter;
-- Build the list of tables names satisfying the pattern
    SELECT array_agg(rel_tblseq) INTO v_tables FROM (
      SELECT rel_tblseq FROM emaj.emaj_relation
        WHERE rel_schema = v_schema
          AND rel_tblseq ~ v_tablesIncludeFilter
          AND (v_tablesExcludeFilter IS NULL OR rel_tblseq !~ v_tablesExcludeFilter)
          AND rel_kind = 'r' AND upper_inf(rel_time_range)
        ORDER BY rel_tblseq) AS t;
-- call the _remove_tables() function for execution
    RETURN emaj._remove_tables(v_schema, v_tables, v_mark, TRUE, TRUE);
  END;
$emaj_remove_tables$;
COMMENT ON FUNCTION emaj.emaj_remove_tables(TEXT,TEXT,TEXT,TEXT) IS
$$Remove several tables on name patterns from their tables group.$$;

CREATE OR REPLACE FUNCTION emaj._remove_tables(v_schema TEXT, v_tables TEXT[], v_mark TEXT, v_multiTable BOOLEAN,
                                               v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_remove_tables$
-- The function effectively removes tables from their tables group.
-- Inputs: schema, array of table names, mark to set if for logging groups,
--         boolean to indicate whether several tables need to be processed,
--         a boolean indicating whether the tables array has been built from regex filters
-- Outputs: number of tables effectively removed to the tables group
-- The function is created as SECURITY DEFINER so that log schemas can be dropped
  DECLARE
    v_function               TEXT;
    v_list                   TEXT;
    v_markName               TEXT;
    v_timeId                 BIGINT;
    v_groups                 TEXT[];
    v_loggingGroups          TEXT[];
    v_groupName              TEXT;
    v_groupIsLogging         BOOLEAN;
    v_schemaPrefix           TEXT = 'emaj_';
    v_eventTriggers          TEXT[];
    v_oneTable               TEXT;
    v_logSchema              TEXT;
    v_nbRemovedTbl           INT = 0;
  BEGIN
    v_function = CASE WHEN v_multiTable THEN 'REMOVE_TABLES' ELSE 'REMOVE_TABLE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check the tables list
    IF NOT v_arrayFromRegex THEN
-- remove duplicates values, NULL and empty strings from the supplied table names array
      SELECT array_agg(DISTINCT table_name) INTO v_tables FROM unnest(v_tables) AS table_name
        WHERE table_name IS NOT NULL AND table_name <> '';
-- check that the tables currently belong to a tables group (not necessarily the same for all tables)
      WITH all_supplied_tables AS (
        SELECT unnest(v_tables) AS table_name),
           tables_in_group AS (
        SELECT rel_tblseq FROM emaj.emaj_relation
          WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range))
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(table_name), ', ') INTO v_list
        FROM (
          SELECT table_name FROM all_supplied_tables
            EXCEPT
          SELECT rel_tblseq FROM tables_in_group) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_remove_tables: some tables (%) do not currently belong to any tables group.', v_list;
      END IF;
    END IF;
-- get the lists of groups and logging groups holding these tables, if any.
-- It locks the tables groups so that no other operation simultaneously occurs these groups
    WITH tables_group AS (
      SELECT group_name, group_is_logging FROM emaj.emaj_relation, emaj.emaj_group
        WHERE rel_group = group_name
          AND rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range)
        FOR UPDATE OF emaj_group
      )
    SELECT (SELECT array_agg(group_name) FROM tables_group),
           (SELECT array_agg(group_name) FROM tables_group WHERE group_is_logging)
      INTO v_groups, v_loggingGroups;
-- check the supplied mark
    SELECT emaj._check_new_mark(v_loggingGroups, v_mark) INTO v_markName;
-- OK,
    IF v_tables IS NULL THEN
-- when no tables are finaly selected, just warn
      RAISE WARNING '_remove_tables: No table to process.';
    ELSE
      v_logSchema = v_schemaPrefix || v_schema;
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_loggingGroups IS NOT NULL THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(v_loggingGroups, 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(v_loggingGroups, v_markName, FALSE, TRUE, NULL, v_timeId);
      END IF;
-- disable event triggers that protect emaj components and keep in memory these triggers name
      SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- effectively drop the log components for each table
      FOREACH v_oneTable IN ARRAY v_tables
      LOOP
-- get some characteristics of the group that holds the table
        SELECT rel_group, group_is_logging INTO v_groupName, v_groupIsLogging
          FROM emaj.emaj_relation, emaj.emaj_group
          WHERE rel_group = group_name
            AND rel_schema = v_schema AND rel_tblseq = v_oneTable AND upper_inf(rel_time_range);
-- drop this table
        PERFORM emaj._remove_tbl(v_schema, v_oneTable, v_groupName, v_groupIsLogging, v_timeId, v_function);
-- insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
        INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging)
          VALUES (v_timeId, 'REMOVE_TBL', v_schema, v_oneTable, v_groupName, v_groupIsLogging);
        v_nbRemovedTbl = v_nbRemovedTbl + 1;
      END LOOP;
-- drop the log schema if it is now useless
      IF NOT EXISTS (SELECT 0 FROM emaj.emaj_relation WHERE rel_log_schema = v_logSchema) THEN
-- drop the schema
        EXECUTE format('DROP SCHEMA %I',
                       v_logSchema);
-- and record the schema drop into the emaj_schema and the emaj_hist tables
        DELETE FROM emaj.emaj_schema WHERE sch_name = v_logSchema;
        INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
          VALUES (CASE WHEN v_multiTable THEN 'REMOVE_TABLES' ELSE 'REMOVE_TABLE' END, 'LOG_SCHEMA DROPPED', quote_ident(v_logSchema));
      END IF;
-- enable previously disabled event triggers
      PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- adjust the groups characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId,
            group_nb_table = (SELECT count(*) FROM emaj.emaj_relation
                                WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'r')
        WHERE group_name = ANY (v_groups);
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbRemovedTbl || ' tables removed from their groups');
    RETURN v_nbRemovedTbl;
  END;
$_remove_tables$;

CREATE OR REPLACE FUNCTION emaj.emaj_move_table(v_schema TEXT, v_table TEXT, v_newGroup TEXT, v_mark TEXT DEFAULT 'MOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_move_table$
-- The function moves a table from its tables group to another tables group.
-- Inputs: schema name, table name, new group name, mark name to set when logging groups (optional)
-- Outputs: number of tables effectively moved to the new tables group, ie. 1
  BEGIN
    RETURN emaj._move_tables(v_schema, ARRAY[v_table], v_newGroup, v_mark, FALSE, FALSE);
  END;
$emaj_move_table$;
COMMENT ON FUNCTION emaj.emaj_move_table(TEXT,TEXT,TEXT,TEXT) IS
$$Move a table from its tables group to another tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_move_tables(v_schema TEXT, v_tables TEXT[], v_newGroup TEXT, v_mark TEXT DEFAULT 'MOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_move_tables$
-- The function moves several tables at once from their tables group to another tables group.
-- Inputs: schema, array of table names, new group name, mark name to set when logging groups (optional)
-- Outputs: number of tables effectively moved to the new tables group
  BEGIN
    RETURN emaj._move_tables(v_schema, v_tables, v_newGroup, v_mark, TRUE, FALSE);
  END;
$emaj_move_tables$;
COMMENT ON FUNCTION emaj.emaj_move_tables(TEXT,TEXT[],TEXT,TEXT) IS
$$Move several tables from their tables group to another tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_move_tables(v_schema TEXT, v_tablesIncludeFilter TEXT, v_tablesExcludeFilter TEXT,
                                                 v_newGroup TEXT, v_mark TEXT DEFAULT 'MOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_move_tables$
-- The function moves tables on name patterns from their tables group to another tables group.
-- Inputs: schema, 2 patterns to filter table names (one to include and another to exclude), new group name,
--         mark name to set when logging groups (optional)
-- Outputs: number of tables effectively moved to the new tables group
  DECLARE
    v_tables                 TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_tablesIncludeFilter = '' THEN NULL ELSE v_tablesIncludeFilter END,
           CASE WHEN v_tablesExcludeFilter = '' THEN NULL ELSE v_tablesExcludeFilter END
      INTO v_tablesIncludeFilter, v_tablesExcludeFilter;
-- Build the list of tables names satisfying the pattern
    SELECT array_agg(rel_tblseq) INTO v_tables FROM (
      SELECT rel_tblseq FROM emaj.emaj_relation
        WHERE rel_schema = v_schema
          AND rel_tblseq ~ v_tablesIncludeFilter
          AND (v_tablesExcludeFilter IS NULL OR rel_tblseq !~ v_tablesExcludeFilter)
          AND rel_kind = 'r' AND upper_inf(rel_time_range)
          AND rel_group <> v_newGroup
        ORDER BY rel_tblseq) AS t;
-- call the _move_tables() function for execution
    RETURN emaj._move_tables(v_schema, v_tables, v_newGroup, v_mark, TRUE, TRUE);
  END;
$emaj_move_tables$;
COMMENT ON FUNCTION emaj.emaj_move_tables(TEXT,TEXT,TEXT,TEXT,TEXT) IS
$$Move several tables on name patterns from their tables group to another tables group.$$;

CREATE OR REPLACE FUNCTION emaj._move_tables(v_schema TEXT, v_tables TEXT[], v_newGroup TEXT, v_mark TEXT, v_multiTable BOOLEAN,
                                             v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS
$_move_tables$
-- The function effectively moves tables from their tables group to another tables group.
-- Inputs: schema, array of table names, new group name, mark to set if for logging groups,
--         boolean to indicate whether several tables need to be processed,
--         a boolean indicating whether the tables array has been built from regex filters
-- Outputs: number of tables effectively moved to the tables group
-- The function is created as SECURITY DEFINER so that log schemas can be dropped
  DECLARE
    v_function               TEXT;
    v_newGroupIsLogging      BOOLEAN;
    v_list                   TEXT;
    v_uselessTables          TEXT[];
    v_markName               TEXT;
    v_timeId                 BIGINT;
    v_groups                 TEXT[];
    v_loggingGroups          TEXT[];
    v_groupName              TEXT;
    v_groupIsLogging         BOOLEAN;
    v_oneTable               TEXT;
    v_nbMovedTbl             INT = 0;
  BEGIN
    v_function = CASE WHEN v_multiTable THEN 'MOVE_TABLES' ELSE 'MOVE_TABLE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check the group name and if ok, get some properties of the group
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_newGroup], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
    SELECT group_is_logging INTO v_newGroupIsLogging
      FROM emaj.emaj_group WHERE group_name = v_NewGroup;
-- check the tables list
    IF NOT v_arrayFromRegex THEN
-- remove duplicates values, NULL and empty strings from the supplied table names array
      SELECT array_agg(DISTINCT table_name) INTO v_tables FROM unnest(v_tables) AS table_name
        WHERE table_name IS NOT NULL AND table_name <> '';
-- check that the tables currently belong to a tables group (not necessarily the same for all table)
      WITH all_supplied_tables AS (
        SELECT unnest(v_tables) AS table_name),
           tables_in_group AS (
        SELECT rel_tblseq FROM emaj.emaj_relation
          WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range))
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(table_name), ', ') INTO v_list
        FROM (
          SELECT table_name FROM all_supplied_tables
            EXCEPT
          SELECT rel_tblseq FROM tables_in_group) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_move_tables: some tables (%) do not currently belong to any tables group.', v_list;
      END IF;
-- remove tables that already belong to the new group
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(rel_tblseq), ', '), array_agg(rel_tblseq)
        INTO v_list, v_uselessTables
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range)
          AND rel_group = v_newGroup;
      IF v_list IS NOT NULL THEN
        RAISE WARNING '_move_tables: some tables (%) already belong to the tables group %.', v_list, v_newGroup;
        SELECT array_remove(v_tables, useless_table) INTO v_tables FROM unnest(v_uselessTables) AS useless_table;
      END IF;
    END IF;
-- get the lists of groups and logging groups holding these tables, if any.
-- It locks the tables groups so that no other operation simultaneously occurs these groups
-- (the CTE is needed for the FOR UPDATE clause not allowed when aggregate functions)
    WITH tables_group AS (
      SELECT group_name, group_is_logging FROM emaj.emaj_group
        WHERE group_name = v_newGroup OR
              group_name IN
               (SELECT DISTINCT rel_group FROM emaj.emaj_relation
                  WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range))
        FOR UPDATE OF emaj_group
      )
    SELECT array_agg(group_name ORDER BY group_name),
           array_agg(group_name ORDER BY group_name) FILTER (WHERE group_is_logging)
      INTO v_groups, v_loggingGroups
      FROM tables_group;
-- check the supplied mark
    SELECT emaj._check_new_mark(v_loggingGroups, v_mark) INTO v_markName;
-- OK,
    IF v_tables IS NULL THEN
-- when no tables are finaly selected, just warn
      RAISE WARNING '_move_tables: No table to process.';
    ELSE
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_loggingGroups IS NOT NULL THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(v_loggingGroups, 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(v_loggingGroups, v_markName, TRUE, TRUE, NULL, v_timeId);
      END IF;
-- effectively move each table
      FOREACH v_oneTable IN ARRAY v_tables
      LOOP
-- get some characteristics of the group that holds the table before the move
        SELECT rel_group, group_is_logging INTO v_groupName, v_groupIsLogging
          FROM emaj.emaj_relation, emaj.emaj_group
          WHERE rel_group = group_name
            AND rel_schema = v_schema AND rel_tblseq = v_oneTable AND upper_inf(rel_time_range);
-- move this table
        PERFORM emaj._move_tbl(v_schema, v_oneTable, v_groupName, v_groupIsLogging, v_newGroup, v_newGroupIsLogging, v_timeId, v_function);
-- insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
        INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging,
                                          altr_new_group, altr_new_group_is_logging)
          VALUES (v_timeId, 'MOVE_TBL', v_schema, v_oneTable, v_groupName, v_groupIsLogging, v_newGroup, v_newGroupIsLogging);
        v_nbMovedTbl = v_nbMovedTbl + 1;
      END LOOP;
-- adjust the groups characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId,
            group_nb_table = (SELECT count(*) FROM emaj.emaj_relation
                                WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'r')
        WHERE group_name = ANY (v_groups);
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbMovedTbl || ' tables moved to the new tables group ' || v_newGroup);
    RETURN v_nbMovedTbl;
  END;
$_move_tables$;

CREATE OR REPLACE FUNCTION emaj.emaj_modify_table(v_schema TEXT, v_table TEXT, v_changedProperties JSONB,
                                                  v_mark TEXT DEFAULT 'MODIFY_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_modify_table$
-- The function modifies the assignment properties of a table.
-- Inputs: schema name, table name, assignment properties changes,
--         mark name to set when logging groups (optional)
-- Outputs: number of tables effectively modified, ie 0 or 1
  BEGIN
    RETURN emaj._modify_tables(v_schema, ARRAY[v_table], v_changedProperties, v_mark, FALSE, FALSE);
  END;
$emaj_modify_table$;
COMMENT ON FUNCTION emaj.emaj_modify_table(TEXT,TEXT,JSONB,TEXT) IS
$$Modify the assignment properties of a table.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_modify_tables(v_schema TEXT, v_tables TEXT[], v_changedProperties JSONB,
                                                   v_mark TEXT DEFAULT 'MODIFY_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_modify_tables$
-- The function modifies the assignment properties for several tables at once.
-- Inputs: schema, array of table names, assignment properties,
--         mark name to set when logging groups (optional)
-- Outputs: number of tables effectively modified
  BEGIN
    RETURN emaj._modify_tables(v_schema, v_tables, v_changedProperties, v_mark, TRUE, FALSE);
  END;
$emaj_modify_tables$;
COMMENT ON FUNCTION emaj.emaj_modify_tables(TEXT,TEXT[],JSONB,TEXT) IS
$$Modify the assignment properties of several tables.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_modify_tables(v_schema TEXT, v_tablesIncludeFilter TEXT, v_tablesExcludeFilter TEXT,
                                                   v_properties JSONB, v_mark TEXT DEFAULT 'MODIFY_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_modify_tables$
-- The function modifies the assignment properties for several tables selected on name regexp pattern at once.
-- Inputs: schema name, 2 patterns to filter table names (one to include and another to exclude),
--         assignment properties, mark name to set when logging groups (optional)
-- Outputs: number of tables effectively modified
  DECLARE
    v_tables                 TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_tablesIncludeFilter = '' THEN NULL ELSE v_tablesIncludeFilter END,
           CASE WHEN v_tablesExcludeFilter = '' THEN NULL ELSE v_tablesExcludeFilter END
      INTO v_tablesIncludeFilter, v_tablesExcludeFilter;
-- Build the list of tables names satisfying the pattern
    SELECT array_agg(relname) INTO v_tables FROM (
      SELECT relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = v_schema
          AND relname ~ v_tablesIncludeFilter
          AND (v_tablesExcludeFilter IS NULL OR relname !~ v_tablesExcludeFilter)
          AND relkind IN ('r', 'p')
        ORDER BY relname) AS t;
-- call the _modify_tables() function for execution
    RETURN emaj._modify_tables(v_schema, v_tables, v_properties, v_mark, TRUE, TRUE);
  END;
$emaj_modify_tables$;
COMMENT ON FUNCTION emaj.emaj_modify_tables(TEXT,TEXT,TEXT,JSONB,TEXT) IS
$$Modify the assignment properties of several tables selected on name patterns.$$;

CREATE OR REPLACE FUNCTION emaj._modify_tables(v_schema TEXT, v_tables TEXT[], v_changedProperties JSONB, v_mark TEXT,
                                               v_multiTable BOOLEAN, v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS
$_modify_tables$
-- The function effectively modify the assignment properties of tables.
-- Inputs: schema, array of table names, properties as JSON structure
--         mark to set for logging groups, a boolean indicating whether several tables need to be processed,
--         a boolean indicating whether the tables array has been built from regex filters
-- Outputs: number of tables effectively modified
-- The JSONB v_properties parameter has the following structure '{"priority":..., "log_data_tablespace":..., "log_index_tablespace":...}'
--   each properties can be set to NULL to delete a previously set value
  DECLARE
    v_function               TEXT;
    v_priorityChanged        BOOLEAN = FALSE;
    v_newPriority            INT;
    v_logDatTspChanged       BOOLEAN = FALSE;
    v_newLogDatTsp           TEXT;
    v_logIdxTspChanged       BOOLEAN = FALSE;
    v_newLogIdxTsp           TEXT;
    v_extraProperties        JSONB;
    v_list                   TEXT;
    v_array                  TEXT[];
    v_groups                 TEXT[];
    v_loggingGroups          TEXT[];
    v_timeId                 BIGINT;
    v_markName               TEXT;
    v_isTableChanged         BOOLEAN;
    v_nbChangedTbl           INT = 0;
    r_rel                    RECORD;
  BEGIN
    v_function = CASE WHEN v_multiTable THEN 'MODIFY_TABLES' ELSE 'MODIFY_TABLE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check supplied parameters
-- check tables
    IF NOT v_arrayFromRegex THEN
-- from the tables array supplied by the user, remove duplicates values, NULL and empty strings from the supplied table names array
      SELECT array_agg(DISTINCT table_name) INTO v_tables FROM unnest(v_tables) AS table_name
        WHERE table_name IS NOT NULL AND table_name <> '';
-- check that the tables currently belong to a tables group (not necessarily the same for all tables)
      WITH all_supplied_tables AS (
        SELECT unnest(v_tables) AS table_name),
           tables_in_group AS (
        SELECT rel_tblseq FROM emaj.emaj_relation
          WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range))
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(table_name), ', ') INTO v_list
        FROM (
          SELECT table_name FROM all_supplied_tables
            EXCEPT
          SELECT rel_tblseq FROM tables_in_group) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_modify_tables: some tables (%) do not currently belong to any tables group.', v_list;
      END IF;
    END IF;
-- get the new priority, if supplied, and check the priority is numeric
    IF v_changedProperties ? 'priority' THEN
      BEGIN
        v_newPriority = (v_changedProperties->>'priority')::INT;
      EXCEPTION
        WHEN invalid_text_representation THEN
          RAISE EXCEPTION '_modify_tables: the "priority" property is not numeric.';
      END;
      v_priorityChanged = TRUE;
    END IF;
-- get the new tablespaces if supplied and check that the tablespaces exist
    IF v_changedProperties ? 'log_data_tablespace' THEN
      v_newLogDatTsp = v_changedProperties->>'log_data_tablespace';
      IF v_newLogDatTsp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname = v_newLogDatTsp) THEN
        RAISE EXCEPTION '_modify_tables: the log data tablespace "%" does not exists.', v_newLogDatTsp;
      END IF;
      v_logDatTspChanged = TRUE;
    END IF;
    IF v_changedProperties ? 'log_index_tablespace' THEN
      v_newLogIdxTsp = v_changedProperties->>'log_index_tablespace';
      IF v_newLogIdxTsp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tablespace WHERE spcname = v_newLogIdxTsp) THEN
        RAISE EXCEPTION '_modify_tables: the log index tablespace "%" does not exists.', v_newLogIdxTsp;
      END IF;
      v_logIdxTspChanged = TRUE;
    END IF;
-- check no properties are unknown
    v_extraProperties = v_changedProperties - 'priority' - 'log_data_tablespace' - 'log_index_tablespace';
    IF v_extraProperties IS NOT NULL AND v_extraProperties <> '{}' THEN
      RAISE EXCEPTION '_modify_tables: properties "%" are unknown.', v_extraProperties;
    END IF;
-- get the lists of groups and logging groups holding these tables, if any.
-- The FOR UPDATE clause locks the tables groups so that no other operation simultaneously occurs on these groups
-- (the CTE is needed for the FOR UPDATE clause not allowed when aggregate functions)
    WITH tables_group AS (
      SELECT group_name, group_is_logging FROM emaj.emaj_group
        WHERE group_name IN
               (SELECT DISTINCT rel_group FROM emaj.emaj_relation
                  WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range))
        FOR UPDATE OF emaj_group
      )
    SELECT array_agg(group_name ORDER BY group_name),
           array_agg(group_name ORDER BY group_name) FILTER (WHERE group_is_logging)
      INTO v_groups, v_loggingGroups
      FROM tables_group;
-- check the supplied mark
    SELECT emaj._check_new_mark(v_loggingGroups, v_mark) INTO v_markName;
-- OK,
    IF v_tables IS NULL OR v_tables = '{}' THEN
-- when no tables are finaly selected, just warn
      RAISE WARNING '_modified_tables: No table to process.';
    ELSE
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_loggingGroups IS NOT NULL THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(v_loggingGroups, 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(v_loggingGroups, v_markName, TRUE, TRUE, NULL, v_timeId);
      END IF;
-- process the changes for each table, if any
      FOR r_rel IN
        SELECT rel_tblseq, rel_time_range, rel_log_schema, rel_priority, rel_log_table, rel_log_index, rel_log_dat_tsp,
               rel_log_idx_tsp, rel_group, group_is_logging
          FROM emaj.emaj_relation, emaj.emaj_group
          WHERE rel_group = group_name
            AND rel_schema = v_schema AND rel_tblseq = ANY(v_tables) AND upper_inf(rel_time_range)
          ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
        v_isTableChanged = FALSE;
-- change the priority, if needed
        IF v_priorityChanged AND
            (r_rel.rel_priority <> v_newPriority
            OR (r_rel.rel_priority IS NULL AND v_newPriority IS NOT NULL)
            OR (r_rel.rel_priority IS NOT NULL AND v_newPriority IS NULL)) THEN
          v_isTableChanged = TRUE;
--   call the dedicated function
          PERFORM emaj._change_priority_tbl(v_schema, r_rel.rel_tblseq, r_rel.rel_priority, v_newPriority, v_function);
--   and insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
          INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group,
                                            altr_priority,  altr_group_is_logging)
            VALUES (v_timeId, 'CHANGE_REL_PRIORITY', v_schema, r_rel.rel_tblseq, r_rel.rel_group, v_newPriority, r_rel.group_is_logging);
        END IF;
-- change the log data tablespace, if needed
        IF v_logDatTspChanged AND coalesce(v_newLogDatTsp, '') <> coalesce(r_rel.rel_log_dat_tsp, '') THEN
          v_isTableChanged = TRUE;
--   call the dedicated function
          PERFORM emaj._change_log_data_tsp_tbl(v_schema, r_rel.rel_tblseq, r_rel.rel_log_schema, r_rel.rel_log_table,
                                                r_rel.rel_log_dat_tsp, v_newLogDatTsp, v_function);
--   and insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
          INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging)
            VALUES (v_timeId, 'CHANGE_TBL_LOG_DATA_TSP', v_schema, r_rel.rel_tblseq, r_rel.rel_group, r_rel.group_is_logging);
        END IF;
-- change the log index tablespace, if needed
        IF v_logIdxTspChanged AND coalesce(v_newLogIdxTsp, '') <> coalesce(r_rel.rel_log_idx_tsp, '') THEN
          v_isTableChanged = TRUE;
--   call the dedicated function
          PERFORM emaj._change_log_index_tsp_tbl(v_schema, r_rel.rel_tblseq, r_rel.rel_log_schema, r_rel.rel_log_index,
                                                 r_rel.rel_log_idx_tsp, v_newLogIdxTsp, v_function);
--   and insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
          INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging)
            VALUES (v_timeId, 'CHANGE_TBL_LOG_INDEX_TSP', v_schema, r_rel.rel_tblseq, r_rel.rel_group, r_rel.group_is_logging);
        END IF;
        IF v_isTableChanged THEN
          v_nbChangedTbl = v_nbChangedTbl + 1;
        END IF;
      END LOOP;
-- adjust the groups characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId
        WHERE group_name = ANY(v_groups);
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbChangedTbl || ' tables effectively modified');
    RETURN v_nbChangedTbl;
  END;
$_modify_tables$;

CREATE OR REPLACE FUNCTION emaj.emaj_get_current_log_table(v_app_schema TEXT, v_app_table TEXT,
                                                           OUT log_schema TEXT, OUT log_table TEXT)
LANGUAGE plpgsql AS
$emaj_get_current_log_table$
-- The function returns the current log table for a given application schema and table.
-- It returns NULL values if the table doesn't currently belong to a tables group.
-- Inputs: schema and table names
-- Outputs: schema and table of the currently associated log table
  BEGIN
-- get the requested data from the emaj_relation table
    SELECT rel_log_schema, rel_log_table INTO log_schema, log_table
      FROM emaj.emaj_relation
      WHERE rel_schema = v_app_schema AND rel_tblseq = v_app_table AND upper_inf(rel_time_range);
    RETURN;
  END;
$emaj_get_current_log_table$;
COMMENT ON FUNCTION emaj.emaj_get_current_log_table(TEXT,TEXT) IS
$$Retrieve the current log table of a given application table.$$;

CREATE OR REPLACE FUNCTION emaj._create_tbl(v_schema TEXT, v_tbl TEXT, v_groupName TEXT, v_priority INT, v_logDatTsp TEXT,
                                            v_logIdxTsp TEXT, v_timeId BIGINT, v_groupIsRollbackable BOOLEAN, v_groupIsLogging BOOLEAN)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_create_tbl$
-- This function creates all what is needed to manage the log and rollback operations for an application table.
-- Input: the application table to process, the group to add it into, the priority and tablespaces attributes, the time id of the
--        operation, 2 booleans indicating whether the group is rollbackable and whether the group is currently in logging state.
-- The objects created in the log schema:
--    - the associated log table, with its own sequence
--    - the function that logs the tables updates, defined as a trigger
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_schemaPrefix           TEXT = 'emaj_';
    v_emajNamesPrefix        TEXT;
    v_baseLogTableName       TEXT;
    v_baseLogIdxName         TEXT;
    v_baseLogFnctName        TEXT;
    v_baseSequenceName       TEXT;
    v_logSchema              TEXT;
    v_fullTableName          TEXT;
    v_logTableName           TEXT;
    v_logIdxName             TEXT;
    v_logFnctName            TEXT;
    v_sequenceName           TEXT;
    v_dataTblSpace           TEXT;
    v_idxTblSpace            TEXT;
    v_rlbkColList            TEXT;
    v_rlbkPkColList          TEXT;
    v_rlbkPkConditions       TEXT;
    v_genColList             TEXT;
    v_genValList             TEXT;
    v_genSetList             TEXT;
    v_genPkConditions        TEXT;
    v_nbGenAlwaysIdentCol    INTEGER;
    v_attnum                 SMALLINT;
    v_alter_log_table_param  TEXT;
    v_stmt                   TEXT;
    v_triggerList            TEXT;
  BEGIN
-- the checks on the table properties are performed by the calling functions
-- build the prefix of all emaj object to create
    IF length(v_tbl) <= 50 THEN
-- for not too long table name, the prefix is the table name itself
      v_emajNamesPrefix = v_tbl;
    ELSE
-- for long table names (over 50 char long), compute the suffix to add to the first 50 characters (#1, #2, ...), by looking at the
-- existing names
      SELECT substr(v_tbl, 1, 50) || '#' || coalesce(max(suffix) + 1, 1)::TEXT INTO v_emajNamesPrefix
        FROM
          (SELECT unnest(regexp_matches(substr(rel_log_table, 51),'#(\d+)'))::INT AS suffix
             FROM emaj.emaj_relation
             WHERE substr(rel_log_table, 1, 50) = substr(v_tbl, 1, 50)
          ) AS t;
    END IF;
-- build the name of emaj components associated to the application table (non schema qualified and not quoted)
    v_baseLogTableName     = v_emajNamesPrefix || '_log';
    v_baseLogIdxName       = v_emajNamesPrefix || '_log_idx';
    v_baseLogFnctName      = v_emajNamesPrefix || '_log_fnct';
    v_baseSequenceName     = v_emajNamesPrefix || '_log_seq';
-- build the different name for table, trigger, functions,...
    v_logSchema        = v_schemaPrefix || v_schema;
    v_fullTableName    = quote_ident(v_schema) || '.' || quote_ident(v_tbl);
    v_logTableName     = quote_ident(v_logSchema) || '.' || quote_ident(v_baseLogTableName);
    v_logIdxName       = quote_ident(v_baseLogIdxName);
    v_logFnctName      = quote_ident(v_logSchema) || '.' || quote_ident(v_baseLogFnctName);
    v_sequenceName     = quote_ident(v_logSchema) || '.' || quote_ident(v_baseSequenceName);
-- prepare TABLESPACE clauses for data and index
    v_dataTblSpace = coalesce('TABLESPACE ' || quote_ident(v_logDatTsp),'');
    v_idxTblSpace = coalesce('TABLESPACE ' || quote_ident(v_logIdxTsp),'');
-- create the log table: it looks like the application table, with some additional technical columns
    EXECUTE format('DROP TABLE IF EXISTS %s',
                   v_logTableName);
    EXECUTE format('CREATE TABLE %s (LIKE %s) %s',
                    v_logTableName, v_fullTableName, v_dataTblSpace);
    EXECUTE format('ALTER TABLE %s'
                   ' ADD COLUMN emaj_verb      VARCHAR(3),'
                   ' ADD COLUMN emaj_tuple     VARCHAR(3),'
                   ' ADD COLUMN emaj_gid       BIGINT      NOT NULL   DEFAULT nextval(''emaj.emaj_global_seq''),'
                   ' ADD COLUMN emaj_changed   TIMESTAMPTZ DEFAULT clock_timestamp(),'
                   ' ADD COLUMN emaj_txid      BIGINT      DEFAULT txid_current(),'
                   ' ADD COLUMN emaj_user      VARCHAR(32) DEFAULT session_user',
                   v_logTableName);
-- get the attnum of the emaj_verb column
    SELECT attnum INTO STRICT v_attnum
      FROM pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
      WHERE relnamespace = pg_namespace.oid AND attrelid = pg_class.oid
        AND nspname = v_logSchema
        AND relname = v_baseLogTableName
        AND attname = 'emaj_verb';
-- adjust the log table structure with the alter_log_table parameter, if set
    SELECT param_value_text INTO v_alter_log_table_param FROM emaj.emaj_param WHERE param_key = ('alter_log_table');
    IF v_alter_log_table_param IS NOT NULL AND v_alter_log_table_param <> '' THEN
      EXECUTE format('ALTER TABLE %s %s',
                     v_logTableName, v_alter_log_table_param);
    END IF;
-- create the index on the log table
    EXECUTE format('CREATE UNIQUE INDEX %s ON %s(emaj_gid, emaj_tuple)',
                    v_logIdxName, v_logTableName, v_idxTblSpace);
-- set the index associated to the primary key as cluster index. It may be useful for CLUSTER command.
    EXECUTE format('ALTER TABLE ONLY %s CLUSTER ON %s',
                   v_logTableName, v_logIdxName);
-- remove the NOT NULL constraints of application columns.
--   They are useless and blocking to store truncate event for tables belonging to audit_only tables
    SELECT string_agg(action, ',') INTO v_stmt FROM (
      SELECT ' ALTER COLUMN ' || quote_ident(attname) || ' DROP NOT NULL' AS action
        FROM pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid AND attrelid = pg_class.oid
          AND nspname = v_logSchema AND relname = v_baseLogTableName
          AND attnum > 0 AND attnum < v_attnum AND attisdropped = FALSE AND attnotnull) AS t;
    IF v_stmt IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %s %s',
                     v_logTableName, v_stmt);
    END IF;
-- create the sequence associated to the log table
    EXECUTE format('CREATE SEQUENCE %s',
                   v_sequenceName);
-- create the log function and the log trigger
    PERFORM emaj._create_log_trigger_tbl(v_fullTableName, v_logTableName, v_sequenceName, v_logFnctName);
-- If the group is idle, deactivate the log trigger (it will be enabled at emaj_start_group time)
    IF NOT v_groupIsLogging THEN
      EXECUTE format('ALTER TABLE %s DISABLE TRIGGER emaj_log_trg',
                     v_fullTableName);
    END IF;
-- creation of the trigger that manage any TRUNCATE on the application table
-- But the trigger is not immediately activated (it will be at emaj_start_group time)
    EXECUTE format('DROP TRIGGER IF EXISTS emaj_trunc_trg ON %s',
                   v_fullTableName);
    IF v_groupIsRollbackable THEN
-- For rollbackable groups, use the common _forbid_truncate_fnct() function that blocks the operation
      EXECUTE format('CREATE TRIGGER emaj_trunc_trg'
                     '  BEFORE TRUNCATE ON %s'
                     '  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._forbid_truncate_fnct()',
                     v_fullTableName);
    ELSE
-- For audit_only groups, use the common _log_truncate_fnct() function that records the operation into the log table
      EXECUTE format('CREATE TRIGGER emaj_trunc_trg'
                     '  BEFORE TRUNCATE ON %s'
                     '  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._log_truncate_fnct()',
                     v_fullTableName);
    END IF;
    IF NOT v_groupIsLogging THEN
      EXECUTE format('ALTER TABLE %s DISABLE TRIGGER emaj_trunc_trg',
                     v_fullTableName);
    END IF;
-- grant appropriate rights to both emaj roles
    EXECUTE format('GRANT SELECT ON TABLE %s TO emaj_viewer',
                   v_logTableName);
    EXECUTE format('GRANT ALL PRIVILEGES ON TABLE %s TO emaj_adm',
                   v_logTableName);
    EXECUTE format('GRANT SELECT ON SEQUENCE %s TO emaj_viewer',
                   v_sequenceName);
    EXECUTE format('GRANT ALL PRIVILEGES ON SEQUENCE %s TO emaj_adm',
                   v_sequenceName);
-- Build some pieces of SQL statements that will be needed at table rollback and gen_sql times
--   left NULL if the table hos no pkey
    SELECT * FROM emaj._build_sql_tbl(v_fullTableName)
      INTO v_rlbkColList, v_rlbkPkColList, v_rlbkPkConditions, v_genColList,
           v_genValList, v_genSetList, v_genPkConditions, v_nbGenAlwaysIdentCol;
-- register the table into emaj_relation
    INSERT INTO emaj.emaj_relation
               (rel_schema, rel_tblseq, rel_time_range, rel_group, rel_priority,
                rel_log_schema, rel_log_dat_tsp, rel_log_idx_tsp, rel_kind, rel_log_table,
                rel_log_index, rel_log_sequence, rel_log_function, rel_emaj_verb_attnum, rel_has_always_ident_col,
                rel_sql_rlbk_columns, rel_sql_rlbk_pk_columns, rel_sql_rlbk_pk_conditions,
                rel_sql_gen_ins_col, rel_sql_gen_ins_val, rel_sql_gen_upd_set, rel_sql_gen_pk_conditions)
        VALUES (v_schema, v_tbl, int8range(v_timeId, NULL, '[)'), v_groupName, v_priority,
                v_logSchema, v_logDatTsp, v_logIdxTsp, 'r', v_baseLogTableName,
                v_baseLogIdxName, v_baseSequenceName, v_baseLogFnctName, v_attnum, v_nbGenAlwaysIdentCol > 0,
                v_rlbkColList, v_rlbkPkColList, v_rlbkPkConditions,
                v_genColList, v_genValList, v_genSetList, v_genPkConditions);
--
-- check if the table has (neither internal - ie. created for fk - nor previously created by emaj) trigger
    SELECT string_agg(tgname, ', ' ORDER BY tgname) INTO v_triggerList FROM (
      SELECT tgname FROM pg_catalog.pg_trigger
        WHERE tgrelid = v_fullTableName::regclass AND tgconstraint = 0 AND tgname NOT LIKE E'emaj\\_%\\_trg') AS t;
-- if yes, issue a warning
--   (if a trigger updates another table in the same table group or outside) it could generate problem at rollback time)
    IF v_triggerList IS NOT NULL THEN
      RAISE WARNING '_create_tbl: The table "%" has triggers (%). They will be automatically disabled during E-Maj rollback operations,'
                    ' unless they have been recorded into the list of triggers that may be kept enabled, with the'
                    ' emaj_ignore_app_trigger() function.', v_fullTableName, v_triggerList;
    END IF;
    RETURN;
  END;
$_create_tbl$;

CREATE OR REPLACE FUNCTION emaj._create_log_trigger_tbl(v_fullTableName TEXT, v_logTableName TEXT, v_sequenceName TEXT, v_logFnctName TEXT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_create_log_trigger_tbl$
-- The function creates the log function and the associated log trigger for an application table.
-- It is called by several functions.
-- Inputs: the full name of the application table, the log table, the log sequence and the log function
-- The function is defined as SECURITY DEFINER so that emaj_adm role can manage the trigger on the application table.
  DECLARE
  BEGIN
-- drop the log trigger if it exists
    EXECUTE format('DROP TRIGGER IF EXISTS emaj_log_trg ON %s',
                   v_fullTableName);
-- create the log fonction that will be mapped to the log trigger just after
--   the new row is logged for each INSERT, the old row is logged for each DELETE
--   and the old and the new rows are logged for each UPDATE.
    EXECUTE 'CREATE OR REPLACE FUNCTION ' || v_logFnctName || '() RETURNS TRIGGER AS $logfnct$'
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
         || '$logfnct$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp;';
-- create the log trigger on the application table, using the previously created log function
    EXECUTE format('CREATE TRIGGER emaj_log_trg'
                   ' AFTER INSERT OR UPDATE OR DELETE ON %s'
                   '  FOR EACH ROW EXECUTE PROCEDURE %s()',
                   v_fullTableName, v_logFnctName);
    RETURN;
  END;
$_create_log_trigger_tbl$;

CREATE OR REPLACE FUNCTION emaj._build_sql_tbl(v_fullTableName TEXT, OUT v_rlbkColList TEXT, OUT v_rlbkPkColList TEXT,
                                               OUT v_rlbkPkConditions TEXT, OUT v_genColList TEXT, OUT v_genValList TEXT,
                                               OUT v_genSetList TEXT, OUT v_genPkConditions TEXT, OUT v_nbGenAlwaysIdentCol INT)
LANGUAGE plpgsql AS
$_build_sql_tbl$
-- This function creates all pieces of SQL that will be recorded into the emaj_relation table, for one application table.
-- They will later be used at rollback or SQL script generation time.
-- All SQL pieces are left empty if the table has no pkey, neither rollback nor sql script generation operations being possible
--   in this case
-- The Insert columns list remains empty if it is not needed to have a specific list (i.e. when the application table does not contain
--   any generated column)
-- Input: the full application table name
-- Output: 7 pieces of SQL, and the number of columns declared GENERATED ALWAYS AS IDENTITY
  DECLARE
    v_stmt                   TEXT;
    v_nbGenAlwaysExprCol     INTEGER;
    v_unquotedType           TEXT[] = array['smallint','integer','bigint','numeric','decimal',
                                             'int2','int4','int8','serial','bigserial',
                                             'real','double precision','float','float4','float8','oid'];
    r_col                    RECORD;
  BEGIN
--   build the pkey columns list and the "equality on the primary key" conditions for the rollback function
--     and for the UPDATE and DELETE statements of the sql generation function
--     (it takes column names in pg_attribute from the table's definition instead of index definition is mandatory
--     starting from pg9.0, joining tables with indkey instead of indexrelid)
    SELECT string_agg(quote_ident(attname), ','),
           string_agg('tbl.' || quote_ident(attname) || ' = keys.' || quote_ident(attname), ' AND '),
           string_agg(
             CASE WHEN format_type = ANY(v_unquotedType) THEN
               quote_ident(replace(attname,'''','''''')) || ' = '' || o.' || quote_ident(attname) || ' || '''
                  ELSE
               quote_ident(replace(attname,'''','''''')) || ' = '' || quote_literal(o.' || quote_ident(attname) || ') || '''
             END, ' AND ')
      INTO v_rlbkPkColList, v_rlbkPkConditions, v_genPkConditions
      FROM (
        SELECT attname, regexp_replace(format_type(atttypid,atttypmod),E'\\(.*$','') AS format_type
          FROM pg_catalog.pg_attribute, pg_catalog.pg_index
          WHERE pg_attribute.attrelid = pg_index.indrelid
            AND attnum = ANY (indkey)
            AND indrelid = v_fullTableName::regclass AND indisprimary
            AND attnum > 0 AND attisdropped = FALSE
          ORDER BY attnum) AS t;
--
-- retrieve from pg_attribute simple columns list and indicators
-- if the table has no pkey, keep all the sql pieces to NULL (rollback or sql script generation operations being impossible)
    IF v_rlbkPkColList IS NOT NULL THEN
      v_stmt = 'SELECT string_agg(''tbl.'' || quote_ident(attname), '','') FILTER (WHERE attgenerated = ''''),'
--                             the columns list for rollback, excluding the GENERATED ALWAYS AS (expression) columns
               '       string_agg(quote_ident(replace(attname,'''''''','''''''''''')), '', '') FILTER (WHERE attgenerated = ''''),'
--                             the INSERT columns list for sql generation, excluding the GENERATED ALWAYS AS (expression) columns
               '       count(*) FILTER (WHERE attidentity = ''a''),'
--                             the number of GENERATED ALWAYS AS IDENTITY columns
               '       count(*) FILTER (WHERE attgenerated <> '''')'
--                             the number of GENERATED ALWAYS AS (expression) columns
               '  FROM ('
               '  SELECT attname, %s AS attidentity, %s AS attgenerated'
               '    FROM pg_catalog.pg_attribute'
               '    WHERE attrelid = %s::regclass'
               '      AND attnum > 0 AND NOT attisdropped'
               '  ORDER BY attnum) AS t';
      EXECUTE format(v_stmt,
                     CASE WHEN emaj._pg_version_num() >= 100000 THEN 'attidentity' ELSE '''''::TEXT' END,
                     CASE WHEN emaj._pg_version_num() >= 120000 THEN 'attgenerated' ELSE '''''::TEXT' END,
                     quote_literal(v_fullTableName))
        INTO v_rlbkColList, v_genColList, v_nbGenAlwaysIdentCol, v_nbGenAlwaysExprCol;
      IF v_nbGenAlwaysExprCol = 0 THEN
-- if the table doesn't contain any generated columns, the is no need for the columns list in the INSERT clause
        v_genColList = '';
      END IF;
--
-- retrieve from pg_attribute all columns of the application table and build :
-- - the VALUES list used in the INSERT statements
-- - the SET list used in the UPDATE statements
-- the logic is too complex to be build with aggregate functions. So loop on all columns.
      v_genValList = '';
      v_genSetList = '';
      FOR r_col IN EXECUTE format(
        ' SELECT attname, format_type(atttypid,atttypmod) AS format_type, %s AS attidentity, %s AS attgenerated'
        ' FROM pg_catalog.pg_attribute'
        ' WHERE attrelid = %s::regclass'
        '   AND attnum > 0 AND NOT attisdropped'
        ' ORDER BY attnum',
        CASE WHEN emaj._pg_version_num() >= 100000 THEN 'attidentity' ELSE '''''::TEXT' END,
        CASE WHEN emaj._pg_version_num() >= 120000 THEN 'attgenerated' ELSE '''''::TEXT' END,
        quote_literal(v_fullTableName))
      LOOP
-- test if the column format (up to the parenthesis) belongs to the list of formats that do not require any quotation (like numeric
-- data types)
        IF regexp_replace(r_col.format_type,E'\\(.*$','') = ANY(v_unquotedType) THEN
-- literal for this column can remain as is
          IF r_col.attgenerated = '' THEN                                     -- GENERATED ALWAYS AS (expression) columns are not inserted
            v_genValList = v_genValList || ''' || coalesce(o.' || quote_ident(r_col.attname) || '::TEXT,''NULL'') || '', ';
          END IF;
          IF r_col.attidentity <> 'a' AND r_col.attgenerated = '' THEN        -- GENERATED ALWAYS columns are not updated
            v_genSetList = v_genSetList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || coalesce(n.'
                                        || quote_ident(r_col.attname) || ' ::TEXT,''NULL'') || '', ';
          END IF;
        ELSE
-- literal for this column must be quoted
          IF r_col.attgenerated = '' THEN                                     -- GENERATED ALWAYS AS (expression) columns are not inserted
            v_genValList = v_genValList || ''' || quote_nullable(o.' || quote_ident(r_col.attname) || ') || '', ';
          END IF;
          IF r_col.attidentity <> 'a' AND r_col.attgenerated = '' THEN        -- GENERATED ALWAYS columns are not updated
            v_genSetList = v_genSetList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || quote_nullable(n.'
                                        || quote_ident(r_col.attname) || ') || '', ';
          END IF;
        END IF;
      END LOOP;
-- suppress the final separators
      v_genValList = substring(v_genValList FROM 1 FOR char_length(v_genValList) - 2);
      v_genSetList = substring(v_genSetList FROM 1 FOR char_length(v_genSetList) - 2);
    END IF;
    RETURN;
  END;
$_build_sql_tbl$;

CREATE OR REPLACE FUNCTION emaj._add_tbl(v_schema TEXT, v_table TEXT, v_group TEXT, v_priority INT, v_logDatTsp TEXT, v_logIdxTsp TEXT,
                                         v_groupIsLogging BOOLEAN, v_timeId BIGINT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_add_tbl$
-- The function adds a table to a group. It is called during an alter group or a dynamic assignment operation.
-- If the group is in idle state, it simply calls the _create_tbl() function.
-- Otherwise, it calls the _create_tbl() function, activates the log trigger and
--    sets a restart value for the log sequence if a previous range exists for the relation.
-- Required inputs: schema and table to add, group name, priority, log data and index tablespace, the group's logging state,
--                  the time stamp id of the operation, main calling function.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can enable triggers on application tables.
  DECLARE
    v_groupIsRollbackable    BOOLEAN;
    v_logSchema              TEXT;
    v_logSequence            TEXT;
    v_nextVal                BIGINT;
  BEGIN
-- get the is_rollbackable status of the related group
    SELECT group_is_rollbackable INTO v_groupIsRollbackable
      FROM emaj.emaj_group WHERE group_name = v_group;
-- create the table
    PERFORM emaj._create_tbl(v_schema, v_table, v_group, v_priority, v_logDatTsp, v_logIdxTsp,
                             v_timeId, v_groupIsRollbackable, v_groupIsLogging);
-- if the group is in logging state, perform additional tasks
    IF v_groupIsLogging THEN
-- ... get the log schema and sequence for the new relation
      SELECT rel_log_schema, rel_log_sequence INTO v_logSchema, v_logSequence
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
-- ... get the last log sequence value, if any, for this relation (recorded in emaj_relation at a previous REMOVE_TBL operation)
      SELECT max(rel_log_seq_last_value) + 1 INTO v_nextVal FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_table
          AND rel_log_seq_last_value IS NOT NULL;
-- ... set the new log sequence next_val, if needed
      IF v_nextVal IS NOT NULL AND v_nextVal > 1 THEN
        EXECUTE format('ALTER SEQUENCE %I.%I RESTART %s',
                       v_logSchema, v_logSequence, v_nextVal);
      END IF;
-- ... record the new log sequence state in the emaj_sequence table for the current operation mark
      INSERT INTO emaj.emaj_sequence (sequ_schema, sequ_name, sequ_time_id, sequ_last_val, sequ_start_val,
                  sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called)
        SELECT * FROM emaj._get_current_sequence_state(v_logSchema, v_logSequence, v_timeId);
    END IF;
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'TABLE ADDED', quote_ident(v_schema) || '.' || quote_ident(v_table),
              'To the ' || CASE WHEN v_groupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_group);
    RETURN;
  END;
$_add_tbl$;

CREATE OR REPLACE FUNCTION emaj._change_priority_tbl(v_schema TEXT, v_table TEXT, v_currentPriority INT, v_newPriority INT,
                                                     v_function TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_change_priority_tbl$
-- This function changes the priority for an application table.
-- Input: the table identity, the old and new priorities and the calling function.
  BEGIN
-- update the emaj_relation row for the table
    UPDATE emaj.emaj_relation SET rel_priority = v_newPriority
      FROM emaj.emaj_group
      WHERE rel_group = group_name
        AND rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'PRIORITY CHANGED',
              quote_ident(v_schema) || '.' || quote_ident(v_table),
              coalesce(v_currentPriority::char, 'NULL') || ' => ' || coalesce(v_newPriority::char, 'NULL'));
    RETURN;
  END;
$_change_priority_tbl$;

CREATE OR REPLACE FUNCTION emaj._change_log_data_tsp_tbl(v_schema TEXT, v_table TEXT, v_logSchema TEXT, v_currentLogTable TEXT,
                                                         v_currentLogDatTsp TEXT, v_newLogDatTsp TEXT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_change_log_data_tsp_tbl$
-- This function changes the log data tablespace for an application table.
-- Input: the existing emaj_relation characteristics for the table, the new log data tablespace and the calling function.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_newTsp                 TEXT;
  BEGIN
-- build the new data tablespace name. If needed, get the name of the current default tablespace.
    v_newTsp = v_newLogDatTsp;
    IF v_newTsp IS NULL OR v_newTsp = '' THEN
      v_newTsp = emaj._get_default_tablespace();
    END IF;
-- process the log data tablespace change
    EXECUTE format('ALTER TABLE %I.%I SET TABLESPACE %I',
                   v_logSchema, v_currentLogTable, v_newTsp);
-- update the table attributes into emaj_relation
    UPDATE emaj.emaj_relation SET rel_log_dat_tsp = v_newLogDatTsp
      WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'LOG DATA TABLESPACE CHANGED',
              quote_ident(v_schema) || '.' || quote_ident(v_table),
              coalesce(v_currentLogDatTsp, 'Default tablespace') || ' => ' || coalesce(v_newLogDatTsp, 'Default tablespace'));
    RETURN;
  END;
$_change_log_data_tsp_tbl$;

CREATE OR REPLACE FUNCTION emaj._change_log_index_tsp_tbl(v_schema TEXT, v_table TEXT, v_logSchema TEXT, v_currentLogIndex TEXT,
                                                         v_currentLogIdxTsp TEXT, v_newLogIdxTsp TEXT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_change_log_index_tsp_tbl$
-- This function changes the log index tablespace for an application table.
-- Input: the existing emaj_relation characteristics for the table, the new log index tablespace and the calling function.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_newTsp                 TEXT;
  BEGIN
-- build the new data tablespace name. If needed, get the name of the current default tablespace.
    v_newTsp = v_newLogIdxTsp;
    IF v_newTsp IS NULL OR v_newTsp = '' THEN
      v_newTsp = emaj._get_default_tablespace();
    END IF;
-- process the log index tablespace change
    EXECUTE format('ALTER INDEX %I.%I SET TABLESPACE %I',
                   v_logSchema, v_currentLogIndex, v_newTsp);
-- update the table attributes into emaj_relation
    UPDATE emaj.emaj_relation SET rel_log_idx_tsp = v_newLogIdxTsp
      WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'LOG INDEX TABLESPACE CHANGED',
              quote_ident(v_schema) || '.' || quote_ident(v_table),
              coalesce(v_currentLogIdxTsp, 'Default tablespace') || ' => ' || coalesce(v_newLogIdxTsp, 'Default tablespace'));
    RETURN;
  END;
$_change_log_index_tsp_tbl$;

CREATE OR REPLACE FUNCTION emaj._remove_tbl(v_schema TEXT, v_table TEXT, v_group TEXT, v_groupIsLogging BOOLEAN,
                                            v_timeId BIGINT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_remove_tbl$
-- The function removes a table from a group. It is called during an alter group or a dynamic removal operation.
-- If the group is in idle state, it simply calls the _drop_tbl() function.
-- Otherwise, only triggers, log function and log sequence are dropped now. The other components will be dropped later (at reset_group
-- time for instance).
-- Required inputs: schema and sequence to remove, related group name and logging state,
--                  time stamp id of the operation, main calling function.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can drop triggers on application tables.
  DECLARE
    v_logSchema              TEXT;
    v_currentLogTable        TEXT;
    v_currentLogIndex        TEXT;
    v_logFunction            TEXT;
    v_logSequence            TEXT;
    v_logSequenceLastValue   BIGINT;
    v_namesSuffix            TEXT;
    v_fullTableName          TEXT;
  BEGIN
    IF NOT v_groupIsLogging THEN
-- if the group is in idle state, drop the table immediately
      PERFORM emaj._drop_tbl(emaj.emaj_relation.*, v_timeId) FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
    ELSE
-- if the group is in logging state, ...
-- ... get the current relation characteristics
      SELECT rel_log_schema, rel_log_table, rel_log_index, rel_log_function, rel_log_sequence
        INTO v_logSchema, v_currentLogTable, v_currentLogIndex, v_logFunction, v_logSequence
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
-- ... get the current log sequence characteristics
      SELECT CASE WHEN sequ_is_called THEN sequ_last_val ELSE sequ_last_val - sequ_increment END INTO STRICT v_logSequenceLastValue
        FROM emaj.emaj_sequence
        WHERE sequ_schema = v_logSchema AND sequ_name = v_logSequence AND sequ_time_id = v_timeId;
-- ... compute the suffix to add to the log table and index names (_1, _2, ...), by looking at the existing names
      SELECT '_' || coalesce(max(suffix) + 1, 1)::TEXT INTO v_namesSuffix
        FROM
          (SELECT unnest(regexp_matches(rel_log_table,'_(\d+)$'))::INT AS suffix
             FROM emaj.emaj_relation
             WHERE rel_schema = v_schema AND rel_tblseq = v_table
          ) AS t;
-- ... rename the log table and its index (they may have been dropped)
      EXECUTE format('ALTER TABLE IF EXISTS %I.%I RENAME TO %I',
                     v_logSchema, v_currentLogTable, v_currentLogTable || v_namesSuffix);
      EXECUTE format('ALTER INDEX IF EXISTS %I.%I RENAME TO %I',
                     v_logSchema, v_currentLogIndex, v_currentLogIndex || v_namesSuffix);
-- ... drop the log and truncate triggers
--     (check the application table exists before dropping its triggers to avoid an error fires with postgres version <= 9.3)
      v_fullTableName  = quote_ident(v_schema) || '.' || quote_ident(v_table);
      PERFORM 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = v_schema AND relname = v_table AND relkind = 'r';
      IF FOUND THEN
        EXECUTE format('DROP TRIGGER IF EXISTS emaj_log_trg ON %s',
                       v_fullTableName);
        EXECUTE format('DROP TRIGGER IF EXISTS emaj_trunc_trg ON %s',
                       v_fullTableName);
      END IF;
-- ... drop the log function and the log sequence
-- (but we keep the sequence related data in the emaj_sequence and the emaj_seq_hole tables)
      EXECUTE format('DROP FUNCTION IF EXISTS %I.%I() CASCADE',
                     v_logSchema, v_logFunction);
      EXECUTE format('DROP SEQUENCE IF EXISTS %I.%I',
                     v_logSchema, v_logSequence);
-- ... register the end of the relation time frame, the last value of the log sequence, the log table and index names change,
-- reflect the changes into the emaj_relation rows
--   - for all timeranges pointing to this log table and index
--     (do not reset the rel_log_sequence value: it will be needed later for _drop_tbl() for the emaj_sequence cleanup)
      UPDATE emaj.emaj_relation
        SET rel_log_table = v_currentLogTable || v_namesSuffix , rel_log_index = v_currentLogIndex || v_namesSuffix,
            rel_log_function = NULL, rel_sql_rlbk_columns = NULL, rel_sql_rlbk_pk_columns = NULL, rel_sql_rlbk_pk_conditions = NULL,
            rel_log_seq_last_value = v_logSequenceLastValue
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND rel_log_table = v_currentLogTable;
--   - and close the last timerange
      UPDATE emaj.emaj_relation
        SET rel_time_range = int8range(lower(rel_time_range), v_timeId, '[)')
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
    END IF;
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'TABLE REMOVED', quote_ident(v_schema) || '.' || quote_ident(v_table),
              'From the ' || CASE WHEN v_groupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_group);
    RETURN;
  END;
$_remove_tbl$;

CREATE OR REPLACE FUNCTION emaj._move_tbl(v_schema TEXT, v_table TEXT, v_oldGroup TEXT, v_oldGroupIsLogging BOOLEAN, v_newGroup TEXT,
                                          v_newGroupIsLogging BOOLEAN, v_timeId BIGINT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_move_tbl$
-- The function change the group ownership of a table. It is called during an alter group or a dynamic assignment operation.
-- Required inputs: schema and table to move, old and new group names and their logging state,
--                  time stamp id of the operation, main calling function.
  DECLARE
    v_logSchema              TEXT;
    v_logSequence            TEXT;
  BEGIN
-- register the end of the previous relation time frame and create a new relation time frame with the new group
    UPDATE emaj.emaj_relation
      SET rel_time_range = int8range(lower(rel_time_range),v_timeId,'[)')
      WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
    INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind, rel_priority, rel_log_schema,
                                    rel_log_table, rel_log_dat_tsp, rel_log_index, rel_log_idx_tsp, rel_log_sequence, rel_log_function,
                                    rel_emaj_verb_attnum, rel_has_always_ident_col,
                                    rel_sql_rlbk_columns, rel_sql_rlbk_pk_columns, rel_sql_rlbk_pk_conditions,
                                    rel_sql_gen_ins_col, rel_sql_gen_ins_val, rel_sql_gen_upd_set, rel_sql_gen_pk_conditions,
                                    rel_log_seq_last_value)
      SELECT rel_schema, rel_tblseq, int8range(v_timeId, NULL, '[)'), v_newGroup, rel_kind, rel_priority, rel_log_schema,
             rel_log_table, rel_log_dat_tsp, rel_log_index, rel_log_idx_tsp, rel_log_sequence, rel_log_function,
             rel_emaj_verb_attnum, rel_has_always_ident_col,
             rel_sql_rlbk_columns, rel_sql_rlbk_pk_columns, rel_sql_rlbk_pk_conditions,
             rel_sql_gen_ins_col, rel_sql_gen_ins_val, rel_sql_gen_upd_set, rel_sql_gen_pk_conditions,
             rel_log_seq_last_value
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper(rel_time_range) = v_timeId;
-- if the table enters in a group in logging state,
    IF NOT v_oldGroupIsLogging AND v_newGroupIsLogging THEN
-- ... get the log schema and sequence for the new relation
      SELECT rel_log_schema, rel_log_sequence INTO v_logSchema, v_logSequence
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_table AND upper_inf(rel_time_range);
-- ... record the new log sequence state in the emaj_sequence table for the current operation mark
      INSERT INTO emaj.emaj_sequence (sequ_schema, sequ_name, sequ_time_id, sequ_last_val, sequ_start_val,
                  sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called)
        SELECT * FROM emaj._get_current_sequence_state(v_logSchema, v_logSequence, v_timeId);
    END IF;
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'TABLE MOVED', quote_ident(v_schema) || '.' || quote_ident(v_table),
              'From the ' || CASE WHEN v_oldGroupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_oldGroup ||
              ' to the ' || CASE WHEN v_newGroupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_newGroup);
    RETURN;
  END;
$_move_tbl$;

CREATE OR REPLACE FUNCTION emaj._drop_tbl(r_rel emaj.emaj_relation, v_timeId BIGINT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_drop_tbl$
-- The function deletes a timerange for a table. This centralizes the deletion of all what has been created by _create_tbl() function.
-- Required inputs: row from emaj_relation corresponding to the appplication table to proccess, time id.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_fullTableName          TEXT;
  BEGIN
    v_fullTableName    = quote_ident(r_rel.rel_schema) || '.' || quote_ident(r_rel.rel_tblseq);
-- if the table is currently linked to a group, drop the log trigger, function and sequence
    IF upper_inf(r_rel.rel_time_range) THEN
-- check the table exists before dropping its triggers
      PERFORM 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = r_rel.rel_schema AND relname = r_rel.rel_tblseq AND relkind = 'r';
      IF FOUND THEN
-- drop the log and truncate triggers on the application table
        EXECUTE format('DROP TRIGGER IF EXISTS emaj_log_trg ON %s',
                       v_fullTableName);
        EXECUTE format('DROP TRIGGER IF EXISTS emaj_trunc_trg ON %s',
                       v_fullTableName);
      END IF;
-- drop the log function
      IF r_rel.rel_log_function IS NOT NULL THEN
        EXECUTE format('DROP FUNCTION IF EXISTS %I.%I() CASCADE',
                       r_rel.rel_log_schema, r_rel.rel_log_function);
      END IF;
-- drop the sequence associated to the log table
      EXECUTE format('DROP SEQUENCE IF EXISTS %I.%I',
                     r_rel.rel_log_schema, r_rel.rel_log_sequence);
    END IF;
-- drop the log table if it is not referenced on other timeranges (for potentially other groups)
    IF NOT EXISTS(SELECT 1 FROM emaj.emaj_relation
                    WHERE rel_log_schema = r_rel.rel_log_schema AND rel_log_table = r_rel.rel_log_table
                      AND rel_time_range <> r_rel.rel_time_range) THEN
      EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE',
                     r_rel.rel_log_schema, r_rel.rel_log_table);
    END IF;
-- process log sequence information if the sequence is not referenced in other timerange (for potentially other groups)
    IF NOT EXISTS(SELECT 1 FROM emaj.emaj_relation
                    WHERE rel_log_schema = r_rel.rel_log_schema AND rel_log_sequence = r_rel.rel_log_sequence
                      AND rel_time_range <> r_rel.rel_time_range) THEN
-- delete rows related to the log sequence from emaj_sequence table
-- (it may delete rows for other already processed time_ranges for the same table)
      DELETE FROM emaj.emaj_sequence WHERE sequ_schema = r_rel.rel_log_schema AND sequ_name = r_rel.rel_log_sequence;
-- delete rows related to the table from emaj_seq_hole table
-- (it may delete holes for timeranges that do not belong to the group, if a table has been moved to another group,
--  but is safe enough for rollbacks)
      DELETE FROM emaj.emaj_seq_hole WHERE sqhl_schema = r_rel.rel_schema AND sqhl_table = r_rel.rel_tblseq;
    END IF;
-- keep a trace of the table group ownership history and finaly delete the table reference from the emaj_relation table
    WITH deleted AS (
      DELETE FROM emaj.emaj_relation
        WHERE rel_schema = r_rel.rel_schema AND rel_tblseq = r_rel.rel_tblseq AND rel_time_range = r_rel.rel_time_range
        RETURNING rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind
      )
    INSERT INTO emaj.emaj_rel_hist
             (relh_schema, relh_tblseq, relh_time_range, relh_group, relh_kind)
      SELECT rel_schema, rel_tblseq,
             CASE WHEN upper_inf(rel_time_range) THEN int8range(lower(rel_time_range), v_timeId, '[)') ELSE rel_time_range END,
             rel_group, rel_kind
        FROM deleted;
    RETURN;
  END;
$_drop_tbl$;

CREATE OR REPLACE FUNCTION emaj.emaj_assign_sequence(v_schema TEXT, v_sequence TEXT, v_group TEXT, v_mark TEXT DEFAULT 'ASSIGN_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_assign_sequence$
-- The function assigns a sequence into a tables group.
-- Inputs: schema name, sequence name, assignment group name, mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively assigned to the tables group, ie. 1
  BEGIN
    RETURN emaj._assign_sequences(v_schema, ARRAY[v_sequence], v_group, v_mark , FALSE, FALSE);
  END;
$emaj_assign_sequence$;
COMMENT ON FUNCTION emaj.emaj_assign_sequence(TEXT,TEXT,TEXT,TEXT) IS
$$Assign a sequence into a tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_assign_sequences(v_schema TEXT, v_sequences TEXT[], v_group TEXT, v_mark TEXT DEFAULT 'ASSIGN_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_assign_sequences$
-- The function assigns several sequences at once into a tables group.
-- Inputs: schema, array of sequence names, assignment group name,
--         mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively assigned to the tables group
  BEGIN
    RETURN emaj._assign_sequences(v_schema, v_sequences, v_group, v_mark, TRUE, FALSE);
  END;
$emaj_assign_sequences$;
COMMENT ON FUNCTION emaj.emaj_assign_sequences(TEXT,TEXT[],TEXT,TEXT) IS
$$Assign several sequences into a tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_assign_sequences(v_schema TEXT, v_sequencesIncludeFilter TEXT, v_sequencesExcludeFilter TEXT,
                                                      v_group TEXT, v_mark TEXT DEFAULT 'ASSIGN_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_assign_sequences$
-- The function assigns sequences on name regexp pattern into a tables group.
-- Inputs: schema name, 2 patterns to filter sequence names (one to include and another to exclude), assignment group name,
--         mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively assigned to the tables group
  DECLARE
    v_sequences              TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_sequencesIncludeFilter = '' THEN NULL ELSE v_sequencesIncludeFilter END,
           CASE WHEN v_sequencesExcludeFilter = '' THEN NULL ELSE v_sequencesExcludeFilter END
      INTO v_sequencesIncludeFilter, v_sequencesExcludeFilter;
-- Build the list of sequences names satisfying the pattern
    SELECT array_agg(relname) INTO v_sequences FROM (
      SELECT relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid
          AND nspname = v_schema
          AND relname ~ v_sequencesIncludeFilter
          AND (v_sequencesExcludeFilter IS NULL OR relname !~ v_sequencesExcludeFilter)
          AND relkind IN ('S')
        ORDER BY relname) AS t;
-- OK, call the _assign_sequences() function for execution
    RETURN emaj._assign_sequences(v_schema, v_sequences, v_group, v_mark, TRUE, TRUE);
  END;
$emaj_assign_sequences$;
COMMENT ON FUNCTION emaj.emaj_assign_sequences(TEXT,TEXT,TEXT,TEXT,TEXT) IS
$$Assign sequences on name patterns into a tables group.$$;

CREATE OR REPLACE FUNCTION emaj._assign_sequences(v_schema TEXT, v_sequences TEXT[], v_group TEXT, v_mark TEXT,
                                                  v_multiSequence BOOLEAN, v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS
$_assign_sequences$
-- The function effectively assigns sequences into a tables group.
-- Inputs: schema, array of sequence names, group name,
--         mark to set for lonnging groups, a boolean indicating whether several sequences need to be processed,
--         a boolean indicating whether the tables array has been built from regex filters
-- Outputs: number of sequences effectively assigned to the tables group
-- The JSONB v_properties parameter has currenlty only one field '{"priority":...}' the properties being NULL by default
  DECLARE
    v_function               TEXT;
    v_groupIsLogging         BOOLEAN;
    v_list                   TEXT;
    v_array                  TEXT[];
    v_timeId                 BIGINT;
    v_markName               TEXT;
    v_oneSequence            TEXT;
    v_nbAssignedSeq          INT = 0;
  BEGIN
    v_function = CASE WHEN v_multiSequence THEN 'ASSIGN_SEQUENCES' ELSE 'ASSIGN_SEQUENCE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check supplied parameters
-- check the group name and if ok, get some properties of the group
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_group], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
    SELECT group_is_logging INTO v_groupIsLogging
      FROM emaj.emaj_group WHERE group_name = v_group;
-- check the supplied schema exists and is not an E-Maj schema
    PERFORM 1 FROM pg_catalog.pg_namespace
      WHERE nspname = v_schema;
    IF NOT FOUND THEN
      RAISE EXCEPTION '_assign_sequences: The schema "%" does not exist.', v_schema;
    END IF;
    PERFORM 1 FROM emaj.emaj_schema
      WHERE sch_name = v_schema;
    IF FOUND THEN
      RAISE EXCEPTION '_assign_sequences: The schema "%" is an E-Maj schema.', v_schema;
    END IF;
-- check sequences
    IF NOT v_arrayFromRegex THEN
-- from the sequences array supplied by the user, remove duplicates values, NULL and empty strings from the supplied sequence names array
      SELECT array_agg(DISTINCT sequence_name) INTO v_sequences FROM unnest(v_sequences) AS sequence_name
        WHERE sequence_name IS NOT NULL AND sequence_name <> '';
-- check that application sequences exist
      WITH sequences AS (
        SELECT unnest(v_sequences) AS sequence_name)
      SELECT string_agg(quote_ident(sequence_name), ', ') INTO v_list
        FROM (
          SELECT sequence_name FROM sequences
          WHERE NOT EXISTS (
            SELECT 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace
              WHERE relnamespace = pg_namespace.oid
                AND nspname = v_schema AND relname = sequence_name
                AND relkind IN ('S'))
        ) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_assign_sequences: In schema %, some sequences (%) do not exist.', quote_ident(v_schema), v_list;
      END IF;
    END IF;
-- check or discard sequences already assigned to a group
    SELECT string_agg(quote_ident(rel_tblseq), ', '), array_agg(rel_tblseq) INTO v_list, v_array
      FROM emaj.emaj_relation
      WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_sequences) AND upper_inf(rel_time_range);
    IF v_list IS NOT NULL THEN
      IF NOT v_arrayFromRegex THEN
        RAISE EXCEPTION '_assign_sequences: In schema %, some sequences (%) already belong to a group.', quote_ident(v_schema), v_list;
      ELSE
        RAISE WARNING '_assign_sequences: Some sequences already belonging to a group (%) are not selected.', v_list;
        -- remove these sequences from the sequences to process
        SELECT array_agg(remaining_sequence) INTO v_sequences
          FROM (SELECT unnest(v_sequences) EXCEPT SELECT unnest(v_array)) AS t(remaining_sequence);
      END IF;
    END IF;
-- check the supplied mark
    SELECT emaj._check_new_mark(array[v_group], v_mark) INTO v_markName;
-- OK,
    IF v_sequences IS NULL OR v_sequences = '{}' THEN
-- when no sequences are finaly selected, just warn
      RAISE WARNING '_assign_sequences: No sequence to process.';
    ELSE
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_groupIsLogging THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(ARRAY[v_group], 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(ARRAY[v_group], v_markName, FALSE, TRUE, NULL, v_timeId);
      END IF;
-- effectively create the log components for each table
      FOREACH v_oneSequence IN ARRAY v_sequences
      LOOP
        PERFORM emaj._add_seq(v_schema, v_oneSequence, v_group, v_groupIsLogging, v_timeId, v_function);
-- insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
        INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging)
          VALUES (v_timeId, 'ADD_SEQ', v_schema, v_oneSequence, v_group, v_groupIsLogging);
        v_nbAssignedSeq = v_nbAssignedSeq + 1;
      END LOOP;
-- adjust the group characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId,
            group_nb_sequence = (SELECT count(*) FROM emaj.emaj_relation
                                WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'S')
        WHERE group_name = v_group;
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbAssignedSeq || ' sequences assigned to the group ' || v_group);
    RETURN v_nbAssignedSeq;
  END;
$_assign_sequences$;

CREATE OR REPLACE FUNCTION emaj.emaj_remove_sequence(v_schema TEXT, v_sequence TEXT, v_mark TEXT DEFAULT 'REMOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_remove_sequence$
-- The function removes a sequence from its tables group.
-- Inputs: schema name, sequence name, mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively removed to the tables group, id. 1
  BEGIN
    RETURN emaj._remove_sequences(v_schema, ARRAY[v_sequence], v_mark, FALSE, FALSE);
  END;
$emaj_remove_sequence$;
COMMENT ON FUNCTION emaj.emaj_remove_sequence(TEXT,TEXT,TEXT) IS
$$Remove a sequence from its tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_remove_sequences(v_schema TEXT, v_sequences TEXT[], v_mark TEXT DEFAULT 'REMOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_remove_sequences$
-- The function removes several sequences at once from their tables group.
-- Inputs: schema, array of sequence names, mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively removed from the tables group
  BEGIN
    RETURN emaj._remove_sequences(v_schema, v_sequences, v_mark, TRUE, FALSE);
  END;
$emaj_remove_sequences$;
COMMENT ON FUNCTION emaj.emaj_remove_sequences(TEXT,TEXT[],TEXT) IS
$$Remove several sequences from their tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_remove_sequences(v_schema TEXT, v_sequencesIncludeFilter TEXT, v_sequencesExcludeFilter TEXT,
                                                      v_mark TEXT DEFAULT 'REMOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_remove_sequences$
-- The function removes sequences on name patterns from their tables group.
-- Inputs: schema, 2 patterns to filter sequence names (one to include and another to exclude),
--         mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively removed from the tables group
  DECLARE
    v_sequences              TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_sequencesIncludeFilter = '' THEN NULL ELSE v_sequencesIncludeFilter END,
           CASE WHEN v_sequencesExcludeFilter = '' THEN NULL ELSE v_sequencesExcludeFilter END
      INTO v_sequencesIncludeFilter, v_sequencesExcludeFilter;
-- Build the list of sequences names satisfying the pattern
    SELECT array_agg(rel_tblseq) INTO v_sequences FROM (
      SELECT rel_tblseq FROM emaj.emaj_relation
        WHERE rel_schema = v_schema
          AND rel_tblseq ~ v_sequencesIncludeFilter
          AND (v_sequencesExcludeFilter IS NULL OR rel_tblseq !~ v_sequencesExcludeFilter)
          AND rel_kind = 'S' AND upper_inf(rel_time_range)
        ORDER BY rel_tblseq) AS t;
-- call the _remove_sequences() function for execution
    RETURN emaj._remove_sequences(v_schema, v_sequences, v_mark, TRUE, TRUE);
  END;
$emaj_remove_sequences$;
COMMENT ON FUNCTION emaj.emaj_remove_sequences(TEXT,TEXT,TEXT,TEXT) IS
$$Remove several sequences on name patterns from their tables group.$$;

CREATE OR REPLACE FUNCTION emaj._remove_sequences(v_schema TEXT, v_sequences TEXT[], v_mark TEXT, v_multiSequence BOOLEAN,
                                                  v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS
$_remove_sequences$
-- The function effectively removes sequences from their sequences group.
-- Inputs: schema, array of sequence names, mark to set if for logging groups,
--         a boolean to indicate whether several sequences need to be processed,
--         a boolean indicating whether the tables array has been built from regex filters
-- Outputs: number of sequences effectively assigned to the sequences group
  DECLARE
    v_function               TEXT;
    v_list                   TEXT;
    v_markName               TEXT;
    v_timeId                 BIGINT;
    v_groups                 TEXT[];
    v_loggingGroups          TEXT[];
    v_groupName              TEXT;
    v_groupIsLogging         BOOLEAN;
    v_eventTriggers          TEXT[];
    v_oneSequence            TEXT;
    v_nbRemovedSeq           INT = 0;
  BEGIN
    v_function = CASE WHEN v_multiSequence THEN 'REMOVE_SEQUENCES' ELSE 'REMOVE_SEQUENCE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check sequences array
    IF NOT v_arrayFromRegex THEN
-- remove duplicates values, NULL and empty strings from the supplied sequence names array
      SELECT array_agg(DISTINCT sequence_name) INTO v_sequences FROM unnest(v_sequences) AS sequence_name
        WHERE sequence_name IS NOT NULL AND sequence_name <> '';
-- check that the sequences currently belong to a tables group (not necessarily the same one)
      WITH all_supplied_sequences AS (
        SELECT unnest(v_sequences) AS sequence_name),
           sequences_in_group AS (
        SELECT rel_tblseq FROM emaj.emaj_relation
          WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_sequences) AND upper_inf(rel_time_range))
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(sequence_name), ', ') INTO v_list
        FROM (
          SELECT sequence_name FROM all_supplied_sequences
            EXCEPT
          SELECT rel_tblseq FROM sequences_in_group) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_remove_sequences: some sequences (%) do not currently belong to any tables group.', v_list;
      END IF;
    END IF;
-- get the lists of groups and logging groups holding these sequences, if any
-- It locks the tables groups so that no other operation simultaneously occurs these groups
    WITH tables_group AS (
      SELECT group_name, group_is_logging FROM emaj.emaj_relation, emaj.emaj_group
        WHERE rel_group = group_name
          AND rel_schema = v_schema AND rel_tblseq = ANY(v_sequences) AND upper_inf(rel_time_range)
        FOR UPDATE OF emaj_group
      )
    SELECT (SELECT array_agg(group_name) FROM tables_group),
           (SELECT array_agg(group_name) FROM tables_group WHERE group_is_logging)
      INTO v_groups, v_loggingGroups;
-- check the supplied mark
    SELECT emaj._check_new_mark(v_loggingGroups, v_mark) INTO v_markName;
-- OK,
    IF v_sequences IS NULL THEN
-- when no sequences are finaly selected, just warn
      RAISE WARNING '_remove_sequences: No sequence to process.';
    ELSE
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_loggingGroups IS NOT NULL THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(v_loggingGroups, 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(v_loggingGroups, v_markName, FALSE, TRUE, NULL, v_timeId);
      END IF;
-- disable event triggers that protect emaj components and keep in memory these triggers name
      SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- effectively drop the log components for each sequence
      FOREACH v_oneSequence IN ARRAY v_sequences
      LOOP
-- get some characteristics of the group that holds the sequence
        SELECT rel_group, group_is_logging INTO v_groupName, v_groupIsLogging
          FROM emaj.emaj_relation, emaj.emaj_group
          WHERE rel_group = group_name
            AND rel_schema = v_schema AND rel_tblseq = v_oneSequence AND upper_inf(rel_time_range);
-- drop this sequence
        PERFORM emaj._remove_seq(v_schema, v_oneSequence, v_groupName, v_groupIsLogging, v_timeId, v_function);
-- record the change into the emaj_alter_plan table (so that future rollback may see the change)
        INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging)
          VALUES (v_timeId, 'REMOVE_SEQ', v_schema, v_oneSequence, v_groupName, v_groupIsLogging);
        v_nbRemovedSeq = v_nbRemovedSeq + 1;
      END LOOP;
-- enable previously disabled event triggers
      PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- adjust the groups characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId,
            group_nb_sequence = (SELECT count(*) FROM emaj.emaj_relation
                                WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'S')
        WHERE group_name = ANY (v_groups);
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbRemovedSeq || ' sequences removed from their groups');
    RETURN v_nbRemovedSeq;
  END;
$_remove_sequences$;

CREATE OR REPLACE FUNCTION emaj.emaj_move_sequence(v_schema TEXT, v_sequence TEXT, v_newGroup TEXT, v_mark TEXT DEFAULT 'MOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_move_sequence$
-- The function moves a sequence from its tables group to another tables group.
-- Inputs: schema name, sequence name, new group name, mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively moved to the new tables group, ie. 1
  BEGIN
    RETURN emaj._move_sequences(v_schema, ARRAY[v_sequence], v_newGroup, v_mark, FALSE, FALSE);
  END;
$emaj_move_sequence$;
COMMENT ON FUNCTION emaj.emaj_move_sequence(TEXT,TEXT,TEXT,TEXT) IS
$$Move a sequence from its tables group to another tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_move_sequences(v_schema TEXT, v_sequences TEXT[], v_newGroup TEXT, v_mark TEXT DEFAULT 'MOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_move_sequences$
-- The function moves several sequences at once from their tables group to another tables group.
-- Inputs: schema, array of sequence names, new group name, mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively moved to the new tables group
  BEGIN
    RETURN emaj._move_sequences(v_schema, v_sequences, v_newGroup, v_mark, TRUE, FALSE);
  END;
$emaj_move_sequences$;
COMMENT ON FUNCTION emaj.emaj_move_sequences(TEXT,TEXT[],TEXT,TEXT) IS
$$Move several sequences from their tables group to another tables group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_move_sequences(v_schema TEXT, v_sequencesIncludeFilter TEXT, v_sequencesExcludeFilter TEXT,
                                                 v_newGroup TEXT, v_mark TEXT DEFAULT 'MOVE_%')
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_move_sequences$
-- The function moves sequences on name patterns from their tables group to another tables group.
-- Inputs: schema, 2 patterns to filter sequence names (one to include and another to exclude), new group name,
--         mark name to set when logging groups (optional)
-- Outputs: number of sequences effectively moved to the new tables group
  DECLARE
    v_sequences              TEXT[];
  BEGIN
-- process empty filters as NULL
    SELECT CASE WHEN v_sequencesIncludeFilter = '' THEN NULL ELSE v_sequencesIncludeFilter END,
           CASE WHEN v_sequencesExcludeFilter = '' THEN NULL ELSE v_sequencesExcludeFilter END
      INTO v_sequencesIncludeFilter, v_sequencesExcludeFilter;
-- Build the list of sequences names satisfying the pattern
    SELECT array_agg(rel_tblseq) INTO v_sequences FROM (
      SELECT rel_tblseq FROM emaj.emaj_relation
        WHERE rel_schema = v_schema
          AND rel_tblseq ~ v_sequencesIncludeFilter
          AND (v_sequencesExcludeFilter IS NULL OR rel_tblseq !~ v_sequencesExcludeFilter)
          AND rel_kind = 'S' AND upper_inf(rel_time_range)
          AND rel_group <> v_newGroup
        ORDER BY rel_tblseq) AS t;
-- call the _move_sequences() function for execution
    RETURN emaj._move_sequences(v_schema, v_sequences, v_newGroup, v_mark, TRUE, TRUE);
  END;
$emaj_move_sequences$;
COMMENT ON FUNCTION emaj.emaj_move_sequences(TEXT,TEXT,TEXT,TEXT,TEXT) IS
$$Move several sequences on name patterns from their tables group to another tables group.$$;

CREATE OR REPLACE FUNCTION emaj._move_sequences(v_schema TEXT, v_sequences TEXT[], v_newGroup TEXT, v_mark TEXT, v_multiSequence BOOLEAN,
                                             v_arrayFromRegex BOOLEAN)
RETURNS INTEGER LANGUAGE plpgsql AS
$_move_sequences$
-- The function effectively moves sequences from their tables group to another tables group.
-- Inputs: schema, array of sequence names, new group name, mark to set if for logging groups,
--         boolean to indicate whether several sequences need to be processed,
--         a boolean indicating whether the sequences array has been built from regex filters
-- Outputs: number of sequences effectively moved to the tables group
  DECLARE
    v_function               TEXT;
    v_newGroupIsLogging      BOOLEAN;
    v_list                   TEXT;
    v_uselessSequences       TEXT[];
    v_markName               TEXT;
    v_timeId                 BIGINT;
    v_groups                 TEXT[];
    v_loggingGroups          TEXT[];
    v_groupName              TEXT;
    v_groupIsLogging         BOOLEAN;
    v_oneSequence            TEXT;
    v_nbMovedSeq             INT = 0;
  BEGIN
    v_function = CASE WHEN v_multiSequence THEN 'MOVE_SEQUENCES' ELSE 'MOVE_SEQUENCE' END;
-- insert the begin entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event)
      VALUES (v_function, 'BEGIN');
-- check the group name and if ok, get some properties of the group
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_newGroup], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
    SELECT group_is_logging INTO v_newGroupIsLogging
      FROM emaj.emaj_group WHERE group_name = v_NewGroup;
-- check the sequences list
    IF NOT v_arrayFromRegex THEN
-- remove duplicates values, NULL and empty strings from the supplied sequence names array
      SELECT array_agg(DISTINCT sequence_name) INTO v_sequences FROM unnest(v_sequences) AS sequence_name
        WHERE sequence_name IS NOT NULL AND sequence_name <> '';
-- check that the sequences currently belong to a tables group (not necessarily the same for all sequences)
      WITH all_supplied_sequences AS (
        SELECT unnest(v_sequences) AS sequence_name),
           sequences_in_group AS (
        SELECT rel_tblseq FROM emaj.emaj_relation
          WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_sequences) AND upper_inf(rel_time_range))
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(sequence_name), ', ') INTO v_list
        FROM (
          SELECT sequence_name FROM all_supplied_sequences
            EXCEPT
          SELECT rel_tblseq FROM sequences_in_group) AS t;
      IF v_list IS NOT NULL THEN
        RAISE EXCEPTION '_move_sequences: some sequences (%) do not currently belong to any tables group.', v_list;
      END IF;
-- remove sequences that already belong to the new group
      SELECT string_agg(quote_ident(v_schema) || '.' || quote_ident(rel_tblseq), ', '), array_agg(rel_tblseq)
        INTO v_list, v_uselessSequences
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_sequences) AND upper_inf(rel_time_range)
          AND rel_group = v_newGroup;
      IF v_list IS NOT NULL THEN
        RAISE WARNING '_move_sequences: some sequences (%) already belong to the tables group %.', v_list, v_newGroup;
        SELECT array_remove(v_sequences, useless_sequence) INTO v_sequences FROM unnest(v_uselessSequences) AS useless_sequence;
      END IF;
    END IF;
-- get the lists of groups and logging groups holding these sequences, if any.
-- It locks the tables groups so that no other operation simultaneously occurs these groups
-- (the CTE is needed for the FOR UPDATE clause not allowed when aggregate functions)
    WITH tables_group AS (
      SELECT group_name, group_is_logging FROM emaj.emaj_group
        WHERE group_name = v_newGroup OR
              group_name IN
               (SELECT DISTINCT rel_group FROM emaj.emaj_relation
                  WHERE rel_schema = v_schema AND rel_tblseq = ANY(v_sequences) AND upper_inf(rel_time_range))
        FOR UPDATE OF emaj_group
      )
    SELECT array_agg(group_name ORDER BY group_name),
           array_agg(group_name ORDER BY group_name) FILTER (WHERE group_is_logging)
      INTO v_groups, v_loggingGroups
      FROM tables_group;
-- check the supplied mark
    SELECT emaj._check_new_mark(v_loggingGroups, v_mark) INTO v_markName;
-- OK,
    IF v_sequences IS NULL THEN
-- when no sequences are finaly selected, just warn
      RAISE WARNING '_move_sequences: No sequence to process.';
    ELSE
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_loggingGroups IS NOT NULL THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(v_loggingGroups, 'ROW EXCLUSIVE', FALSE);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(v_loggingGroups, v_markName, TRUE, TRUE, NULL, v_timeId);
      END IF;
-- effectively move each sequence
      FOREACH v_oneSequence IN ARRAY v_sequences
      LOOP
-- get some characteristics of the group that holds the sequence before the move
        SELECT rel_group, group_is_logging INTO v_groupName, v_groupIsLogging
          FROM emaj.emaj_relation, emaj.emaj_group
          WHERE rel_group = group_name
            AND rel_schema = v_schema AND rel_tblseq = v_oneSequence AND upper_inf(rel_time_range);
-- move this sequence
        PERFORM emaj._move_seq(v_schema, v_oneSequence, v_groupName, v_groupIsLogging, v_newGroup, v_newGroupIsLogging, v_timeId,
                               v_function);
-- insert an entry into the emaj_alter_plan table (so that future rollback may see the change)
        INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_group_is_logging,
                                          altr_new_group, altr_new_group_is_logging)
          VALUES (v_timeId, 'MOVE_SEQ', v_schema, v_oneSequence, v_groupName, v_groupIsLogging, v_newGroup, v_newGroupIsLogging);
        v_nbMovedSeq = v_nbMovedSeq + 1;
      END LOOP;
-- adjust the groups characteristics
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId,
            group_nb_sequence = (SELECT count(*) FROM emaj.emaj_relation
                                 WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'S')
        WHERE group_name = ANY (v_groups);
    END IF;
-- insert the end entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES (v_function, 'END', v_nbMovedSeq || ' sequences moved to the new tables group ' || v_newGroup);
    RETURN v_nbMovedSeq;
  END;
$_move_sequences$;

CREATE OR REPLACE FUNCTION emaj._create_seq(v_schema TEXT, v_seq TEXT, v_groupName TEXT, v_timeId BIGINT)
RETURNS VOID LANGUAGE plpgsql AS
$_create_seq$
-- The function records a sequence into a tables group
-- Required inputs: the application sequence to process, the group to add it into, the priority attribute, the time id of the operation.
  BEGIN
-- record the sequence in the emaj_relation table
    INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind)
      VALUES (v_schema, v_seq, int8range(v_timeId, NULL, '[)'), v_groupName, 'S');
    RETURN;
  END;
$_create_seq$;

CREATE OR REPLACE FUNCTION emaj._add_seq(v_schema TEXT, v_sequence TEXT, v_group TEXT, v_groupIsLogging BOOLEAN,
                                         v_timeId BIGINT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_add_seq$
-- The function adds a sequence to a group. It is called during an alter group or a dynamic assignment operation.
-- If the group is in idle state, it simply calls the _create_seq() function.
-- Otherwise, it calls the _create_seql() function, and records the current state of the sequence.
-- Required inputs: schema and sequence to add, group name, priority, the group's logging state,
--                  the time stamp id of the operation, main calling function.
  BEGIN
-- create the sequence
    PERFORM emaj._create_seq(v_schema, v_sequence, v_group, v_timeId);
-- if the group is in logging state, perform additional tasks
    IF v_groupIsLogging THEN
-- ... record the new sequence state in the emaj_sequence table for the current alter_group mark
      INSERT INTO emaj.emaj_sequence (sequ_schema, sequ_name, sequ_time_id, sequ_last_val, sequ_start_val,
                  sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called)
        SELECT * FROM emaj._get_current_sequence_state(v_schema, v_sequence, v_timeId);
    END IF;
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'SEQUENCE ADDED', quote_ident(v_schema) || '.' || quote_ident(v_sequence),
              'To the ' || CASE WHEN v_groupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_group);
    RETURN;
  END;
$_add_seq$;

CREATE OR REPLACE FUNCTION emaj._remove_seq(v_schema TEXT, v_sequence TEXT, v_group TEXT, v_groupIsLogging BOOLEAN,
                                            v_timeId BIGINT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_remove_seq$
-- The function removes a sequence from a group. It is called during an alter group or a dynamic removal operation.
-- Required inputs: schema and sequence to remove, related group name and logging state,
--                  time stamp id of the operation, main calling function.
  BEGIN
    IF NOT v_groupIsLogging THEN
-- if the group is in idle state, drop the sequence immediately
      PERFORM emaj._drop_seq(emaj.emaj_relation.*, v_timeId) FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_sequence AND upper_inf(rel_time_range);
    ELSE
-- if the group is in logging state, just register the end of the relation time frame
      UPDATE emaj.emaj_relation SET rel_time_range = int8range(lower(rel_time_range),v_timeId, '[)')
        WHERE rel_schema = v_schema AND rel_tblseq = v_sequence AND upper_inf(rel_time_range);
    END IF;
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'SEQUENCE REMOVED', quote_ident(v_schema) || '.' || quote_ident(v_sequence),
              'From the ' || CASE WHEN v_groupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_group);
    RETURN;
  END;
$_remove_seq$;

CREATE OR REPLACE FUNCTION emaj._move_seq(v_schema TEXT, v_sequence TEXT, v_oldGroup TEXT, v_oldGroupIsLogging BOOLEAN, v_newGroup TEXT,
                                          v_newGroupIsLogging BOOLEAN, v_timeId BIGINT, v_function TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_move_seq$
-- The function change the group ownership of a sequence. It is called during an alter group or a dynamic assignment operation.
-- Required inputs: schema and sequence to move, old and new group names and their logging state,
--                  time stamp id of the operation, main calling function.
  BEGIN
-- register the end of the previous relation time frame and create a new relation time frame with the new group
    UPDATE emaj.emaj_relation
      SET rel_time_range = int8range(lower(rel_time_range),v_timeId,'[)')
      WHERE rel_schema = v_schema AND rel_tblseq = v_sequence AND upper_inf(rel_time_range);
    INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind)
      SELECT rel_schema, rel_tblseq, int8range(v_timeId, NULL, '[)'), v_newGroup, rel_kind
        FROM emaj.emaj_relation
        WHERE rel_schema = v_schema AND rel_tblseq = v_sequence AND upper(rel_time_range) = v_timeId;
-- insert an entry into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (v_function, 'SEQUENCE MOVED', quote_ident(v_schema) || '.' || quote_ident(v_sequence),
              'From the ' || CASE WHEN v_oldGroupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_oldGroup ||
              ' to the ' || CASE WHEN v_newGroupIsLogging THEN 'logging ' ELSE 'idle ' END || 'group ' || v_newGroup);
    RETURN;
  END;
$_move_seq$;

CREATE OR REPLACE FUNCTION emaj._drop_seq(r_rel emaj.emaj_relation, v_timeId BIGINT)
RETURNS VOID LANGUAGE plpgsql AS
$_drop_seq$
-- The function deletes the rows stored into emaj_sequence for a particular sequence timerange.
-- Required inputs: row from emaj_relation corresponding to the appplication sequence to proccess.
  BEGIN
-- delete rows from emaj_sequence, but only when dealing with the last timerange of the sequence
    IF NOT EXISTS(SELECT 1 FROM emaj.emaj_relation
                    WHERE rel_schema = r_rel.rel_schema AND rel_tblseq = r_rel.rel_tblseq
                      AND rel_time_range <> r_rel.rel_time_range) THEN
      DELETE FROM emaj.emaj_sequence WHERE sequ_schema = r_rel.rel_schema AND sequ_name = r_rel.rel_tblseq;
    END IF;
-- keep a trace of the sequence group ownership history and finaly delete the sequence timerange from the emaj_relation table
    WITH deleted AS (
      DELETE FROM emaj.emaj_relation
        WHERE rel_schema = r_rel.rel_schema AND rel_tblseq = r_rel.rel_tblseq AND rel_time_range = r_rel.rel_time_range
        RETURNING rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind
      )
    INSERT INTO emaj.emaj_rel_hist
             (relh_schema, relh_tblseq, relh_time_range, relh_group, relh_kind)
      SELECT rel_schema, rel_tblseq,
             CASE WHEN upper_inf(rel_time_range) THEN int8range(lower(rel_time_range), v_timeId, '[)') ELSE rel_time_range END,
             rel_group, rel_kind
        FROM deleted;
    RETURN;
  END;
$_drop_seq$;

CREATE OR REPLACE FUNCTION emaj._rlbk_tbl(r_rel emaj.emaj_relation, v_minGlobalSeq BIGINT, v_maxGlobalSeq BIGINT, v_nbSession INT,
                                          v_isLoggedRlbk BOOLEAN)
RETURNS BIGINT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_rlbk_tbl$
-- This function rollbacks one table to a given point in time represented by the value of the global sequence.
-- The function is called by emaj._rlbk_session_exec().
-- Input: row from emaj_relation corresponding to the appplication table to proccess
--        global sequence (non inclusive) lower and (inclusive) upper limits covering the rollback time frame
--        number of sessions and a boolean indicating whether the rollback is logged
-- Output: number of rolled back primary keys
-- For unlogged rollback, the log triggers have been disabled previously and will be enabled later.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_fullTableName          TEXT;
    v_logTableName           TEXT;
    v_tmpTable               TEXT;
    v_tableType              TEXT;
    v_nbPk                   BIGINT;
  BEGIN
    v_fullTableName  = quote_ident(r_rel.rel_schema) || '.' || quote_ident(r_rel.rel_tblseq);
    v_logTableName   = quote_ident(r_rel.rel_log_schema) || '.' || quote_ident(r_rel.rel_log_table);
-- insert begin event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('ROLLBACK_TABLE', 'BEGIN', v_fullTableName,
              'All log rows with emaj_gid > ' || v_minGlobalSeq || ' and <= ' || v_maxGlobalSeq);
-- create the temporary table containing all primary key values with their earliest emaj_gid
    IF v_nbSession = 1 THEN
      v_tableType = 'TEMP';
      v_tmpTable = 'emaj_tmp_' || pg_backend_pid();
    ELSE
--   with multi session parallel rollbacks, the table cannot be a TEMP table because it would not be usable in 2PC
--   but it may be an UNLOGGED table
      v_tableType = 'UNLOGGED';
      v_tmpTable = 'emaj.emaj_tmp_' || pg_backend_pid();
    END IF;
    EXECUTE format('CREATE %s TABLE %s AS '
                   '  SELECT %s, min(emaj_gid) as emaj_gid FROM %s'
                   '    WHERE emaj_gid > %s AND emaj_gid <= %s'
                   '    GROUP BY %s',
                   v_tableType, v_tmpTable, r_rel.rel_sql_rlbk_pk_columns, v_logTableName,
                   v_minGlobalSeq, v_maxGlobalSeq, r_rel.rel_sql_rlbk_pk_columns);
    GET DIAGNOSTICS v_nbPk = ROW_COUNT;
-- delete all rows from the application table corresponding to each touched primary key
--   this deletes rows inserted or updated during the rolled back period
    EXECUTE format('DELETE FROM ONLY %s tbl USING %s keys WHERE %s',
                   v_fullTableName, v_tmpTable, r_rel.rel_sql_rlbk_pk_conditions);
-- for logged rollbacks, if the number of pkey to process is greater than 1.000, ANALYZE the log table to take into account
--   the impact of just inserted rows, avoiding a potentialy bad plan for the next INSERT statement
    IF v_isLoggedRlbk AND v_nbPk > 1000 THEN
      EXECUTE format('ANALYZE %s',
                     v_logTableName);
    END IF;
-- insert into the application table rows that were deleted or updated during the rolled back period
    EXECUTE format('INSERT INTO %s (%s) %s'
                   '  SELECT %s FROM %s tbl, %s keys '
                   '    WHERE %s AND tbl.emaj_gid = keys.emaj_gid AND tbl.emaj_tuple = ''OLD'''
                   '      AND tbl.emaj_gid > %s AND tbl.emaj_gid <= %s',
                   v_fullTableName, replace(r_rel.rel_sql_rlbk_columns, 'tbl.',''),
                   CASE WHEN r_rel.rel_has_always_ident_col THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END,
                   r_rel.rel_sql_rlbk_columns, v_logTableName, v_tmpTable,
                   r_rel.rel_sql_rlbk_pk_conditions,
                   v_minGlobalSeq, v_maxGlobalSeq);
-- drop the now useless temporary table
    EXECUTE format('DROP TABLE %s',
                   v_tmpTable);
-- insert end event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('ROLLBACK_TABLE', 'END', v_fullTableName, v_nbPk || ' rolled back primary keys');
    RETURN v_nbPk;
  END;
$_rlbk_tbl$;

CREATE OR REPLACE FUNCTION emaj._delete_log_tbl(r_rel emaj.emaj_relation, v_beginTimeId BIGINT, v_endTimeId BIGINT, v_lastGlobalSeq BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS
$_delete_log_tbl$
-- This function deletes the part of a log table corresponding to updates that have been rolled back.
-- The function is only called by emaj._rlbk_session_exec(), for unlogged rollbacks.
-- It deletes sequences records corresponding to marks that are not visible anymore after the rollback.
-- It also registers the hole in sequence numbers generated by the deleted log rows.
-- Input: row from emaj_relation corresponding to the appplication table to proccess,
--        begin and end time stamp ids to define the time range identifying the hole to create in the log sequence
--        global sequence value limit for rollback, mark timestamp,
-- Output: deleted rows
  DECLARE
    v_nbRows                 BIGINT;
  BEGIN
-- delete obsolete log rows
    EXECUTE format('DELETE FROM %I.%I WHERE emaj_gid > %s',
                   r_rel.rel_log_schema, r_rel.rel_log_table, v_lastGlobalSeq);
    GET DIAGNOSTICS v_nbRows = ROW_COUNT;
-- record the sequence holes generated by the delete operation
-- this is due to the fact that log sequences are not rolled back, this information will be used by the emaj_log_stat_group() function
--   (and indirectly by emaj_estimate_rollback_group() and emaj_estimate_rollback_groups())
-- first delete, if exist, sequence holes that have disappeared with the rollback
    DELETE FROM emaj.emaj_seq_hole
      WHERE sqhl_schema = r_rel.rel_schema AND sqhl_table = r_rel.rel_tblseq
        AND sqhl_begin_time_id >= v_beginTimeId AND sqhl_begin_time_id < v_endTimeId;
-- and then insert the new sequence hole
    IF emaj._pg_version_num() >= 100000 THEN
      EXECUTE format('INSERT INTO emaj.emaj_seq_hole (sqhl_schema, sqhl_table, sqhl_begin_time_id, sqhl_end_time_id, sqhl_hole_size)'
                     ' VALUES (%L, %L, %s, %s, ('
                     '   SELECT CASE WHEN rel.is_called THEN rel.last_value + increment_by ELSE rel.last_value END'
                     '     FROM %I.%I rel, pg_sequences'
                     '     WHERE schemaname = %L AND sequencename = %L'
                     '   )-('
                     '   SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END'
                     '     FROM emaj.emaj_sequence'
                     '     WHERE sequ_schema = %L AND sequ_name = %L AND sequ_time_id = %s))',
                     r_rel.rel_schema, r_rel.rel_tblseq, v_beginTimeId, v_endTimeId, r_rel.rel_log_schema, r_rel.rel_log_sequence,
                     r_rel.rel_log_schema, r_rel.rel_log_sequence, r_rel.rel_log_schema, r_rel.rel_log_sequence, v_beginTimeId);
    ELSE
      EXECUTE format('INSERT INTO emaj.emaj_seq_hole (sqhl_schema, sqhl_table, sqhl_begin_time_id, sqhl_end_time_id, sqhl_hole_size)'
                     ' VALUES (%L, %L, %s, %s, ('
                     '   SELECT CASE WHEN is_called THEN last_value + increment_by ELSE last_value END FROM %I.%I'
                     '   )-('
                     '   SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END'
                     '     FROM emaj.emaj_sequence'
                     '     WHERE sequ_schema = %L AND sequ_name = %L AND sequ_time_id = %s))',
                     r_rel.rel_schema, r_rel.rel_tblseq, v_beginTimeId, v_endTimeId, r_rel.rel_log_schema, r_rel.rel_log_sequence,
                     r_rel.rel_log_schema, r_rel.rel_log_sequence, v_beginTimeId);
    END IF;
    RETURN v_nbRows;
  END;
$_delete_log_tbl$;

CREATE OR REPLACE FUNCTION emaj.emaj_ignore_app_trigger(v_action TEXT, v_schema TEXT, v_table TEXT, v_trigger TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_ignore_app_trigger$
-- This function records the list of application table triggers that must not be automatically disabled when launching a rollback
-- operation.
-- Input: the action to perform, either ADD or REMOVE,
--        the schema and table names of the table that owns the trigger
--        and the trigger to record into or remove from the emaj_ignored_app_trigger table
-- Output: number of recorded or removed triggers
-- A trigger to add must exist. E-Maj triggers are not processed.
-- The trigger parameter may contain '%' and/or '_' characters, these characters having the same meaning as in LIKE clauses.
  DECLARE
    v_nbRows                 INT;
    v_tableOid               OID;
    v_trgList                TEXT;
  BEGIN
-- check the action parameter
    IF upper(v_action) NOT IN ('ADD','REMOVE') THEN
      RAISE EXCEPTION 'emaj_ignore_app_trigger: the action "%" must be either ''ADD'' or ''REMOVE''.', v_action;
    END IF;
-- process the REMOVE action
    IF upper(v_action) = 'REMOVE' THEN
      DELETE FROM emaj.emaj_ignored_app_trigger
        WHERE trg_schema = v_schema AND trg_table = v_table AND trg_name LIKE v_trigger;
      GET DIAGNOSTICS v_nbRows = ROW_COUNT;
      RETURN v_nbRows;
    END IF;
-- process the ADD action
-- check that the supplied schema qualified table name exists
    SELECT pg_class.oid INTO v_tableOid
      FROM pg_catalog.pg_class, pg_catalog.pg_namespace
      WHERE relnamespace = pg_namespace.oid
        AND nspname = v_schema AND relname = v_table
        AND relkind = 'r';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_ignore_app_trigger: the table "%.%" does not exist.', v_schema, v_table;
    END IF;
-- check that the trigger exists for the table
    PERFORM 1 FROM pg_catalog.pg_trigger
      WHERE tgrelid = v_tableOid
        AND tgname LIKE v_trigger AND NOT tgisinternal;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_ignore_app_trigger: no trigger like "%" found for the table "%.%".', v_trigger, v_schema, v_table;
    END IF;
-- issue a warning if there is at least 1 emaj trigger selected
    SELECT string_agg(tgname,', ') INTO v_trgList
      FROM pg_catalog.pg_trigger
      WHERE tgrelid = v_tableOid
        AND tgname LIKE v_trigger AND tgname IN ('emaj_trunc_trg', 'emaj_log_trg') AND NOT tgisinternal;
    IF v_trgList IS NOT NULL THEN
      RAISE WARNING 'emaj_ignore_app_trigger: the triggers "%" are E-Maj triggers and are not processed by the function.', v_trgList;
    END IF;
-- insert into the emaj_ignored_app_trigger table the not yet recorded triggers
    INSERT INTO emaj.emaj_ignored_app_trigger
      SELECT v_schema, v_table, tgname
        FROM pg_catalog.pg_trigger
        WHERE tgrelid = v_tableOid
          AND tgname LIKE v_trigger AND tgname NOT IN ('emaj_trunc_trg', 'emaj_log_trg') AND NOT tgisinternal
      ON CONFLICT DO NOTHING;
-- return the number of effectively added triggers
    GET DIAGNOSTICS v_nbRows = ROW_COUNT;
    RETURN v_nbRows;
  END;
$emaj_ignore_app_trigger$;
COMMENT ON FUNCTION emaj.emaj_ignore_app_trigger(TEXT,TEXT,TEXT,TEXT) IS
$$Records application tables triggers that are not automatically disabled at rollback time.$$;

CREATE OR REPLACE FUNCTION emaj._rlbk_seq(r_rel emaj.emaj_relation, v_timeId BIGINT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_rlbk_seq$
-- This function rollbacks one application sequence to a given mark.
-- The function is called by emaj.emaj._rlbk_end().
-- Input: the emaj_group_def row related to the application sequence to process, time id of the mark to rollback to.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if it is not the owner of the application sequence.
  DECLARE
    v_fullSeqName            TEXT;
    v_stmt                   TEXT;
    mark_seq_rec             RECORD;
    curr_seq_rec             RECORD;
  BEGIN
-- Read sequence's characteristics at mark time
    BEGIN
      SELECT sequ_schema, sequ_name, sequ_last_val, sequ_start_val, sequ_increment,
             sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called
        INTO STRICT mark_seq_rec
        FROM emaj.emaj_sequence
        WHERE sequ_schema = r_rel.rel_schema AND sequ_name = r_rel.rel_tblseq AND sequ_time_id = v_timeId;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE EXCEPTION '_rlbk_seq: No mark at time id "%" can be found for the sequence "%.%".',
            v_timeId, r_rel.rel_schema, r_rel.rel_tblseq;
    END;
-- Read the current sequence's characteristics
    v_fullSeqName = quote_ident(r_rel.rel_schema) || '.' || quote_ident(r_rel.rel_tblseq);
    IF emaj._pg_version_num() >= 100000 THEN
      EXECUTE format('SELECT rel.last_value, start_value, increment_by, max_value, min_value, cache_size as cache_value, '
                     '       cycle as is_cycled, rel.is_called'
                     '  FROM %s rel, pg_catalog.pg_sequences '
                     '  WHERE schemaname = %L AND sequencename = %L',
                     v_fullSeqName, r_rel.rel_schema, r_rel.rel_tblseq)
              INTO STRICT curr_seq_rec;
    ELSE
      EXECUTE format('SELECT last_value, start_value, increment_by, max_value, min_value, cache_value, is_cycled, is_called FROM %s',
                     v_fullSeqName)
              INTO STRICT curr_seq_rec;
    END IF;
-- Build the ALTER SEQUENCE statement, depending on the differences between the present values and the related
--   values at the requested mark time
    SELECT emaj._build_alter_seq(curr_seq_rec.last_value, curr_seq_rec.is_called, curr_seq_rec.increment_by,
                                 curr_seq_rec.start_value, curr_seq_rec.min_value, curr_seq_rec.max_value,
                                 curr_seq_rec.cache_value, curr_seq_rec.is_cycled, mark_seq_rec.sequ_last_val,
                                 mark_seq_rec.sequ_is_called, mark_seq_rec.sequ_increment, mark_seq_rec.sequ_start_val,
                                 mark_seq_rec.sequ_min_val, mark_seq_rec.sequ_max_val, mark_seq_rec.sequ_cache_val,
                                 mark_seq_rec.sequ_is_cycled) INTO v_stmt;
-- and execute the statement if at least one parameter has changed
    IF v_stmt <> '' THEN
      EXECUTE format('ALTER SEQUENCE %s %s',
                     v_fullSeqName, v_stmt);
    END IF;
-- insert event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('ROLLBACK_SEQUENCE', v_fullSeqName, substr(v_stmt,2));
    RETURN;
  END;
$_rlbk_seq$;

CREATE OR REPLACE FUNCTION emaj._build_alter_seq(v_refLastValue BIGINT, v_refIsCalled BOOLEAN, v_refIncrementBy BIGINT,
                                                 v_refStartValue BIGINT, v_refMinValue BIGINT, v_refMaxValue BIGINT,
                                                 v_refCacheValue BIGINT, v_refIsCycled BOOLEAN, v_trgLastValue BIGINT,
                                                 v_trgIsCalled BOOLEAN, v_trgIncrementBy BIGINT, v_trgStartValue BIGINT,
                                                 v_trgMinValue BIGINT, v_trgMaxValue BIGINT, v_trgCacheValue BIGINT,
                                                 v_trgIsCycled BOOLEAN)
RETURNS TEXT LANGUAGE plpgsql AS
$_build_alter_seq$
-- This function builds an ALTER SEQUENCE clause including only the sequence characteristics that have changed between a reference
-- and a target.
-- The function is called by _rlbk_seq() and _gen_sql_groups()
-- Input: elementary reference and target sequence characteristics
-- Output: the alter sequence clause with all modified characteristics
  DECLARE
    v_stmt                   TEXT;
  BEGIN
    v_stmt='';
-- Build the ALTER SEQUENCE clause, depending on the differences between the reference and target values
    IF v_refLastValue <> v_trgLastValue OR
       v_refIsCalled <> v_trgIsCalled THEN
      IF v_trgIsCalled THEN
        v_stmt = v_stmt || ' RESTART ' || v_trgLastValue + v_trgIncrementBy;
      ELSE
        v_stmt = v_stmt || ' RESTART ' || v_trgLastValue;
      END IF;
    END IF;
    IF v_refStartValue <> v_trgStartValue THEN
      v_stmt = v_stmt || ' START ' || v_trgStartValue;
    END IF;
    IF v_refIncrementBy <> v_trgIncrementBy THEN
      v_stmt = v_stmt || ' INCREMENT ' || v_trgIncrementBy;
    END IF;
    IF v_refMinValue <> v_trgMinValue THEN
      v_stmt = v_stmt || ' MINVALUE ' || v_trgMinValue;
    END IF;
    IF v_refMaxValue <> v_trgMaxValue THEN
      v_stmt = v_stmt || ' MAXVALUE ' || v_trgMaxValue;
    END IF;
    IF v_refCacheValue <> v_trgCacheValue THEN
      v_stmt = v_stmt || ' CACHE ' || v_trgCacheValue;
    END IF;
    IF v_refIsCycled <> v_trgIsCycled THEN
      IF v_trgIsCycled = 'f' THEN
        v_stmt = v_stmt || ' NO ';
      END IF;
      v_stmt=v_stmt || ' CYCLE ';
    END IF;
    RETURN v_stmt;
  END;
$_build_alter_seq$;

CREATE OR REPLACE FUNCTION emaj._log_stat_tbl(r_rel emaj.emaj_relation, v_beginTimeId BIGINT, v_endTimeId BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS
$_log_stat_tbl$
-- This function returns the number of log rows for a single table between 2 time stamps or between a time stamp and the current situation.
-- It is called by the emaj_log_stat_group(), _rlbk_planning(), _rlbk_start_mark() and _gen_sql_groups() functions.
-- These statistics are computed using the serial id of log tables and holes is sequences recorded into emaj_seq_hole at rollback time or
-- rollback consolidation time.
-- Input: row from emaj_relation corresponding to the appplication table to proccess, the time stamp ids defining the time range to examine
--        (a end time stamp id set to NULL indicates the current situation)
-- Output: number of log rows between both marks for the table
  DECLARE
    v_beginLastValue         BIGINT;
    v_endLastValue           BIGINT;
    v_sumHole                BIGINT;
  BEGIN
-- get the log table id at begin time id
    SELECT CASE WHEN sequ_is_called THEN sequ_last_val ELSE sequ_last_val - sequ_increment END INTO STRICT v_beginLastValue
      FROM emaj.emaj_sequence
      WHERE sequ_schema = r_rel.rel_log_schema
        AND sequ_name = r_rel.rel_log_sequence
        AND sequ_time_id = v_beginTimeId;
    IF v_endTimeId IS NULL THEN
-- last time id is NULL, so examine the current state of the log table id
      IF emaj._pg_version_num() >= 100000 THEN
       EXECUTE format('SELECT CASE WHEN rel.is_called THEN rel.last_value ELSE rel.last_value - increment_by END'
                       '  FROM %I.%I rel, pg_sequences'
                       '  WHERE schemaname = %L  AND sequencename = %L ',
                       r_rel.rel_log_schema, r_rel.rel_log_sequence, r_rel.rel_log_schema, r_rel.rel_log_sequence)
          INTO v_endLastValue;
      ELSE
        EXECUTE format('SELECT CASE WHEN is_called THEN last_value ELSE last_value - increment_by END FROM %I.%I',
                       r_rel.rel_log_schema, r_rel.rel_log_sequence)
          INTO v_endLastValue;
      END IF;
--   and count the sum of hole from the start time to now
      SELECT coalesce(sum(sqhl_hole_size),0) INTO v_sumHole FROM emaj.emaj_seq_hole
        WHERE sqhl_schema = r_rel.rel_schema AND sqhl_table = r_rel.rel_tblseq
          AND sqhl_begin_time_id >= v_beginTimeId;
    ELSE
-- last time id is not NULL, so get the log table id at end time id
      SELECT CASE WHEN sequ_is_called THEN sequ_last_val ELSE sequ_last_val - sequ_increment END INTO v_endLastValue
         FROM emaj.emaj_sequence
         WHERE sequ_schema = r_rel.rel_log_schema
           AND sequ_name = r_rel.rel_log_sequence
           AND sequ_time_id = v_endTimeId;
--   and count the sum of hole from the start time to the end time
      SELECT coalesce(sum(sqhl_hole_size),0) INTO v_sumHole FROM emaj.emaj_seq_hole
        WHERE sqhl_schema = r_rel.rel_schema AND sqhl_table = r_rel.rel_tblseq
          AND sqhl_begin_time_id >= v_beginTimeId AND sqhl_end_time_id <= v_endTimeId;
    END IF;
-- return the stat row for the table
    RETURN (v_endLastValue - v_beginLastValue - v_sumHole);
  END;
$_log_stat_tbl$;

CREATE OR REPLACE FUNCTION emaj._gen_sql_tbl(r_rel emaj.emaj_relation, v_firstEmajGid BIGINT, v_lastEmajGid BIGINT)
RETURNS BIGINT LANGUAGE plpgsql
SECURITY DEFINER SET standard_conforming_strings = ON AS
$_gen_sql_tbl$
-- This function generates SQL commands representing all updates performed on a table between 2 marks
-- or beetween a mark and the current situation.
-- These commands are stored into a temporary table created by the _gen_sql_groups() calling function.
-- Input: row from emaj_relation corresponding to the appplication table to proccess,
--        the global sequence value at requested start and end marks
-- Output: number of generated SQL statements
  DECLARE
    v_fullTableName          TEXT;
    v_logTableName           TEXT;
    v_rqInsert               TEXT;
    v_rqUpdate               TEXT;
    v_rqDelete               TEXT;
    v_rqTruncate             TEXT;
    v_conditions             TEXT;
    v_lastEmajGidRel         BIGINT;
    v_nbSQL                  BIGINT;
  BEGIN
-- build schema specified table name and log table name
    v_fullTableName = quote_ident(r_rel.rel_schema) || '.' || quote_ident(r_rel.rel_tblseq);
    v_logTableName = quote_ident(r_rel.rel_log_schema) || '.' || quote_ident(r_rel.rel_log_table);
-- prepare sql skeletons for each statement type, using the pieces of sql recorded in the emaj_relation row at table assignment time
    v_rqInsert = '''INSERT INTO ' || replace(v_fullTableName,'''','''''')
              || CASE WHEN r_rel.rel_sql_gen_ins_col <> '' THEN ' (' || r_rel.rel_sql_gen_ins_col || ')' ELSE '' END
              || CASE WHEN r_rel.rel_has_always_ident_col THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END
              || ' VALUES (' || r_rel.rel_sql_gen_ins_val || ');''';
    v_rqUpdate = '''UPDATE ONLY ' || replace(v_fullTableName,'''','''''')
              || ' SET ' || r_rel.rel_sql_gen_upd_set || ' WHERE ' || r_rel.rel_sql_gen_pk_conditions || ';''';
    v_rqDelete = '''DELETE FROM ONLY ' || replace(v_fullTableName,'''','''''')
              || ' WHERE ' || r_rel.rel_sql_gen_pk_conditions || ';''';
    v_rqTruncate = '''TRUNCATE ' || replace(v_fullTableName,'''','''''') || ';''';
-- build the restriction conditions on emaj_gid, depending on supplied marks range and the relation time range upper bound
    v_conditions = 'o.emaj_gid > ' || v_firstEmajGid;
--   get the EmajGid of the relation time range upper bound, if any
    IF NOT upper_inf(r_rel.rel_time_range) THEN
      SELECT time_last_emaj_gid INTO v_lastEmajGidRel FROM emaj.emaj_time_stamp WHERE time_id = upper(r_rel.rel_time_range);
    END IF;
--   if the relation time range upper bound is before the requested end mark, restrict the EmajGid upper limit
    IF v_lastEmajGidRel IS NOT NULL AND
       (v_lastEmajGid IS NULL OR (v_lastEmajGid IS NOT NULL AND v_lastEmajGidRel < v_lastEmajGid)) THEN
      v_lastEmajGid = v_lastEmajGidRel;
    END IF;
--   complete the restriction conditions
    IF v_lastEmajGid IS NOT NULL THEN
      v_conditions = v_conditions || ' AND o.emaj_gid <= ' || v_lastEmajGid;
    END IF;
-- now scan the log table to process all statement types at once
    EXECUTE format('INSERT INTO emaj_temp_script '
                   'SELECT o.emaj_gid, 0, o.emaj_txid, CASE '
                   '    WHEN o.emaj_verb = ''INS'' THEN %s'
                   '    WHEN o.emaj_verb = ''UPD'' AND o.emaj_tuple = ''OLD'' THEN %s'
                   '    WHEN o.emaj_verb = ''DEL'' THEN %s'
                   '    WHEN o.emaj_verb = ''TRU'' THEN %s'
                   '  END '
                   '  FROM %s o'
                   '       LEFT OUTER JOIN %s n ON n.emaj_gid = o.emaj_gid'
                   '                          AND (n.emaj_verb = ''UPD'' AND n.emaj_tuple = ''NEW'') '
                   ' WHERE NOT (o.emaj_verb = ''UPD'' AND o.emaj_tuple = ''NEW'')'
                   ' AND %s',
                   v_rqInsert, v_rqUpdate, v_rqDelete, v_rqTruncate, v_logTableName, v_logTableName, v_conditions);
    GET DIAGNOSTICS v_nbSQL = ROW_COUNT;
    RETURN v_nbSQL;
  END;
$_gen_sql_tbl$;

CREATE OR REPLACE FUNCTION emaj._gen_sql_seq(r_rel emaj.emaj_relation, v_firstMarkTimeId BIGINT, v_lastMarkTimeId BIGINT, v_nbSeq BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS
$_gen_sql_seq$
-- This function generates a SQL command to set the final characteristics of a sequence.
-- The command is stored into a temporary table created by the _gen_sql_groups() calling function.
-- Input: row from emaj_relation corresponding to the appplication sequence to proccess,
--        the time id at requested start and end marks,
--        the number of already processed sequences
-- Output: number of generated SQL statements (0 or 1)
  DECLARE
    v_fullSeqName            TEXT;
    v_refLastValue           BIGINT;
    v_refIsCalled            BOOLEAN;
    v_refIncrementBy         BIGINT;
    v_refStartValue          BIGINT;
    v_refMinValue            BIGINT;
    v_refMaxValue            BIGINT;
    v_refCacheValue          BIGINT;
    v_refIsCycled            BOOLEAN;
    v_stmt                   TEXT;
    v_trgLastValue           BIGINT;
    v_trgIsCalled            BOOLEAN;
    v_trgIncrementBy         BIGINT;
    v_trgStartValue          BIGINT;
    v_trgMinValue            BIGINT;
    v_trgMaxValue            BIGINT;
    v_trgCacheValue          BIGINT;
    v_trgIsCycled            BOOLEAN;
    v_endTimeId              BIGINT;
    v_rqSeq                  TEXT;
  BEGIN
    v_fullSeqName = quote_ident(r_rel.rel_schema) || '.' || quote_ident(r_rel.rel_tblseq);
-- get the sequence characteristics at start mark
    SELECT sequ_last_val, sequ_is_called, sequ_increment, sequ_start_val,
           sequ_min_val, sequ_max_val, sequ_cache_val, sequ_is_cycled
      INTO STRICT v_refLastValue, v_refIsCalled, v_refIncrementBy, v_refStartValue,
           v_refMinValue, v_refMaxValue, v_refCacheValue, v_refIsCycled
      FROM emaj.emaj_sequence
      WHERE sequ_schema = r_rel.rel_schema AND sequ_name = r_rel.rel_tblseq
        AND sequ_time_id = v_firstMarkTimeId;
-- get the sequence characteristics at end mark or the current state
    IF v_lastMarkTimeId IS NULL AND upper_inf(r_rel.rel_time_range) THEN
-- no supplied last mark and the sequence currently belongs to its group, so get current sequence characteritics
      IF emaj._pg_version_num() >= 100000 THEN
        v_stmt = 'SELECT rel.last_value, is_called, increment_by, start_value, min_value, max_value, cache_size, cycle '
              || 'FROM ' || v_fullSeqName  || ' rel, pg_catalog.pg_sequences '
              || ' WHERE schemaname = ' || quote_literal(r_rel.rel_schema) || ' AND sequencename = '
              || quote_literal(r_rel.rel_tblseq);
      ELSE
        v_stmt = 'SELECT last_value, is_called, increment_by, start_value, min_value, max_value, cache_value, is_cycled '
              || 'FROM ' || v_fullSeqName;
      END IF;
      EXECUTE v_stmt INTO v_trgLastValue, v_trgIsCalled, v_trgIncrementBy, v_trgStartValue,
                          v_trgMinValue, v_trgMaxValue, v_trgCacheValue, v_trgIsCycled;
    ELSE
-- a last mark is supplied, or the sequence does not belong to its groupe anymore, so get sequence characteristics from the emaj_sequence
-- table
      v_endTimeId = CASE WHEN upper_inf(r_rel.rel_time_range) OR v_lastMarkTimeId < upper(r_rel.rel_time_range)
                           THEN v_lastMarkTimeId
                         ELSE upper(r_rel.rel_time_range) END;
      SELECT sequ_last_val, sequ_is_called, sequ_increment, sequ_start_val,
             sequ_min_val, sequ_max_val, sequ_cache_val, sequ_is_cycled
        INTO STRICT v_trgLastValue, v_trgIsCalled, v_trgIncrementBy, v_trgStartValue,
             v_trgMinValue, v_trgMaxValue, v_trgCacheValue, v_trgIsCycled
        FROM emaj.emaj_sequence
        WHERE sequ_schema = r_rel.rel_schema AND sequ_name = r_rel.rel_tblseq
          AND sequ_time_id = v_endTimeId;
    END IF;
-- build the ALTER SEQUENCE clause
    SELECT emaj._build_alter_seq(v_refLastValue, v_refIsCalled, v_refIncrementBy, v_refStartValue,
                                 v_refMinValue, v_refMaxValue, v_refCacheValue, v_refIsCycled,
                                 v_trgLastValue, v_trgIsCalled, v_trgIncrementBy, v_trgStartValue,
                                 v_trgMinValue, v_trgMaxValue, v_trgCacheValue, v_trgIsCycled) INTO v_rqSeq;
-- insert into the temp table and return 1 if at least 1 characteristic needs to be changed
    IF v_rqSeq <> '' THEN
      v_rqSeq = 'ALTER SEQUENCE ' || v_fullSeqName || ' ' || v_rqSeq || ';';
      EXECUTE 'INSERT INTO emaj_temp_script '
              '  SELECT NULL, -1 * $1, txid_current(), $2'
        USING v_nbSeq + 1, v_rqSeq;
      RETURN 1;
    END IF;
-- otherwise return 0
    RETURN 0;
  END;
$_gen_sql_seq$;

CREATE OR REPLACE FUNCTION emaj._get_current_sequence_state(v_schema TEXT, v_sequence TEXT, v_timeId BIGINT)
RETURNS emaj.emaj_sequence LANGUAGE plpgsql AS
$_get_current_sequence_state$
-- The function returns the current state of a single sequence.
-- Input: schema and sequence name,
--        time_id to set the sequ_time_id
-- Output: an emaj_sequence record
  DECLARE
    r_sequ                   emaj.emaj_sequence%ROWTYPE;
  BEGIN
    IF emaj._pg_version_num() >= 100000 THEN
      EXECUTE format('SELECT schemaname, sequencename, %s, rel.last_value, start_value, increment_by, max_value, min_value, cache_size,'
                     '       cycle, rel.is_called FROM %I.%I rel, pg_catalog.pg_sequences '
                     '  WHERE schemaname = %L AND sequencename = %L',
                     v_timeId, v_schema, v_sequence, v_schema, v_sequence)
        INTO STRICT r_sequ;
    ELSE
      EXECUTE format('SELECT %L, %L, %s, last_value, start_value, increment_by, max_value, min_value, cache_value, is_cycled, is_called'
                     ' FROM %I.%I',
                     v_schema, v_sequence, v_timeId, v_schema, v_sequence)
        INTO STRICT r_sequ;
    END IF;
    RETURN r_sequ;
  END;
$_get_current_sequence_state$;

--------------------------------------------
--                                        --
--       Functions to manage groups       --
--                                        --
--------------------------------------------

CREATE OR REPLACE FUNCTION emaj._verify_groups(v_groups TEXT[], v_onErrorStop BOOLEAN)
RETURNS SETOF emaj._verify_groups_type LANGUAGE plpgsql AS
$_verify_groups$
-- The function verifies the consistency of a tables groups array.
-- Input: - tables groups array,
--        - a boolean indicating whether the function has to raise an exception in case of detected unconsistency.
-- If onErrorStop boolean is false, it returns a set of _verify_groups_type records, one row per detected unconsistency, including
-- the faulting schema and table or sequence names and a detailed message.
-- If no error is detected, no row is returned.
-- This function may be directly called by the Emaj_web client.
  DECLARE
    v_hint                   TEXT = 'You may use "SELECT * FROM emaj.emaj_verify_all()" to look for other issues.';
    r_object                 RECORD;
  BEGIN
-- Note that there is no check that the supplied groups exist. This has already been done by all calling functions.
-- Let's start with some global checks that always raise an exception if an issue is detected
-- check the postgres version: E-Maj needs postgres 9.5+
    IF emaj._pg_version_num() < 90500 THEN
      RAISE EXCEPTION '_verify_groups: The current postgres version (%) is not compatible with this E-Maj version.'
                      ' It should be at least 9.5.', version();
    END IF;
-- OK, now look for groups unconsistency
-- Unlike emaj_verify_all(), there is no direct check that application schemas exist
-- check all application relations referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT t.rel_schema, t.rel_tblseq, r.rel_group,
             'In group "' || r.rel_group || '", the ' ||
               CASE WHEN t.rel_kind = 'r' THEN 'table "' ELSE 'sequence "' END ||
               t.rel_schema || '"."' || t.rel_tblseq || '" does not exist any more.' AS msg
        FROM (                                    -- all relations currently belonging to the groups
          SELECT rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
            WHERE rel_group = ANY (v_groups) AND upper_inf(rel_time_range)
            EXCEPT                                -- all relations known by postgres
          SELECT nspname, relname, relkind FROM pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND relkind IN ('r','S')
             ) AS t, emaj.emaj_relation r         -- join with emaj_relation to get the group name
        WHERE t.rel_schema = r.rel_schema AND t.rel_tblseq = r.rel_tblseq AND upper_inf(r.rel_time_range)
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (1): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check the log table for all tables referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT rel_schema, rel_tblseq, rel_group,
             'In group "' || rel_group || '", the log table "' ||
               rel_log_schema || '"."' || rel_log_table || '" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groups)
          AND rel_kind = 'r'
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_log_schema AND relname = rel_log_table
                   AND relnamespace = pg_namespace.oid)
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (2): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check the log function for each table referenced in the emaj_relation table still exists
    FOR r_object IN
                                                  -- the schema and table names are rebuilt from the returned function name
      SELECT rel_schema, rel_tblseq, rel_group,
             'In group "' || rel_group || '", the log function "' || rel_log_schema || '"."' || rel_log_function || '" is not found.'
               AS msg
        FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_proc, pg_catalog.pg_namespace
                 WHERE nspname = rel_log_schema AND proname = rel_log_function
                   AND pronamespace = pg_namespace.oid)
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (3): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check log and truncate triggers for all tables referenced in the emaj_relation table still exist
--   start with log trigger
    FOR r_object IN
      SELECT rel_schema, rel_tblseq, rel_group,
             'In group "' || rel_group || '", the log trigger "emaj_log_trg" on table "' ||
               rel_schema || '"."' || rel_tblseq || '" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND tgname = 'emaj_log_trg'
                   AND tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid)
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (4): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
--   then truncate trigger
    FOR r_object IN
      SELECT rel_schema, rel_tblseq, rel_group,
             'In group "' || rel_group || '", the truncate trigger "emaj_trunc_trg" on table "' ||
             rel_schema || '"."' || rel_tblseq || '" is not found.' AS msg
        FROM emaj.emaj_relation
      WHERE rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND tgname = 'emaj_trunc_trg'
                   AND tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid)
      ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (5): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check all log tables have a structure consistent with the application tables they reference
--      (same columns and same formats). It only returns one row per faulting table.
    FOR r_object IN
      WITH cte_app_tables_columns AS (                -- application table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = FALSE
              AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)),
           cte_log_tables_columns AS (                -- log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema
              AND relname = rel_log_table
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = FALSE AND attnum < rel_emaj_verb_attnum
              AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range))
      SELECT DISTINCT rel_schema, rel_tblseq, rel_group,
             'In group "' || rel_group || '", the structure of the application table "' ||
               rel_schema || '"."' || rel_tblseq || '" is not coherent with its log table ("' ||
             rel_log_schema || '"."' || rel_log_table || '").' AS msg
        FROM (
          (                                        -- application table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
            FROM cte_app_tables_columns
          EXCEPT                                   -- minus log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
            FROM cte_log_tables_columns
          )
          UNION
          (                                         -- log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
            FROM cte_log_tables_columns
          EXCEPT                                    -- minus application table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
            FROM cte_app_tables_columns
          )) AS t
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (6): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check all tables have their primary key if they belong to a rollbackable group
    FOR r_object IN
      SELECT rel_schema, rel_tblseq, rel_group,
             'In rollbackable group "' || rel_group || '", the table "' ||
             rel_schema || '"."' || rel_tblseq || '" has no primary key any more.' AS msg
        FROM emaj.emaj_relation, emaj.emaj_group
        WHERE rel_group = group_name
          AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
          AND group_is_rollbackable
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_constraint
                 WHERE nspname = rel_schema AND relname = rel_tblseq
                   AND relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid
                   AND contype = 'p')
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (7): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- for rollbackable groups, check no table has been altered as UNLOGGED or dropped and recreated as TEMP table after tables groups creation
    FOR r_object IN
      SELECT rel_schema, rel_tblseq, rel_group,
             'In rollbackable group "' || rel_group || '", the table "' ||
             rel_schema || '"."' || rel_tblseq || '" is UNLOGGED or TEMP.' AS msg
        FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_group
        WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
          AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
          AND group_name = rel_group AND group_is_rollbackable
          AND relpersistence <> 'p'
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (8): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- for rollbackable groups, with PG 11-, check no table has been altered as WITH OIDS after tables groups creation
    IF emaj._pg_version_num() < 120000 THEN
      FOR r_object IN
        SELECT rel_schema, rel_tblseq, rel_group,
               'In rollbackable group "' || rel_group || '", the table "' ||
               rel_schema || '"."' || rel_tblseq || '" is declared WITH OIDS.' AS msg
          FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_group
          WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
            AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
            AND group_name = rel_group AND group_is_rollbackable
            AND relhasoids
          ORDER BY 1,2,3
      LOOP
        IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (9): % %',r_object.msg,v_hint; END IF;
        RETURN NEXT r_object;
      END LOOP;
    END IF;
-- check the primary key structure of all tables belonging to rollbackable groups is unchanged
    FOR r_object IN
      SELECT rel_schema, rel_tblseq, rel_group,
             'In rollbackable group "' || rel_group || '", the primary key of the table "' ||
             rel_schema || '"."' || rel_tblseq || '" has changed (' ||
             rel_sql_rlbk_pk_columns || ' => ' || current_pk_columns || ').' AS msg
        FROM (
          SELECT rel_schema, rel_tblseq, rel_group, rel_sql_rlbk_pk_columns,
                 string_agg(quote_ident(attname), ',' ORDER BY attnum) AS current_pk_columns
            FROM emaj.emaj_relation, emaj.emaj_group, pg_catalog.pg_attribute, pg_catalog.pg_index, pg_catalog.pg_class,
                 pg_catalog.pg_namespace
            WHERE -- join conditions
                  rel_group = group_name
              AND relname = rel_tblseq AND nspname = rel_schema
              AND pg_attribute.attrelid = pg_index.indrelid
              AND indrelid = pg_class.oid AND relnamespace = pg_namespace.oid
                  -- filter conditions
              AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
              AND group_is_rollbackable
              AND attnum = ANY (indkey)
              AND indisprimary
              AND attnum > 0 AND attisdropped = FALSE
            GROUP BY rel_schema, rel_tblseq, rel_group, rel_sql_rlbk_pk_columns
          ) AS t
          WHERE rel_sql_rlbk_pk_columns <> current_pk_columns
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (10): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check all log tables have the 6 required technical columns. It only returns one row per faulting table.
    FOR r_object IN
      SELECT DISTINCT rel_schema, rel_tblseq, rel_group,
             'In group "' || rel_group || '", the log table "' ||
             rel_log_schema || '"."' || rel_log_table || '" miss some technical columns (' ||
             string_agg(attname,', ') || ').' AS msg
        FROM (
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname
              FROM emaj.emaj_relation,
                  (VALUES ('emaj_verb'), ('emaj_tuple'), ('emaj_gid'), ('emaj_changed'), ('emaj_txid'), ('emaj_user')) AS t(attname)
              WHERE rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
                AND EXISTS
                  (SELECT NULL FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                     WHERE nspname = rel_log_schema AND relname = rel_log_table
                       AND relnamespace = pg_namespace.oid)
          EXCEPT
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname
              FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
              WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema
                AND relname = rel_log_table
                AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = FALSE
                AND attname IN ('emaj_verb', 'emaj_tuple', 'emaj_gid', 'emaj_changed', 'emaj_txid', 'emaj_user')
                AND rel_group = ANY (v_groups) AND rel_kind = 'r' AND upper_inf(rel_time_range)
          ) AS t2
        GROUP BY rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_groups (11): % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
--
    RETURN;
  END;
$_verify_groups$;

CREATE OR REPLACE FUNCTION emaj._check_fk_groups(v_groupNames TEXT[])
RETURNS VOID LANGUAGE plpgsql AS
$_check_fk_groups$
-- This function checks foreign key constraints for tables of a groups array.
-- Tables from audit_only groups are ignored in this check because they will never be rolled back.
-- Input: group names array
  DECLARE
    r_fk                     RECORD;
  BEGIN
-- issue a warning if a table of the groups has a foreign key that references a table outside the groups
    FOR r_fk IN
      SELECT c.conname,r.rel_schema,r.rel_tblseq,nf.nspname,tf.relname
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace nf, pg_catalog.pg_class tf, emaj.emaj_relation r, emaj.emaj_group g
        WHERE contype = 'f'                                         -- FK constraints only
          AND c.conrelid  = t.oid  AND t.relnamespace  = n.oid      -- join for table and namespace
          AND c.confrelid = tf.oid AND tf.relnamespace = nf.oid     -- join for referenced table and namespace
          AND n.nspname = r.rel_schema AND t.relname = r.rel_tblseq -- join on emaj_relation table
          AND r.rel_group = g.group_name                            -- join on emaj_group table
          AND upper_inf(r.rel_time_range)
          AND r.rel_group = ANY (v_groupNames)                      -- only tables currently belonging to the selected groups
          AND g.group_is_rollbackable                               -- only tables from rollbackable groups
          AND NOT EXISTS                                            -- referenced table currently outside the groups
              (SELECT NULL FROM emaj.emaj_relation
                 WHERE rel_schema = nf.nspname AND rel_tblseq = tf.relname
                   AND upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames))
        ORDER BY 1,2,3
    LOOP
      RAISE WARNING '_check_fk_groups: The foreign key "%" on the table "%.%" references the table "%.%" that is outside the groups (%).',
        r_fk.conname,r_fk.rel_schema,r_fk.rel_tblseq,r_fk.nspname,r_fk.relname,array_to_string(v_groupNames,',');
    END LOOP;
-- issue a warning if a table of the groups is referenced by a table outside the groups
    FOR r_fk IN
      SELECT c.conname,n.nspname,t.relname,r.rel_schema,r.rel_tblseq
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace nf, pg_catalog.pg_class tf, emaj.emaj_relation r, emaj.emaj_group g
        WHERE contype = 'f'                                           -- FK constraints only
          AND c.conrelid  = t.oid  AND t.relnamespace  = n.oid        -- join for table and namespace
          AND c.confrelid = tf.oid AND tf.relnamespace = nf.oid       -- join for referenced table and namespace
          AND nf.nspname = r.rel_schema AND tf.relname = r.rel_tblseq -- join with emaj_relation table
          AND r.rel_group = g.group_name                              -- join on emaj_group table
          AND upper_inf(r.rel_time_range)
          AND r.rel_group = ANY (v_groupNames)                        -- only tables currently belonging to the selected groups
          AND g.group_is_rollbackable                                 -- only tables from rollbackable groups
          AND NOT EXISTS                                              -- referenced table outside the groups
              (SELECT NULL FROM emaj.emaj_relation
                 WHERE rel_schema = n.nspname AND rel_tblseq = t.relname AND upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames))
        ORDER BY 1,2,3
    LOOP
      RAISE WARNING '_check_fk_groups: The table "%.%" is referenced by the foreign key "%" on the table "%.%" that is outside'
                    ' the groups (%).', r_fk.rel_schema, r_fk.rel_tblseq, r_fk.conname, r_fk.nspname, r_fk.relname,
                    array_to_string(v_groupNames,',');
    END LOOP;
    RETURN;
  END;
$_check_fk_groups$;

CREATE OR REPLACE FUNCTION emaj._lock_groups(v_groupNames TEXT[], v_lockMode TEXT, v_multiGroup BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS
$_lock_groups$
-- This function locks all tables of a groups array.
-- The lock mode is provided by the calling function.
-- It only locks existing tables. It is calling function's responsability to handle cases when application tables are missing.
-- Input: array of group names, lock mode, flag indicating whether the function is called to processed several groups
  DECLARE
    v_nbRetry                SMALLINT = 0;
    v_nbTbl                  INT;
    v_ok                     BOOLEAN = FALSE;
    v_fullTableName          TEXT;
    r_tblsq                  RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES (CASE WHEN v_multiGroup THEN 'LOCK_GROUPS' ELSE 'LOCK_GROUP' END,'BEGIN', array_to_string(v_groupNames,','));
-- acquire lock on all tables
-- in case of deadlock, retry up to 5 times
    WHILE NOT v_ok AND v_nbRetry < 5 LOOP
      BEGIN
-- scan all tables currently belonging to the groups
        v_nbTbl = 0;
        FOR r_tblsq IN
            SELECT rel_priority, rel_schema, rel_tblseq
               FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace
               WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r' AND upper_inf(rel_time_range)
                 AND relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
               ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
-- lock the table
          v_fullTableName = quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
          EXECUTE format('LOCK TABLE %s IN %s MODE',
                         v_fullTableName, v_lockMode);
          v_nbTbl = v_nbTbl + 1;
        END LOOP;
-- ok, all tables locked
        v_ok = TRUE;
      EXCEPTION
        WHEN deadlock_detected THEN
          v_nbRetry = v_nbRetry + 1;
          RAISE NOTICE '_lock_groups: A deadlock has been trapped while locking tables of group "%".', v_groupNames;
      END;
    END LOOP;
    IF NOT v_ok THEN
      RAISE EXCEPTION '_lock_groups: Too many (5) deadlocks encountered while locking tables of group "%".',v_groupNames;
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'LOCK_GROUPS' ELSE 'LOCK_GROUP' END, 'END',
              array_to_string(v_groupNames,','), v_nbTbl || ' tables locked, ' || v_nbRetry || ' deadlock(s)');
    RETURN;
  END;
$_lock_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_create_group(v_groupName TEXT, v_isRollbackable BOOLEAN DEFAULT TRUE,
                                                  v_is_empty BOOLEAN DEFAULT FALSE)
RETURNS INT LANGUAGE plpgsql AS
$emaj_create_group$
-- This function creates emaj objects for all tables of a group.
-- It also creates the log E-Maj schemas when needed.
-- Input: group name,
--        boolean indicating whether the group is rollbackable or not (true by default),
--        boolean explicitely indicating whether the group is empty or not
-- Output: number of processed tables and sequences
  DECLARE
    v_timeId                 BIGINT;
    v_nbTbl                  INT = 0;
    v_nbSeq                  INT = 0;
    r                        RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('CREATE_GROUP', 'BEGIN', v_groupName, CASE WHEN v_isRollbackable THEN 'rollbackable' ELSE 'audit_only' END);
-- check that the group name is valid
    IF v_groupName IS NULL OR v_groupName = '' THEN
      RAISE EXCEPTION 'emaj_create_group: The group name can''t be NULL or empty.';
    END IF;
-- check that the group is not yet recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF FOUND THEN
      RAISE EXCEPTION 'emaj_create_group: The group "%" already exists.', v_groupName;
    END IF;
-- check the consistency between the emaj_group_def table content and the v_is_empty input parameter
    PERFORM 0 FROM emaj.emaj_group_def WHERE grpdef_group = v_groupName LIMIT 1;
    IF NOT v_is_empty AND NOT FOUND THEN
       RAISE EXCEPTION 'emaj_create_group: The group "%" is unknown in the emaj_group_def table. To create an empty group,'
                       ' explicitely set the third parameter to true.', v_groupName;
    END IF;
    IF v_is_empty AND FOUND THEN
       RAISE WARNING 'emaj_create_group: Although the group "%" is referenced into the emaj_group_def table, it is left empty.',
                     v_groupName;
    END IF;
-- performs various checks on the group's content described in the emaj_group_def table
    IF NOT v_is_empty THEN
      FOR r IN
        SELECT chk_message FROM emaj._check_conf_groups(ARRAY[v_groupName])
          WHERE (v_isRollbackable AND chk_severity <= 2)
             OR (NOT v_isRollbackable AND chk_severity <= 1)
          ORDER BY chk_msg_type, chk_group, chk_schema, chk_tblseq
      LOOP
        RAISE WARNING 'emaj_create_group: error, %', r.chk_message;
      END LOOP;
      IF FOUND THEN
        RAISE EXCEPTION 'emaj_create_group: One or several errors have been detected in the emaj_group_def table content.';
      END IF;
    END IF;
-- OK
-- get the time stamp of the operation
    SELECT emaj._set_time_stamp('C') INTO v_timeId;
-- insert the row describing the group into the emaj_group table
-- (The group_is_rlbk_protected boolean column is always initialized as not group_is_rollbackable)
    INSERT INTO emaj.emaj_group (group_name, group_is_rollbackable, group_creation_time_id, group_has_waiting_changes,
                                 group_is_logging, group_is_rlbk_protected, group_nb_table, group_nb_sequence)
      VALUES (v_groupName, v_isRollbackable, v_timeId, FALSE, FALSE, NOT v_isRollbackable, 0, 0);
-- populate the group
    IF NOT v_is_empty THEN
-- create new E-Maj log schemas, if needed
      PERFORM emaj._create_log_schemas('CREATE_GROUP', ARRAY[v_groupName]);
-- get and process all tables of the group (in priority order, NULLS being processed last)
      PERFORM emaj._create_tbl(grpdef_schema, grpdef_tblseq, grpdef_group, grpdef_priority, grpdef_log_dat_tsp, grpdef_log_idx_tsp,
                               v_timeId, v_isRollbackable, FALSE)
        FROM (
          SELECT grpdef_schema, grpdef_tblseq, grpdef_group, grpdef_priority, grpdef_log_dat_tsp, grpdef_log_idx_tsp
            FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE grpdef_group = v_groupName
              AND relnamespace = pg_namespace.oid
              AND nspname = grpdef_schema AND relname = grpdef_tblseq
              AND relkind = 'r'
            ORDER BY grpdef_priority, grpdef_schema, grpdef_tblseq
             ) AS t;
      SELECT count(*) INTO v_nbTbl
        FROM emaj.emaj_relation
        WHERE rel_group = v_groupName AND rel_kind = 'r' AND upper_inf(rel_time_range);
-- get and process all sequences of the group (in alphabetical order)
      PERFORM emaj._create_seq(grpdef_schema, grpdef_tblseq, grpdef_group, v_timeId)
        FROM (
          SELECT grpdef_schema, grpdef_tblseq, grpdef_group, grpdef_priority
            FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE grpdef_group = v_groupName
              AND relnamespace = pg_namespace.oid
              AND nspname = grpdef_schema AND relname = grpdef_tblseq
              AND relkind = 'S'
            ORDER BY grpdef_schema, grpdef_tblseq
             ) AS t;
      SELECT count(*) INTO v_nbSeq
        FROM emaj.emaj_relation
        WHERE rel_group = v_groupName AND rel_kind = 'S' AND upper_inf(rel_time_range);
-- update tables and sequences counters in the emaj_group table
      UPDATE emaj.emaj_group SET group_nb_table = v_nbTbl, group_nb_sequence = v_nbSeq
        WHERE group_name = v_groupName;
-- check foreign keys with tables outside the group
      PERFORM emaj._check_fk_groups(array[v_groupName]);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('CREATE_GROUP', 'END', v_groupName, v_nbTbl + v_nbSeq || ' tables/sequences processed');
    RETURN v_nbTbl + v_nbSeq;
  END;
$emaj_create_group$;
COMMENT ON FUNCTION emaj.emaj_create_group(TEXT,BOOLEAN,BOOLEAN) IS
$$Creates an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_comment_group(v_groupName TEXT, v_comment TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$emaj_comment_group$
-- This function sets or modifies a comment on a group by updating the group_comment of the emaj_group table.
-- Input: group name, comment
--   To reset an existing comment for a group, the supplied comment can be NULL.
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- update the group_comment column from emaj_group table
    UPDATE emaj.emaj_group SET group_comment = v_comment WHERE group_name = v_groupName;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object)
      VALUES ('COMMENT_GROUP', v_groupName);
    RETURN;
  END;
$emaj_comment_group$;
COMMENT ON FUNCTION emaj.emaj_comment_group(TEXT,TEXT) IS
$$Sets a comment on an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_drop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_drop_group$
-- This function deletes the emaj objects for all tables of a group.
-- Input: group name
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTb                   INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('DROP_GROUP', 'BEGIN', v_groupName);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := 'IDLE');
-- effectively drop the group
    SELECT emaj._drop_group(v_groupName, FALSE) INTO v_nbTb;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DROP_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_drop_group$;
COMMENT ON FUNCTION emaj.emaj_drop_group(TEXT) IS
$$Drops an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_force_drop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_force_drop_group$
-- This function deletes the emaj objects for all tables of a group.
-- It differs from emaj_drop_group by the fact that:
--   - the group may be in LOGGING state,
--   - a missing component in the drop processing does not generate any error.
-- This allows to drop a group that is not consistent, following hasardeous operations.
-- This function should not be used, except if the emaj_drop_group fails.
-- Input: group name
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTb                   INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('FORCE_DROP_GROUP', 'BEGIN', v_groupName);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- effectively drop the group
    SELECT emaj._drop_group(v_groupName, TRUE) INTO v_nbTb;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('FORCE_DROP_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_force_drop_group$;
COMMENT ON FUNCTION emaj.emaj_force_drop_group(TEXT) IS
$$Drops an E-Maj group, even in LOGGING state.$$;

CREATE OR REPLACE FUNCTION emaj._drop_group(v_groupName TEXT, v_isForced BOOLEAN)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_drop_group$
-- This function effectively deletes the emaj objects for all tables of a group.
-- It also drops log schemas that are not useful any more.
-- Input: group name, and a boolean indicating whether the group's state has to be checked
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that log schemas can be dropped.
  DECLARE
    v_eventTriggers          TEXT[];
    v_timeId                 BIGINT;
    v_nbTb                   INT;
    r_rel                    emaj.emaj_relation%ROWTYPE;
  BEGIN
-- get the time stamp of the operation
    SELECT emaj._set_time_stamp('D') INTO v_timeId;
-- disable event triggers that protect emaj components and keep in memory these triggers name
    SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- delete the emaj objects and references for each table and sequences of the group
    FOR r_rel IN
        SELECT * FROM emaj.emaj_relation
          WHERE rel_group = v_groupName
          ORDER BY rel_priority, rel_schema, rel_tblseq, rel_time_range
    LOOP
        PERFORM CASE WHEN r_rel.rel_kind = 'r' THEN emaj._drop_tbl(r_rel, v_timeId)
                     WHEN r_rel.rel_kind = 'S' THEN emaj._drop_seq(r_rel, v_timeId) END;
    END LOOP;
-- drop the E-Maj log schemas that are now useless (i.e. not used by any other created group)
    PERFORM emaj._drop_log_schemas(CASE WHEN v_isForced THEN 'FORCE_DROP_GROUP' ELSE 'DROP_GROUP' END, v_isForced);
-- delete group row from the emaj_group table.
--   By cascade, it also deletes rows from emaj_mark
    DELETE FROM emaj.emaj_group WHERE group_name = v_groupName
      RETURNING group_nb_table + group_nb_sequence INTO v_nbTb;
-- enable previously disabled event triggers
    PERFORM emaj._enable_event_triggers(v_eventTriggers);
    RETURN v_nbTb;
  END;
$_drop_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_alter_group(v_groupName TEXT, v_mark TEXT DEFAULT 'ALTER_%')
RETURNS INT LANGUAGE plpgsql AS
$emaj_alter_group$
-- This function alters a tables group.
-- Input: group name
-- Output: number of tables and sequences belonging to the group after the operation
  BEGIN
    RETURN emaj._alter_groups(ARRAY[v_groupName], FALSE, v_mark);
  END;
$emaj_alter_group$;
COMMENT ON FUNCTION emaj.emaj_alter_group(TEXT, TEXT) IS
$$Alter an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_alter_groups(v_groupNames TEXT[], v_mark TEXT DEFAULT 'ALTER_%')
RETURNS INT LANGUAGE plpgsql AS
$emaj_alter_groups$
-- This function alters several tables groups.
-- Input: group names array
-- Output: number of tables and sequences belonging to the groups after the operation
  BEGIN
    RETURN emaj._alter_groups(v_groupNames, TRUE, v_mark);
  END;
$emaj_alter_groups$;
COMMENT ON FUNCTION emaj.emaj_alter_groups(TEXT[], TEXT) IS
$$Alter several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj._alter_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$_alter_groups$
-- This function effectively alters a tables groups array.
-- It takes into account the changes recorded in the emaj_group_def table since the groups have been created.
-- Input: group names array, flag indicating whether the function is called by the multi-group function or not
-- Output: number of tables and sequences belonging to the groups after the operation
  DECLARE
    v_loggingGroups          TEXT[];
    v_markName               TEXT;
    v_timeId                 BIGINT;
    v_eventTriggers          TEXT[];
    r                        RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES (CASE WHEN v_multiGroup THEN 'ALTER_GROUPS' ELSE 'ALTER_GROUP' END, 'BEGIN', array_to_string(v_groupNames,','));
-- check the group names
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := TRUE, v_checkList := '')
      INTO v_groupNames;
    IF v_groupNames IS NOT NULL THEN
-- performs various checks on the groups content described in the emaj_group_def table
    FOR r IN
      SELECT chk_message FROM emaj._check_conf_groups(v_groupNames), emaj.emaj_group
        WHERE chk_group = group_name
          AND ((group_is_rollbackable AND chk_severity <= 2)
            OR (NOT group_is_rollbackable AND chk_severity <= 1))
        ORDER BY chk_msg_type, chk_group, chk_schema, chk_tblseq
    LOOP
      RAISE WARNING '_alter_groups: %', r.chk_message;
    END LOOP;
    IF FOUND THEN
      RAISE EXCEPTION '_alter_groups: One or several errors have been detected in the emaj_group_def table content.';
    END IF;
-- build the list of groups that are in logging state
      SELECT array_agg(group_name ORDER BY group_name) INTO v_loggingGroups FROM emaj.emaj_group
        WHERE group_name = ANY(v_groupNames) AND group_is_logging;
-- check and process the supplied mark name, if it is worth to be done
      IF v_loggingGroups IS NOT NULL THEN
        SELECT emaj._check_new_mark(v_groupNames, v_mark) INTO v_markName;
      END IF;
-- OK
-- get the time stamp of the operation
      SELECT emaj._set_time_stamp('A') INTO v_timeId;
-- for LOGGING groups, lock all tables to get a stable point
      IF v_loggingGroups IS NOT NULL THEN
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
--  vacuum operation.
        PERFORM emaj._lock_groups(v_loggingGroups, 'ROW EXCLUSIVE', v_multiGroup);
-- and set the mark, using the same time identifier
        PERFORM emaj._set_mark_groups(v_loggingGroups, v_markName, v_multiGroup, TRUE, NULL, v_timeId);
      END IF;
-- disable event triggers that protect emaj components and keep in memory these triggers name
      SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- we can now plan all the steps needed to perform the operation
      PERFORM emaj._alter_plan(v_groupNames, v_timeId);
-- create the needed log schemas
      PERFORM emaj._create_log_schemas(CASE WHEN v_multiGroup THEN 'ALTER_GROUPS' ELSE 'ALTER_GROUP' END, v_groupNames);
-- execute the plan
      PERFORM emaj._alter_exec(v_timeId, v_multiGroup);
-- drop the E-Maj log schemas that are now useless (i.e. not used by any created group)
      PERFORM emaj._drop_log_schemas(CASE WHEN v_multiGroup THEN 'ALTER_GROUPS' ELSE 'ALTER_GROUP' END, FALSE);
-- update some attributes in the emaj_group table
      UPDATE emaj.emaj_group
        SET group_last_alter_time_id = v_timeId, group_has_waiting_changes = FALSE,
            group_nb_table = (SELECT count(*) FROM emaj.emaj_relation
                                WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'r'),
            group_nb_sequence = (SELECT count(*) FROM emaj.emaj_relation
                                   WHERE rel_group = group_name AND upper_inf(rel_time_range) AND rel_kind = 'S')
        WHERE group_name = ANY (v_groupNames);
-- enable previously disabled event triggers
      PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- check foreign keys with tables outside the groups in logging state
      PERFORM emaj._check_fk_groups(v_loggingGroups);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'ALTER_GROUPS' ELSE 'ALTER_GROUP' END, 'END', array_to_string(v_groupNames,','),
              'Timestamp Id : ' || v_timeId );
-- and return
    RETURN sum(group_nb_table) + sum(group_nb_sequence) FROM emaj.emaj_group WHERE group_name = ANY (v_groupNames);
  END;
$_alter_groups$;

CREATE OR REPLACE FUNCTION emaj._alter_plan(v_groupNames TEXT[], v_timeId BIGINT)
RETURNS VOID LANGUAGE plpgsql AS
$_alter_plan$
-- This function build the elementary steps that will be needed to perform an alter_groups operation.
-- Looking at emaj_relation and emaj_group_def tables, it populates the emaj_alter_plan table that will be used by the _alter_exec()
-- function.
-- Input: group names array, timestamp id of the operation (it will be used to identify rows in the emaj_alter_plan table)
  BEGIN
-- the plan is built using the same steps order than the coming execution
-- determine the relations that do not belong to the groups anymore
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority)
      SELECT v_timeId, CAST(CASE WHEN rel_kind = 'r' THEN 'REMOVE_TBL' ELSE 'REMOVE_SEQ' END AS emaj._alter_step_enum),
             rel_schema, rel_tblseq, rel_group, rel_priority
        FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groupNames) AND upper_inf(rel_time_range)
          AND NOT EXISTS (
              SELECT NULL FROM emaj.emaj_group_def
                WHERE grpdef_schema = rel_schema AND grpdef_tblseq = rel_tblseq
                  AND grpdef_group = ANY (v_groupNames));
-- determine the tables that need to be "repaired" (damaged or out of sync E-Maj components)
-- (normally, there should not be any REPAIR_SEQ - if any, the _alter_exec() function will produce an exception)
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority, altr_new_group)
      SELECT v_timeId, CAST(CASE WHEN rel_kind = 'r' THEN 'REPAIR_TBL' ELSE 'REPAIR_SEQ' END AS emaj._alter_step_enum),
             rel_schema, rel_tblseq, rel_group, grpdef_priority,
             CASE WHEN rel_group <> grpdef_group THEN grpdef_group ELSE NULL END
        FROM (                                   -- all damaged or out of sync tables
          SELECT DISTINCT ver_schema, ver_tblseq FROM emaj._verify_groups(v_groupNames, FALSE)
             ) AS t, emaj.emaj_relation, emaj.emaj_group_def
        WHERE rel_schema = ver_schema AND rel_tblseq = ver_tblseq AND upper_inf(rel_time_range)
          AND rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq
          AND rel_group = ANY (v_groupNames)
          AND grpdef_group = ANY (v_groupNames)
--   exclude relations that will have been removed in a previous step
          AND NOT EXISTS (
            SELECT 0 FROM emaj.emaj_alter_plan
              WHERE altr_schema = rel_schema AND altr_tblseq = rel_tblseq
                AND altr_time_id = v_timeId AND altr_step IN ('REMOVE_TBL', 'REMOVE_SEQ'));
-- determine the groups that will be reset (i.e. those in IDLE state)
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group)
      SELECT v_timeId, 'RESET_GROUP', '', '', group_name
        FROM emaj.emaj_group
        WHERE group_name = ANY (v_groupNames)
          AND NOT group_is_logging;
-- determine the tables whose log data tablespace in emaj_group_def has changed
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority, altr_new_group)
      SELECT v_timeId, 'CHANGE_TBL_LOG_DATA_TSP', rel_schema, rel_tblseq, rel_group, grpdef_priority,
             CASE WHEN rel_group <> grpdef_group THEN grpdef_group ELSE NULL END
        FROM emaj.emaj_relation, emaj.emaj_group_def
        WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq AND upper_inf(rel_time_range)
          AND rel_group = ANY (v_groupNames)
          AND grpdef_group = ANY (v_groupNames)
          AND rel_kind = 'r'
          AND coalesce(rel_log_dat_tsp,'') <> coalesce(grpdef_log_dat_tsp,'')
--   exclude tables that will have been repaired in a previous step
          AND NOT EXISTS (
            SELECT 0 FROM emaj.emaj_alter_plan
              WHERE altr_schema = rel_schema AND altr_tblseq = rel_tblseq
                AND altr_time_id = v_timeId AND altr_step = 'REPAIR_TBL');
-- determine the tables whose log data tablespace in emaj_group_def has changed
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority, altr_new_group)
      SELECT v_timeId, 'CHANGE_TBL_LOG_INDEX_TSP', rel_schema, rel_tblseq, rel_group, grpdef_priority,
             CASE WHEN rel_group <> grpdef_group THEN grpdef_group ELSE NULL END
        FROM emaj.emaj_relation, emaj.emaj_group_def
        WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq AND upper_inf(rel_time_range)
          AND rel_group = ANY (v_groupNames)
          AND grpdef_group = ANY (v_groupNames)
          AND rel_kind = 'r'
          AND coalesce(rel_log_idx_tsp,'') <> coalesce(grpdef_log_idx_tsp,'')
--   exclude tables that will have been repaired in a previous step
          AND NOT EXISTS (
            SELECT 0 FROM emaj.emaj_alter_plan
              WHERE altr_schema = rel_schema AND altr_tblseq = rel_tblseq
                AND altr_time_id = v_timeId AND altr_step = 'REPAIR_TBL');
-- determine the tables or sequences that change their group ownership
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority, altr_new_group)
      SELECT v_timeId, CAST(CASE WHEN rel_kind = 'r' THEN 'MOVE_TBL' ELSE 'MOVE_SEQ' END AS emaj._alter_step_enum),
             rel_schema, rel_tblseq, rel_group, grpdef_priority, grpdef_group
      FROM emaj.emaj_relation, emaj.emaj_group_def
      WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq AND upper_inf(rel_time_range)
        AND rel_group = ANY (v_groupNames)
        AND grpdef_group = ANY (v_groupNames)
        AND rel_group <> grpdef_group;
-- determine the tables that change their priority level
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority)
      SELECT v_timeId, 'CHANGE_REL_PRIORITY', rel_schema, rel_tblseq, rel_group, grpdef_priority
      FROM emaj.emaj_relation, emaj.emaj_group_def
      WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq AND upper_inf(rel_time_range)
        AND rel_kind = 'r'
        AND rel_group = ANY (v_groupNames)
        AND grpdef_group = ANY (v_groupNames)
        AND ( (rel_priority IS NULL AND grpdef_priority IS NOT NULL) OR
              (rel_priority IS NOT NULL AND grpdef_priority IS NULL) OR
              (rel_priority <> grpdef_priority) );
-- determine the relations to add to the groups
    INSERT INTO emaj.emaj_alter_plan (altr_time_id, altr_step, altr_schema, altr_tblseq, altr_group, altr_priority)
      SELECT v_timeId, CAST(CASE WHEN relkind = 'r' THEN 'ADD_TBL' ELSE 'ADD_SEQ' END AS emaj._alter_step_enum),
             grpdef_schema, grpdef_tblseq, grpdef_group, grpdef_priority
        FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE grpdef_group = ANY (v_groupNames)
          AND NOT EXISTS (
              SELECT NULL FROM emaj.emaj_relation
                WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq AND upper_inf(rel_time_range)
                  AND rel_group = ANY (v_groupNames))
          AND relnamespace = pg_namespace.oid AND nspname = grpdef_schema AND relname = grpdef_tblseq;
-- set the altr_group_is_logging column value
    UPDATE emaj.emaj_alter_plan SET altr_group_is_logging = group_is_logging
      FROM emaj.emaj_group
      WHERE altr_group = group_name
        AND altr_time_id = v_timeId AND altr_group <> '';
-- set the altr_new_group_is_logging column value for the cases when the group ownership changes
    UPDATE emaj.emaj_alter_plan SET altr_new_group_is_logging = group_is_logging
      FROM emaj.emaj_group
      WHERE altr_new_group = group_name
        AND altr_time_id = v_timeId AND altr_new_group IS NOT NULL;
-- and return
    RETURN;
  END;
$_alter_plan$;

CREATE OR REPLACE FUNCTION emaj._alter_exec(v_timeId BIGINT, v_multiGroup BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS
$_alter_exec$
-- This function executes the alter groups operation that has been planned by the _alter_plan() function.
-- It looks at the emaj_alter_plan table and executes elementary step in proper order.
-- Input: timestamp id of the operation
  DECLARE
    v_function               TEXT;
    v_logDatTsp              TEXT;
    v_logIdxTsp              TEXT;
    v_isRollbackable         BOOLEAN;
    r_plan                   emaj.emaj_alter_plan%ROWTYPE;
    r_rel                    emaj.emaj_relation%ROWTYPE;
  BEGIN
    v_function = CASE WHEN v_multiGroup THEN 'ALTER_GROUPS' ELSE 'ALTER_GROUP' END;
-- scan the emaj_alter_plan table and execute each elementary item in the proper order
    FOR r_plan IN
      SELECT *
        FROM emaj.emaj_alter_plan
        WHERE altr_time_id = v_timeId
        ORDER BY altr_step, altr_priority, altr_schema, altr_tblseq, altr_group
    LOOP
      CASE r_plan.altr_step
        WHEN 'REMOVE_TBL' THEN
-- remove a table from its group
          PERFORM emaj._remove_tbl(r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group, r_plan.altr_group_is_logging,
                                   v_timeId, v_function);
--
        WHEN 'REMOVE_SEQ' THEN
-- remove a sequence from its group
          PERFORM emaj._remove_seq(r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group, r_plan.altr_group_is_logging,
                                   v_timeId, v_function);
--
        WHEN 'RESET_GROUP' THEN
-- reset a group
          PERFORM emaj._reset_groups(ARRAY[r_plan.altr_group]);
--
        WHEN 'REPAIR_TBL' THEN
          IF r_plan.altr_group_is_logging THEN
            RAISE EXCEPTION 'alter_exec: Cannot repair the table %.%. Its group % is in LOGGING state.',
              r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group;
          ELSE
-- remove the table from its group
            PERFORM emaj._drop_tbl(emaj.emaj_relation.*, v_timeId) FROM emaj.emaj_relation
              WHERE rel_schema = r_plan.altr_schema AND rel_tblseq = r_plan.altr_tblseq AND upper_inf(rel_time_range);
-- get the is_rollbackable status of the related group
            SELECT group_is_rollbackable INTO v_isRollbackable
              FROM emaj.emaj_group WHERE group_name = r_plan.altr_group;
-- and recreate it
            PERFORM emaj._create_tbl(grpdef_schema, grpdef_tblseq, grpdef_group, grpdef_priority, grpdef_log_dat_tsp, grpdef_log_idx_tsp,
                                     v_timeId, v_isRollbackable, r_plan.altr_group_is_logging)
              FROM emaj.emaj_group_def
              WHERE grpdef_group = coalesce (r_plan.altr_new_group, r_plan.altr_group)
                AND grpdef_schema = r_plan.altr_schema AND grpdef_tblseq = r_plan.altr_tblseq;
          END IF;
--
        WHEN 'REPAIR_SEQ' THEN
          RAISE EXCEPTION 'alter_exec: Internal error, trying to repair a sequence (%.%) is abnormal.',
            r_plan.altr_schema, r_plan.altr_tblseq;
--
        WHEN 'CHANGE_TBL_LOG_DATA_TSP' THEN
-- get the table description from emaj_relation
          SELECT * INTO r_rel FROM emaj.emaj_relation
            WHERE rel_schema = r_plan.altr_schema AND rel_tblseq = r_plan.altr_tblseq AND upper_inf(rel_time_range);
-- get the table description from emaj_group_def
          SELECT grpdef_log_dat_tsp INTO v_logDatTsp FROM emaj.emaj_group_def
            WHERE grpdef_group = coalesce (r_plan.altr_new_group, r_plan.altr_group)
              AND grpdef_schema = r_plan.altr_schema AND grpdef_tblseq = r_plan.altr_tblseq;
-- then alter the relation, depending on the changes
          PERFORM emaj._change_log_data_tsp_tbl(r_rel.rel_schema, r_rel.rel_tblseq, r_rel.rel_log_schema, r_rel.rel_log_table,
                                                r_rel.rel_log_dat_tsp, v_logDatTsp, v_function);
--
        WHEN 'CHANGE_TBL_LOG_INDEX_TSP' THEN
-- get the table description from emaj_relation
          SELECT * INTO r_rel FROM emaj.emaj_relation
            WHERE rel_schema = r_plan.altr_schema AND rel_tblseq = r_plan.altr_tblseq AND upper_inf(rel_time_range);
-- get the table description from emaj_group_def
          SELECT grpdef_log_idx_tsp INTO v_logIdxTsp FROM emaj.emaj_group_def
            WHERE grpdef_group = coalesce (r_plan.altr_new_group, r_plan.altr_group)
              AND grpdef_schema = r_plan.altr_schema AND grpdef_tblseq = r_plan.altr_tblseq;
-- then alter the relation, depending on the changes
          PERFORM emaj._change_log_index_tsp_tbl(r_rel.rel_schema, r_rel.rel_tblseq, r_rel.rel_log_schema, r_rel.rel_log_index,
                                                 r_rel.rel_log_idx_tsp, v_logIdxTsp, v_function);
--
        WHEN 'MOVE_TBL' THEN
-- move a table from one group to another group
          PERFORM emaj._move_tbl(r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group, r_plan.altr_group_is_logging,
                                r_plan.altr_new_group, r_plan.altr_new_group_is_logging, v_timeId, v_function);
--
        WHEN 'MOVE_SEQ' THEN
-- move a sequence from one group to another group
          PERFORM emaj._move_seq(r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group, r_plan.altr_group_is_logging,
                                r_plan.altr_new_group, r_plan.altr_new_group_is_logging, v_timeId, v_function);
--
        WHEN 'CHANGE_REL_PRIORITY' THEN
-- get the table description from emaj_relation
          SELECT * INTO r_rel FROM emaj.emaj_relation
            WHERE rel_schema = r_plan.altr_schema AND rel_tblseq = r_plan.altr_tblseq AND upper_inf(rel_time_range);
-- update the emaj_relation table to report the priority change
          PERFORM emaj._change_priority_tbl(r_plan.altr_schema, r_plan.altr_tblseq, r_rel.rel_priority, r_plan.altr_priority, v_function);
--
        WHEN 'ADD_TBL' THEN
-- add a table to a group
          PERFORM emaj._add_tbl(r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group, grpdef_priority, grpdef_log_dat_tsp,
                                grpdef_log_idx_tsp, r_plan.altr_group_is_logging, v_timeId, v_function)
            FROM emaj.emaj_group_def
            WHERE grpdef_group = r_plan.altr_group AND grpdef_schema = r_plan.altr_schema AND grpdef_tblseq = r_plan.altr_tblseq;
--
        WHEN 'ADD_SEQ' THEN
-- add a sequence to a group
          PERFORM emaj._add_seq(r_plan.altr_schema, r_plan.altr_tblseq, r_plan.altr_group, r_plan.altr_group_is_logging,
                                v_timeId, v_function);
--
      END CASE;
    END LOOP;
    RETURN;
  END;
$_alter_exec$;

CREATE OR REPLACE FUNCTION emaj.emaj_sync_def_group(v_group TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS
$emaj_sync_def_group$
-- The function re-synchronizes the content of the emaj_group_def table for one tables group
--   based on the current groups content.
-- Inputs: group name
-- Outputs: number of tables and sequences of the tables group
  DECLARE
    v_nbTblSeq               INT;
  BEGIN
-- check that the group exists
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_group], v_mayBeNull := FALSE, v_lockGroups := FALSE, v_checkList := '');
-- in emaj_group_def, delete existing rows for the group
    DELETE FROM emaj.emaj_group_def WHERE grpdef_group = v_group;
-- ... and insert the rows describing the current group content
    INSERT INTO emaj.emaj_group_def (grpdef_group, grpdef_schema, grpdef_tblseq, grpdef_priority, grpdef_log_dat_tsp, grpdef_log_idx_tsp)
      SELECT rel_group, rel_schema, rel_tblseq, rel_priority, rel_log_dat_tsp, rel_log_idx_tsp
        FROM emaj.emaj_relation
        WHERE rel_group = v_group AND upper_inf(rel_time_range);
    GET DIAGNOSTICS v_nbTblSeq = ROW_COUNT;
-- reset the group_has_waiting_changes flag
    UPDATE emaj.emaj_group SET group_has_waiting_changes = FALSE WHERE group_name = v_group;
-- take a trace in the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('SYNC_DEF_GROUP', 'EMAJ_GROUP_DEF SYNCHRONIZED', v_group);
    RETURN v_nbTblSeq;
  END;
$emaj_sync_def_group$;
COMMENT ON FUNCTION emaj.emaj_sync_def_group(TEXT) IS
$$Re-synchronize the content of the emaj_group_def table for one tables group based on its current content.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_start_group(v_groupName TEXT, v_mark TEXT DEFAULT 'START_%', v_resetLog BOOLEAN DEFAULT TRUE)
RETURNS INT LANGUAGE plpgsql AS
$emaj_start_group$
-- This function activates the log triggers of all the tables for a group and set a first mark.
-- It may reset log tables.
-- Input: group name,
--        name of the mark to set
--          '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--          if omitted or if null or '', the mark is set to 'START_%', % representing the current timestamp
--        boolean indicating whether the log tables of the group must be reset, true by default.
-- Output: number of processed tables and sequences
  BEGIN
-- call the common _start_groups function
    RETURN emaj._start_groups(array[v_groupName], v_mark, FALSE, v_resetLog);
  END;
$emaj_start_group$;
COMMENT ON FUNCTION emaj.emaj_start_group(TEXT,TEXT,BOOLEAN) IS
$$Starts an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_start_groups(v_groupNames TEXT[], v_mark TEXT DEFAULT 'START_%', v_resetLog BOOLEAN DEFAULT TRUE)
RETURNS INT LANGUAGE plpgsql AS
$emaj_start_groups$
-- This function activates the log triggers of all the tables for a groups array and set a first mark.
-- Input: array of group names,
--        name of the mark to set (if omitted, START_<current timestamp>)
--          '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--          if omitted or if null or '', the mark is set to 'START_%', % representing the current timestamp
--        boolean indicating whether the log tables of the group must be reset, true by default.
-- Output: total number of processed tables and sequences
  BEGIN
-- call the common _start_groups function
    RETURN emaj._start_groups(v_groupNames, v_mark, TRUE, v_resetLog);
  END;
$emaj_start_groups$;
COMMENT ON FUNCTION emaj.emaj_start_groups(TEXT[],TEXT, BOOLEAN) IS
$$Starts several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj._start_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_resetLog BOOLEAN)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_start_groups$
-- This function activates the log triggers of all the tables for one or several groups and set a first mark.
-- It also delete oldest rows in emaj_hist table.
-- Input: array of group names, name of the mark to set, boolean indicating whether the function is called by a multi group function,
--        boolean indicating whether the function must reset the group at start time
-- Output: number of processed tables
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables and
-- sequences.
  DECLARE
    v_nbTblSeq               INT = 0;
    v_markName               TEXT;
    v_eventTriggers          TEXT[];
    r_tblsq                  RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'START_GROUPS' ELSE 'START_GROUP' END, 'BEGIN', array_to_string(v_groupNames,','),
              CASE WHEN v_resetLog THEN 'With log reset' ELSE 'Without log reset' END);
-- check the group names
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := TRUE, v_checkList := 'IDLE')
      INTO v_groupNames;
    IF v_groupNames IS NOT NULL THEN
-- if there is at least 1 group to process, go on
-- check that no group is damaged
      PERFORM 0 FROM emaj._verify_groups(v_groupNames, TRUE);
-- check foreign keys with tables outside the group
      PERFORM emaj._check_fk_groups(v_groupNames);
-- purge the emaj history, if needed
      PERFORM emaj._purge_hist();
-- if requested by the user, call the emaj_reset_groups() function to erase remaining traces from previous logs
      if v_resetLog THEN
        PERFORM emaj._reset_groups(v_groupNames);
--    drop the log schemas that would have been emptied by the _reset_groups() call
        SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
        PERFORM emaj._drop_log_schemas(CASE WHEN v_multiGroup THEN 'START_GROUPS' ELSE 'START_GROUP' END, FALSE);
        PERFORM emaj._enable_event_triggers(v_eventTriggers);
      END IF;
-- check the supplied mark name (the check must be performed after the _reset_groups() call to allow to reuse an old mark name that is
-- being deleted
      IF v_mark IS NULL OR v_mark = '' THEN
        v_mark = 'START_%';
      END IF;
      SELECT emaj._check_new_mark(v_groupNames, v_mark) INTO v_markName;
-- OK, lock all tables to get a stable point
--   one sets the locks at the beginning of the operation (rather than let the ALTER TABLE statements set their own locks) to decrease the
--   risk of deadlock.
      PERFORM emaj._lock_groups(v_groupNames,'SHARE ROW EXCLUSIVE',v_multiGroup);
-- enable all log triggers for the groups
-- for each relation currently belonging to the group,
      FOR r_tblsq IN
         SELECT rel_kind, quote_ident(rel_schema) || '.' || quote_ident(rel_tblseq) AS full_relation_name FROM emaj.emaj_relation
           WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames) ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
        IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, enable the emaj log and truncate triggers
          EXECUTE format('ALTER TABLE %s ENABLE TRIGGER emaj_log_trg, ENABLE TRIGGER emaj_trunc_trg',
                           r_tblsq.full_relation_name);
        END IF;
        v_nbTblSeq = v_nbTblSeq + 1;
      END LOOP;
-- update the state of the group row from the emaj_group table
      UPDATE emaj.emaj_group SET group_is_logging = TRUE WHERE group_name = ANY (v_groupNames);
-- Set the first mark for each group
      PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, TRUE);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'START_GROUPS' ELSE 'START_GROUP' END, 'END', array_to_string(v_groupNames,','),
              v_nbTblSeq || ' tables/sequences processed');
--
    RETURN v_nbTblSeq;
  END;
$_start_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_stop_group(v_groupName TEXT, v_mark TEXT DEFAULT 'STOP_%')
RETURNS INT LANGUAGE plpgsql AS
$emaj_stop_group$
-- This function de-activates the log triggers of all the tables for a group.
-- Execute several emaj_stop_group functions for the same group doesn't produce any error.
-- Input: group name
--        name of the mark to set (if omitted, STOP_<current timestamp>)
--          '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--          if omitted or if null or '', the mark is set to 'STOP_%', % representing the current timestamp
-- Output: number of processed tables and sequences
  BEGIN
    RETURN emaj._stop_groups(array[v_groupName], v_mark, FALSE, FALSE);
  END;
$emaj_stop_group$;
COMMENT ON FUNCTION emaj.emaj_stop_group(TEXT,TEXT) IS
$$Stops an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_stop_groups(v_groupNames TEXT[], v_mark TEXT DEFAULT 'STOP_%')
RETURNS INT LANGUAGE plpgsql AS
$emaj_stop_groups$
-- This function de-activates the log triggers of all the tables for a groups array.
-- Groups already not in LOGGING state are simply not processed.
-- Input: array of group names, stop mark name to set (by default, STOP_<current timestamp>)
-- Output: number of processed tables and sequences
  BEGIN
    RETURN emaj._stop_groups(v_groupNames, v_mark, TRUE, FALSE);
  END;
$emaj_stop_groups$;
COMMENT ON FUNCTION emaj.emaj_stop_groups(TEXT[], TEXT) IS
$$Stops several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_force_stop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_force_stop_group$
-- This function forces a tables group stop.
-- The differences with the standart emaj_stop_group() function are:
--   - it silently ignores errors when an application table or one of its triggers is missing,
--   - no stop mark is set (to avoid error)
-- Input: group name
-- Output: number of processed tables and sequences
  BEGIN
    RETURN emaj._stop_groups(array[v_groupName], NULL, FALSE, TRUE);
  END;
$emaj_force_stop_group$;
COMMENT ON FUNCTION emaj.emaj_force_stop_group(TEXT) IS
$$Forces an E-Maj group stop.$$;

CREATE OR REPLACE FUNCTION emaj._stop_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_isForced BOOLEAN)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_stop_groups$
-- This function effectively de-activates the log triggers of all the tables for a group.
-- Input: array of group names, a mark name to set, and a boolean indicating if the function is called by a multi group function
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables and
-- sequences.
  DECLARE
    v_groupList              TEXT;
    v_count                  INT;
    v_nbTblSeq               INT = 0;
    v_markName               TEXT;
    v_fullTableName          TEXT;
    r_schema                 RECORD;
    r_tblsq                  RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES (CASE WHEN v_multiGroup THEN 'STOP_GROUPS'
                   WHEN NOT v_multiGroup AND NOT v_isForced THEN 'STOP_GROUP'
                   ELSE 'FORCE_STOP_GROUP' END,
              'BEGIN', array_to_string(v_groupNames,','));
-- check the group names
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := TRUE, v_checkList := '')
      INTO v_groupNames;
-- for all groups already IDLE, generate a warning message and remove them from the list of the groups to process
    SELECT string_agg(group_name,', ' ORDER BY group_name), count(*) INTO v_groupList, v_count FROM emaj.emaj_group
      WHERE group_name = ANY(v_groupNames) AND NOT group_is_logging;
    IF v_count = 1 THEN
      RAISE WARNING '_stop_groups: The group "%" is already in IDLE state.', v_groupList;
    END IF;
    IF v_count > 1 THEN
      RAISE WARNING '_stop_groups: The groups "%" are already in IDLE state.', v_groupList;
    END IF;
    SELECT array_agg(DISTINCT group_name) INTO v_groupNames FROM emaj.emaj_group
      WHERE group_name = ANY(v_groupNames) AND group_is_logging;
-- process the LOGGING groups
    IF v_groupNames IS NOT NULL THEN
-- check and process the supplied mark name (except if the function is called by emaj_force_stop_group())
      IF v_mark IS NULL OR v_mark = '' THEN
        v_mark = 'STOP_%';
      END IF;
      IF NOT v_isForced THEN
        SELECT emaj._check_new_mark(v_groupNames, v_mark) INTO v_markName;
      END IF;
-- OK (no error detected and at least one group in logging state)
-- lock all tables to get a stable point
--   one sets the locks at the beginning of the operation (rather than let the ALTER TABLE statements set their own locks) to decrease the
--   risk of deadlock.
      PERFORM emaj._lock_groups(v_groupNames,'SHARE ROW EXCLUSIVE',v_multiGroup);
-- verify that all application schemas for the groups still exists
      FOR r_schema IN
          SELECT DISTINCT rel_schema FROM emaj.emaj_relation
            WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames)
              AND NOT EXISTS (SELECT nspname FROM pg_catalog.pg_namespace WHERE nspname = rel_schema)
            ORDER BY rel_schema
      LOOP
        IF v_isForced THEN
          RAISE WARNING '_stop_groups: The schema "%" does not exist any more.', r_schema.rel_schema;
        ELSE
          RAISE EXCEPTION '_stop_groups: The schema "%" does not exist any more.', r_schema.rel_schema;
        END IF;
      END LOOP;
-- for each relation currently belonging to the groups to process,
      FOR r_tblsq IN
          SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
            WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames)
            ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
        IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, check the table still exists
          PERFORM 1 FROM pg_catalog.pg_namespace, pg_catalog.pg_class
            WHERE  relnamespace = pg_namespace.oid AND nspname = r_tblsq.rel_schema AND relname = r_tblsq.rel_tblseq;
          IF NOT FOUND THEN
            IF v_isForced THEN
              RAISE WARNING '_stop_groups: The table "%.%" does not exist any more.', r_tblsq.rel_schema, r_tblsq.rel_tblseq;
            ELSE
              RAISE EXCEPTION '_stop_groups: The table "%.%" does not exist any more.', r_tblsq.rel_schema, r_tblsq.rel_tblseq;
            END IF;
          ELSE
-- ... and disable the emaj log and truncate triggers
--     errors are captured so that emaj_force_stop_group() can be silently executed
            v_fullTableName  = quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
            BEGIN
              EXECUTE format('ALTER TABLE %s DISABLE TRIGGER emaj_log_trg',
                             v_fullTableName);
            EXCEPTION
              WHEN undefined_object THEN
                IF v_isForced THEN
                  RAISE WARNING '_stop_groups: The log trigger "emaj_log_trg" on table "%.%" does not exist any more.',
                    r_tblsq.rel_schema, r_tblsq.rel_tblseq;
                ELSE
                  RAISE EXCEPTION '_stop_groups: The log trigger "emaj_log_trg" on table "%.%" does not exist any more.',
                    r_tblsq.rel_schema, r_tblsq.rel_tblseq;
                END IF;
            END;
            BEGIN
              EXECUTE format('ALTER TABLE %s DISABLE TRIGGER emaj_trunc_trg',
                             v_fullTableName);
            EXCEPTION
              WHEN undefined_object THEN
                IF v_isForced THEN
                  RAISE WARNING '_stop_groups: The truncate trigger "emaj_trunc_trg" on table "%.%" does not exist any more.',
                    r_tblsq.rel_schema, r_tblsq.rel_tblseq;
                ELSE
                  RAISE EXCEPTION '_stop_groups: The truncate trigger "emaj_trunc_trg" on table "%.%" does not exist any more.',
                    r_tblsq.rel_schema, r_tblsq.rel_tblseq;
                END IF;
            END;
          END IF;
        END IF;
        v_nbTblSeq = v_nbTblSeq + 1;
      END LOOP;
      IF NOT v_isForced THEN
-- if the function is not called by emaj_force_stop_group(), set the stop mark for each group
        PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, TRUE);
-- and set the number of log rows to 0 for these marks
        UPDATE emaj.emaj_mark m SET mark_log_rows_before_next = 0
          WHERE mark_group = ANY (v_groupNames)
            AND (mark_group, mark_time_id) IN                        -- select only last mark of each concerned group
                (SELECT mark_group, max(mark_time_id) FROM emaj.emaj_mark
                 WHERE mark_group = ANY (v_groupNames) AND NOT mark_is_deleted GROUP BY mark_group);
      END IF;
-- set all marks for the groups from the emaj_mark table as 'DELETED' to avoid any further rollback and remove protection if any
      UPDATE emaj.emaj_mark SET mark_is_deleted = TRUE, mark_is_rlbk_protected = FALSE
        WHERE mark_group = ANY (v_groupNames) AND NOT mark_is_deleted;
-- update the state of the groups rows from the emaj_group table (the rollback protection of rollbackable groups is reset)
      UPDATE emaj.emaj_group SET group_is_logging = FALSE, group_is_rlbk_protected = NOT group_is_rollbackable
        WHERE group_name = ANY (v_groupNames);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'STOP_GROUPS'
                   WHEN NOT v_multiGroup AND NOT v_isForced THEN 'STOP_GROUP'
                   ELSE 'FORCE_STOP_GROUP' END,
              'END', array_to_string(v_groupNames,','), v_nbTblSeq || ' tables/sequences processed');
--
    RETURN v_nbTblSeq;
  END;
$_stop_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_protect_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_protect_group$
-- This function sets a protection on a group against accidental rollback.
-- However this doesn't block rollback simulations performed with the emaj_estimate_rollback_group() function.
-- Input: group name
-- Output: 1 if successful, 0 if the group was already in protected state
  DECLARE
    v_status                 INT;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                    v_checkList := 'LOGGING,ROLLBACKABLE');
-- OK, set the protection
    UPDATE emaj.emaj_group SET group_is_rlbk_protected = TRUE WHERE group_name = v_groupName AND NOT group_is_rlbk_protected;
    GET DIAGNOSTICS v_status = ROW_COUNT;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('PROTECT_GROUP', v_groupName, 'Status ' || v_status);
    RETURN v_status;
  END;
$emaj_protect_group$;
COMMENT ON FUNCTION emaj.emaj_protect_group(TEXT) IS
$$Sets a protection against a rollback on an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_unprotect_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_unprotect_group$
-- This function unsets a protection on a group against accidental rollback.
-- Input: group name
-- Output: 1 if successful, 0 if the group was not already in protected state
  DECLARE
    v_status                 INT;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                    v_checkList := 'ROLLBACKABLE');
-- OK, unset the protection
    UPDATE emaj.emaj_group SET group_is_rlbk_protected = FALSE WHERE group_name = v_groupName AND group_is_rlbk_protected;
    GET DIAGNOSTICS v_status = ROW_COUNT;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('UNPROTECT_GROUP', v_groupName, 'Status ' || v_status);
    RETURN v_status;
  END;
$emaj_unprotect_group$;
COMMENT ON FUNCTION emaj.emaj_unprotect_group(TEXT) IS
$$Unsets a protection against a rollback on an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_set_mark_group(v_groupName TEXT, v_mark TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS
$emaj_set_mark_group$
-- This function inserts a mark in the emaj_mark table and takes an image of the sequences definitions for the group.
-- Input: group name, mark to set
--        '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--        if omitted or if null or '', the mark is set to 'MARK_%', % representing the current timestamp
-- Output: number of processed tables and sequences
  DECLARE
    v_markName               TEXT;
    v_nbTb                   INT;
  BEGIN
-- insert begin into the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUP', 'BEGIN', v_groupName, v_markName);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                    v_checkList := 'LOGGING');
-- check if the emaj group is OK
    PERFORM 0 FROM emaj._verify_groups(array[v_groupName], TRUE);
-- check and process the supplied mark name
    SELECT emaj._check_new_mark(array[v_groupName], v_mark) INTO v_markName;
-- OK, lock all tables to get a stable point ...
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
-- vacuum operation.
    PERFORM emaj._lock_groups(array[v_groupName],'ROW EXCLUSIVE',FALSE);
-- Effectively set the mark using the internal _set_mark_groups() function
    SELECT emaj._set_mark_groups(array[v_groupName], v_markName, FALSE, FALSE) INTO v_nbTb;
-- insert end into the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUP', 'END', v_groupName, v_markName);
--
    RETURN v_nbTb;
  END;
$emaj_set_mark_group$;
COMMENT ON FUNCTION emaj.emaj_set_mark_group(TEXT,TEXT) IS
$$Sets a mark on an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_set_mark_groups(v_groupNames TEXT[], v_mark TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS
$emaj_set_mark_groups$
-- This function inserts a mark in the emaj_mark table and takes an image of the sequences definitions for several groups at a time.
-- Input: array of group names, mark to set
--        '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--        if omitted or if null or '', the mark is set to 'MARK_%', % representing the current timestamp
-- Output: number of processed tables and sequences
  DECLARE
    v_markName               TEXT;
    v_nbTblseq               INT = 0;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUPS', 'BEGIN', array_to_string(v_groupNames,','), v_mark);
-- check the group names
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := TRUE, v_lockGroups := TRUE, v_checkList := 'LOGGING')
      INTO v_groupNames;
-- process the groups
    IF v_groupNames IS NOT NULL THEN
-- check that no group is damaged
      PERFORM 0 FROM emaj._verify_groups(v_groupNames, TRUE);
-- check and process the supplied mark name
      SELECT emaj._check_new_mark(v_groupNames, v_mark) INTO v_markName;
-- OK, lock all tables to get a stable point ...
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or
-- vacuum operation.
      PERFORM emaj._lock_groups(v_groupNames,'ROW EXCLUSIVE',TRUE);
-- Effectively set the mark using the internal _set_mark_groups() function
      SELECT emaj._set_mark_groups(v_groupNames, v_markName, TRUE, FALSE) INTO v_nbTblseq;
    END IF;
-- insert end into the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUPS', 'END', array_to_string(v_groupNames,','), v_mark);
--
    RETURN v_nbTblseq;
  END;
$emaj_set_mark_groups$;
COMMENT ON FUNCTION emaj.emaj_set_mark_groups(TEXT[],TEXT) IS
$$Sets a mark on several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj._set_mark_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_eventToRecord BOOLEAN,
                                                 v_loggedRlbkTargetMark TEXT DEFAULT NULL, v_timeId BIGINT DEFAULT NULL,
                                                 v_dblinkSchema TEXT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS
$_set_mark_groups$
-- This function effectively inserts a mark in the emaj_mark table and takes an image of the sequences definitions for the array of groups.
-- It also updates the previous mark of each group to setup the mark_log_rows_before_next column with the number of rows recorded into all
-- log tables between this previous mark and the new mark.
-- It is called by emaj_set_mark_group and emaj_set_mark_groups functions but also by other functions that set internal marks, like
-- functions that start or rollback groups.
-- Input: group names array, mark to set,
--        boolean indicating whether the function is called by a multi group function
--        boolean indicating whether the event has to be recorded into the emaj_hist table
--        name of the rollback target mark when this mark is created by the logged_rollback functions (NULL by default)
--        time stamp identifier to reuse (NULL by default) (this parameter is set when the mark is a rollback start mark)
--        dblink schema when the mark is set by a rollback operation and dblink connection are used (NULL by default)
-- Output: number of processed tables and sequences
-- The insertion of the corresponding event in the emaj_hist table is performed by callers.
  DECLARE
    v_nbTbl                  INT;
    v_nbSeq                  INT;
    v_stmt                   TEXT;
  BEGIN
-- if requested, record the set mark begin in emaj_hist
    IF v_eventToRecord THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES (CASE WHEN v_multiGroup THEN 'SET_MARK_GROUPS'
                     ELSE 'SET_MARK_GROUP' END, 'BEGIN', array_to_string(v_groupNames,','), v_mark);
    END IF;
-- get the time stamp of the operation, if not supplied as input parameter
    IF v_timeId IS NULL THEN
      SELECT emaj._set_time_stamp('M') INTO v_timeId;
    END IF;
-- record sequences state as early as possible (no lock protects them from other transactions activity)
--   the join on pg_namespace and pg_class filters the potentially dropped application sequences
    WITH seq AS (                        -- selected sequences
      SELECT rel_schema, rel_tblseq
        FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relname = rel_tblseq AND nspname = rel_schema AND relnamespace = pg_namespace.oid
          AND upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames) AND rel_kind = 'S'
      )
    INSERT INTO emaj.emaj_sequence (sequ_schema, sequ_name, sequ_time_id, sequ_last_val, sequ_start_val,
                sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called)
      SELECT t.*
        FROM seq,
             LATERAL emaj._get_current_sequence_state(rel_schema, rel_tblseq, v_timeId) AS t;
    GET DIAGNOSTICS v_nbSeq = ROW_COUNT;
-- record the number of log rows for the old last mark of each group
--   the statement updates no row in case of emaj_start_group(s)
    WITH stat_group1 AS (                             -- for each group, time id of the last active mark
      SELECT mark_group, max(mark_time_id) AS last_mark_time_id
        FROM emaj.emaj_mark
        WHERE NOT mark_is_deleted
        GROUP BY mark_group),
         stat_group2 AS (                             -- compute the number of log rows for all tables currently belonging to these groups
      SELECT mark_group, last_mark_time_id, coalesce(
          (SELECT sum(emaj._log_stat_tbl(emaj_relation, greatest(last_mark_time_id, lower(rel_time_range)),NULL))
             FROM emaj.emaj_relation
             WHERE rel_group = mark_group AND rel_kind = 'r' AND upper_inf(rel_time_range)), 0) AS mark_stat
        FROM stat_group1 )
    UPDATE emaj.emaj_mark m SET mark_log_rows_before_next = mark_stat
      FROM stat_group2 s
      WHERE s.mark_group = m.mark_group AND s.last_mark_time_id = m.mark_time_id;
-- for tables currently belonging to the groups, record the associated log sequence state into the emaj sequence table
    INSERT INTO emaj.emaj_sequence (sequ_schema, sequ_name, sequ_time_id, sequ_last_val, sequ_start_val,
                sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called)
      SELECT seq.* FROM emaj.emaj_relation, LATERAL emaj._get_current_sequence_state(rel_log_schema, rel_log_sequence, v_timeId) AS seq
        WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames) AND rel_kind = 'r';
    GET DIAGNOSTICS v_nbTbl = ROW_COUNT;
-- record the mark for each group into the emaj_mark table
    INSERT INTO emaj.emaj_mark (mark_group, mark_name, mark_time_id, mark_is_deleted, mark_is_rlbk_protected, mark_logged_rlbk_target_mark)
      SELECT group_name, v_mark, v_timeId, FALSE, FALSE, v_loggedRlbkTargetMark
        FROM emaj.emaj_group WHERE group_name = ANY(v_groupNames) ORDER BY group_name;
-- before exiting, cleanup the state of the pending rollback events from the emaj_rlbk table
-- it uses a dblink connection when the mark to set comes from a rollback operation that uses dblink connections
    v_stmt = 'SELECT emaj._cleanup_rollback_state()';
    PERFORM emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema);
-- if requested, record the set mark end in emaj_hist
    IF v_eventToRecord THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES (CASE WHEN v_multiGroup THEN 'SET_MARK_GROUPS' ELSE 'SET_MARK_GROUP' END, 'END', array_to_string(v_groupNames,','), v_mark);
    END IF;
--
    RETURN v_nbSeq + v_nbTbl;
  END;
$_set_mark_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_comment_mark_group(v_groupName TEXT, v_mark TEXT, v_comment TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$emaj_comment_mark_group$
-- This function sets or modifies a comment on a mark by updating the mark_comment of the emaj_mark table.
-- Input: group name, mark to comment, comment
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to delete to specify the last set mark.
--   To reset an existing comment for a mark, the supplied comment can be NULL.
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := '') INTO v_mark;
-- OK, update the mark_comment from emaj_mark table
    UPDATE emaj.emaj_mark SET mark_comment = v_comment WHERE mark_group = v_groupName AND mark_name = v_mark;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('COMMENT_MARK_GROUP', v_groupName, 'Mark ' || v_mark);
    RETURN;
  END;
$emaj_comment_mark_group$;
COMMENT ON FUNCTION emaj.emaj_comment_mark_group(TEXT,TEXT,TEXT) IS
$$Sets a comment on a mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_datetime TIMESTAMPTZ)
RETURNS TEXT LANGUAGE plpgsql AS
$emaj_get_previous_mark_group$
-- This function returns the name of the mark that immediately precedes a given date and time.
-- It may return unpredictable result in case of system date or time change.
-- The function can be called by both emaj_adm and emaj_viewer roles.
-- Input: group name, date and time
-- Output: mark name, or NULL if there is no mark before the given date and time
  DECLARE
    v_markName               TEXT;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := FALSE, v_checkList := '');
-- find the requested mark
    SELECT mark_name INTO v_markName FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupName AND time_clock_timestamp < v_datetime
      ORDER BY time_clock_timestamp DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN NULL;
    ELSE
      RETURN v_markName;
    END IF;
  END;
$emaj_get_previous_mark_group$;
COMMENT ON FUNCTION emaj.emaj_get_previous_mark_group(TEXT,TIMESTAMPTZ) IS
$$Returns the latest mark name preceeding a point in time.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS TEXT LANGUAGE plpgsql AS
$emaj_get_previous_mark_group$
-- This function returns the name of the mark that immediately precedes a given mark for a group.
-- The function can be called by both emaj_adm and emaj_viewer roles.
-- Input: group name, mark name
--   The keyword 'EMAJ_LAST_MARK' can be used to specify the last set mark.
-- Output: mark name, or NULL if there is no mark before the given mark
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := FALSE, v_checkList := '');
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := '') INTO v_mark;
-- find the requested mark
    RETURN emaj._get_previous_mark_group(v_groupName, v_mark);
  END;
$emaj_get_previous_mark_group$;
COMMENT ON FUNCTION emaj.emaj_get_previous_mark_group(TEXT,TEXT) IS
$$Returns the latest mark name preceeding a given mark for a group.$$;

CREATE OR REPLACE FUNCTION emaj._get_previous_mark_group(v_groupName TEXT, v_realMark TEXT)
RETURNS TEXT LANGUAGE plpgsql AS
$_get_previous_mark_group$
-- This function returns the name of the mark that immediately precedes a given mark for a group.
-- The function can be called by both emaj_adm and emaj_viewer roles.
-- Input: group name, mark name
--   The mark name has already been checked and resolved if the keyword 'EMAJ_LAST_MARK' has been used by the user.
-- Output: mark name, or NULL if there is no mark before the given mark
  DECLARE
    v_markName               TEXT;
  BEGIN
-- find the requested mark
    SELECT mark_name INTO v_markName FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_time_id <
        (SELECT mark_time_id FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark)
      ORDER BY mark_time_id DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN NULL;
    ELSE
      RETURN v_markName;
    END IF;
  END;
$_get_previous_mark_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_delete_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_delete_mark_group$
-- This function deletes all traces from a previous set_mark_group(s) function.
-- Then, any rollback on the deleted mark will not be possible.
-- It deletes rows corresponding to the mark to delete from emaj_mark and emaj_sequence.
-- If this mark is the first mark, it also deletes rows from all concerned log tables and holes from emaj_seq_hole.
-- The statistical mark_log_rows_before_next column's content of the previous mark is also maintained.
-- At least one mark must remain after the operation (otherwise it is not worth having a group in LOGGING state !).
-- Input: group name, mark to delete
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to delete to specify the last set mark.
-- Output: number of deleted marks, i.e. 1
  DECLARE
    v_markTimeId             BIGINT;
    v_previousMarkTimeId     BIGINT;
    v_previousMarkName       TEXT;
    v_previousMarkGlobalSeq  BIGINT;
    v_nextMarkTimeId         BIGINT;
    v_nextMarkName           TEXT;
    v_nextMarkGlobalSeq      BIGINT;
    v_timeIdNewMin           BIGINT;
    v_markNewMin             TEXT;
    v_count                  INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DELETE_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := '') INTO v_mark;
-- count the number of marks in the group
    SELECT count(*) INTO v_count FROM emaj.emaj_mark WHERE mark_group = v_groupName;
-- and check there are at least 2 marks for the group
    IF v_count < 2 THEN
      RAISE EXCEPTION 'emaj_delete_mark_group: "%" is the only mark of the group. It cannot be deleted.', v_mark;
    END IF;
-- OK, now get the time stamp id of the mark to delete
    SELECT mark_time_id INTO v_markTimeId
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_mark;
-- ... and the timestamp of the future first mark
    SELECT mark_time_id, mark_name INTO v_timeIdNewMin, v_markNewMin
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name <> v_mark ORDER BY mark_time_id LIMIT 1;
-- ... and the name, the time id and the last global sequence value of the previous mark
    SELECT emaj._get_previous_mark_group(v_groupName, v_mark) INTO v_previousMarkName;
    SELECT mark_time_id, time_last_emaj_gid INTO v_previousMarkTimeId, v_previousMarkGlobalSeq
      FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupName AND mark_name = v_previousMarkName;
-- ... and the name, the time id and the last global sequence value of the next mark
    SELECT mark_name INTO v_nextMarkName FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_time_id >
        (SELECT mark_time_id FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_mark)
      ORDER BY mark_time_id ASC LIMIT 1;
    SELECT mark_time_id, time_last_emaj_gid INTO v_nextMarkTimeId, v_nextMarkGlobalSeq
      FROM emaj.emaj_mark, emaj.emaj_time_stamp WHERE mark_time_id = time_id AND mark_group = v_groupName AND mark_name = v_nextMarkName;
-- effectively delete the mark for the group
    IF v_previousMarkTimeId IS NULL THEN
-- if the mark to delete is the first one, process its deletion with _delete_before_mark_group(), as the first rows of log tables become
-- useless
      PERFORM emaj._delete_before_mark_group(v_groupName, v_markNewMin);
    ELSE
-- otherwise, the mark to delete is an intermediate mark for the group
-- process the mark deletion with _delete_intermediate_mark_group()
      PERFORM emaj._delete_intermediate_mark_group(v_groupName, v_mark, v_markTimeId);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DELETE_MARK_GROUP', 'END', v_groupName, v_mark);
    RETURN 1;
  END;
$emaj_delete_mark_group$;
COMMENT ON FUNCTION emaj.emaj_delete_mark_group(TEXT,TEXT) IS
$$Deletes a mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_delete_before_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
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
    v_nbMark                 INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DELETE_BEFORE_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- return NULL if mark name is NULL
    IF v_mark IS NULL THEN
      RETURN NULL;
    END IF;
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := '') INTO v_mark;
-- effectively delete all marks before the supplied mark
    SELECT emaj._delete_before_mark_group(v_groupName, v_mark) INTO v_nbMark;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DELETE_BEFORE_MARK_GROUP', 'END', v_groupName,  v_nbMark || ' marks deleted ; ' || v_mark || ' is now the initial mark' );
    RETURN v_nbMark;
  END;
$emaj_delete_before_mark_group$;
COMMENT ON FUNCTION emaj.emaj_delete_before_mark_group(TEXT,TEXT) IS
$$Deletes all marks preceeding a given mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj._delete_before_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_delete_before_mark_group$
-- This function deletes all logs and marks set before a given mark.
-- The function is called by the emaj_delete_before_mark_group(), emaj_delete_mark_group() functions.
-- It deletes rows corresponding to the marks to delete from emaj_mark and emaj_sequence.
-- It deletes rows from emaj_relation corresponding to old versions that become unreacheable.
-- It deletes rows from all concerned log tables.
-- To complete, the function deletes oldest rows from emaj_hist.
-- Input: group name, name of the new first mark.
-- Output: number of deleted marks, number of tables effectively processed (for which at least one log row has been deleted)
  DECLARE
    v_eventTriggers          TEXT[];
    v_markGlobalSeq          BIGINT;
    v_markTimeId             BIGINT;
    v_nbMark                 INT;
    r_rel                    RECORD;
  BEGIN
-- disable event triggers that protect emaj components and keep in memory these triggers name
    SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- retrieve the timestamp and the emaj_gid value and the time stamp id of the target new first mark
    SELECT time_last_emaj_gid, mark_time_id INTO v_markGlobalSeq, v_markTimeId
      FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupName AND mark_name = v_mark;
--
-- first process all obsolete time ranges for the group
--
-- drop obsolete old log tables
    FOR r_rel IN
          -- log tables for the group, whose end time stamp is older than the new first mark time stamp
          SELECT DISTINCT rel_log_schema, rel_log_table FROM emaj.emaj_relation
            WHERE rel_kind = 'r' AND rel_group = v_groupName AND upper(rel_time_range) <= v_markTimeId
        EXCEPT
          -- unless they are also used for more recent time range, or are also linked to other groups
          SELECT rel_log_schema, rel_log_table FROM emaj.emaj_relation
            WHERE rel_kind = 'r'
              AND (upper(rel_time_range) > v_markTimeId OR upper_inf(rel_time_range) OR rel_group <> v_groupName)
          ORDER BY 1,2
    LOOP
      EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE',
                     r_rel.rel_log_schema, r_rel.rel_log_table);
    END LOOP;
-- delete emaj_sequence rows corresponding to obsolete relation time range that will be deleted just later
-- (the related emaj_seq_hole rows will be deleted just later ; they are not directly linked to an emaj_relation row)
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation r1
      WHERE rel_group = v_groupName AND rel_kind = 'r'
        AND sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND upper(rel_time_range) <= v_markTimeId
        AND (sequ_time_id < v_markTimeId                  -- all sequences prior the mark time
          OR (sequ_time_id = v_markTimeId                 -- and the sequence of the mark time
              AND NOT EXISTS (                            --   if it is not the lower bound of an adjacent time range
                SELECT 1 FROM emaj.emaj_relation r2
                  WHERE r2.rel_schema = r1.rel_log_schema AND r2.rel_tblseq = r1.rel_log_sequence
                    AND lower(r2.rel_time_range) = v_marktimeid)));
-- keep a trace of the relation group ownership history
--   and finaly delete from the emaj_relation table the relation that ended before the new first mark
    WITH deleted AS (
      DELETE FROM emaj.emaj_relation
        WHERE rel_group = v_groupName AND upper(rel_time_range) <= v_markTimeId
        RETURNING rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind
      )
    INSERT INTO emaj.emaj_rel_hist
             (relh_schema, relh_tblseq, relh_time_range, relh_group, relh_kind)
      SELECT rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind
        FROM deleted;
-- drop the E-Maj log schemas that are now useless (i.e. not used by any created group)
    PERFORM emaj._drop_log_schemas('DELETE_BEFORE_MARK_GROUP', FALSE);
--
-- then process the current relation time range for the group
--
-- delete rows from all log tables
    FOR r_rel IN
        SELECT quote_ident(rel_log_schema) || '.' || quote_ident(rel_log_table) AS log_table_name FROM emaj.emaj_relation
          WHERE rel_group = v_groupName AND rel_kind = 'r'
            AND (upper_inf(rel_time_range) OR upper(rel_time_range) > v_markTimeId)
          ORDER BY rel_priority, rel_schema, rel_tblseq
    LOOP
-- delete log rows prior to the new first mark
      EXECUTE format('DELETE FROM %s WHERE emaj_gid <= $1',
                     r_rel.log_table_name)
        USING v_markGlobalSeq;
    END LOOP;
-- process emaj_seq_hole content
-- delete all existing holes, if any, before the mark
-- (it may delete holes for timeranges that do not belong to the group, if a table has been moved to another group,
--  but is safe enough for rollbacks)
    DELETE FROM emaj.emaj_seq_hole USING emaj.emaj_relation
      WHERE rel_group = v_groupName AND rel_kind = 'r'
        AND rel_schema = sqhl_schema AND rel_tblseq = sqhl_table
        AND sqhl_begin_time_id < v_markTimeId;
-- now the sequences related to the mark to delete can be suppressed
--   delete first application sequences related data for the group
--   the sequence state at time range bounds are kept (if the mark comes from a logging group alter operation)
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_schema AND sequ_name = rel_tblseq AND rel_time_range @> sequ_time_id
        AND rel_group = v_groupName AND rel_kind = 'S'
        AND sequ_time_id < v_markTimeId
        AND lower(rel_time_range) <> sequ_time_id;
--   delete then emaj sequences related data for the group
--   the sequence state at time range bounds are kept
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND rel_time_range @> sequ_time_id
        AND rel_group = v_groupName AND rel_kind = 'r'
        AND sequ_time_id < v_markTimeId
        AND lower(rel_time_range) <> sequ_time_id;
--    and that may have one of the deleted marks as target mark from a previous logged rollback operation
    UPDATE emaj.emaj_mark SET mark_logged_rlbk_target_mark = NULL
      WHERE mark_group = v_groupName AND mark_time_id >= v_markTimeId
        AND mark_logged_rlbk_target_mark IN (
            SELECT mark_name FROM emaj.emaj_mark
              WHERE mark_group = v_groupName AND mark_time_id < v_markTimeId
            );
-- delete oldest marks
    DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_time_id < v_markTimeId;
    GET DIAGNOSTICS v_nbMark = ROW_COUNT;
-- enable previously disabled event triggers
    PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- purge the emaj history, if needed (even if no mark as been really dropped)
    PERFORM emaj._purge_hist();
    RETURN v_nbMark;
  END;
$_delete_before_mark_group$;

CREATE OR REPLACE FUNCTION emaj._delete_intermediate_mark_group(v_groupName TEXT, v_markName TEXT, v_markTimeId BIGINT)
RETURNS VOID LANGUAGE plpgsql AS
$_delete_intermediate_mark_group$
-- This function effectively deletes an intermediate mark for a group.
-- It is called by the emaj_delete_mark_group() function.
-- It deletes rows corresponding to the mark to delete from emaj_mark and emaj_sequence.
-- The statistical mark_log_rows_before_next column's content of the previous mark is also maintained.
-- Input: group name, mark name, mark id and mark time stamp id of the mark to delete
  DECLARE
    v_previousMark           TEXT;
    v_nextMark               TEXT;
    v_previousMarkTimeId     BIGINT;
    v_nextMarkTimeId         BIGINT;
  BEGIN
-- delete the sequences related to the mark to delete
--   delete first data related to the application sequences (those attached to the group at the set mark time, but excluding the time
--   range bounds)
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_schema AND sequ_name = rel_tblseq AND rel_time_range @> sequ_time_id
        AND rel_group = v_groupName AND rel_kind = 'S'
        AND sequ_time_id = v_markTimeId
        AND lower(rel_time_range) <> sequ_time_id;
--   delete then data related to the log sequences for tables (those attached to the group at the set mark time, but excluding the time
--   range bounds)
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND rel_time_range @> sequ_time_id
        AND rel_group = v_groupName AND rel_kind = 'r'
        AND sequ_time_id = v_markTimeId
        AND lower(rel_time_range) <> sequ_time_id;
-- physically delete the mark from emaj_mark
    DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_markName;
-- adjust the mark_log_rows_before_next column of the previous mark
-- get the name of the mark immediately preceeding the mark to delete
    SELECT mark_name, mark_time_id INTO v_previousMark, v_previousMarkTimeId FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_time_id < v_markTimeId ORDER BY mark_time_id DESC LIMIT 1;
-- get the name of the first mark succeeding the mark to delete
    SELECT mark_name, mark_time_id INTO v_nextMark, v_nextMarkTimeId FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_time_id > v_markTimeId ORDER BY mark_time_id LIMIT 1;
    IF NOT FOUND THEN
-- no next mark, so update the previous mark with NULL
      UPDATE emaj.emaj_mark SET mark_log_rows_before_next = NULL
        WHERE mark_group = v_groupName AND mark_name = v_previousMark;
    ELSE
-- update the previous mark by computing the sum of _log_stat_tbl() call's result
--   for all relations that belonged to the group at the time when the mark before the deleted mark had been set
      UPDATE emaj.emaj_mark SET mark_log_rows_before_next =
          (SELECT sum(emaj._log_stat_tbl(emaj_relation, v_previousMarkTimeId, v_nextMarkTimeId))
             FROM emaj.emaj_relation
             WHERE rel_group = v_groupName AND rel_kind = 'r' AND rel_time_range @> v_previousMarkTimeId)
        WHERE mark_group = v_groupName AND mark_name = v_previousMark;
    END IF;
-- reset the mark_logged_rlbk_target_mark column to null for other marks of the group
--   that may have the deleted mark as target mark from a previous logged rollback operation
    UPDATE emaj.emaj_mark SET mark_logged_rlbk_target_mark = NULL
      WHERE mark_group = v_groupName AND mark_logged_rlbk_target_mark = v_markName;
    RETURN;
  END;
$_delete_intermediate_mark_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_rename_mark_group(v_groupName TEXT, v_mark TEXT, v_newName TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$emaj_rename_mark_group$
-- This function renames an existing mark.
-- The group can be in LOGGING or not.
-- Rows from emaj_mark and emaj_sequence tables are updated accordingly.
-- Input: group name, mark to rename, new name for the mark
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to rename to specify the last set mark.
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('RENAME_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := '') INTO v_mark;
-- check the new mark name
    SELECT emaj._check_new_mark(ARRAY[v_groupName], v_newName) INTO v_newName;
-- OK, update the emaj_mark table
    UPDATE emaj.emaj_mark SET mark_name = v_newName
      WHERE mark_group = v_groupName AND mark_name = v_mark;
-- also rename mark names recorded in the mark_logged_rlbk_target_mark column if needed
    UPDATE emaj.emaj_mark SET mark_logged_rlbk_target_mark = v_newName
      WHERE mark_group = v_groupName AND mark_logged_rlbk_target_mark = v_mark;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('RENAME_MARK_GROUP', 'END', v_groupName, v_mark || ' renamed ' || v_newName);
    RETURN;
  END;
$emaj_rename_mark_group$;
COMMENT ON FUNCTION emaj.emaj_rename_mark_group(TEXT,TEXT,TEXT) IS
$$Renames a mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_protect_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_protect_mark_group$
-- This function sets a protection on a mark for a group against accidental rollback.
-- However this doesn't block rollback simulations performed with the emaj_estimate_rollback_group() function.
-- Input: group name, mark to protect
-- Output: 1 if successful, 0 if the mark was already in protected state
-- The group must be ROLLBACKABLE and in LOGGING state.
  DECLARE
    v_status                 INT;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                    v_checkList := 'ROLLBACKABLE');
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := 'ACTIVE') INTO v_mark;
-- OK, set the protection, if not already set, and return 1, or 0 if the mark was already protected
    UPDATE emaj.emaj_mark SET mark_is_rlbk_protected = TRUE
      WHERE mark_group = v_groupName AND mark_name = v_mark AND NOT mark_is_rlbk_protected;
    GET DIAGNOSTICS v_status = ROW_COUNT;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('PROTECT_MARK_GROUP', v_groupName, 'Mark ' || v_mark || ' ; status ' || v_status);
    RETURN v_status;
  END;
$emaj_protect_mark_group$;
COMMENT ON FUNCTION emaj.emaj_protect_mark_group(TEXT,TEXT) IS
$$Sets a protection against a rollback on a mark of an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_unprotect_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_unprotect_mark_group$
-- This function unsets a protection on a mark for a group against accidental rollback.
-- Input: group name, mark to unprotect
-- Output: 1 if successful, 0 if the mark was already in unprotected state
-- The group must be ROLLBACKABLE and in LOGGING state.
  DECLARE
    v_status                 INT;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                    v_checkList := 'ROLLBACKABLE');
-- check the mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_mark, v_checkList := '') INTO v_mark;
-- OK, unset the protection, and return 1, or 0 if the mark was already unprotected
    UPDATE emaj.emaj_mark SET mark_is_rlbk_protected = FALSE
      WHERE mark_group = v_groupName AND mark_name = v_mark AND mark_is_rlbk_protected;
    GET DIAGNOSTICS v_status = ROW_COUNT;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('UNPROTECT_MARK_GROUP', v_groupName, 'Mark ' || v_mark || ' ; status ' || v_status);
    RETURN v_status;
  END;
$emaj_unprotect_mark_group$;
COMMENT ON FUNCTION emaj.emaj_unprotect_mark_group(TEXT,TEXT) IS
$$Unsets a protection against a rollback on a mark of an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_rollback_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_rollback_group$
-- The function rollbacks all tables and sequences of a group up to a mark in the history.
-- Input: group name, mark to rollback to
-- Output: number of processed tables and sequences
  BEGIN
-- just (unlogged) rollback the group (with boolean: isLoggedRlbk = false, multiGroup = false, v_isAlterGroupAllowed = null)
    RETURN rlbk_message::INT FROM emaj._rlbk_groups(array[v_groupName], v_mark, FALSE, FALSE, NULL) WHERE rlbk_severity = 'Notice';
  END;
$emaj_rollback_group$;
COMMENT ON FUNCTION emaj.emaj_rollback_group(TEXT,TEXT) IS
$$Rollbacks an E-Maj group to a given mark (deprecated).$$;

CREATE OR REPLACE FUNCTION emaj.emaj_rollback_groups(v_groupNames TEXT[], v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_rollback_groups$
-- The function rollbacks all tables and sequences of a group array up to a mark in the history.
-- Input: array of group names, mark to rollback to
-- Output: number of processed tables and sequences
  BEGIN
-- just (unlogged) rollback the groups (with boolean: isLoggedRlbk = false, multiGroup = true, v_isAlterGroupAllowed = null)
    RETURN rlbk_message::INT FROM emaj._rlbk_groups(v_groupNames, v_mark, FALSE, TRUE, NULL) WHERE rlbk_severity = 'Notice';
  END;
$emaj_rollback_groups$;
COMMENT ON FUNCTION emaj.emaj_rollback_groups(TEXT[],TEXT) IS
$$Rollbacks an set of E-Maj groups to a given mark (deprecated).$$;

CREATE OR REPLACE FUNCTION emaj.emaj_logged_rollback_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_logged_rollback_group$
-- The function performs a logged rollback of all tables and sequences of a group up to a mark in the history.
-- A logged rollback is a rollback which can be later rolled back! To achieve this:
-- - log triggers are not disabled at rollback time,
-- - a mark is automatically set at the beginning and at the end of the rollback operation,
-- - rolled back log rows and any marks inside the rollback time frame are kept.
-- Input: group name, mark to rollback to
-- Output: number of processed tables and sequences
  BEGIN
-- just "logged-rollback" the group (with boolean: isLoggedRlbk = true, multiGroup = false, v_isAlterGroupAllowed = null)
    RETURN rlbk_message::INT FROM emaj._rlbk_groups(array[v_groupName], v_mark, TRUE, FALSE, NULL) WHERE rlbk_severity = 'Notice';
  END;
$emaj_logged_rollback_group$;
COMMENT ON FUNCTION emaj.emaj_logged_rollback_group(TEXT,TEXT) IS
$$Performs a logged (cancellable) rollbacks of an E-Maj group to a given mark (deprecated).$$;

CREATE OR REPLACE FUNCTION emaj.emaj_logged_rollback_groups(v_groupNames TEXT[], v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_logged_rollback_groups$
-- The function performs a logged rollback of all tables and sequences of a groups array up to a mark in the history.
-- A logged rollback is a rollback which can be later rolled back! To achieve this:
-- - log triggers are not disabled at rollback time,
-- - a mark is automatically set at the beginning and at the end of the rollback operation,
-- - rolled back log rows and any marks inside the rollback time frame are kept.
-- Input: array of group names, mark to rollback to
-- Output: number of processed tables and sequences
  BEGIN
-- just "logged-rollback" the groups (with boolean: isLoggedRlbk = true, multiGroup = true, v_isAlterGroupAllowed = null)
    RETURN rlbk_message::INT FROM emaj._rlbk_groups(v_groupNames, v_mark, TRUE, TRUE, NULL) WHERE rlbk_severity = 'Notice';
  END;
$emaj_logged_rollback_groups$;
COMMENT ON FUNCTION emaj.emaj_logged_rollback_groups(TEXT[],TEXT) IS
$$Performs a logged (cancellable) rollbacks for a set of E-Maj groups to a given mark (deprecated).$$;

CREATE OR REPLACE FUNCTION emaj.emaj_rollback_group(v_groupName TEXT, v_mark TEXT, v_isAlterGroupAllowed BOOLEAN,
                                                    OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$emaj_rollback_group$
-- The function rollbacks all tables and sequences of a group up to a mark in the history.
-- Input: group name, mark to rollback to, boolean indicating whether the rollback may return to a mark set before an alter group operation
-- Output: a set of records building the execution report, with a severity level (N-otice or W-arning) and a text message
  BEGIN
-- just (unlogged) rollback the group (with boolean: isLoggedRlbk = false, multiGroup = false)
    RETURN QUERY SELECT * FROM emaj._rlbk_groups(array[v_groupName], v_mark, FALSE, FALSE, coalesce(v_isAlterGroupAllowed, FALSE));
  END;
$emaj_rollback_group$;
COMMENT ON FUNCTION emaj.emaj_rollback_group(TEXT,TEXT,BOOLEAN) IS
$$Rollbacks an E-Maj group to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_rollback_groups(v_groupNames TEXT[], v_mark TEXT, v_isAlterGroupAllowed BOOLEAN,
                                                     OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$emaj_rollback_groups$
-- The function rollbacks all tables and sequences of a group array up to a mark in the history.
-- Input: array of group names, mark to rollback to, boolean indicating whether the rollback may return to a mark set before an alter group
-- operation
-- Output: a set of records building the execution report, with a severity level (N-otice or W-arning) and a text message
  BEGIN
-- just (unlogged) rollback the groups (with boolean: isLoggedRlbk = false, multiGroup = true)
    RETURN QUERY SELECT * FROM emaj._rlbk_groups(v_groupNames, v_mark, FALSE, TRUE, coalesce(v_isAlterGroupAllowed, FALSE));
  END;
$emaj_rollback_groups$;
COMMENT ON FUNCTION emaj.emaj_rollback_groups(TEXT[],TEXT,BOOLEAN) IS
$$Rollbacks an set of E-Maj groups to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_logged_rollback_group(v_groupName TEXT, v_mark TEXT, v_isAlterGroupAllowed BOOLEAN,
                                                           OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$emaj_logged_rollback_group$
-- The function performs a logged rollback of all tables and sequences of a group up to a mark in the history.
-- A logged rollback is a rollback which can be later rolled back! To achieve this:
-- - log triggers are not disabled at rollback time,
-- - a mark is automatically set at the beginning and at the end of the rollback operation,
-- - rolled back log rows and any marks inside the rollback time frame are kept.
-- Input: group name, mark to rollback to, boolean indicating whether the rollback may return to a mark set before an alter group operation
-- Output: a set of records building the execution report, with a severity level (N-otice or W-arning) and a text message
  BEGIN
-- just "logged-rollback" the group (with boolean: isLoggedRlbk = true, multiGroup = false)
    RETURN QUERY SELECT * FROM emaj._rlbk_groups(array[v_groupName], v_mark, TRUE, FALSE, coalesce(v_isAlterGroupAllowed, FALSE));
  END;
$emaj_logged_rollback_group$;
COMMENT ON FUNCTION emaj.emaj_logged_rollback_group(TEXT,TEXT,BOOLEAN) IS
$$Performs a logged (cancellable) rollbacks of an E-Maj group to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_logged_rollback_groups(v_groupNames TEXT[], v_mark TEXT, v_isAlterGroupAllowed BOOLEAN,
                                                            OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$emaj_logged_rollback_groups$
-- The function performs a logged rollback of all tables and sequences of a groups array up to a mark in the history.
-- A logged rollback is a rollback which can be later rolled back! To achieve this:
-- - log triggers are not disabled at rollback time,
-- - a mark is automatically set at the beginning and at the end of the rollback operation,
-- - rolled back log rows and any marks inside the rollback time frame are kept.
-- Input: array of group names, mark to rollback to, boolean indicating whether the rollback may return to a mark set before an alter
--          group operation
-- Output: a set of records building the execution report, with a severity level (N-otice or W-arning) and a text message
  BEGIN
-- just "logged-rollback" the groups (with boolean: isLoggedRlbk = true, multiGroup = true)
    RETURN QUERY SELECT * FROM emaj._rlbk_groups(v_groupNames, v_mark, TRUE, TRUE, coalesce(v_isAlterGroupAllowed, FALSE));
  END;
$emaj_logged_rollback_groups$;
COMMENT ON FUNCTION emaj.emaj_logged_rollback_groups(TEXT[],TEXT,BOOLEAN) IS
$$Performs a logged (cancellable) rollbacks for a set of E-Maj groups to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups(v_groupNames TEXT[], v_mark TEXT, v_isLoggedRlbk BOOLEAN, v_multiGroup BOOLEAN,
                                             v_isAlterGroupAllowed BOOLEAN, OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$_rlbk_groups$
-- The function rollbacks all tables and sequences of a groups array up to a mark in the history.
-- It is called by emaj_rollback_group.
-- It effectively manages the rollback operation for each table or sequence, deleting rows from log tables
-- only when asked by the calling functions.
-- Its activity is split into smaller functions that are also called by the parallel restore php function.
-- Input: group name, mark to rollback to, a boolean indicating whether the rollback is a logged rollback, a boolean indicating whether
--          the function
--        is a multi_group function and a boolean saying whether the rollback may return to a mark set before an alter group operation
-- Output: a set of records building the execution report, with a severity level (N-otice or W-arning) and a text message
  DECLARE
    v_rlbkId                 INT;
  BEGIN
-- check the group names (the groups lock and the state checks are delayed for the later - needed for rollbacks generated by the web
-- application)
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := FALSE, v_checkList := '')
      INTO v_groupNames;
-- if the group names array is null, immediately return 0
    IF v_groupNames IS NULL THEN
       rlbk_severity = 'Notice'; rlbk_message = 0;
       RETURN NEXT;
      RETURN;
    END IF;
-- check supplied parameter and prepare the rollback operation
    SELECT emaj._rlbk_init(v_groupNames, v_mark, v_isLoggedRlbk, 1, v_multiGroup, v_isAlterGroupAllowed) INTO v_rlbkId;
-- lock all tables
    PERFORM emaj._rlbk_session_lock(v_rlbkId, 1);
-- set a rollback start mark if logged rollback
    PERFORM emaj._rlbk_start_mark(v_rlbkId, v_multiGroup);
-- execute the rollback planning
    PERFORM emaj._rlbk_session_exec(v_rlbkId, 1);
-- process sequences, complete the rollback operation and return the execution report
    RETURN QUERY SELECT * FROM emaj._rlbk_end(v_rlbkId, v_multiGroup);
  END;
$_rlbk_groups$;

CREATE OR REPLACE FUNCTION emaj._rlbk_async(v_rlbkId INT, v_multiGroup BOOLEAN, OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$_rlbk_async$
-- The function calls the main rollback functions following the initialisation phase.
-- It is only called by the Emaj_web client, in an asynchronous way, so that the rollback can be then monitored by the client.
-- Input: rollback identifier, and a boolean saying if the rollback is a logged rollback
-- Output: a set of records building the execution report, with a severity level (N-otice or W-arning) and a text message
  BEGIN
-- simply chain the internal functions
    PERFORM emaj._rlbk_session_lock(v_rlbkId, 1);
    PERFORM emaj._rlbk_start_mark(v_rlbkId, v_multiGroup);
    PERFORM emaj._rlbk_session_exec(v_rlbkId, 1);
    RETURN QUERY SELECT * FROM emaj._rlbk_end(v_rlbkId, v_multiGroup);
  END;
$_rlbk_async$;

CREATE OR REPLACE FUNCTION emaj._rlbk_init(v_groupNames TEXT[], v_mark TEXT, v_isLoggedRlbk BOOLEAN, v_nbSession INT, v_multiGroup BOOLEAN,
                                           v_isAlterGroupAllowed BOOLEAN DEFAULT FALSE)
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_init$
-- This is the first step of a rollback group processing.
-- It tests the environment, the supplied parameters and the foreign key constraints.
-- By calling the _rlbk_planning() function, it defines the different elementary steps needed for the operation,
-- and spread the load on the requested number of sessions.
-- It returns a rollback id that will be needed by next steps (or NULL if there are some NULL input).
-- This function may be directly called by the Emaj_web client.
  DECLARE
    v_markName               TEXT;
    v_markTimeId             BIGINT;
    v_markTimestamp          TIMESTAMPTZ;
    v_nbTblInGroups          INT;
    v_nbSeqInGroups          INT;
    v_dbLinkCnxStatus        INT;
    v_isDblinkUsed           BOOLEAN;
    v_dbLinkSchema           TEXT;
    v_effNbTable             INT;
    v_histId                 BIGINT;
    v_stmt                   TEXT;
    v_rlbkId                 INT;
  BEGIN
-- check supplied group names and mark parameters
    SELECT emaj._rlbk_check(v_groupNames, v_mark, v_isAlterGroupAllowed, FALSE) INTO v_markName;
    IF v_markName IS NOT NULL THEN
-- check that no group is damaged
      PERFORM 0 FROM emaj._verify_groups(v_groupNames, TRUE);
-- get the time stamp id and its clock timestamp for the first group (as we know this time stamp is the same for all groups of the array)
      SELECT time_id, time_clock_timestamp INTO v_markTimeId, v_markTimestamp
        FROM emaj.emaj_mark, emaj.emaj_time_stamp
        WHERE time_id = mark_time_id AND mark_group = v_groupNames[1] AND mark_name = v_markName;
-- insert begin in the history
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'BEGIN',
                array_to_string(v_groupNames,','),
                CASE WHEN v_isLoggedRlbk THEN 'Logged' ELSE 'Unlogged' END || ' rollback to mark ' || v_markName
                || ' [' || v_markTimestamp || ']'
               ) RETURNING hist_id INTO v_histId;
-- get the total number of tables for these groups
      SELECT sum(group_nb_table), sum(group_nb_sequence) INTO v_nbTblInGroups, v_nbSeqInGroups
        FROM emaj.emaj_group WHERE group_name = ANY (v_groupNames) ;
-- first try to open a dblink connection
      SELECT v_status, (v_status >= 0), CASE WHEN v_status >= 0 THEN v_schema ELSE NULL END
        INTO v_dbLinkCnxStatus, v_isDblinkUsed, v_dbLinkSchema
        FROM emaj._dblink_open_cnx('rlbk#1');
-- for parallel rollback (i.e. when nb sessions > 1), the dblink connection must be ok
      IF v_nbSession > 1 AND NOT v_isDblinkUsed THEN
        RAISE EXCEPTION '_rlbk_init: Cannot use several sessions without dblink connection capability. (Status of the dblink'
                        ' connection attempt = % - see E-Maj documentation)',
          v_dbLinkCnxStatus;
      END IF;
-- create the row representing the rollback event in the emaj_rlbk table and get the rollback id back
      v_stmt = 'INSERT INTO emaj.emaj_rlbk (rlbk_groups, rlbk_mark, rlbk_mark_time_id, rlbk_is_logged, rlbk_is_alter_group_allowed, ' ||
               'rlbk_nb_session, rlbk_nb_table, rlbk_nb_sequence, rlbk_status, rlbk_begin_hist_id, ' ||
               'rlbk_dblink_schema, rlbk_is_dblink_used) ' ||
               'VALUES (' || quote_literal(v_groupNames) || ',' || quote_literal(v_markName) || ',' ||
               v_markTimeId || ',' || v_isLoggedRlbk || ',' || quote_nullable(v_isAlterGroupAllowed) || ',' ||
               v_nbSession || ',' || v_nbTblInGroups || ',' || v_nbSeqInGroups || ', ''PLANNING'',' || v_histId || ',' ||
               quote_nullable(v_dbLinkSchema) || ',' || v_isDblinkUsed || ') RETURNING rlbk_id';
      SELECT emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema) INTO v_rlbkId;
-- call the rollback planning function to define all the elementary steps to perform,
-- compute their estimated duration and spread the elementary steps among sessions
      v_stmt = 'SELECT emaj._rlbk_planning(' || v_rlbkId || ')';
      SELECT emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema) INTO v_effNbTable;
-- update the emaj_rlbk table to set the real number of tables to process and adjust the rollback status
      v_stmt = 'UPDATE emaj.emaj_rlbk SET rlbk_eff_nb_table = ' || v_effNbTable ||
               ', rlbk_status = ''LOCKING'' ' || ' WHERE rlbk_id = ' || v_rlbkId || ' RETURNING 1';
      PERFORM emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema);
    END IF;
    RETURN v_rlbkId;
  END;
$_rlbk_init$;

CREATE OR REPLACE FUNCTION emaj._rlbk_check(v_groupNames TEXT[], v_mark TEXT, v_isAlterGroupAllowed BOOLEAN, isRollbackSimulation BOOLEAN)
RETURNS TEXT LANGUAGE plpgsql AS
$_rlbk_check$
-- This functions performs checks on group names and mark names supplied as parameter for the emaj_rollback_groups()
-- and emaj_estimate_rollback_groups() functions.
-- It returns the real mark name, or NULL if the groups array is NULL or empty.
  DECLARE
    v_markName               TEXT;
    v_aGroupName             TEXT;
    v_markTimeId             BIGINT;
    v_protectedMarksList     TEXT;
  BEGIN
-- check the group names and states
    IF isRollbackSimulation THEN
      SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                     v_checkList := 'LOGGING,ROLLBACKABLE') INTO v_groupNames;
    ELSE
      SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := FALSE, v_lockGroups := TRUE,
                                     v_checkList := 'LOGGING,ROLLBACKABLE,UNPROTECTED') INTO v_groupNames;
    END IF;
    IF v_groupNames IS NOT NULL THEN
-- check the mark name
      SELECT emaj._check_mark_name(v_groupNames := v_groupNames, v_mark := v_mark, v_checkList := 'ACTIVE') INTO v_markName;
      IF NOT isRollbackSimulation THEN
-- check that for each group that the rollback wouldn't delete protected marks (check disabled for rollback simulation)
        FOREACH v_aGroupName IN ARRAY v_groupNames LOOP
--   get the target mark time id
          SELECT mark_time_id INTO v_markTimeId FROM emaj.emaj_mark
            WHERE mark_group = v_aGroupName AND mark_name = v_markName;
--   and look at the protected mark
          SELECT string_agg(mark_name,', ' ORDER BY mark_name) INTO v_protectedMarksList FROM (
            SELECT mark_name FROM emaj.emaj_mark
              WHERE mark_group = v_aGroupName AND mark_time_id > v_markTimeId AND mark_is_rlbk_protected
              ORDER BY mark_time_id) AS t;
          IF v_protectedMarksList IS NOT NULL THEN
            RAISE EXCEPTION '_rlbk_check: Protected marks (%) for the group "%" block the rollback to the mark "%".',
              v_protectedMarksList, v_aGroupName, v_markName;
          END IF;
        END LOOP;
      END IF;
-- if the isAlterGroupAllowed flag is not explicitely set to true, check that the rollback would not cross any alter group operation for
-- the groups
      IF v_isAlterGroupAllowed IS NULL OR NOT v_isAlterGroupAllowed THEN
        SELECT mark_time_id INTO v_markTimeId
          FROM emaj.emaj_mark WHERE mark_group = v_groupNames[1] AND mark_name = v_markName;
        PERFORM 0 FROM emaj.emaj_alter_plan
          WHERE altr_time_id > v_markTimeId AND altr_group = ANY (v_groupNames) AND altr_rlbk_id IS NULL;
        IF FOUND THEN
          RAISE EXCEPTION '_rlbk_check: This rollback operation would cross some previously executed alter group operations,'
                          ' which is not allowed by the current function parameters.';
        END IF;
      END IF;
    END IF;
    RETURN v_markName;
  END;
$_rlbk_check$;

CREATE OR REPLACE FUNCTION emaj._rlbk_planning(v_rlbkId INT)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_rlbk_planning$
-- This function builds the rollback steps for a rollback operation.
-- It stores the result into the emaj_rlbk_plan table.
-- The function returns the effective number of tables to process.
-- It is called in an autonomous dblink transaction, if possible.
-- The function is defined as SECURITY DEFINER so that emaj_viwer role can write into rollback tables without having specific privileges
-- to do it.
  DECLARE
    v_groupNames             TEXT[];
    v_mark                   TEXT;
    v_isLoggedRlbk           BOOLEAN;
    v_markTimeId             BIGINT;
    v_nbSession              INT;
    v_ctrlStepName           emaj._rlbk_step_enum;
    v_effNbTable             INT;
    v_batchNumber            INT;
    v_checks                 INT;
    v_estimDuration          INTERVAL;
    v_estimMethod            INT;
    v_estimDropFkDuration    INTERVAL;
    v_estimDropFkMethod      INT;
    v_estimSetFkDefDuration  INTERVAL;
    v_estimSetFkDefMethod    INT;
    v_avg_row_rlbk           INTERVAL;
    v_avg_row_del_log        INTERVAL;
    v_avg_fkey_check         INTERVAL;
    v_fixed_step_rlbk        INTERVAL;
    v_fixed_dblink_rlbk      INTERVAL;
    v_sessionLoad            INTERVAL[];
    v_minSession             INT;
    v_minDuration            INTERVAL;
    v_nbStep                 INT;
    r_tbl                    RECORD;
    r_fk                     RECORD;
    r_batch                  RECORD;
  BEGIN
-- get the rollback characteristics for the emaj_rlbk event
    SELECT rlbk_groups, rlbk_mark, rlbk_is_logged, rlbk_nb_session,
           CASE WHEN rlbk_is_dblink_used THEN 'CTRL+DBLINK'::emaj._rlbk_step_enum ELSE 'CTRL-DBLINK'::emaj._rlbk_step_enum END
      INTO v_groupNames, v_mark, v_isLoggedRlbk, v_nbSession, v_ctrlStepName
      FROM emaj.emaj_rlbk WHERE rlbk_id = v_rlbkId;
-- get some mark attributes from emaj_mark
    SELECT mark_time_id INTO v_markTimeId
      FROM emaj.emaj_mark
      WHERE mark_group = v_groupNames[1] AND mark_name = v_mark;
-- get all duration parameters that will be needed later from the emaj_param table,
--   or get default values for rows that are not present in emaj_param table
    SELECT coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'avg_row_rollback_duration'),'100 microsecond'::INTERVAL),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'avg_row_delete_log_duration'),'10 microsecond'::INTERVAL),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'avg_fkey_check_duration'),'5 microsecond'::INTERVAL),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'fixed_step_rollback_duration'),'2.5 millisecond'::INTERVAL),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'fixed_dblink_rollback_duration'),'4 millisecond'::INTERVAL)
           INTO v_avg_row_rlbk, v_avg_row_del_log, v_avg_fkey_check, v_fixed_step_rlbk, v_fixed_dblink_rlbk;
-- insert into emaj_rlbk_plan a row per table currently belonging to the tables groups to process.
    INSERT INTO emaj.emaj_rlbk_plan (rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object)
      SELECT v_rlbkId, 'LOCK_TABLE', rel_schema, rel_tblseq, ''
        FROM emaj.emaj_relation
        WHERE upper_inf(rel_time_range) AND rel_group = ANY(v_groupNames) AND rel_kind = 'r';
-- insert into emaj_rlbk_plan a row per table to effectively rollback.
-- the numbers of log rows is computed using the _log_stat_tbl() function.
-- a final check will be performed after tables will be locked to be sure no new table will have been updated
     INSERT INTO emaj.emaj_rlbk_plan
            (rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_target_time_id, rlbp_estimated_quantity)
      SELECT v_rlbkId, 'RLBK_TABLE', rel_schema, rel_tblseq, '', greatest(v_markTimeId, lower(rel_time_range)),
             emaj._log_stat_tbl(t, greatest(v_markTimeId, lower(rel_time_range)), NULL)
        FROM (SELECT * FROM emaj.emaj_relation
                WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames) AND rel_kind = 'r') AS t
        WHERE emaj._log_stat_tbl(t, greatest(v_markTimeId, lower(rel_time_range)), NULL) > 0;
     GET DIAGNOSTICS v_effNbTable = ROW_COUNT;
--
-- group tables into batchs to process all tables linked by foreign keys as a batch
--
    v_batchNumber = 1;
--   allocate tables with rows to rollback to batch number starting with the heaviest to rollback tables
--     as reported by emaj_log_stat_group() function
    FOR r_tbl IN
        SELECT * FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE' ORDER BY rlbp_estimated_quantity DESC
    LOOP
--   is the table already allocated to a batch number (it may have been already allocated because of a fkey link) ?
      PERFORM 0 FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'
          AND rlbp_schema = r_tbl.rlbp_schema AND rlbp_table = r_tbl.rlbp_table AND rlbp_batch_number IS NULL;
--   no,
      IF FOUND THEN
--   allocate the table to the batch number, with all other tables linked by foreign key constraints
        PERFORM emaj._rlbk_set_batch_number(v_rlbkId, v_batchNumber, r_tbl.rlbp_schema, r_tbl.rlbp_table);
        v_batchNumber = v_batchNumber + 1;
      END IF;
    END LOOP;
--
-- if unlogged rollback, register into emaj_rlbk_plan "disable log triggers", "deletes from log tables"
-- and "enable log trigger" steps
--
    IF NOT v_isLoggedRlbk THEN
-- compute the cost for each DIS_LOG_TRG step
--   if DIS_LOG_TRG statistics are available, compute an average cost
      SELECT sum(rlbt_duration) / sum(rlbt_quantity) INTO v_estimDuration FROM emaj.emaj_rlbk_stat
        WHERE rlbt_step = 'DIS_LOG_TRG';
      v_estimMethod = 2;
      IF v_estimDuration IS NULL THEN
--   otherwise, use the fixed_step_rollback_duration parameter
        v_estimDuration = v_fixed_step_rlbk;
        v_estimMethod = 3;
      END IF;
-- insert all DIS_LOG_TRG steps
      INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number,
          rlbp_estimated_duration, rlbp_estimate_method
        ) SELECT v_rlbkId, 'DIS_LOG_TRG', rlbp_schema, rlbp_table, '', rlbp_batch_number,
                 v_estimDuration, v_estimMethod
          FROM emaj.emaj_rlbk_plan
          WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE';
-- insert all DELETE_LOG steps. But the duration estimates will be computed later
-- the estimated number of log rows to delete is set to the the estimated number of updates. This is underestimated
--   in particular when SQL UPDATES are logged. But the collected statistics used for duration estimates are also
--   based on the estimated number of updates.
      INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_target_time_id, rlbp_batch_number, rlbp_estimated_quantity
        ) SELECT v_rlbkId, 'DELETE_LOG', rlbp_schema, rlbp_table, '', rlbp_target_time_id, rlbp_batch_number, rlbp_estimated_quantity
          FROM emaj.emaj_rlbk_plan
          WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE';
-- compute the cost for each ENA_LOG_TRG step
--   if DIS_LOG_TRG statistics are available, compute an average cost
      SELECT sum(rlbt_duration) / sum(rlbt_quantity) INTO v_estimDuration FROM emaj.emaj_rlbk_stat
        WHERE rlbt_step = 'ENA_LOG_TRG';
      v_estimMethod = 2;
      IF v_estimDuration IS NULL THEN
--   otherwise, use the fixed_step_rollback_duration parameter
        v_estimDuration = v_fixed_step_rlbk;
        v_estimMethod = 3;
      END IF;
-- insert all ENA_LOG_TRG steps
      INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number,
          rlbp_estimated_duration, rlbp_estimate_method
        ) SELECT v_rlbkId, 'ENA_LOG_TRG', rlbp_schema, rlbp_table, '', rlbp_batch_number,
                 v_estimDuration, v_estimMethod
          FROM emaj.emaj_rlbk_plan
          WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE';
    END IF;
--
-- process application triggers
--
-- compute the cost for each DIS_APP_TRG step
--   if DIS_APP_TRG statistics are available, compute an average cost
    SELECT sum(rlbt_duration) / sum(rlbt_quantity) INTO v_estimDuration FROM emaj.emaj_rlbk_stat
      WHERE rlbt_step = 'DIS_APP_TRG';
    v_estimMethod = 2;
    IF v_estimDuration IS NULL THEN
--   otherwise, use the fixed_step_rollback_duration parameter
      v_estimDuration = v_fixed_step_rlbk;
      v_estimMethod = 3;
    END IF;
-- insert all DIS_APP_TRG steps
    INSERT INTO emaj.emaj_rlbk_plan (
        rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number,
        rlbp_estimated_duration, rlbp_estimate_method
      ) SELECT v_rlbkId, 'DIS_APP_TRG', rlbp_schema, rlbp_table, tgname, rlbp_batch_number,
               v_estimDuration, v_estimMethod
        FROM emaj.emaj_rlbk_plan, pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_trigger
        WHERE nspname = rlbp_schema AND relname = rlbp_table AND relnamespace = pg_namespace.oid
          AND tgrelid = pg_class.oid
          AND rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'
          AND NOT tgisinternal AND NOT tgenabled = 'D'
          AND tgname NOT IN ('emaj_trunc_trg','emaj_log_trg')
          AND NOT EXISTS (SELECT trg_name FROM emaj.emaj_ignored_app_trigger
                            WHERE trg_schema = rlbp_schema AND trg_table = rlbp_table AND trg_name = tgname);
-- compute the cost for each ENA_APP_TRG step
--   if ENA_APP_TRG statistics are available, compute an average cost
    SELECT sum(rlbt_duration) / sum(rlbt_quantity) INTO v_estimDuration FROM emaj.emaj_rlbk_stat
      WHERE rlbt_step = 'ENA_APP_TRG';
    v_estimMethod = 2;
    IF v_estimDuration IS NULL THEN
--   otherwise, use the fixed_step_rollback_duration parameter
      v_estimDuration = v_fixed_step_rlbk;
      v_estimMethod = 3;
    END IF;
-- insert all ENA_APP_TRG steps
    INSERT INTO emaj.emaj_rlbk_plan (
        rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_object_def, rlbp_batch_number,
        rlbp_estimated_duration, rlbp_estimate_method
      ) SELECT v_rlbkId, 'ENA_APP_TRG', rlbp_schema, rlbp_table, rlbp_object,
               CASE WHEN tgenabled = 'A' THEN 'ALWAYS' WHEN tgenabled = 'R' THEN 'REPLICA' ELSE '' END,
               rlbp_batch_number, v_estimDuration, v_estimMethod
        FROM emaj.emaj_rlbk_plan, pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_trigger
        WHERE nspname = rlbp_schema AND relname = rlbp_table AND relnamespace = pg_namespace.oid
          AND tgrelid = pg_class.oid AND tgname = rlbp_object
          AND rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'DIS_APP_TRG';
--
-- process foreign key to define which action to perform on them
--
-- First compute the fixed duration estimates for each 'DROP_FK' and 'SET_FK_DEF' steps
--   if DROP_FK statistics are available, compute an average cost
    SELECT sum(rlbt_duration) / sum(rlbt_quantity) INTO v_estimDropFkDuration FROM emaj.emaj_rlbk_stat
      WHERE rlbt_step = 'DROP_FK';
    v_estimDropFkMethod = 2;
    IF v_estimDropFkDuration IS NULL THEN
--   if no statistics are available for this step, use the fixed_step_rollback_duration parameter
      v_estimDropFkDuration = v_fixed_step_rlbk;
      v_estimDropFkMethod = 3;
    END IF;
--   if SET_FK_DEF statistics are available, compute an average cost
    SELECT sum(rlbt_duration) / sum(rlbt_quantity) INTO v_estimSetFkDefDuration FROM emaj.emaj_rlbk_stat
      WHERE rlbt_step = 'SET_FK_DEF';
    v_estimSetFkDefMethod = 2;
    IF v_estimSetFkDefDuration IS NULL THEN
--   if no statistics are available for this step, use the fixed_step_rollback_duration parameter
      v_estimSetFkDefDuration = v_fixed_step_rlbk;
      v_estimSetFkDefMethod = 3;
    END IF;
-- select all foreign keys belonging to or referencing the tables to process
    FOR r_fk IN
      SELECT c.oid AS conoid, c.conname, n.nspname, t.relname, t.reltuples, pg_get_constraintdef(c.oid) AS def, c.condeferrable,
             c.condeferred, c.confupdtype, c.confdeltype, r.rlbp_batch_number
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t, emaj.emaj_rlbk_plan r
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'       -- tables to rollback
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND n.nspname = r.rlbp_schema AND t.relname = r.rlbp_table     -- join on emaj_rlbk_plan table
      UNION
      SELECT c.oid AS conoid, c.conname, n.nspname, t.relname, t.reltuples, pg_get_constraintdef(c.oid) AS def, c.condeferrable,
             c.condeferred, c.confupdtype, c.confdeltype, r.rlbp_batch_number
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace rn, pg_catalog.pg_class rt, emaj.emaj_rlbk_plan r
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'       -- tables to rollback
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
          AND rn.nspname = r.rlbp_schema AND rt.relname = r.rlbp_table   -- join on emaj_rlbk_plan table
      ORDER BY nspname, relname, conname
    LOOP
-- depending on the foreign key characteristics, record as 'to be dropped' or 'to be set deffered' or 'to just be reset immediate'
      IF NOT r_fk.condeferrable OR r_fk.confupdtype <> 'a' OR r_fk.confdeltype <> 'a' THEN
-- non deferrable fkeys and deferrable fkeys with an action for UPDATE or DELETE other than 'no action' need to be dropped
        INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number,
          rlbp_estimated_duration, rlbp_estimate_method
          ) VALUES (
          v_rlbkId, 'DROP_FK', r_fk.nspname, r_fk.relname, r_fk.conname, r_fk.rlbp_batch_number,
          v_estimDropFkDuration, v_estimDropFkMethod
          );
        INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number, rlbp_object_def, rlbp_estimated_quantity
          ) VALUES (
          v_rlbkId, 'ADD_FK', r_fk.nspname, r_fk.relname, r_fk.conname, r_fk.rlbp_batch_number, r_fk.def, r_fk.reltuples
          );
      ELSE
-- other deferrable but not deferred fkeys need to be set deferred
        IF NOT r_fk.condeferred THEN
          INSERT INTO emaj.emaj_rlbk_plan (
            rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number,
            rlbp_estimated_duration, rlbp_estimate_method
            ) VALUES (
            v_rlbkId, 'SET_FK_DEF', r_fk.nspname, r_fk.relname, r_fk.conname, r_fk.rlbp_batch_number,
            v_estimSetFkDefDuration, v_estimSetFkDefMethod
            );
        END IF;
-- deferrable fkeys are recorded as 'to be set immediate at the end of the rollback operation'
-- compute the number of fkey values to check at set immediate time
        SELECT (coalesce(
--   get the number of rolled back rows in the referencing table, if any
           (SELECT rlbp_estimated_quantity
              FROM emaj.emaj_rlbk_plan
              WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'       -- tables of the rollback event
                AND rlbp_schema = r_fk.nspname AND rlbp_table = r_fk.relname)  -- referencing schema.table
            , 0)) + (coalesce(
--   get the number of rolled back rows in the referenced table, if any
           (SELECT rlbp_estimated_quantity
              FROM emaj.emaj_rlbk_plan, pg_catalog.pg_constraint c, pg_catalog.pg_namespace rn, pg_catalog.pg_class rt
              WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'       -- tables of the rollback event
                AND c.oid = r_fk.conoid                                        -- constraint id
                AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced schema.table
                AND rn.nspname = rlbp_schema AND rt.relname = rlbp_table)      -- join on emaj_rlbk_plan
            , 0)) INTO v_checks;
-- and record the SET_FK_IMM step
        INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_batch_number, rlbp_estimated_quantity
          ) VALUES (
          v_rlbkId, 'SET_FK_IMM', r_fk.nspname, r_fk.relname, r_fk.conname, r_fk.rlbp_batch_number, v_checks
          );
      END IF;
    END LOOP;
--
-- Now compute the estimation duration for each complex step ('RLBK_TABLE', 'DELETE_LOG', 'ADD_FK', 'SET_FK_IMM')
--
-- Compute the rollback duration estimates for the tables
-- for each table with content to rollback
    FOR r_tbl IN
        SELECT * FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'
    LOOP
-- first look at the previous rollback durations for the table and with similar rollback volume (same order of magnitude)
      SELECT sum(rlbt_duration) * r_tbl.rlbp_estimated_quantity / sum(rlbt_quantity) INTO v_estimDuration
        FROM emaj.emaj_rlbk_stat
        WHERE rlbt_step = 'RLBK_TABLE' AND rlbt_quantity > 0
          AND rlbt_schema = r_tbl.rlbp_schema AND rlbt_table = r_tbl.rlbp_table
          AND rlbt_quantity / r_tbl.rlbp_estimated_quantity < 10 AND r_tbl.rlbp_estimated_quantity / rlbt_quantity < 10;
      v_estimMethod = 1;
      IF v_estimDuration IS NULL THEN
-- if there is no previous rollback operation with similar volume, take statistics for the table with all available volumes
        SELECT sum(rlbt_duration) * r_tbl.rlbp_estimated_quantity / sum(rlbt_quantity) INTO v_estimDuration
          FROM emaj.emaj_rlbk_stat
          WHERE rlbt_step = 'RLBK_TABLE' AND rlbt_quantity > 0
            AND rlbt_schema = r_tbl.rlbp_schema AND rlbt_table = r_tbl.rlbp_table;
        v_estimMethod = 2;
        IF v_estimDuration IS NULL THEN
-- if there is no previous rollback operation, use the avg_row_rollback_duration from the emaj_param table
          v_estimDuration = v_avg_row_rlbk * r_tbl.rlbp_estimated_quantity + v_fixed_step_rlbk;
          v_estimMethod = 3;
        END IF;
      END IF;
      UPDATE emaj.emaj_rlbk_plan
        SET rlbp_estimated_duration = v_estimDuration, rlbp_estimate_method = v_estimMethod
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE'
          AND rlbp_schema = r_tbl.rlbp_schema AND rlbp_table = r_tbl.rlbp_table;
    END LOOP;
-- Compute the log rows delete duration for the tables
    FOR r_tbl IN
        SELECT * FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'DELETE_LOG'
    LOOP
-- first look at the previous rollback durations for the table and with similar rollback volume (same order of magnitude)
      SELECT sum(rlbt_duration) * r_tbl.rlbp_estimated_quantity / sum(rlbt_quantity) INTO v_estimDuration
        FROM emaj.emaj_rlbk_stat
        WHERE rlbt_step = 'DELETE_LOG' AND rlbt_quantity > 0
          AND rlbt_schema = r_tbl.rlbp_schema AND rlbt_table = r_tbl.rlbp_table
          AND rlbt_quantity / r_tbl.rlbp_estimated_quantity < 10 AND r_tbl.rlbp_estimated_quantity / rlbt_quantity < 10;
      v_estimMethod = 1;
      IF v_estimDuration IS NULL THEN
-- if there is no previous rollback operation with similar volume, take statistics for the table with all available volumes
        SELECT sum(rlbt_duration) * r_tbl.rlbp_estimated_quantity / sum(rlbt_quantity) INTO v_estimDuration
          FROM emaj.emaj_rlbk_stat
          WHERE rlbt_step = 'DELETE_LOG' AND rlbt_quantity > 0
            AND rlbt_schema = r_tbl.rlbp_schema AND rlbt_table = r_tbl.rlbp_table;
        v_estimMethod = 2;
        IF v_estimDuration IS NULL THEN
-- if there is no previous rollback operation, use the avg_row_rollback_duration from the emaj_param table
          v_estimDuration = v_avg_row_del_log * r_tbl.rlbp_estimated_quantity + v_fixed_step_rlbk;
          v_estimMethod = 3;
        END IF;
      END IF;
      UPDATE emaj.emaj_rlbk_plan
        SET rlbp_estimated_duration = v_estimDuration, rlbp_estimate_method = v_estimMethod
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'DELETE_LOG'
          AND rlbp_schema = r_tbl.rlbp_schema AND rlbp_table = r_tbl.rlbp_table;
    END LOOP;
-- Compute the fkey recreation duration
    FOR r_fk IN
        SELECT * FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'ADD_FK'
    LOOP
      IF r_fk.rlbp_estimated_quantity = 0 THEN
-- empty table (or table not analyzed) => duration = 0
        v_estimDuration = '0 SECONDS'::INTERVAL;
        v_estimMethod = 3;
      ELSE
-- non empty table and statistics (with at least one row) are available
        SELECT sum(rlbt_duration) * r_fk.rlbp_estimated_quantity / sum(rlbt_quantity) INTO v_estimDuration
          FROM emaj.emaj_rlbk_stat
          WHERE rlbt_step = 'ADD_FK' AND rlbt_quantity > 0
            AND rlbt_schema = r_fk.rlbp_schema AND rlbt_table = r_fk.rlbp_table AND rlbt_object = r_fk.rlbp_object;
        v_estimMethod = 1;
        IF v_estimDuration IS NULL THEN
-- non empty table, but no statistics with at least one row are available => take the last duration for this fkey, if any
          SELECT rlbt_duration INTO v_estimDuration FROM emaj.emaj_rlbk_stat
            WHERE rlbt_step = 'ADD_FK'
              AND rlbt_schema = r_fk.rlbp_schema AND rlbt_table = r_tbl.rlbp_table AND rlbt_object = r_fk.rlbp_object
              AND rlbt_rlbk_id =
               (SELECT max(rlbt_rlbk_id) FROM emaj.emaj_rlbk_stat WHERE rlbt_step = 'ADD_FK'
                  AND rlbt_schema = r_fk.rlbp_schema AND rlbt_table = r_fk.rlbp_table AND rlbt_object = r_fk.rlbp_object);
          v_estimMethod = 2;
          IF v_estimDuration IS NULL THEN
-- definitely no statistics available, compute with the avg_fkey_check_duration parameter
            v_estimDuration = r_fk.rlbp_estimated_quantity * v_avg_fkey_check + v_fixed_step_rlbk;
            v_estimMethod = 3;
          END IF;
        END IF;
      END IF;
      UPDATE emaj.emaj_rlbk_plan
        SET rlbp_estimated_duration = v_estimDuration, rlbp_estimate_method = v_estimMethod
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'ADD_FK'
          AND rlbp_schema = r_fk.rlbp_schema AND rlbp_table = r_fk.rlbp_table AND rlbp_object = r_fk.rlbp_object;
    END LOOP;
-- Compute the fkey checks duration
    FOR r_fk IN
        SELECT * FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'SET_FK_IMM'
    LOOP
-- if fkey checks statistics are available for this fkey, compute an average cost
      SELECT sum(rlbt_duration) * r_fk.rlbp_estimated_quantity / sum(rlbt_quantity) INTO v_estimDuration
        FROM emaj.emaj_rlbk_stat
        WHERE rlbt_step = 'SET_FK_IMM' AND rlbt_quantity > 0
          AND rlbt_schema = r_fk.rlbp_schema AND rlbt_table = r_fk.rlbp_table AND rlbt_object = r_fk.rlbp_object;
      v_estimMethod = 2;
      IF v_estimDuration IS NULL THEN
-- if no statistics are available for this fkey, use the avg_fkey_check parameter
        v_estimDuration = r_fk.rlbp_estimated_quantity * v_avg_fkey_check + v_fixed_step_rlbk;
        v_estimMethod = 3;
      END IF;
      UPDATE emaj.emaj_rlbk_plan
        SET rlbp_estimated_duration = v_estimDuration, rlbp_estimate_method = v_estimMethod
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'SET_FK_IMM'
          AND rlbp_schema = r_fk.rlbp_schema AND rlbp_table = r_fk.rlbp_table AND rlbp_object = r_fk.rlbp_object;
    END LOOP;
--
-- Allocate batch number to sessions to spread the load on sessions as best as possible
-- A batch represents all steps related to the processing of one table or several tables linked by foreign keys
--
--   initialisation
    FOR v_session IN 1 .. v_nbSession LOOP
      v_sessionLoad [v_session] = '0 SECONDS'::INTERVAL;
    END LOOP;
--   allocate tables batch to sessions, starting with the heaviest to rollback batch
    FOR r_batch IN
        SELECT rlbp_batch_number, sum(rlbp_estimated_duration) AS batch_duration
          FROM emaj.emaj_rlbk_plan
          WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_batch_number IS NOT NULL
          GROUP BY rlbp_batch_number
          ORDER BY sum(rlbp_estimated_duration) DESC
    LOOP
--   compute the least loaded session
      v_minSession=1; v_minDuration = v_sessionLoad [1];
      FOR v_session IN 2 .. v_nbSession LOOP
        IF v_sessionLoad [v_session] < v_minDuration THEN
          v_minSession = v_session;
          v_minDuration = v_sessionLoad [v_session];
        END IF;
      END LOOP;
--   allocate the batch to the session
      UPDATE emaj.emaj_rlbk_plan SET rlbp_session = v_minSession
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_batch_number = r_batch.rlbp_batch_number;
      v_sessionLoad [v_minSession] = v_sessionLoad [v_minSession] + r_batch.batch_duration;
    END LOOP;
-- assign session 1 to all 'LOCK_TABLE' steps not yet affected
    UPDATE emaj.emaj_rlbk_plan SET rlbp_session = 1
      WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_session IS NULL;
-- Create the pseudo 'CTRL+DBLINK' or 'CTRL-DBLINK' step and compute its duration estimate
-- get the number of recorded steps (except LOCK_TABLE)
    SELECT count(*) INTO v_nbStep FROM emaj.emaj_rlbk_plan
      WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step <> 'LOCK_TABLE';
    IF v_nbStep > 0 THEN
-- if CTRLxDBLINK statistics are available, compute an average cost
      SELECT sum(rlbt_duration) * v_nbStep / sum(rlbt_quantity) INTO v_estimDuration
        FROM emaj.emaj_rlbk_stat WHERE rlbt_step = v_ctrlStepName AND rlbt_quantity > 0;
      v_estimMethod = 2;
      IF v_estimDuration IS NULL THEN
--   otherwise, use the fixed_step_rollback_duration parameter
        v_estimDuration = v_fixed_dblink_rlbk * v_nbStep;
        v_estimMethod = 3;
      END IF;
-- insert the 'CTRLxDBLINK' pseudo step
      INSERT INTO emaj.emaj_rlbk_plan (
          rlbp_rlbk_id, rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_estimated_quantity,
          rlbp_estimated_duration, rlbp_estimate_method
        ) VALUES (
          v_rlbkId, v_ctrlStepName, '', '', '', v_nbStep, v_estimDuration, v_estimMethod
        );
    END IF;
-- return the number of tables to effectively rollback
    RETURN v_effNbTable;
  END;
$_rlbk_planning$;

CREATE OR REPLACE FUNCTION emaj._rlbk_set_batch_number(v_rlbkId INT, v_batchNumber INT, v_schema TEXT, v_table TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_rlbk_set_batch_number$
-- This function updates the emaj_rlbk_plan table to set the batch_number for one table.
-- It also looks for all tables that are linked to this table by foreign keys to force them to be allocated to the same batch number.
-- The function is called by _rlbk_planning().
-- As those linked tables can also be linked to other tables by other foreign keys, the function has to be recursiley called.
  DECLARE
    v_fullTableName          TEXT;
    r_tbl                    RECORD;
  BEGIN
-- set the batch number to this application table (there is a 'LOCK_TABLE' step and potentialy a 'RLBK_TABLE' step)
    UPDATE emaj.emaj_rlbk_plan SET rlbp_batch_number = v_batchNumber
      WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_schema = v_schema AND rlbp_table = v_table;
-- then look for all other application tables linked by foreign key relationships
    v_fullTableName = quote_ident(v_schema) || '.' || quote_ident(v_table);
    FOR r_tbl IN
        SELECT rlbp_schema, rlbp_table FROM emaj.emaj_rlbk_plan
          WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'LOCK_TABLE'
            AND rlbp_batch_number IS NULL            -- not yet allocated
            AND (rlbp_schema, rlbp_table) IN (       -- list of (schema,table) linked to the original table by fkeys
              SELECT nspname, relname FROM pg_catalog.pg_constraint, pg_catalog.pg_class t, pg_catalog.pg_namespace n
                WHERE contype = 'f' AND confrelid = v_fullTableName::regclass
                  AND t.oid = conrelid AND relnamespace = n.oid
              UNION
              SELECT nspname, relname FROM pg_catalog.pg_constraint, pg_catalog.pg_class t, pg_catalog.pg_namespace n
                WHERE contype = 'f' AND conrelid = v_fullTableName::regclass
                  AND t.oid = confrelid AND relnamespace = n.oid
              )
    LOOP
-- recursive call to allocate these linked tables to the same batch_number
      PERFORM emaj._rlbk_set_batch_number(v_rlbkId, v_batchNumber, r_tbl.rlbp_schema, r_tbl.rlbp_table);
    END LOOP;
    RETURN;
  END;
$_rlbk_set_batch_number$;

CREATE OR REPLACE FUNCTION emaj._rlbk_session_lock(v_rlbkId INT, v_session INT)
RETURNS VOID LANGUAGE plpgsql AS
$_rlbk_session_lock$
-- It creates the session row in the emaj_rlbk_session table and then locks all the application tables for the session.
  DECLARE
    v_isDblinkUsed           BOOLEAN;
    v_dblinkSchema           TEXT;
    v_dbLinkCnxStatus        INT;
    v_stmt                   TEXT;
    v_groupNames             TEXT[];
    v_nbRetry                SMALLINT = 0;
    v_ok                     BOOLEAN = FALSE;
    v_nbTbl                  INT;
    r_tbl                    RECORD;
  BEGIN
-- get the rollback characteristics from the emaj_rlbk table
    SELECT rlbk_is_dblink_used, rlbk_dblink_schema, rlbk_groups
      INTO v_isDblinkUsed, v_dblinkSchema, v_groupNames
      FROM emaj.emaj_rlbk WHERE rlbk_id = v_rlbkId;
-- for dblink session > 1, open the connection (the session 1 is already opened)
    IF v_session > 1 THEN
      SELECT v_status INTO v_dbLinkCnxStatus
        FROM emaj._dblink_open_cnx('rlbk#'||v_session);
      IF v_dbLinkCnxStatus < 0 THEN
        RAISE EXCEPTION '_rlbk_session_lock: Error while opening the dblink session #% (Status of the dblink connection attempt = %'
                        ' - see E-Maj documentation).',
          v_session, v_dbLinkCnxStatus;
      END IF;
    END IF;
-- create the session row the emaj_rlbk_session table.
    v_stmt = 'INSERT INTO emaj.emaj_rlbk_session (rlbs_rlbk_id, rlbs_session, rlbs_txid, rlbs_start_datetime) ' ||
             'VALUES (' || v_rlbkId || ',' || v_session || ',' || txid_current() || ',' ||
              quote_literal(clock_timestamp()) || ') RETURNING 1';
    PERFORM emaj._dblink_sql_exec('rlbk#'||v_session, v_stmt, v_dblinkSchema);
-- insert lock begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('LOCK_GROUP', 'BEGIN', array_to_string(v_groupNames,','), 'Rollback session #' || v_session);
--
-- acquire locks on tables
--
-- in case of deadlock, retry up to 5 times
    WHILE NOT v_ok AND v_nbRetry < 5 LOOP
      BEGIN
        v_nbTbl = 0;
-- scan all tables of the session, in priority ascending order (priority being defined in emaj_group_def and stored in emaj_relation)
        FOR r_tbl IN
          SELECT quote_ident(rlbp_schema) || '.' || quote_ident(rlbp_table) AS fullName,
                 EXISTS (SELECT 1 FROM emaj.emaj_rlbk_plan rlbp2
                         WHERE rlbp2.rlbp_rlbk_id = v_rlbkId AND rlbp2.rlbp_session = v_session AND
                               rlbp2.rlbp_schema = rlbp1.rlbp_schema AND rlbp2.rlbp_table = rlbp1.rlbp_table AND
                               rlbp2.rlbp_step = 'DIS_LOG_TRG') AS disLogTrg
            FROM emaj.emaj_rlbk_plan rlbp1, emaj.emaj_relation
            WHERE rel_schema = rlbp_schema AND rel_tblseq = rlbp_table AND upper_inf(rel_time_range)
              AND rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'LOCK_TABLE'
              AND rlbp_session = v_session
            ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
--   lock each table
--     The locking level is EXCLUSIVE mode.
--     This blocks all concurrent update capabilities of all tables of the groups (including tables with no logged update to rollback),
--     in order to ensure a stable state of the group at the end of the rollback operation).
--     But these tables can be accessed by SELECT statements during the E-Maj rollback.
          EXECUTE format('LOCK TABLE %s IN EXCLUSIVE MODE',
                         r_tbl.fullName);
          v_nbTbl = v_nbTbl + 1;
        END LOOP;
-- ok, all tables locked
        v_ok = TRUE;
      EXCEPTION
        WHEN deadlock_detected THEN
          v_nbRetry = v_nbRetry + 1;
          RAISE NOTICE '_rlbk_session_lock: A deadlock has been trapped while locking tables for groups "%".',
            array_to_string(v_groupNames,',');
      END;
    END LOOP;
    IF NOT v_ok THEN
      PERFORM emaj._rlbk_error(v_rlbkId, '_rlbk_session_lock: Too many (5) deadlocks encountered while locking tables',
                               'rlbk#' || v_session);
      RAISE EXCEPTION '_rlbk_session_lock: Too many (5) deadlocks encountered while locking tables for groups "%".',
        array_to_string(v_groupNames,',');
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('LOCK_GROUP', 'END', array_to_string(v_groupNames,','),
              'Rollback session #' || v_session || ': ' || v_nbTbl || ' tables locked, ' || v_nbRetry || ' deadlock(s)');
    RETURN;
-- trap and record exception during the rollback operation
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN             -- Do not trap the exceptions raised by the function
      RAISE;
    WHEN OTHERS THEN                       -- Otherwise, log the E-Maj rollback abort in emaj_rlbk, if possible
      PERFORM emaj._rlbk_error(v_rlbkId, 'In _rlbk_session_lock() for session ' || v_session || ': ' || SQLERRM, 'rlbk#'||v_session);
      RAISE;
  END;
$_rlbk_session_lock$;

CREATE OR REPLACE FUNCTION emaj._rlbk_start_mark(v_rlbkId INT, v_multiGroup BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS
$_rlbk_start_mark$
-- For logged rollback, it sets a mark that materialize the point in time just before the tables rollback.
-- All concerned tables are already locked.
-- Before setting the mark, it checks no update has been recorded between the planning step and the locks set
-- for tables for which no rollback was needed at planning time.
-- It also sets the rollback status to EXECUTING.
  DECLARE
    v_isDblinkUsed           BOOLEAN;
    v_dblinkSchema           TEXT;
    v_stmt                   TEXT;
    v_groupNames             TEXT[];
    v_mark                   TEXT;
    v_timeId                 BIGINT;
    v_isLoggedRlbk           BOOLEAN;
    v_rlbkDatetime           TIMESTAMPTZ;
    v_markTimeId             BIGINT;
    v_markName               TEXT;
    v_errorMsg               TEXT;
  BEGIN
-- get the dblink usage characteristics for the current rollback
    SELECT rlbk_is_dblink_used, rlbk_dblink_schema
      INTO v_isDblinkUsed, v_dblinkSchema
      FROM emaj.emaj_rlbk WHERE rlbk_id = v_rlbkId;
-- get a time stamp for the rollback operation
    v_stmt = 'SELECT emaj._set_time_stamp(''R'')';
    SELECT emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema) INTO v_timeId;
-- update the emaj_rlbk table to record the time stamp and adjust the rollback status
    v_stmt = 'UPDATE emaj.emaj_rlbk SET rlbk_time_id = ' || v_timeId || ', rlbk_status = ''EXECUTING''' ||
             ' WHERE rlbk_id = ' || v_rlbkId || ' RETURNING 1';
    PERFORM emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema);
-- get the rollback characteristics from the emaj_rlbk table
    SELECT rlbk_groups, rlbk_mark, rlbk_time_id, rlbk_is_logged, time_clock_timestamp
      INTO v_groupNames, v_mark, v_timeId, v_isLoggedRlbk, v_rlbkDatetime
      FROM emaj.emaj_rlbk, emaj.emaj_time_stamp WHERE rlbk_time_id = time_id AND rlbk_id = v_rlbkId;
-- get some mark attributes from emaj_mark
    SELECT mark_time_id INTO v_markTimeId
      FROM emaj.emaj_mark
      WHERE mark_group = v_groupNames[1] AND mark_name = v_mark;
-- check that no update has been recorded between planning time and lock time for tables that did not need to
-- be rolled back at planning time.
-- This may occur and cannot be avoided because tables cannot be locked before processing the rollback planning.
-- (Sessions must lock the tables they will rollback and the planning processing distribute those tables to sessions.)
    PERFORM 1 FROM (SELECT * FROM emaj.emaj_relation
                      WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames) AND rel_kind = 'r'
                        AND NOT EXISTS
                            (SELECT NULL FROM emaj.emaj_rlbk_plan
                              WHERE rlbp_schema = rel_schema AND rlbp_table = rel_tblseq
                                AND rlbp_rlbk_id = v_rlbkId AND rlbp_step = 'RLBK_TABLE')
                    ) AS t
      WHERE emaj._log_stat_tbl(t, greatest(v_markTimeId, lower(rel_time_range)), NULL) > 0;
    IF FOUND THEN
      v_errorMsg = 'the rollback operation has been cancelled due to concurrent activity at E-Maj rollback planning time on tables'
                || ' to process.';
      PERFORM emaj._rlbk_error(v_rlbkId, v_errorMsg, 'rlbk#1');
      RAISE EXCEPTION '_rlbk_start_mark: % Please retry.', v_errorMsg;
    END IF;
    IF v_isLoggedRlbk THEN
-- If rollback is "logged" rollback, set a mark named with the pattern:
-- 'RLBK_<mark name to rollback to>_%_START', where % represents the rollback start time
      v_markName = 'RLBK_' || v_mark || '_' || substring(to_char(v_rlbkDatetime, 'HH24.MI.SS.US') from 1 for 13) || '_START';
      PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, TRUE, NULL, v_timeId, v_dblinkSchema);
    END IF;
    RETURN;
-- trap and record exception during the rollback operation
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN             -- Do not trap the exceptions raised by the function
      RAISE;
    WHEN OTHERS THEN                       -- Otherwise, log the E-Maj rollback abort in emaj_rlbk, if possible
      PERFORM emaj._rlbk_error(v_rlbkId, 'In _rlbk_start_mark(): ' || SQLERRM, 'rlbk#1');
      RAISE;
  END;
$_rlbk_start_mark$;

CREATE OR REPLACE FUNCTION emaj._rlbk_session_exec(v_rlbkId INT, v_session INT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_rlbk_session_exec$
-- This function executes the main part of a rollback operation.
-- It executes the steps identified by _rlbk_planning() and stored into emaj_rlbk_plan, for one session.
-- It updates the emaj_rlbk_plan table, using dblink connection if possible, giving a visibility of the rollback progress.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if it doesn't own the application tables.
  DECLARE
    v_stmt                   TEXT;
    v_dblinkSchema           TEXT;
    v_isDblinkUsed           BOOLEAN;
    v_groupNames             TEXT[];
    v_mark                   TEXT;
    v_rlbkMarkTimeId         BIGINT;
    v_rlbkTimeId             BIGINT;
    v_isLoggedRlbk           BOOLEAN;
    v_nbSession              INT;
    v_maxGlobalSeq           BIGINT;
    v_lastGlobalSeq          BIGINT;
    v_nbRows                 BIGINT;
    r_step                   RECORD;
  BEGIN
-- get the rollback characteristics from the emaj_rlbk table
    SELECT rlbk_groups, rlbk_mark, rlbk_time_id, rlbk_is_logged, rlbk_nb_session, rlbk_dblink_schema, rlbk_is_dblink_used,
           time_last_emaj_gid
      INTO v_groupNames, v_mark, v_rlbkTimeId, v_isLoggedRlbk, v_nbSession, v_dblinkSchema, v_isDblinkUsed,
           v_maxGlobalSeq
      FROM emaj.emaj_rlbk, emaj.emaj_time_stamp WHERE rlbk_id = v_rlbkId AND rlbk_time_id = time_id;
-- fetch the mark_time_id, the last global sequence at set_mark time for the first group of the groups array
-- (they all share the same values)
    SELECT mark_time_id, time_last_emaj_gid
      INTO v_rlbkMarkTimeId, v_lastGlobalSeq
      FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupNames[1] AND mark_name = v_mark;
-- scan emaj_rlbp_plan to get all steps to process that have been affected to this session, in batch_number and step order
    FOR r_step IN
      SELECT rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_object_def, rlbp_target_time_id
        FROM emaj.emaj_rlbk_plan,
             (VALUES ('DIS_APP_TRG',1),('DIS_LOG_TRG',2),('DROP_FK',3),('SET_FK_DEF',4),
                     ('RLBK_TABLE',5),('DELETE_LOG',6),('SET_FK_IMM',7),('ADD_FK',8),
                     ('ENA_APP_TRG',9),('ENA_LOG_TRG',10)) AS step(step_name, step_order)
        WHERE rlbp_step::TEXT = step.step_name
          AND rlbp_rlbk_id = v_rlbkId AND rlbp_step NOT IN ('LOCK_TABLE','CTRL-DBLINK','CTRL+DBLINK')
          AND rlbp_session = v_session
        ORDER BY rlbp_batch_number, step_order, rlbp_table, rlbp_object
    LOOP
-- update the emaj_rlbk_plan table to set the step start time
      v_stmt = 'UPDATE emaj.emaj_rlbk_plan SET rlbp_start_datetime = clock_timestamp() ' ||
               ' WHERE rlbp_rlbk_id = ' || v_rlbkId || ' AND rlbp_step = ' || quote_literal(r_step.rlbp_step) ||
               ' AND rlbp_schema = ' || quote_literal(r_step.rlbp_schema) ||
               ' AND rlbp_table = ' || quote_literal(r_step.rlbp_table) ||
               ' AND rlbp_object = ' || quote_literal(r_step.rlbp_object) || ' RETURNING 1';
      PERFORM emaj._dblink_sql_exec('rlbk#'||v_session, v_stmt, v_dblinkSchema);
-- process the step depending on its type
      CASE r_step.rlbp_step
        WHEN 'DIS_APP_TRG' THEN
-- process an application trigger disable
          EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER %I',
                         r_step.rlbp_schema, r_step.rlbp_table, r_step.rlbp_object);
        WHEN 'DIS_LOG_TRG' THEN
-- process a log trigger disable
          EXECUTE format('ALTER TABLE %I.%I DISABLE TRIGGER emaj_log_trg',
                         r_step.rlbp_schema, r_step.rlbp_table);
        WHEN 'DROP_FK' THEN
-- process a foreign key deletion
          EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I',
                         r_step.rlbp_schema, r_step.rlbp_table, r_step.rlbp_object);
        WHEN 'SET_FK_DEF' THEN
-- set a foreign key deferred
          EXECUTE format('SET CONSTRAINTS %I.%I DEFERRED',
                         r_step.rlbp_schema, r_step.rlbp_object);
        WHEN 'RLBK_TABLE' THEN
-- process a table rollback
--  for tables added to the group after the rollback target mark, get the last sequence value specific to each table
          SELECT emaj._rlbk_tbl(emaj_relation.*,
                                CASE WHEN v_rlbkMarkTimeId = r_step.rlbp_target_time_id THEN v_lastGlobalSeq      -- common case
                                     ELSE (SELECT time_last_emaj_gid FROM emaj.emaj_time_stamp WHERE time_id = r_step.rlbp_target_time_id)
                                END,
                                v_maxGlobalSeq, v_nbSession, v_isLoggedRlbk) INTO v_nbRows
            FROM emaj.emaj_relation
            WHERE rel_schema = r_step.rlbp_schema AND rel_tblseq = r_step.rlbp_table AND upper_inf(rel_time_range);
        WHEN 'DELETE_LOG' THEN
-- process the deletion of log rows
--  for tables added to the group after the rollback target mark, get the last sequence value specific to each table
          SELECT emaj._delete_log_tbl(emaj_relation.*, r_step.rlbp_target_time_id, v_rlbkTimeId,
                                      CASE WHEN v_rlbkMarkTimeId = r_step.rlbp_target_time_id THEN v_lastGlobalSeq      -- common case
                                           ELSE (SELECT time_last_emaj_gid FROM emaj.emaj_time_stamp
                                                   WHERE time_id = r_step.rlbp_target_time_id) END)
            INTO v_nbRows
            FROM emaj.emaj_relation
            WHERE rel_schema = r_step.rlbp_schema AND rel_tblseq = r_step.rlbp_table AND upper_inf(rel_time_range);
        WHEN 'SET_FK_IMM' THEN
-- set a foreign key immediate
          EXECUTE format('SET CONSTRAINTS %I.%I IMMEDIATE',
                         r_step.rlbp_schema, r_step.rlbp_object);
        WHEN 'ADD_FK' THEN
-- process a foreign key creation
          EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
                         r_step.rlbp_schema, r_step.rlbp_table, r_step.rlbp_object, r_step.rlbp_object_def);
        WHEN 'ENA_APP_TRG' THEN
-- process an application trigger enable
          EXECUTE format('ALTER TABLE %I.%I ENABLE %s TRIGGER %I',
                         r_step.rlbp_schema, r_step.rlbp_table, r_step.rlbp_object_def, r_step.rlbp_object);
        WHEN 'ENA_LOG_TRG' THEN
-- process a log trigger enable
          EXECUTE format('ALTER TABLE %I.%I ENABLE TRIGGER emaj_log_trg',
                         r_step.rlbp_schema, r_step.rlbp_table);
      END CASE;
-- update the emaj_rlbk_plan table to set the step duration
-- NB: the computed duration does not include the time needed to update the emaj_rlbk_plan table
      v_stmt = 'UPDATE emaj.emaj_rlbk_plan SET rlbp_duration = ' || quote_literal(clock_timestamp()) || ' - rlbp_start_datetime';
      IF r_step.rlbp_step = 'RLBK_TABLE' OR r_step.rlbp_step = 'DELETE_LOG' THEN
--   and the effective number of processed rows for RLBK_TABLE and DELETE_LOG steps
        v_stmt = v_stmt || ' , rlbp_quantity = ' || v_nbRows;
      END IF;
      v_stmt = v_stmt ||
               ' WHERE rlbp_rlbk_id = ' || v_rlbkId || ' AND rlbp_step = ' || quote_literal(r_step.rlbp_step) ||
               ' AND rlbp_schema = ' || quote_literal(r_step.rlbp_schema) ||
               ' AND rlbp_table = ' || quote_literal(r_step.rlbp_table) ||
               ' AND rlbp_object = ' || quote_literal(r_step.rlbp_object) || ' RETURNING 1';
      PERFORM emaj._dblink_sql_exec('rlbk#'||v_session, v_stmt, v_dblinkSchema);
    END LOOP;
-- update the emaj_rlbk_session table to set the timestamp representing the end of work for the session
    v_stmt = 'UPDATE emaj.emaj_rlbk_session SET rlbs_end_datetime = clock_timestamp()' ||
             ' WHERE rlbs_rlbk_id = ' || v_rlbkId || ' AND rlbs_session = ' || v_session ||
             ' RETURNING 1';
    PERFORM emaj._dblink_sql_exec('rlbk#'||v_session, v_stmt, v_dblinkSchema);
-- close the dblink connection, if any, for session > 1
    IF v_isDblinkUsed AND v_session > 1 THEN
      PERFORM emaj._dblink_close_cnx('rlbk#'||v_session, v_dblinkSchema);
    END IF;
    RETURN;
-- trap and record exception during the rollback operation
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN             -- Do not trap the exceptions raised by the function
      RAISE;
    WHEN OTHERS THEN                       -- Otherwise, log the E-Maj rollback abort in emaj_rlbk, if possible
      PERFORM emaj._rlbk_error(v_rlbkId, 'In _rlbk_session_exec() for session ' || v_session || ': ' || SQLERRM, 'rlbk#'||v_session);
      RAISE;
  END;
$_rlbk_session_exec$;

CREATE OR REPLACE FUNCTION emaj._rlbk_end(v_rlbkId INT, v_multiGroup BOOLEAN, OUT rlbk_severity TEXT, OUT rlbk_message TEXT)
RETURNS SETOF RECORD LANGUAGE plpgsql AS
$_rlbk_end$
-- This is the last step of a rollback group processing. It:
--    - deletes the marks that are no longer available,
--    - deletes the recorded sequences values for these deleted marks
--    - copy data into the emaj_rlbk_stat table,
--    - rollbacks all sequences of the groups,
--    - set the end rollback mark if logged rollback,
--    - and finaly set the operation as COMPLETED or COMMITED.
-- It returns the execution report of the rollback operation (a set of rows).
  DECLARE
    v_stmt                   TEXT;
    v_dblinkSchema           TEXT;
    v_isDblinkUsed           BOOLEAN;
    v_groupNames             TEXT[];
    v_mark                   TEXT;
    v_isLoggedRlbk           BOOLEAN;
    v_isAlterGroupAllowed    BOOLEAN;
    v_nbTbl                  INT;
    v_effNbTbl               INT;
    v_rlbkDatetime           TIMESTAMPTZ;
    v_ctrlDuration           INTERVAL;
    v_markTimeId             BIGINT;
    v_nbSeq                  INT;
    v_markName               TEXT;
    v_messages               TEXT;
    r_msg                    RECORD;
  BEGIN
-- get the rollback characteristics from the emaj_rlbk table
    SELECT rlbk_groups, rlbk_mark, rlbk_is_logged, rlbk_is_alter_group_allowed, rlbk_nb_table, rlbk_eff_nb_table,
           rlbk_dblink_schema, rlbk_is_dblink_used, time_clock_timestamp
      INTO v_groupNames, v_mark, v_isLoggedRlbk, v_isAlterGroupAllowed, v_nbTbl, v_effNbTbl,
           v_dblinkSchema, v_isDblinkUsed, v_rlbkDatetime
      FROM emaj.emaj_rlbk, emaj.emaj_time_stamp WHERE rlbk_time_id = time_id AND  rlbk_id = v_rlbkId;
-- get the mark timestamp for the 1st group (they all share the same timestamp)
    SELECT mark_time_id INTO v_markTimeId FROM emaj.emaj_mark
      WHERE mark_group = v_groupNames[1] AND mark_name = v_mark;
-- if "unlogged" rollback, delete all marks later than the now rolled back mark and the associated sequences
    IF NOT v_isLoggedRlbk THEN
-- get the highest mark time id of the mark used for rollback, for all groups
-- delete the marks that are suppressed by the rollback (the related sequences have been already deleted by rollback functions)
-- with a logging in the history
      WITH deleted AS (
        DELETE FROM emaj.emaj_mark
          WHERE mark_group = ANY (v_groupNames) AND mark_time_id > v_markTimeId
          RETURNING mark_time_id, mark_group, mark_name),
           sorted_deleted AS (                                       -- the sort is performed to produce stable results in regression tests
        SELECT mark_group, mark_name FROM deleted ORDER BY mark_time_id, mark_group)
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        SELECT CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END,
               'MARK DELETED', mark_group, 'mark ' || mark_name || ' is deleted' FROM sorted_deleted;
-- and reset the mark_log_rows_before_next column for the new last mark
      UPDATE emaj.emaj_mark SET mark_log_rows_before_next = NULL
        WHERE mark_group = ANY (v_groupNames)
          AND (mark_group, mark_time_id) IN                -- select only the last non deleted mark of each concerned group
              (SELECT mark_group, max(mark_time_id) FROM emaj.emaj_mark
               WHERE mark_group = ANY (v_groupNames) AND NOT mark_is_deleted GROUP BY mark_group);
-- the sequences related to the deleted marks can be also suppressed
--   delete first application sequences related data for the groups
      DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
        WHERE sequ_schema = rel_schema AND sequ_name = rel_tblseq AND upper_inf(rel_time_range)
          AND rel_group = ANY (v_groupNames) AND rel_kind = 'S'
          AND sequ_time_id > v_markTimeId
          AND lower(rel_time_range) <> sequ_time_id;
--   delete then emaj sequences related data for the groups
      DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
        WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND upper_inf(rel_time_range)
          AND rel_group = ANY (v_groupNames) AND rel_kind = 'r'
          AND sequ_time_id > v_markTimeId
          AND sequ_time_id <@ rel_time_range AND sequ_time_id <> lower(rel_time_range);
    END IF;
-- delete the now useless 'LOCK TABLE' steps from the emaj_rlbk_plan table
    v_stmt = 'DELETE FROM emaj.emaj_rlbk_plan ' ||
             ' WHERE rlbp_rlbk_id = ' || v_rlbkId || ' AND rlbp_step = ''LOCK_TABLE'' RETURNING 1';
    PERFORM emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema);
-- Prepare the CTRLxDBLINK pseudo step statistic by computing the global time spent between steps
    SELECT coalesce(sum(ctrl_duration),'0'::INTERVAL) INTO v_ctrlDuration FROM (
      SELECT rlbs_session, rlbs_end_datetime - min(rlbp_start_datetime) - sum(rlbp_duration) AS ctrl_duration
        FROM emaj.emaj_rlbk_session rlbs, emaj.emaj_rlbk_plan rlbp
        WHERE rlbp_rlbk_id = rlbs_rlbk_id AND rlbp_session = rlbs_session
          AND rlbs_rlbk_id = v_rlbkID
        GROUP BY rlbs_session, rlbs_end_datetime ) AS t;
-- report duration statistics into the emaj_rlbk_stat table
    v_stmt = 'INSERT INTO emaj.emaj_rlbk_stat (rlbt_step, rlbt_schema, rlbt_table, rlbt_object,' ||
             '      rlbt_rlbk_id, rlbt_quantity, rlbt_duration)' ||
--   copy elementary steps for RLBK_TABLE, DELETE_LOG, ADD_FK and SET_FK_IMM step types
--     (record the rlbp_estimated_quantity as reference for later forecast)
             '  SELECT rlbp_step, rlbp_schema, rlbp_table, rlbp_object, rlbp_rlbk_id,' ||
             '      rlbp_estimated_quantity, rlbp_duration' ||
             '    FROM emaj.emaj_rlbk_plan' ||
             '    WHERE rlbp_rlbk_id = ' || v_rlbkId ||
             '      AND rlbp_step IN (''RLBK_TABLE'',''DELETE_LOG'',''ADD_FK'',''SET_FK_IMM'') ' ||
             '  UNION ALL ' ||
--   for 6 other steps, aggregate other elementary steps into a global row for each step type
             '  SELECT rlbp_step, '''', '''', '''', rlbp_rlbk_id, ' ||
             '      count(*), sum(rlbp_duration)' ||
             '    FROM emaj.emaj_rlbk_plan' ||
             '    WHERE rlbp_rlbk_id = ' || v_rlbkId ||
             '      AND rlbp_step IN (''DIS_APP_TRG'',''DIS_LOG_TRG'',''DROP_FK'',''SET_FK_DEF'',''ENA_APP_TRG'',''ENA_LOG_TRG'') ' ||
             '    GROUP BY 1, 2, 3, 4, 5' ||
             '  UNION ALL ' ||
--   and the final CTRLxDBLINK pseudo step statistic
             '  SELECT rlbp_step, '''', '''', '''', rlbp_rlbk_id, ' ||
             '      rlbp_estimated_quantity, ' || quote_literal(v_ctrlDuration) ||
             '    FROM emaj.emaj_rlbk_plan' ||
             '    WHERE rlbp_rlbk_id = ' || v_rlbkId ||
             '      AND rlbp_step IN (''CTRL+DBLINK'',''CTRL-DBLINK'') ' ||
             ' RETURNING 1';
    PERFORM emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema);
-- rollback the application sequences belonging to the groups
-- warning, this operation is not transaction safe (that's why it is placed at the end of the operation)!
-- if the sequence has been added to its group after the target rollback mark, rollback up to the corresponding alter_group time
    PERFORM emaj._rlbk_seq(t.*, greatest(v_markTimeId, lower(t.rel_time_range)))
      FROM (SELECT * FROM emaj.emaj_relation
              WHERE upper_inf(rel_time_range) AND rel_group = ANY (v_groupNames) AND rel_kind = 'S'
              ORDER BY rel_schema, rel_tblseq) as t;
    GET DIAGNOSTICS v_nbSeq = ROW_COUNT;
-- if rollback is "logged" rollback, automatically set a mark representing the tables state just after the rollback.
-- this mark is named 'RLBK_<mark name to rollback to>_%_DONE', where % represents the rollback start time
    IF v_isLoggedRlbk THEN
      v_markName = 'RLBK_' || v_mark || '_' || substring(to_char(v_rlbkDatetime, 'HH24.MI.SS.US') from 1 for 13) || '_DONE';
      PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, TRUE, v_mark);
    END IF;
-- build and return the execution report
-- start with the NOTICE messages
    rlbk_severity = 'Notice';
    rlbk_message = format ('%s / %s tables effectively processed.', v_effNbTbl::TEXT, v_nbTbl::TEXT);
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'NOTICE', 'Rollback id ' || v_rlbkId, rlbk_message);
    v_messages = quote_literal(rlbk_severity || ': ' || rlbk_message);
    IF v_isAlterGroupAllowed IS NULL THEN
-- for old style calling functions just return the number of processed tables and sequences
      rlbk_message = (v_effNbTbl + v_nbSeq)::TEXT;
      RETURN NEXT;
    ELSE
      RETURN NEXT;
    END IF;
-- return the execution report to new style calling functions
-- ... the general notice messages with counters
    IF v_nbSeq > 0 THEN
      rlbk_message = format ('%s sequences processed.', v_nbSeq::TEXT);
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'NOTICE',
                'Rollback id ' || v_rlbkId, rlbk_message);
      v_messages = concat(v_messages, ',', quote_literal(rlbk_severity || ': ' || rlbk_message));
      IF v_isAlterGroupAllowed IS NOT NULL THEN
        RETURN NEXT;
      END IF;
    END IF;
-- then, for new style calling functions, return the WARNING messages for any elementary action from alter group operations that has not
-- been rolled back
    IF v_isAlterGroupAllowed IS NOT NULL THEN
      rlbk_severity = 'Warning';
      FOR r_msg IN
-- steps are splitted into 2 groups to filter them differently
        SELECT altr_time_id, altr_step, altr_schema, altr_tblseq,
               (CASE altr_step
                  WHEN 'ADD_SEQ' THEN
                    'The sequence ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq) ||
                    ' has only been rolled back to its latest group attachment state ('
                    || to_char(time_tx_timestamp, 'YYYY/MM/DD HH:MI:SS TZ') || ')'
                  WHEN 'ADD_TBL' THEN
                    'The table ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq) ||
                    ' has only been rolled back to its latest group attachment ('
                    || to_char(time_tx_timestamp, 'YYYY/MM/DD HH:MI:SS TZ') || ')'
                  WHEN 'REMOVE_SEQ' THEN
                    'The sequence ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq) ||
                    ' has been left unchanged (not in group anymore since ' || to_char(time_tx_timestamp, 'YYYY/MM/DD HH:MI:SS TZ') || ')'
                  WHEN 'REMOVE_TBL' THEN
                    'The table ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq) ||
                    ' has been left unchanged (not in group anymore since ' || to_char(time_tx_timestamp, 'YYYY/MM/DD HH:MI:SS TZ') || ')'
                  WHEN 'MOVE_SEQ' THEN
                    'The sequence ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq) ||
                    ' has only been rolled back to its latest group attachment state ('
                    || to_char(time_tx_timestamp, 'YYYY/MM/DD HH:MI:SS TZ') || ')'
                  WHEN 'MOVE_TBL' THEN
                    'The table ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq) ||
                    ' has only been rolled back to its latest group attachment ('
                    || to_char(time_tx_timestamp, 'YYYY/MM/DD HH:MI:SS TZ') || ')'
                  END)::TEXT AS message
            FROM (
-- suppress duplicate ADD_TBL / REMOVE_TBL or ADD_SEQ / REMOVE_SEQ for same table or sequence, by keeping the most recent step
              SELECT altr_schema, altr_tblseq, altr_time_id, altr_step FROM (
                SELECT altr_schema, altr_tblseq, altr_time_id, altr_step,
                       rank() OVER (PARTITION BY altr_schema, altr_tblseq ORDER BY altr_time_id DESC) AS altr_rank
                FROM emaj.emaj_alter_plan
                WHERE altr_time_id > v_markTimeId AND altr_group = ANY (v_groupNames) AND altr_tblseq <> '' AND altr_rlbk_id IS NULL AND
                      altr_step IN ('ADD_TBL','ADD_SEQ','REMOVE_TBL','REMOVE_SEQ','MOVE_TBL','MOVE_SEQ')
                ) AS t1
              WHERE altr_rank = 1
            ) AS t2, emaj.emaj_time_stamp
          WHERE altr_time_id = time_id
        UNION
        SELECT altr_time_id, altr_step, altr_schema, altr_tblseq,
               (CASE altr_step
                  WHEN 'CHANGE_REL_PRIORITY' THEN
                    'Tables group change not rolled back: E-Maj priority for '
                    || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq)
                  WHEN 'CHANGE_TBL_LOG_SCHEMA' THEN
                    'Tables group change not rolled back: E-Maj log schema for '
                    || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq)
                  WHEN 'CHANGE_TBL_NAMES_PREFIX' THEN
                    'Tables group change not rolled back: E-Maj names prefix for '
                    || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq)
                  WHEN 'CHANGE_TBL_LOG_DATA_TSP' THEN
                    'Tables group change not rolled back: log data tablespace for '
                    || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq)
                  WHEN 'CHANGE_TBL_LOG_INDEX_TSP' THEN
                    'Tables group change not rolled back: log index tablespace for '
                    || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq)
                  ELSE altr_step::TEXT || ' / ' || quote_ident(altr_schema) || '.' || quote_ident(altr_tblseq)
                  END)::TEXT AS message
            FROM (
-- suppress duplicates for other steps for each table or sequence
              SELECT altr_schema, altr_tblseq, altr_time_id, altr_step FROM (
                SELECT altr_schema, altr_tblseq, altr_time_id, altr_step,
                       rank() OVER (PARTITION BY altr_schema, altr_tblseq ORDER BY altr_time_id DESC) AS altr_rank
                FROM emaj.emaj_alter_plan
                WHERE altr_time_id > v_markTimeId AND altr_group = ANY (v_groupNames) AND altr_tblseq <> '' AND altr_rlbk_id IS NULL AND
                      altr_step NOT IN ('ADD_TBL','ADD_SEQ','REMOVE_TBL','REMOVE_SEQ','MOVE_TBL','MOVE_SEQ')
                ) AS t1
              WHERE altr_rank = 1
            ) AS t2
          ORDER BY altr_time_id, altr_step, altr_schema, altr_tblseq
      LOOP
          INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
            VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'WARNING', 'Rollback id ' || v_rlbkId,
                    r_msg.message);
          rlbk_message = r_msg.message;
          v_messages = concat(v_messages, ',', quote_literal(rlbk_severity || ': ' || rlbk_message));
          RETURN NEXT;
      END LOOP;
    END IF;
-- update the alter steps that have been covered by the rollback
    UPDATE emaj.emaj_alter_plan SET altr_rlbk_id = v_rlbkId
      WHERE altr_time_id > v_markTimeId AND altr_group = ANY (v_groupNames) AND altr_rlbk_id IS NULL;
-- update the emaj_rlbk table to set the real number of tables to process, adjust the rollback status and set the result message
    v_stmt = 'UPDATE emaj.emaj_rlbk SET rlbk_status = '''
          || CASE WHEN v_isDblinkUsed THEN 'COMPLETED' ELSE 'COMMITTED' END
          || ''', rlbk_end_datetime = clock_timestamp(), rlbk_messages = ARRAY[' || v_messages || ']' ||
               ' WHERE rlbk_id = ' || v_rlbkId || ' RETURNING 1';
    PERFORM emaj._dblink_sql_exec('rlbk#1', v_stmt, v_dblinkSchema);
-- close the dblink connection, if any
    IF v_isDblinkUsed THEN
      PERFORM emaj._dblink_close_cnx('rlbk#1', v_dblinkSchema);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'END',
              array_to_string(v_groupNames,','),
              'Rollback_id ' || v_rlbkId || ', ' || v_effNbTbl || ' tables and ' || v_nbSeq || ' sequences effectively processed'
             );
-- end of the function
    RETURN;
-- trap and record exception during the rollback operation
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN             -- Do not trap the exceptions raised by the function
      RAISE;
    WHEN OTHERS THEN                       -- Otherwise, log the E-Maj rollback abort in emaj_rlbk, if possible
      PERFORM emaj._rlbk_error(v_rlbkId, 'In _rlbk_end(): ' || SQLERRM, 'rlbk#1');
      RAISE;
  END;
$_rlbk_end$;

CREATE OR REPLACE FUNCTION emaj._rlbk_error(v_rlbkId INT, v_msg TEXT, v_cnxName TEXT)
RETURNS VOID LANGUAGE plpgsql AS
$_rlbk_error$
-- This function records a rollback error into the emaj_rlbk table, but only if a dblink connection is open.
-- Input: rollback identifier, message to record and dblink connection name.
-- If the rollback operation is already in aborted state, one keeps the emaj_rlbk data unchanged.
  DECLARE
    v_isDblinkUsed           BOOLEAN;
    v_dblinkSchema           TEXT;
    v_stmt                   TEXT;
  BEGIN
-- get the dblink usage characteristics for the current rollback
    SELECT rlbk_is_dblink_used, rlbk_dblink_schema
      INTO v_isDblinkUsed, v_dblinkSchema
      FROM emaj.emaj_rlbk WHERE rlbk_id = v_rlbkId;
-- if a dblink connection is open, update the emaj_rlbk table
    IF v_isDblinkUsed THEN
      v_stmt = 'UPDATE emaj.emaj_rlbk SET rlbk_status = ''ABORTED'', rlbk_messages = ARRAY[' || quote_literal(v_msg) ||
                '], rlbk_end_datetime =  clock_timestamp() ' ||
               'WHERE rlbk_id = ' || v_rlbkId || ' AND rlbk_status <> ''ABORTED'' RETURNING 1';
      PERFORM emaj._dblink_sql_exec(v_cnxName, v_stmt, v_dblinkSchema);
    END IF;
    RETURN;
  END;
$_rlbk_error$;

CREATE OR REPLACE FUNCTION emaj.emaj_cleanup_rollback_state()
RETURNS INT LANGUAGE plpgsql AS
$emaj_cleanup_rollback_state$
-- This function sets the status of not yet "COMMITTED" or "ABORTED" rollback events.
-- To perform its tasks, it just calls the _cleanup_rollback_state() function.
-- Input: no parameter
-- Output: number of updated rollback events
  BEGIN
    RETURN emaj._cleanup_rollback_state();
  END;
$emaj_cleanup_rollback_state$;
COMMENT ON FUNCTION emaj.emaj_cleanup_rollback_state() IS
$$Sets the status of pending E-Maj rollback events.$$;

CREATE OR REPLACE FUNCTION emaj._cleanup_rollback_state()
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_cleanup_rollback_state$
-- This function effectively cleans the rollback states up. It is called by the emaj_cleanup_rollback_state()
-- and by other emaj functions.
-- The rollbacks whose transaction(s) is/are active are left as is.
-- Among the others, those which are also visible in the emaj_hist table are set "COMMITTED",
--   while those which are not visible in the emaj_hist table are set "ABORTED".
-- Input: no parameter
-- Output: number of updated rollback events
  DECLARE
    v_nbRlbk                 INT = 0;
    v_newStatus              emaj._rlbk_status_enum;
    r_rlbk                   RECORD;
  BEGIN
-- scan all pending rollback events having all their session transactions completed (either committed or rolled back)
    FOR r_rlbk IN
      SELECT rlbk_id, rlbk_status, rlbk_begin_hist_id, rlbk_nb_session, count(rlbs_txid) AS nbVisibleTx
        FROM emaj.emaj_rlbk
             LEFT OUTER JOIN emaj.emaj_rlbk_session ON
               (    rlbk_id = rlbs_rlbk_id                                      -- main join condition
                AND txid_visible_in_snapshot(rlbs_txid,txid_current_snapshot()) -- only visible tx
                AND rlbs_txid <> txid_current()                                 -- exclude the current tx
               )
        WHERE rlbk_status IN ('PLANNING', 'LOCKING', 'EXECUTING', 'COMPLETED')  -- only pending rollback events
        GROUP BY rlbk_id, rlbk_status, rlbk_begin_hist_id, rlbk_nb_session
        HAVING count(rlbs_txid) = rlbk_nb_session                               -- all sessions tx must be visible
        ORDER BY rlbk_id
    LOOP
-- look at the emaj_hist to find the trace of the rollback begin event
      PERFORM 0 FROM emaj.emaj_hist WHERE hist_id = r_rlbk.rlbk_begin_hist_id;
      IF FOUND THEN
-- if the emaj_hist rollback_begin event is visible, the rollback transaction has been committed.
-- then set the rollback event in emaj_rlbk as "COMMITTED"
        v_newStatus = 'COMMITTED';
      ELSE
-- otherwise, set the rollback event in emaj_rlbk as "ABORTED"
        v_newStatus = 'ABORTED';
      END IF;
      UPDATE emaj.emaj_rlbk SET rlbk_status = v_newStatus WHERE rlbk_id = r_rlbk.rlbk_id;
      INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
        VALUES ('CLEANUP_RLBK_STATE', 'Rollback id ' || r_rlbk.rlbk_id, 'set to ' || v_newStatus);
      v_nbRlbk = v_nbRlbk + 1;
    END LOOP;
    RETURN v_nbRlbk;
  END;
$_cleanup_rollback_state$;

CREATE OR REPLACE FUNCTION emaj.emaj_consolidate_rollback_group(v_groupName TEXT, v_endRlbkMark TEXT)
RETURNS BIGINT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$emaj_consolidate_rollback_group$
-- This function "consolidates" a rollback for a group. It transforms an already completed logged rollback into an unlogged rollback.
-- All marks and update logs between a mark used as reference by an unlogged rollback operation and the final mark set by this rollback
-- are suppressed.
-- The group may be in any state (logging or idle).
-- Input: group name, name of the final mark set by the rollback operation to consolidate
-- Output: number of sequences and tables effectively processed
  DECLARE
    v_firstMark              TEXT;
    v_lastMark               TEXT;
    v_nbMark                 INT;
    v_nbTbl                  INT;
    v_nbSeq                  INT;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := '');
-- check the supplied end rollback mark name
    SELECT emaj._check_mark_name(v_groupNames := ARRAY[v_groupName], v_mark := v_endRlbkMark, v_checkList := '') INTO v_lastMark;
-- check that no group is damaged
    PERFORM 0 FROM emaj._verify_groups(ARRAY[v_groupName], TRUE);
-- check the supplied mark is known as an end rollback mark
    SELECT mark_logged_rlbk_target_mark INTO v_firstMark FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_name = v_lastMark;
    IF v_firstMark IS NULL THEN
      RAISE EXCEPTION 'emaj_consolidate_rollback_group: The mark "%" for the group "%" is not an end rollback mark.',
        v_lastMark, v_groupName;
    END IF;
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('CONSOLIDATE_RLBK_GROUP', 'BEGIN', v_groupName, 'Erase all between marks ' || v_firstMark || ' and ' || v_lastMark);
-- check the first mark really exists (it should, because deleting or renaming a mark must update the mark_logged_rlbk_mark_name column)
    PERFORM 1 FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_firstMark;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_consolidate_rollback_group: The rollback target mark "%" for the group "%" has not been found.',
        v_firstMark, v_groupName;
    END IF;
-- perform the consolidation operation
    SELECT * FROM emaj._delete_between_marks_group(v_groupName, v_firstMark, v_lastMark) INTO v_nbMark, v_nbTbl;
-- get the number of sequences belonging to the group
    SELECT group_nb_sequence INTO v_nbSeq FROM emaj.emaj_group WHERE group_name = v_groupName;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('CONSOLIDATE_RLBK_GROUP', 'END', v_groupName,
              v_nbTbl || ' tables and ' || v_nbSeq || ' sequences processed ; ' || v_nbMark || ' marks deleted');
    RETURN v_nbTbl + v_nbSeq;
  END;
$emaj_consolidate_rollback_group$;
COMMENT ON FUNCTION emaj.emaj_consolidate_rollback_group(TEXT,TEXT) IS
$$Consolidate a rollback for a group.$$;

CREATE OR REPLACE FUNCTION emaj._delete_between_marks_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT,
                                                            OUT v_nbMark INT, OUT v_nbTbl INT)
RETURNS RECORD LANGUAGE plpgsql AS
$_delete_between_marks_group$
-- This function deletes all logs and intermediate marks set between two given marks.
-- The function is called by the emaj_consolidate_rollback_group() function.
-- It deletes rows corresponding to the marks to delete from emaj_mark and emaj_sequence.
-- It deletes rows from emaj_relation corresponding to old versions that become unreacheable.
-- It deletes rows from all concerned log tables.
-- It also manages sequence holes in emaj_seq_hole.
-- Input: group name, name of both marks that defines the range to delete.
-- Output: number of deleted marks, number of tables effectively processed (for which at least one log row has been deleted)
  DECLARE
    v_firstMarkGlobalSeq     BIGINT;
    v_firstMarkTimeId        BIGINT;
    v_lastMarkGlobalSeq      BIGINT;
    v_lastMarkTimeId         BIGINT;
    v_nbUpd                  BIGINT;
    r_rel                    RECORD;
  BEGIN
-- retrieve the timestamp and the emaj_gid value and the time stamp id of the first mark
    SELECT time_last_emaj_gid, mark_time_id INTO v_firstMarkGlobalSeq, v_firstMarkTimeId
      FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupName AND mark_name = v_firstMark;
-- retrieve the timestamp and the emaj_gid value and the time stamp id of the last mark
    SELECT time_last_emaj_gid, mark_time_id INTO v_lastMarkGlobalSeq, v_lastMarkTimeId
      FROM emaj.emaj_mark, emaj.emaj_time_stamp
      WHERE mark_time_id = time_id AND mark_group = v_groupName AND mark_name = v_lastMark;
-- delete rows from all log tables (no need to try to delete if v_firstMarkGlobalSeq and v_lastMarkGlobalSeq are equal)
    v_nbTbl = 0;
    IF v_firstMarkGlobalSeq < v_lastMarkGlobalSeq THEN
-- loop on all tables that belonged to the group at the end of the period
      FOR r_rel IN
          SELECT quote_ident(rel_log_schema) || '.' || quote_ident(rel_log_table) AS log_table_name FROM emaj.emaj_relation
            WHERE rel_group = v_groupName AND rel_kind = 'r'
              AND rel_time_range @> v_lastMarkTimeId
            ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
-- delete log rows
        EXECUTE format('DELETE FROM %s WHERE emaj_gid > $1 AND emaj_gid <= $2',
                       r_rel.log_table_name)
          USING v_firstMarkGlobalSeq, v_lastMarkGlobalSeq;
        GET DIAGNOSTICS v_nbUpd = ROW_COUNT;
        IF v_nbUpd > 0 THEN
           v_nbTbl = v_nbTbl + 1;
        END IF;
      END LOOP;
    END IF;
-- process emaj_seq_hole content
-- delete all existing holes (if any) between both marks for tables that belonged to the group at the end of the period
    DELETE FROM emaj.emaj_seq_hole USING emaj.emaj_relation
      WHERE rel_group = v_groupName AND rel_kind = 'r' AND rel_time_range @> v_lastMarkTimeId
        AND rel_schema = sqhl_schema AND rel_tblseq = sqhl_table
        AND sqhl_begin_time_id >= v_firstMarkTimeId AND sqhl_begin_time_id < v_lastMarkTimeId;
-- create holes representing the deleted logs
    INSERT INTO emaj.emaj_seq_hole (sqhl_schema, sqhl_table, sqhl_begin_time_id, sqhl_end_time_id, sqhl_hole_size)
      SELECT rel_schema, rel_tblseq, greatest(v_firstMarkTimeId, lower(rel_time_range)), v_lastMarkTimeId,
             (SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END FROM emaj.emaj_sequence
                WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND sequ_time_id = v_lastMarkTimeId)
             -
             (SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END FROM emaj.emaj_sequence
                WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence
                  AND sequ_time_id = greatest(v_firstMarkTimeId, lower(rel_time_range)))
        FROM emaj.emaj_relation
        WHERE rel_group = v_groupName AND rel_kind = 'r' AND rel_time_range @> v_lastMarkTimeId
          AND 0 <
             (SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END FROM emaj.emaj_sequence
                WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND sequ_time_id = v_lastMarkTimeId)
             -
             (SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END FROM emaj.emaj_sequence
                WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence
                  AND sequ_time_id = greatest(v_firstMarkTimeId, lower(rel_time_range)));
-- now the sequences related to the mark to delete can be suppressed
--   delete first application sequences related data for the group (excluding the time range bounds)
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_schema AND sequ_name = rel_tblseq AND rel_time_range @> v_lastMarkTimeId
        AND rel_group = v_groupName AND rel_kind = 'S'
        AND sequ_time_id > v_firstMarkTimeId AND sequ_time_id < v_lastMarkTimeId
        AND lower(rel_time_range) <> sequ_time_id;
--   delete then emaj sequences related data for the group (excluding the time range bounds)
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence AND rel_time_range @> v_lastMarkTimeId
        AND rel_group = v_groupName AND rel_kind = 'r'
        AND sequ_time_id > v_firstMarkTimeId AND sequ_time_id < v_lastMarkTimeId
        AND sequ_time_id <@ rel_time_range AND sequ_time_id <> lower(rel_time_range);
-- in emaj_mark, reset the mark_logged_rlbk_target_mark column to null for marks of the group that will remain
--    and that may have one of the deleted marks as target mark from a previous logged rollback operation
    UPDATE emaj.emaj_mark SET mark_logged_rlbk_target_mark = NULL
      WHERE mark_group = v_groupName AND mark_time_id >= v_lastMarkTimeId
        AND mark_logged_rlbk_target_mark IN (
            SELECT mark_name FROM emaj.emaj_mark
              WHERE mark_group = v_groupName AND mark_time_id > v_firstMarkTimeId AND mark_time_id < v_lastMarkTimeId
            );
-- set the mark_log_rows_before_next of the first mark to 0
    UPDATE emaj.emaj_mark SET mark_log_rows_before_next = 0
      WHERE mark_group = v_groupName AND mark_name = v_firstMark;
-- and finaly delete all intermediate marks
    DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_time_id > v_firstMarkTimeId AND mark_time_id < v_lastMarkTimeId;
    GET DIAGNOSTICS v_nbMark = ROW_COUNT;
    RETURN;
  END;
$_delete_between_marks_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_get_consolidable_rollbacks()
RETURNS SETOF emaj.emaj_consolidable_rollback_type LANGUAGE plpgsql AS
$emaj_get_consolidable_rollbacks$
-- This function returns the list of logged rollback operations that can be consolidated, defined as a marks range for a group.
-- It doesn't need input parameter.
-- It returns a set of emaj_consolidable_rollback_type records, sorted by ascending rollback time.
-- The cons_group and cons_end_rlbk_mark_name returned columns can be used as input parameters for the emaj_consolidate_rollback_group()
-- function.
  BEGIN
-- search and return all marks range corresponding to any logged rollback operation
    RETURN QUERY
      SELECT m1.mark_group AS cons_group,
             m2.mark_name AS cons_target_rlbk_mark_name, m2.mark_time_id AS cons_target_rlbk_mark_time_id,
             m1.mark_name AS cons_end_rlbk_mark_name, m1.mark_time_id AS cons_end_rlbk_mark_time_id,
             cast(coalesce(
                  (SELECT sum(emaj._log_stat_tbl(emaj_relation,
                                                 greatest(m2.mark_time_id, lower(rel_time_range)),
                                                 m1.mark_time_id))
                     FROM emaj.emaj_relation
                           -- for tables belonging to the group at the rollback time
                     WHERE rel_group = m1.mark_group AND rel_kind = 'r' AND rel_time_range @> m1.mark_time_id)
                          ,0) AS BIGINT) AS cons_rows,
             cast((SELECT count(*) FROM emaj.emaj_mark m3
                   WHERE m3.mark_group = m1.mark_group AND m3.mark_time_id > m2.mark_time_id
                     AND m3.mark_time_id < m1.mark_time_id) AS INT) AS cons_marks
        FROM emaj.emaj_mark m1
          JOIN emaj.emaj_mark m2 ON (m2.mark_name = m1.mark_logged_rlbk_target_mark AND m2.mark_group = m1.mark_group)
          WHERE m1.mark_logged_rlbk_target_mark IS NOT NULL
          ORDER BY m1.mark_time_id;
  END;
$emaj_get_consolidable_rollbacks$;
COMMENT ON FUNCTION emaj.emaj_get_consolidable_rollbacks() IS
$$Returns the list of logged rollback operations that can be consolidated.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_reset_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$emaj_reset_group$
-- This function empties the log tables for all tables of a group and deletes the sequences saves.
-- It calls the emaj_rst_group function to do the job.
-- Input: group name
-- Output: number of processed tables
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables.
  DECLARE
    v_nbTb                   INT = 0;
    v_eventTriggers          TEXT[];
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('RESET_GROUP', 'BEGIN', v_groupName);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := TRUE, v_checkList := 'IDLE');
-- perform the reset operation
    SELECT emaj._reset_groups(ARRAY[v_groupName]) INTO v_nbTb;
-- drop the log schemas that would have been emptied by the _reset_groups() call
    SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
    PERFORM emaj._drop_log_schemas('RESET_GROUP', FALSE);
    PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('RESET_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_reset_group$;
COMMENT ON FUNCTION emaj.emaj_reset_group(TEXT) IS
$$Resets all log tables content of a stopped E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj._reset_groups(v_groupNames TEXT[])
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_reset_groups$
-- This function empties the log tables for all tables of a group, using a TRUNCATE, and deletes the sequences images.
-- It is called by emaj_reset_group(), emaj_start_group() and emaj_alter_group() functions.
-- Input: group names array
-- Output: number of processed tables and sequences
-- There is no check of the groups state (this is done by callers).
-- The function is defined as SECURITY DEFINER so that an emaj_adm role can truncate log tables.
  DECLARE
    v_eventTriggers          TEXT[];
    r_rel                    RECORD;
  BEGIN
-- disable event triggers that protect emaj components and keep in memory these triggers name
    SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- delete all marks for the groups from the emaj_mark table
    DELETE FROM emaj.emaj_mark WHERE mark_group = ANY (v_groupNames);
-- delete emaj_sequence rows related to the tables of the groups
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation r1
      WHERE sequ_schema = rel_log_schema AND sequ_name = rel_log_sequence
        AND rel_group = ANY (v_groupNames) AND rel_kind = 'r'
        AND ((sequ_time_id <@ rel_time_range               -- all log sequences inside the relation time range
             AND (sequ_time_id <> lower(rel_time_range)    -- except the lower bound if
                  OR NOT EXISTS(                           --   it is the upper bound of another time range for another group
                     SELECT 1 FROM emaj.emaj_relation r2
                       WHERE r2.rel_log_schema = sequ_schema AND r2.rel_log_sequence = sequ_name
                         AND upper(r2.rel_time_range) = sequ_time_id
                         AND NOT (r2.rel_group = ANY (v_groupNames)) )))
         OR (sequ_time_id = upper(rel_time_range)          -- but including the upper bound if
                  AND NOT EXISTS (                         --   it is not the lower bound of another time range (for any group)
                     SELECT 1 FROM emaj.emaj_relation r3
                       WHERE r3.rel_log_schema = sequ_schema AND r3.rel_log_sequence = sequ_name
                         AND lower(r3.rel_time_range) = sequ_time_id))
            );
-- delete all sequence holes for the tables of the groups
-- (it may delete holes for timeranges that do not belong to the group, if a table has been moved to another group,
--  but is safe enough for rollbacks)
    DELETE FROM emaj.emaj_seq_hole USING emaj.emaj_relation
      WHERE rel_schema = sqhl_schema AND rel_tblseq = sqhl_table
        AND rel_group = ANY (v_groupNames) AND rel_kind = 'r';
-- drop obsolete log tables (but keep those linked to other groups)
    FOR r_rel IN
          SELECT DISTINCT rel_log_schema, rel_log_table FROM emaj.emaj_relation
            WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r' AND NOT upper_inf(rel_time_range)
        EXCEPT
          SELECT rel_log_schema, rel_log_table FROM emaj.emaj_relation
            WHERE rel_kind = 'r'
              AND (upper_inf(rel_time_range) OR NOT rel_group = ANY (v_groupNames))
          ORDER BY 1,2
    LOOP
      EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE',
                     r_rel.rel_log_schema, r_rel.rel_log_table);
    END LOOP;
-- delete emaj_sequence rows related to the sequences of the groups
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE sequ_schema = rel_schema AND sequ_name = rel_tblseq
        AND rel_group = ANY (v_groupNames) AND rel_kind = 'S'
        AND ((sequ_time_id <@ rel_time_range               -- all application sequences inside the relation time range
             AND (sequ_time_id <> lower(rel_time_range)    -- except the lower bound if
                  OR NOT EXISTS(                           --   it is the upper bound of another time range for another group
                     SELECT 1 FROM emaj.emaj_relation r2
                       WHERE r2.rel_schema = sequ_schema AND r2.rel_tblseq = sequ_name AND upper(r2.rel_time_range) = sequ_time_id
                         AND NOT (r2.rel_group = ANY (v_groupNames)) )))
         OR (sequ_time_id = upper(rel_time_range)          -- including the upper bound if
                  AND NOT EXISTS (                         --   it is not the lower bound of another time range for another group
                     SELECT 1 FROM emaj.emaj_relation r3
                       WHERE r3.rel_schema = sequ_schema AND r3.rel_tblseq = sequ_name AND lower(r3.rel_time_range) = sequ_time_id))
            );
-- keep a trace of the relation group ownership history
--   and finaly delete the old versions of emaj_relation rows (those with a not infinity upper bound)
    WITH deleted AS (
      DELETE FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groupNames) AND NOT upper_inf(rel_time_range)
        RETURNING rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind
      )
    INSERT INTO emaj.emaj_rel_hist
             (relh_schema, relh_tblseq, relh_time_range, relh_group, relh_kind)
      SELECT rel_schema, rel_tblseq, rel_time_range, rel_group, rel_kind
        FROM deleted;
-- truncate remaining log tables for application tables
    FOR r_rel IN
        SELECT rel_log_schema, rel_log_table, rel_log_sequence FROM emaj.emaj_relation
          WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r'
          ORDER BY rel_priority, rel_schema, rel_tblseq
    LOOP
--   truncate the log table
      EXECUTE format('TRUNCATE %I.%I',
                     r_rel.rel_log_schema, r_rel.rel_log_table);
    END LOOP;
-- enable previously disabled event triggers
    PERFORM emaj._enable_event_triggers(v_eventTriggers);
    RETURN sum(group_nb_table)+sum(group_nb_sequence) FROM emaj.emaj_group WHERE group_name = ANY (v_groupNames);
  END;
$_reset_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_log_stat_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj.emaj_log_stat_type LANGUAGE plpgsql AS
$emaj_log_stat_group$
-- This function returns statistics on row updates executed between 2 marks or between a mark and the current situation for a single group.
-- It is used to quickly get simple statistics of updates logged between 2 marks (i.e. for one or several processing).
-- Input: group name, the 2 mark names defining a range
-- Output: set of log rows by table (including tables with 0 rows to rollback)
  BEGIN
    RETURN QUERY
      SELECT stat_group, stat_schema, stat_table, stat_first_mark, stat_first_mark_datetime, stat_last_mark,
             stat_last_mark_datetime, stat_rows
        FROM emaj._log_stat_groups(ARRAY[v_groupName], FALSE, v_firstMark, v_lastMark);
  END;
$emaj_log_stat_group$;
COMMENT ON FUNCTION emaj.emaj_log_stat_group(TEXT,TEXT,TEXT) IS
$$Returns global statistics about logged events for an E-Maj group between 2 marks for a single group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_log_stat_groups(v_groupNames TEXT[], v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj.emaj_log_stat_type LANGUAGE plpgsql AS
$emaj_log_stat_groups$
-- This function returns statistics on row updates executed between 2 marks or between a mark and the current situation for a groups array.
-- It is used to quickly get simple statistics of updates logged between 2 marks (i.e. for one or several processing).
-- Input: group names array, the 2 mark names defining a range
-- Output: set of log rows by table (including tables with 0 rows to rollback)
  BEGIN
    RETURN QUERY
      SELECT stat_group, stat_schema, stat_table, stat_first_mark, stat_first_mark_datetime, stat_last_mark,
             stat_last_mark_datetime, stat_rows
        FROM emaj._log_stat_groups(v_groupNames, TRUE, v_firstMark, v_lastMark);
  END;
$emaj_log_stat_groups$;
COMMENT ON FUNCTION emaj.emaj_log_stat_groups(TEXT[],TEXT,TEXT) IS
$$Returns global statistics about logged events for an E-Maj group between 2 marks for a groups array.$$;

CREATE OR REPLACE FUNCTION emaj._log_stat_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj._log_stat_type LANGUAGE plpgsql AS
$_log_stat_groups$
-- This function effectively returns statistics on row updates executed between 2 marks or between a mark and the current situation for 1
-- or several groups.
-- These statistics are computed using the serial id of log tables and holes is sequences recorded into emaj_seq_hole at rollback time.
-- The function is directly called by Emaj_web.
-- Input: groups name array, a boolean indicating whether the calling function is a multi_groups function, the 2 mark names defining a
--          range
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string as last_mark indicates the current situation
--   Use a NULL or an empty string as last_mark to know the number of rows to rollback to reach the mark specified by the first_mark
--   parameter.
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark for the groups.
-- Output: set of log rows by table (including tables with 0 rows to rollback)
-- This function may be directly called by the Emaj_web client.
  DECLARE
    v_firstMarkTimeId        BIGINT;
    v_lastMarkTimeId         BIGINT;
    v_firstMarkTs            TIMESTAMPTZ;
    v_lastMarkTs             TIMESTAMPTZ;
    v_firstEmajGid           BIGINT;
    v_lastEmajGid            BIGINT;
  BEGIN
-- check the groups name
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := FALSE, v_checkList := '')
      INTO v_groupNames;
    IF v_groupNames IS NOT NULL THEN
-- check the marks range
      SELECT * FROM emaj._check_marks_range(v_groupNames, v_firstMark, v_lastMark)
        INTO v_firstMark, v_lastMark, v_firstMarkTimeId, v_lastMarkTimeId;
-- get additional data for both mark timestamps (in some cases, v_firstMarkTimeId may be NULL)
      SELECT time_clock_timestamp, time_last_emaj_gid INTO v_firstMarkTs, v_firstEmajGid
        FROM emaj.emaj_time_stamp WHERE time_id = v_firstMarkTimeId;
      IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
        SELECT time_clock_timestamp, time_last_emaj_gid INTO v_lastMarkTs, v_lastEmajGid
          FROM emaj.emaj_time_stamp WHERE time_id = v_lastMarkTimeId;
      END IF;
-- for each table of the group, get the number of log rows and return the statistics
-- shorten the timeframe if the table did not belong to the group on the entire requested time frame
      RETURN QUERY
        SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table,
               CASE WHEN v_firstMarkTimeId IS NULL THEN NULL
                    WHEN v_firstMarkTimeId >= lower(rel_time_range) THEN v_firstMark
                    ELSE coalesce((SELECT mark_name FROM emaj.emaj_mark
                            WHERE mark_time_id = lower(rel_time_range) AND mark_group = rel_group),'[deleted mark]')
                 END AS stat_first_mark,
               CASE WHEN v_firstMarkTimeId IS NULL THEN NULL
                    WHEN v_firstMarkTimeId >= lower(rel_time_range) THEN v_firstMarkTs
                    ELSE (SELECT time_clock_timestamp FROM emaj.emaj_time_stamp
                            WHERE time_id = lower(rel_time_range))
                 END AS stat_first_mark_datetime,
               CASE WHEN v_firstMarkTimeId IS NULL THEN NULL
                    WHEN v_firstMarkTimeId >= lower(rel_time_range) THEN v_firstEmajGid
                    ELSE (SELECT time_last_emaj_gid FROM emaj.emaj_time_stamp
                            WHERE time_id = lower(rel_time_range))
                 END AS stat_first_mark_gid,
               CASE WHEN v_lastMarkTimeId IS NULL AND upper_inf(rel_time_range) THEN NULL
                    WHEN NOT upper_inf(rel_time_range) AND (v_lastMarkTimeId IS NULL OR upper(rel_time_range) < v_lastMarkTimeId)
                         THEN coalesce((SELECT mark_name FROM emaj.emaj_mark
                                 WHERE mark_time_id = upper(rel_time_range) AND mark_group = rel_group),'[deleted mark]')
                    ELSE v_lastMark
                 END AS stat_last_mark,
               CASE WHEN v_lastMarkTimeId IS NULL AND upper_inf(rel_time_range) THEN NULL
                    WHEN NOT upper_inf(rel_time_range) AND (v_lastMarkTimeId IS NULL OR upper(rel_time_range) < v_lastMarkTimeId)
                         THEN (SELECT time_clock_timestamp FROM emaj.emaj_time_stamp
                                 WHERE time_id = upper(rel_time_range))
                    ELSE v_lastMarkTs
                 END AS stat_last_mark_datetime,
               CASE WHEN v_lastMarkTimeId IS NULL AND upper_inf(rel_time_range) THEN NULL
                    WHEN NOT upper_inf(rel_time_range) AND (v_lastMarkTimeId IS NULL OR upper(rel_time_range) < v_lastMarkTimeId)
                         THEN (SELECT time_last_emaj_gid FROM emaj.emaj_time_stamp
                                 WHERE time_id = upper(rel_time_range))
                    ELSE v_lastEmajGid
                 END AS stat_last_mark_gid,
               CASE WHEN v_firstMarkTimeId IS NULL THEN 0                                       -- group just created but without any mark
                    ELSE emaj._log_stat_tbl(emaj_relation,
                                            CASE WHEN v_firstMarkTimeId >= lower(rel_time_range)
                                                   THEN v_firstMarkTimeId ELSE lower(rel_time_range) END,
                                            CASE WHEN NOT upper_inf(rel_time_range)
                                                   AND (v_lastMarkTimeId IS NULL OR upper(rel_time_range) < v_lastMarkTimeId)
                                                   THEN upper(rel_time_range) ELSE v_lastMarkTimeId END)
                 END AS nb_rows
          FROM emaj.emaj_relation
          WHERE rel_group = ANY(v_groupNames) AND rel_kind = 'r'                                -- tables belonging to the groups
            AND (upper_inf(rel_time_range) OR upper(rel_time_range) > v_firstMarkTimeId)        --   at the requested time frame
            AND (v_lastMarkTimeId IS NULL OR lower(rel_time_range) < v_lastMarkTimeId)
          ORDER BY rel_schema, rel_tblseq, rel_time_range;
    ELSE
      RETURN;
    END IF;
  END;
$_log_stat_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_detailed_log_stat_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj.emaj_detailed_log_stat_type LANGUAGE plpgsql AS
$emaj_detailed_log_stat_group$
-- This function returns statistics on row updates executed between 2 marks as viewed through the log tables for one tables group.
-- It provides more information than emaj_log_stat_group but it needs to scan log tables in order to provide these data.
-- So the response time may be much longer.
-- Input: group name, the 2 marks names defining a range
-- Output: table of updates by user and table.
  BEGIN
    RETURN QUERY
      SELECT stat_group, stat_schema, stat_table, stat_first_mark, stat_first_mark_datetime, stat_last_mark, stat_last_mark_datetime,
             stat_role, stat_verb, stat_rows
        FROM emaj._detailed_log_stat_groups(ARRAY[v_groupName], FALSE, v_firstMark, v_lastMark);
  END;
$emaj_detailed_log_stat_group$;
COMMENT ON FUNCTION emaj.emaj_detailed_log_stat_group(TEXT,TEXT,TEXT) IS
$$Returns detailed statistics about logged events for an E-Maj group between 2 marks for a group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_detailed_log_stat_groups(v_groupNames TEXT[], v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj.emaj_detailed_log_stat_type LANGUAGE plpgsql AS
$emaj_detailed_log_stat_groups$
-- This function returns statistics on row updates executed between 2 marks as viewed through the log tables for several tables group.
-- It provides more information than emaj_log_stat_group but it needs to scan log tables in order to provide these data.
-- So the response time may be much longer.
-- Input: group names array, the 2 marks names defining a range
-- Output: table of updates by user and table
  BEGIN
    RETURN QUERY
      SELECT stat_group, stat_schema, stat_table, stat_first_mark, stat_first_mark_datetime, stat_last_mark, stat_last_mark_datetime,
             stat_role, stat_verb, stat_rows
        FROM emaj._detailed_log_stat_groups(v_groupNames, TRUE, v_firstMark, v_lastMark);
  END;
$emaj_detailed_log_stat_groups$;
COMMENT ON FUNCTION emaj.emaj_detailed_log_stat_groups(TEXT[],TEXT,TEXT) IS
$$Returns detailed statistics about logged events for an E-Maj group between 2 marks for several groups.$$;

CREATE OR REPLACE FUNCTION emaj._detailed_log_stat_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj._detailed_log_stat_type LANGUAGE plpgsql AS
$_detailed_log_stat_groups$
-- This function effectively returns statistics on row updates executed between 2 marks as viewed through the log tables for one or several
-- groups.
-- It provides more information than emaj_log_stat_group but it needs to scan log tables in order to provide these data.
-- So the response time may be much longer.
-- The function is directly called by Emaj_web.
-- Input: groups name array, a boolean indicating whether the calling function is a multi_groups function,
--        the 2 mark names defining a range
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string as last_mark indicates the current situation
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark.
-- Output: table of updates by user and table
-- This function may be directly called by the Emaj_web client.
  DECLARE
    v_firstMarkTimeId        BIGINT;
    v_lastMarkTimeId         BIGINT;
    v_firstMarkTs            TIMESTAMPTZ;
    v_lastMarkTs             TIMESTAMPTZ;
    v_firstEmajGid           BIGINT;
    v_lastEmajGid            BIGINT;
    v_lowerBoundMark         TEXT;
    v_lowerBoundMarkTs       TIMESTAMPTZ;
    v_lowerBoundGid          BIGINT;
    v_upperBoundMark         TEXT;
    v_upperBoundMarkTs       TIMESTAMPTZ;
    v_upperBoundGid          BIGINT;
    v_stmt                   TEXT;
    r_tblsq                  RECORD;
    r_stat                   RECORD;
  BEGIN
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := FALSE, v_checkList := '');
    IF v_groupNames IS NOT NULL THEN
-- check the marks range
      SELECT * FROM emaj._check_marks_range(v_groupNames, v_firstMark, v_lastMark)
        INTO v_firstMark, v_lastMark, v_firstMarkTimeId, v_lastMarkTimeId;
-- if there is no first mark, return quickly
      IF v_firstMark IS NULL THEN
        RETURN;
      END IF;
-- get additional data for both mark timestamps
      SELECT time_last_emaj_gid, time_clock_timestamp INTO v_firstEmajGid, v_firstMarkTs
        FROM emaj.emaj_time_stamp WHERE time_id = v_firstMarkTimeId;
      IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
        SELECT time_last_emaj_gid, time_clock_timestamp INTO v_lastEmajGid, v_lastMarkTs
          FROM emaj.emaj_time_stamp WHERE time_id = v_lastMarkTimeId;
      END IF;
-- for each table currently belonging to the group
-- count the number of operations per type (INSERT, UPDATE and DELETE) and role
      FOR r_tblsq IN
          SELECT rel_priority, rel_schema, rel_tblseq, rel_group, rel_time_range, rel_log_schema, rel_log_table
            FROM emaj.emaj_relation
            WHERE rel_group = ANY(v_groupNames) AND rel_kind = 'r'                                       -- tables belonging to the groups
              AND (upper_inf(rel_time_range) OR upper(rel_time_range) > v_firstMarkTimeId)               --   at the requested time frame
              AND (v_lastMarkTimeId IS NULL OR lower(rel_time_range) < v_lastMarkTimeId)
            ORDER BY rel_schema, rel_tblseq, rel_time_range
      LOOP
-- compute the lower bound for this table
        IF v_firstMarkTimeId >= lower(r_tblsq.rel_time_range) THEN
-- usual case: the table belonged to the group at statistics start mark
          v_lowerBoundMark = v_firstMark;
          v_lowerBoundMarkTs = v_firstMarkTs;
          v_lowerBoundGid = v_firstEmajGid;
        ELSE
-- special case: the table has been added to the group after the statistics start mark
          SELECT mark_name INTO v_lowerBoundMark
            FROM emaj.emaj_mark
            WHERE mark_time_id = lower(r_tblsq.rel_time_range) AND mark_group = r_tblsq.rel_group;
          IF v_lowerBoundMark IS NULL THEN
-- the mark set at alter_group time may have been deleted
            v_lowerBoundMark = '[deleted mark]';
          END IF;
          SELECT time_clock_timestamp, time_last_emaj_gid INTO v_lowerBoundMarkTs, v_lowerBoundGid
            FROM emaj.emaj_time_stamp
            WHERE time_id = lower(r_tblsq.rel_time_range);
        END IF;
-- compute the upper bound for this table
        IF v_lastMarkTimeId IS NULL AND upper_inf(r_tblsq.rel_time_range) THEN
-- no supplied end mark and the table has not been removed from its group => the current situation
          v_upperBoundMark = NULL;
          v_upperBoundMarkTs = NULL;
          v_upperBoundGid = NULL;
        ELSIF NOT upper_inf(r_tblsq.rel_time_range) AND (v_lastMarkTimeId IS NULL OR upper(r_tblsq.rel_time_range) < v_lastMarkTimeId) THEN
-- special case: the table has been removed from its group before the statistics end mark
          SELECT mark_name INTO v_upperBoundMark
            FROM emaj.emaj_mark
            WHERE mark_time_id = upper(r_tblsq.rel_time_range) AND mark_group = r_tblsq.rel_group;
          IF v_upperBoundMark IS NULL THEN
-- the mark set at alter_group time may have been deleted
            v_upperBoundMark = '[deleted mark]';
          END IF;
          SELECT time_clock_timestamp, time_last_emaj_gid INTO v_upperBoundMarkTs, v_upperBoundGid
            FROM emaj.emaj_time_stamp
            WHERE time_id = upper(r_tblsq.rel_time_range);
        ELSE
-- usual case: the table belonged to the group at statistics end mark
          v_upperBoundMark = v_lastMark;
          v_upperBoundMarkTs = v_lastMarkTs;
          v_upperBoundGid = v_lastEmajGid;
        END IF;
-- build the statement
        v_stmt= 'SELECT ' || quote_literal(r_tblsq.rel_group) || '::TEXT AS stat_group, '
             || quote_literal(r_tblsq.rel_schema) || '::TEXT AS stat_schema, '
             || quote_literal(r_tblsq.rel_tblseq) || '::TEXT AS stat_table, '
             || quote_literal(r_tblsq.rel_log_schema) || '::TEXT AS stat_log_schema, '
             || quote_literal(r_tblsq.rel_log_table) || '::TEXT AS stat_log_table, '
             || quote_literal(v_lowerBoundMark) || '::TEXT AS stat_first_mark, '
             || quote_literal(v_lowerBoundMarkTs) || '::TIMESTAMPTZ AS stat_first_mark_datetime, '
             || v_lowerBoundGid || '::BIGINT AS stat_first_mark_gid, '
             || coalesce(quote_literal(v_upperBoundMark),'NULL') || '::TEXT AS stat_last_mark, '
             || coalesce(quote_literal(v_upperBoundMarkTs),'NULL') || '::TIMESTAMPTZ AS stat_last_mark_datetime, '
             || coalesce(v_upperBoundGid::text,'NULL') || '::BIGINT AS stat_last_mark_gid, '
             || ' emaj_user AS stat_user,'
             || ' CASE emaj_verb WHEN ''INS'' THEN ''INSERT'''
             ||                ' WHEN ''UPD'' THEN ''UPDATE'''
             ||                ' WHEN ''DEL'' THEN ''DELETE'''
             ||                             ' ELSE ''?'' END::VARCHAR(6) AS stat_verb,'
             || ' count(*) AS stat_rows'
             || ' FROM ' || quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_log_table)
             || ' WHERE NOT (emaj_verb = ''UPD'' AND emaj_tuple = ''OLD'')'
             || ' AND emaj_gid > '|| v_lowerBoundGid
             || coalesce(' AND emaj_gid <= '|| v_upperBoundGid, '')
             || ' GROUP BY stat_group, stat_schema, stat_table, stat_user, stat_verb'
             || ' ORDER BY stat_user, stat_verb';
-- and execute the statement
        FOR r_stat IN EXECUTE v_stmt LOOP
          RETURN NEXT r_stat;
        END LOOP;
      END LOOP;
    END IF;
    RETURN;
  END;
$_detailed_log_stat_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_estimate_rollback_group(v_groupName TEXT, v_mark TEXT, v_isLoggedRlbk BOOLEAN)
RETURNS INTERVAL LANGUAGE plpgsql AS
$emaj_estimate_rollback_group$
-- This function computes an approximate duration of a rollback to a predefined mark for a group.
-- It uses the _estimate_rollback_group() function to effectively compute this estimate.
-- Input: group name, the mark name of the rollback operation, the rollback type.
-- Output: the approximate duration that the rollback would need as time interval
  BEGIN
    RETURN emaj._estimate_rollback_groups(ARRAY[v_groupName], FALSE, v_mark, v_isLoggedRlbk);
  END;
$emaj_estimate_rollback_group$;
COMMENT ON FUNCTION emaj.emaj_estimate_rollback_group(TEXT,TEXT,BOOLEAN) IS
$$Estimates the duration of a potential rollback for a tables group to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_estimate_rollback_groups(v_groupNames TEXT[], v_mark TEXT, v_isLoggedRlbk BOOLEAN)
RETURNS INTERVAL LANGUAGE plpgsql AS
$emaj_estimate_rollback_groups$
-- This function computes an approximate duration of a rollback to a predefined mark for a groups array.
-- It uses the _estimate_rollback_group() function to effectively compute this estimate.
-- Input: a group names array, the mark name of the rollback operation, the rollback type.
-- Output: the approximate duration that the rollback would need as time interval
  BEGIN
    RETURN emaj._estimate_rollback_groups(v_groupNames, TRUE, v_mark, v_isLoggedRlbk);
  END;
$emaj_estimate_rollback_groups$;
COMMENT ON FUNCTION emaj.emaj_estimate_rollback_groups(TEXT[],TEXT,BOOLEAN) IS
$$Estimates the duration of a potential rollback for a set of tables groups to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj._estimate_rollback_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_mark TEXT, v_isLoggedRlbk BOOLEAN)
RETURNS INTERVAL LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_estimate_rollback_groups$
-- This function effectively computes an approximate duration of a rollback to a predefined mark for a groups array.
-- It simulates a rollback on 1 session, by calling the _rlbk_planning function that already estimates elementary.
-- rollback steps duration. Once the global estimate is got, the rollback planning is cancelled.
-- Input: group names array, a boolean indicating whether the groups array may contain several groups,
--        the mark name of the rollback operation, the rollback type.
-- Output: the approximate duration that the rollback would need as time interval.
-- The function is declared SECURITY DEFINER so that emaj_viewer doesn't need a specific INSERT permission on emaj_rlbk.
  DECLARE
    v_markName               TEXT;
    v_fixed_table_rlbk       INTERVAL;
    v_rlbkId                 INT;
    v_estimDuration          INTERVAL;
    v_nbTblseq               INT;
  BEGIN
-- check the group names (the groups state checks are delayed for later)
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := FALSE, v_checkList := '')
      INTO v_groupNames;
-- if the group names array is null, immediately return NULL
    IF v_groupNames IS NULL THEN
      RETURN NULL;
    END IF;
-- check supplied group names and mark parameters with the isAlterGroupAllowed and isRollbackSimulation flags set to true
    SELECT emaj._rlbk_check(v_groupNames, v_mark, TRUE, TRUE) INTO v_markName;
-- compute a random negative rollback-id (not to interfere with ids of real rollbacks)
    SELECT (random() * -2147483648)::INT INTO v_rlbkId;
--
-- simulate a rollback planning
--
    BEGIN
-- insert a row into the emaj_rlbk table for this simulated rollback operation
      INSERT INTO emaj.emaj_rlbk (rlbk_id, rlbk_groups, rlbk_mark, rlbk_mark_time_id, rlbk_is_logged, rlbk_is_alter_group_allowed,
                                  rlbk_nb_session)
        SELECT v_rlbkId, v_groupNames, v_markName, mark_time_id, v_isLoggedRlbk, FALSE, 1
          FROM emaj.emaj_mark WHERE mark_group = v_groupNames[1] AND mark_name = v_markName;
-- call the _rlbk_planning function
      PERFORM emaj._rlbk_planning(v_rlbkId);
-- compute the sum of the duration estimates of all elementary steps (except LOCK_TABLE)
      SELECT coalesce(sum(rlbp_estimated_duration), '0 SECONDS'::INTERVAL) INTO v_estimDuration
        FROM emaj.emaj_rlbk_plan
        WHERE rlbp_rlbk_id = v_rlbkId AND rlbp_step <> 'LOCK_TABLE';
-- cancel the effect of the rollback planning
      RAISE EXCEPTION '';
    EXCEPTION
      WHEN RAISE_EXCEPTION THEN                 -- catch the raised exception and continue
    END;
-- get the "fixed_table_rollback_duration" parameter from the emaj_param table
    SELECT coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'fixed_table_rollback_duration'),'1 millisecond'::INTERVAL)
           INTO v_fixed_table_rlbk;
-- get the the number of tables to lock and sequences to rollback
    SELECT sum(group_nb_table)+sum(group_nb_sequence) INTO v_nbTblseq
      FROM emaj.emaj_group
      WHERE group_name = ANY(v_groupNames);
-- compute the final estimated duration
    v_estimDuration = v_estimDuration + (v_nbTblseq * v_fixed_table_rlbk);
    RETURN v_estimDuration;
  END;
$_estimate_rollback_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_rollback_activity()
RETURNS SETOF emaj.emaj_rollback_activity_type LANGUAGE plpgsql AS
$emaj_rollback_activity$
-- This function returns the list of rollback operations currently in execution, with information about their progress.
-- It doesn't need input parameter.
-- It returns a set of emaj_rollback_activity_type records.
  BEGIN
-- cleanup the freshly completed rollback operations, if any
    PERFORM emaj._cleanup_rollback_state();
-- and retrieve information regarding the rollback operations that are always in execution
    RETURN QUERY SELECT * FROM emaj._rollback_activity();
  END;
$emaj_rollback_activity$;
COMMENT ON FUNCTION emaj.emaj_rollback_activity() IS
$$Returns the list of rollback operations currently in execution, with information about their progress.$$;

CREATE OR REPLACE FUNCTION emaj._rollback_activity()
RETURNS SETOF emaj.emaj_rollback_activity_type LANGUAGE plpgsql AS
$_rollback_activity$
-- This function effectively builds the list of rollback operations currently in execution.
-- It is called by the emaj_rollback_activity() function.
-- This is a separate function to help in testing the feature (avoiding the effects of _cleanup_rollback_state()).
-- The number of parallel rollback sessions is not taken into account here,
--   as it is difficult to estimate the benefit brought by several parallel sessions.
-- The times and progression indicators reported are based on the transaction timestamp (allowing stable results in regression tests).
  DECLARE
    v_ipsDuration            INTERVAL;           -- In Progress Steps Duration
    v_nyssDuration           INTERVAL;           -- Not Yes Started Steps Duration
    v_nbNyss                 INT;                -- Number of Net Yes Started Steps
    v_ctrlDuration           INTERVAL;
    v_currentTotalEstimate   INTERVAL;
    r_rlbk                   emaj.emaj_rollback_activity_type;
  BEGIN
-- retrieve all not completed rollback operations (ie in 'PLANNING', 'LOCKING' or 'EXECUTING' state)
    FOR r_rlbk IN
      SELECT rlbk_id, rlbk_groups, rlbk_mark, t1.time_clock_timestamp, rlbk_is_logged, rlbk_is_alter_group_allowed,
             rlbk_nb_session, rlbk_nb_table, rlbk_nb_sequence, rlbk_eff_nb_table, rlbk_status, t2.time_tx_timestamp,
             transaction_timestamp() - t2.time_tx_timestamp AS "elapse", NULL, 0
        FROM emaj.emaj_rlbk
             JOIN emaj.emaj_time_stamp t1 ON (rlbk_mark_time_id = t1.time_id)
             LEFT OUTER JOIN emaj.emaj_time_stamp t2 ON (rlbk_time_id = t2.time_id)
        WHERE rlbk_status IN ('PLANNING', 'LOCKING', 'EXECUTING')
        ORDER BY rlbk_id
    LOOP
-- compute the estimated remaining duration
--   for rollback operations in 'PLANNING' state, the remaining duration is NULL
      IF r_rlbk.rlbk_status IN ('LOCKING', 'EXECUTING') THEN
--     estimated duration of remaining work of in progress steps
        SELECT coalesce(
               sum(CASE WHEN rlbp_start_datetime + rlbp_estimated_duration - transaction_timestamp() > '0'::INTERVAL
                        THEN rlbp_start_datetime + rlbp_estimated_duration - transaction_timestamp()
                        ELSE '0'::INTERVAL END),'0'::INTERVAL) INTO v_ipsDuration
          FROM emaj.emaj_rlbk_plan WHERE rlbp_rlbk_id = r_rlbk.rlbk_id
           AND rlbp_start_datetime IS NOT NULL AND rlbp_duration IS NULL;
--     estimated duration and number of not yet started steps
        SELECT coalesce(sum(rlbp_estimated_duration),'0'::INTERVAL), count(*) INTO v_nyssDuration, v_nbNyss
          FROM emaj.emaj_rlbk_plan WHERE rlbp_rlbk_id = r_rlbk.rlbk_id
           AND rlbp_start_datetime IS NULL
           AND rlbp_step NOT IN ('CTRL-DBLINK','CTRL+DBLINK');
--     estimated duration of inter-step duration for not yet started steps
        SELECT coalesce(sum(rlbp_estimated_duration) * v_nbNyss / sum(rlbp_estimated_quantity),'0'::INTERVAL)
          INTO v_ctrlDuration
          FROM emaj.emaj_rlbk_plan WHERE rlbp_rlbk_id = r_rlbk.rlbk_id
           AND rlbp_step IN ('CTRL-DBLINK','CTRL+DBLINK');
--     update the global remaining duration estimate
        r_rlbk.rlbk_remaining = v_ipsDuration + v_nyssDuration + v_ctrlDuration;
      END IF;
-- compute the completion pct
--   for rollback operations in 'PLANNING' or 'LOCKING' state, the completion_pct = 0
      IF r_rlbk.rlbk_status = 'EXECUTING' THEN
--   first compute the new total duration estimate, using the estimate of the remaining work
        SELECT transaction_timestamp() - time_tx_timestamp + r_rlbk.rlbk_remaining INTO v_currentTotalEstimate
          FROM emaj.emaj_rlbk, emaj.emaj_time_stamp
          WHERE rlbk_time_id = time_id AND rlbk_id = r_rlbk.rlbk_id;
--   and then the completion pct
        IF v_currentTotalEstimate <> '0'::INTERVAL THEN
          SELECT 100 - (extract(epoch FROM r_rlbk.rlbk_remaining) * 100
                      / extract(epoch FROM v_currentTotalEstimate))::SMALLINT
            INTO r_rlbk.rlbk_completion_pct;
        END IF;
      END IF;
      RETURN NEXT r_rlbk;
    END LOOP;
    RETURN;
  END;
$_rollback_activity$;

CREATE OR REPLACE FUNCTION emaj.emaj_snap_group(v_groupName TEXT, v_dir TEXT, v_copyOptions TEXT)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$emaj_snap_group$
-- This function creates a file for each table and sequence belonging to the group.
-- For tables, these files contain all rows sorted on primary key.
-- For sequences, they contain a single row describing the sequence.
-- To do its job, the function performs COPY TO statement, with all default parameters.
-- For table without primary key, rows are sorted on all columns.
-- There is no need for the group not to be logging.
-- As all COPY statements are executed inside a single transaction:
--   - the function can be called while other transactions are running,
--   - the snap files will present a coherent state of tables.
-- It's users responsability:
--   - to create the directory (with proper permissions allowing the cluster to write into) before the emaj_snap_group function call, and
--   - maintain its content outside E-maj.
-- Input: group name,
--        the absolute pathname of the directory where the files are to be created and the options to used in the COPY TO statements
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use.
  DECLARE
    v_nbTb                   INT = 0;
    r_tblsq                  RECORD;
    v_fullTableName          TEXT;
    v_colList                TEXT;
    v_fileName               TEXT;
    v_stmt                   TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_GROUP', 'BEGIN', v_groupName, v_dir);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := FALSE, v_checkList := '');
-- check the supplied directory is not null
    IF v_dir IS NULL THEN
      RAISE EXCEPTION 'emaj_snap_group: The directory parameter cannot be NULL.';
    END IF;
-- check the copy options parameter doesn't contain unquoted ; that could be used for sql injection
    IF regexp_replace(v_copyOptions,'''.*''','') LIKE '%;%' THEN
      RAISE EXCEPTION 'emaj_snap_group: The COPY options parameter format is invalid.';
    END IF;
-- for each table/sequence of the emaj_relation table
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
          WHERE upper_inf(rel_time_range) AND rel_group = v_groupName
          ORDER BY rel_priority, rel_schema, rel_tblseq
    LOOP
      v_fileName = v_dir || '/' || translate(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '.snap', E' /\\$<>*', '_______');
      v_fullTableName = quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
      CASE r_tblsq.rel_kind
        WHEN 'r' THEN
-- if it is a table,
--   first build the order by column list
          PERFORM 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_constraint
            WHERE relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid AND
                  contype = 'p' AND nspname = r_tblsq.rel_schema AND relname = r_tblsq.rel_tblseq;
          IF FOUND THEN
--   the table has a pkey,
            SELECT string_agg(quote_ident(attname), ',') INTO v_colList FROM (
              SELECT attname FROM pg_catalog.pg_attribute, pg_catalog.pg_index
                WHERE pg_attribute.attrelid = pg_index.indrelid
                  AND attnum = ANY (indkey)
                  AND indrelid = v_fullTableName::regclass AND indisprimary
                  AND attnum > 0 AND attisdropped = FALSE) AS t;
          ELSE
--   the table has no pkey
            SELECT string_agg(quote_ident(attname), ',') INTO v_colList FROM (
              SELECT attname FROM pg_catalog.pg_attribute
                WHERE attrelid = v_fullTableName::regclass
                  AND attnum > 0  AND attisdropped = FALSE) AS t;
          END IF;
--   prepare the COPY statement
          v_stmt= 'COPY (SELECT * FROM ' || v_fullTableName || ' ORDER BY ' || v_colList || ') TO ' ||
                  quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
        WHEN 'S' THEN
-- if it is a sequence, the statement has no order by
          IF emaj._pg_version_num() >= 100000 THEN
            v_stmt = 'COPY (SELECT sequencename, rel.last_value, start_value, increment_by, max_value, '
                  || 'min_value, cache_size, cycle, rel.is_called '
                  || 'FROM ' || v_fullTableName || ' rel, pg_sequences '
                  || 'WHERE schemaname = '|| quote_literal(r_tblsq.rel_schema) || ' AND sequencename = '
                  || quote_literal(r_tblsq.rel_tblseq) ||') TO ' || quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
          ELSE
            v_stmt = 'COPY (SELECT sequence_name, last_value, start_value, increment_by, max_value, '
                  || 'min_value, cache_value, is_cycled, is_called FROM ' || v_fullTableName
                  || ') TO ' || quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
          END IF;
      END CASE;
-- and finaly perform the COPY
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

CREATE OR REPLACE FUNCTION emaj.emaj_snap_log_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT, v_dir TEXT, v_copyOptions TEXT)
RETURNS INT LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$emaj_snap_log_group$
-- This function creates a file for each log table belonging to the group.
-- It also creates 2 files containing the state of sequences respectively at start mark and end mark.
-- For log tables, files contain all rows related to the time frame, sorted on emaj_gid.
-- For sequences, files are names <group>_sequences_at_<mark>, or <group>_sequences_at_<time> if no end mark is specified.
--   They contain one row per sequence belonging to the group at the related time
--   (a sequence may belong to a group at the start mark time and not at the end mark time for instance).
-- To do its job, the function performs COPY TO statement, using the options provided by the caller.
-- There is no need for the group not to be logging.
-- As all COPY statements are executed inside a single transaction:
--   - the function can be called while other transactions are running,
--   - the snap files will present a coherent state of tables.
-- It's users responsability:
--   - to create the directory (with proper permissions allowing the cluster to write into) before emaj_snap_log_group function call, and
--   - to maintain its content outside E-maj.
-- Input: group name, the 2 mark names defining a range,
--        the absolute pathname of the directory where the files are to be created,
--        options for COPY TO statements
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string can be used as last_mark indicating the current state
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark.
-- Output: number of generated files (for tables and sequences, including the _INFO file)
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it.
  DECLARE
    v_nbFile                 INT = 3;        -- start with 3 = 2 files for sequences + _INFO
    v_noSuppliedLastMark     BOOLEAN;
    v_firstEmajGid           BIGINT;
    v_lastEmajGid            BIGINT;
    v_firstMarkTimeId        BIGINT;
    v_lastMarkTimeId         BIGINT;
    v_firstMarkTs            TIMESTAMPTZ;
    v_lastMarkTs             TIMESTAMPTZ;
    v_logTableName           TEXT;
    v_fileName               TEXT;
    v_conditions             TEXT;
    v_stmt                   TEXT;
    r_tblsq                  RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_LOG_GROUP', 'BEGIN', v_groupName,
       CASE WHEN v_firstMark IS NULL OR v_firstMark = '' THEN 'From initial mark' ELSE 'From mark ' || v_firstMark END ||
       CASE WHEN v_lastMark IS NULL OR v_lastMark = '' THEN ' to current situation' ELSE ' to mark ' || v_lastMark END || ' towards '
       || v_dir);
-- check the group name
    PERFORM emaj._check_group_names(v_groupNames := ARRAY[v_groupName], v_mayBeNull := FALSE, v_lockGroups := FALSE, v_checkList := '');
-- check the marks range
    v_noSuppliedLastMark = (v_lastMark IS NULL OR v_lastMark = '');
    SELECT * FROM emaj._check_marks_range(ARRAY[v_groupName], v_firstMark, v_lastMark)
      INTO v_firstMark, v_lastMark, v_firstMarkTimeId, v_lastMarkTimeId;
-- check the supplied directory is not null
    IF v_dir IS NULL THEN
      RAISE EXCEPTION 'emaj_snap_log_group: The directory parameter cannot be NULL.';
    END IF;
-- check the copy options parameter doesn't contain unquoted ; that could be used for sql injection
    IF regexp_replace(v_copyOptions,'''.*''','') LIKE '%;%'  THEN
      RAISE EXCEPTION 'emaj_snap_log_group: The COPY options parameter format is invalid.';
    END IF;
-- get additional data for the first mark (in some cases, v_firstMarkTimeId may be NULL)
    SELECT time_last_emaj_gid, time_clock_timestamp INTO v_firstEmajGid, v_firstMarkTs
      FROM emaj.emaj_time_stamp WHERE time_id = v_firstMarkTimeId;
    IF v_noSuppliedLastMark THEN
-- the end mark is not supplied (look for the current state)
-- get a simple time stamp and its attributes
      SELECT emaj._set_time_stamp('S') INTO v_lastMarkTimeId;
      SELECT time_last_emaj_gid, time_clock_timestamp INTO v_lastEmajGid, v_lastMarkTs
        FROM emaj.emaj_time_stamp
        WHERE time_id = v_lastMarkTimeId;
    ELSE
-- the end mark is supplied, get additional data for the last mark
      SELECT mark_time_id, time_last_emaj_gid, time_clock_timestamp INTO v_lastMarkTimeId, v_lastEmajGid, v_lastMarkTs
        FROM emaj.emaj_mark, emaj.emaj_time_stamp
        WHERE mark_time_id = time_id AND mark_group = v_groupName AND mark_name = v_lastMark;
    END IF;
-- build the conditions on emaj_gid corresponding to this marks frame, used for the COPY statements dumping the tables
    v_conditions = 'TRUE';
    IF NOT v_firstMark IS NOT NULL AND v_firstMark <> '' THEN
      v_conditions = v_conditions || ' AND emaj_gid > '|| v_firstEmajGid;
    END IF;
    IF NOT v_noSuppliedLastMark THEN
      v_conditions = v_conditions || ' AND emaj_gid <= '|| v_lastEmajGid;
    END IF;
-- process all log tables of the emaj_relation table that enter in the marks range
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema, rel_log_table FROM emaj.emaj_relation
          WHERE rel_group = v_groupName AND rel_kind = 'r'
            AND rel_time_range && int8range(v_firstMarkTimeId, v_lastMarkTimeId,'[)')
          ORDER BY rel_priority, rel_schema, rel_tblseq
    LOOP
--   build names
      v_fileName = v_dir || '/' || translate(r_tblsq.rel_schema || '_' || r_tblsq.rel_log_table || '.snap', E' /\\$<>*', '_______');
      v_logTableName = quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_log_table);
--   prepare the execute the COPY statement
      v_stmt= 'COPY (SELECT * FROM ' || v_logTableName || ' WHERE ' || v_conditions
           || ' ORDER BY emaj_gid ASC) TO ' || quote_literal(v_fileName)
           || ' ' || coalesce (v_copyOptions, '');
      EXECUTE v_stmt;
      v_nbFile = v_nbFile + 1;
    END LOOP;
-- generate the file for sequences state at start mark
    v_fileName = v_dir || '/' || translate(v_groupName || '_sequences_at_' || v_firstMark, E' /\\$<>*', '_______');
-- and execute the COPY statement
    v_stmt = 'COPY (SELECT emaj_sequence.*' ||
             ' FROM emaj.emaj_sequence, emaj.emaj_relation' ||
             ' WHERE sequ_time_id = ' || v_firstMarkTimeId ||
             '   AND rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) ||
             '   AND rel_time_range @> ' || v_firstMarkTimeId || '::BIGINT' ||
             '   AND sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
             ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' ||
             coalesce (v_copyOptions, '');
    EXECUTE v_stmt;
-- prepare the file for sequences state at end mark
-- generate the full file name and the COPY statement
    IF v_noSuppliedLastMark THEN
      v_fileName = v_dir || '/' || translate(v_groupName || '_sequences_at_'
                || to_char(v_lastMarkTs,'HH24.MI.SS.MS'), E' /\\$<>*', '_______');
      v_stmt = 'SELECT seq.* FROM emaj.emaj_relation, LATERAL emaj._get_current_sequence_state(rel_schema, rel_tblseq, ' ||
                                                                                               v_lastMarkTimeId || ') AS seq' ||
               '  WHERE upper_inf(rel_time_range) AND rel_group = ' || quote_literal(v_groupName) || ' AND rel_kind = ''S''';
    ELSE
      v_fileName = v_dir || '/' || translate(v_groupName || '_sequences_at_' || v_lastMark, E' /\\$<>*', '_______');
      v_stmt = 'SELECT emaj_sequence.*'
            || ' FROM emaj.emaj_sequence, emaj.emaj_relation'
            || ' WHERE sequ_time_id = ' || v_lastMarkTimeId
            || '   AND rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName)
            || '   AND (rel_time_range @> ' || v_lastMarkTimeId || '::BIGINT'
            || '        OR upper(rel_time_range) = ' || v_lastMarkTimeId || '::BIGINT)'
            || '   AND sequ_schema = rel_schema AND sequ_name = rel_tblseq'
            || ' ORDER BY sequ_schema, sequ_name';
    END IF;
-- and create the file
    EXECUTE format('COPY (%s) TO %L %s',
                   v_stmt, v_fileName, coalesce (v_copyOptions, ''));
-- create the _INFO file to keep general information about the snap operation
    EXECUTE format('COPY (SELECT %L) TO %L %s',
                  'E-Maj log tables snap of group ' || v_groupName || ' between marks ' || v_firstMark || ' and ' ||
                    CASE WHEN v_noSuppliedLastMark THEN 'current state' ELSE v_lastMark END || ' at ' || statement_timestamp(),
                  v_dir || '/_INFO', coalesce (v_copyOptions, ''));
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_LOG_GROUP', 'END', v_groupName, v_nbFile || ' generated files');
    RETURN v_nbFile;
  END;
$emaj_snap_log_group$;
COMMENT ON FUNCTION emaj.emaj_snap_log_group(TEXT,TEXT,TEXT,TEXT,TEXT) IS
$$Snaps all application tables and sequences of an E-Maj group into a given directory.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_gen_sql_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT, v_location TEXT,
                                                   v_tblseqs TEXT[] DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql
SECURITY DEFINER SET standard_conforming_strings = ON SET search_path = pg_catalog, pg_temp AS
$emaj_gen_sql_group$
-- This function generates a SQL script representing all updates performed on a tables group between 2 marks.
-- or beetween a mark and the current situation. The result is stored into an external file.
-- It calls the _gen_sql_groups() function to effetively process the request.
-- Input: - tables group
--        - start mark, NULL representing the first mark
--        - end mark, NULL representing the current situation, and 'EMAJ_LAST_MARK' the last set mark for the group
--        - absolute pathname describing the file that will hold the result
--          (may be NULL if the caller reads the temporary table that will hold the script after the function execution)
--        - array of schema qualified table and sequence names to only process those tables and sequences (NULL by default)
-- Output: number of generated SQL statements (non counting comments and transaction management)
  BEGIN
-- call the _gen_sql_groups() function that effectively processes the request
    RETURN emaj._gen_sql_groups(array[v_groupName], FALSE, v_firstMark, v_lastMark, v_location, v_tblseqs);
  END;
$emaj_gen_sql_group$;
COMMENT ON FUNCTION emaj.emaj_gen_sql_group(TEXT,TEXT,TEXT,TEXT,TEXT[]) IS
$$Generates a sql script corresponding to all updates performed on a tables group between two marks and stores it into a given file.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_gen_sql_groups(v_groupNames TEXT[], v_firstMark TEXT, v_lastMark TEXT, v_location TEXT,
                                                    v_tblseqs TEXT[] DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql
SECURITY DEFINER SET standard_conforming_strings = ON SET search_path = pg_catalog, pg_temp AS
$emaj_gen_sql_groups$
-- This function generates a SQL script representing all updates performed on a set of tables groups between 2 marks
-- or beetween a mark and the current situation. The result is stored into an external file.
-- It calls the _gen_sql_groups() function to effetively process the request.
-- Input: - tables groups array
--        - start mark, NULL representing the first mark
--        - end mark, NULL representing the current situation, and 'EMAJ_LAST_MARK' the last set mark for the group
--        - absolute pathname describing the file that will hold the result
--          (may be NULL if the caller reads the temporary table that will hold the script after the function execution)
--        - array of schema qualified table and sequence names to only process those tables and sequences (NULL by default)
-- Output: number of generated SQL statements (non counting comments and transaction management)
  BEGIN
-- call the _gen_sql_groups() function that effectively processes the request
    RETURN emaj._gen_sql_groups(v_groupNames, TRUE, v_firstMark, v_lastMark, v_location, v_tblseqs);
  END;
$emaj_gen_sql_groups$;
COMMENT ON FUNCTION emaj.emaj_gen_sql_groups(TEXT[],TEXT,TEXT,TEXT,TEXT[]) IS
$$Generates a sql script replaying all updates performed on a tables groups set between two marks and stores it into a given file.$$;

CREATE OR REPLACE FUNCTION emaj._gen_sql_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_firstMark TEXT, v_lastMark TEXT,
                                                v_location TEXT, v_tblseqs TEXT[])
RETURNS BIGINT LANGUAGE plpgsql
SET DateStyle = 'ISO, YMD' AS
$_gen_sql_groups$
-- This function generates a SQL script representing all updates performed on a tables groups array between 2 marks
-- or beetween a mark and the current situation. The result is stored into an external file.
-- The function can process groups that are in LOGGING state or not.
-- The sql statements are placed between a BEGIN TRANSACTION and a COMMIT statements.
-- The output file can be reused as input file to a psql command to replay the updates scenario. Just '\\'
-- character strings (double antislash), if any, must be replaced by '\' (single antislash) before feeding
-- the psql command.
-- Input: - tables groups array
--        - start mark, NULL representing the first mark
--        - end mark, NULL representing the current situation, and 'EMAJ_LAST_MARK' the last set mark for the group
--        - absolute pathname describing the file that will hold the result
--          (may be NULL if the caller reads the temporary table that will hold the script after the function execution)
--        - optional array of schema qualified table and sequence names to only process those tables and sequences
-- Output: number of generated SQL statements (non counting comments and transaction management)
  DECLARE
    v_firstMarkTimeId        BIGINT;
    v_firstEmajGid           BIGINT;
    v_lastMarkTimeId         BIGINT;
    v_lastEmajGid            BIGINT;
    v_tblseqErr              TEXT;
    v_count                  INT;
    v_nbSQL                  BIGINT;
    v_nbSeq                  INT;
    v_cumNbSQL               BIGINT = 0;
    v_endComment             TEXT;
    v_dateStyle              TEXT;
    r_rel                    emaj.emaj_relation%ROWTYPE;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'GEN_SQL_GROUPS' ELSE 'GEN_SQL_GROUP' END, 'BEGIN', array_to_string(v_groupNames,','),
       CASE WHEN v_firstMark IS NULL OR v_firstMark = '' THEN 'From initial mark' ELSE 'From mark ' || v_firstMark END ||
       CASE WHEN v_lastMark IS NULL OR v_lastMark = '' THEN ' to current situation' ELSE ' to mark ' || v_lastMark END ||
       CASE WHEN v_tblseqs IS NOT NULL THEN ' with tables/sequences filtering' ELSE '' END );
-- check the group name
    SELECT emaj._check_group_names(v_groupNames := v_groupNames, v_mayBeNull := v_multiGroup, v_lockGroups := FALSE, v_checkList := '')
      INTO v_groupNames;
-- if there is at least 1 group to process, go on
    IF v_groupNames IS NOT NULL THEN
-- check the marks range
      SELECT * FROM emaj._check_marks_range(v_groupNames, v_firstMark, v_lastMark)
        INTO v_firstMark, v_lastMark, v_firstMarkTimeId, v_lastMarkTimeId;
-- if table/sequence names are supplied, check them
      IF v_tblseqs IS NOT NULL THEN
-- remove duplicates values, NULL and empty strings from the supplied tables/sequences names array
        SELECT array_agg(DISTINCT table_seq_name) INTO v_tblseqs FROM unnest(v_tblseqs) AS table_seq_name
          WHERE table_seq_name IS NOT NULL AND table_seq_name <> '';
        IF v_tblseqs IS NULL THEN
          RAISE EXCEPTION '_gen_sql_groups: The filtered table/sequence names array cannot be empty.';
        END IF;
      END IF;
-- check the array of tables and sequences to filter, if supplied.
-- each table/sequence of the filter must be known in emaj_relation and be owned by one of the supplied table groups
      IF v_tblseqs IS NOT NULL THEN
        SELECT string_agg(t,', ' ORDER BY t), count(*)
          INTO v_tblseqErr, v_count FROM (
            SELECT t FROM unnest(v_tblseqs) AS t
              EXCEPT
            SELECT rel_schema || '.' || rel_tblseq FROM emaj.emaj_relation
              WHERE rel_time_range @> v_firstMarkTimeId AND rel_group = ANY (v_groupNames)  -- tables/sequences that belong to their group
                                                                                            -- at the start mark time
            ) AS t2;
        IF v_tblseqErr IS NOT NULL THEN
          RAISE EXCEPTION '_gen_sql_groups: % tables/sequences (%) did not belong to any of the selected tables groups at % mark time.',
            v_count, v_tblseqErr, v_firstMark;
        END IF;
      END IF;
-- check that all tables had pk at start mark time
--   verifying the emaj_relation.rel_sql_gen_pk_conditions column
      SELECT string_agg(rel_schema || '.' || rel_tblseq, ', ' ORDER BY rel_schema, rel_tblseq), count(*)
        INTO v_tblseqErr, v_count FROM (
          SELECT * FROM emaj.emaj_relation
            WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r'                               -- tables belonging to the groups
              AND rel_time_range @> v_firstMarkTimeId                                             --   at the first mark time
              AND (v_tblseqs IS NULL OR rel_schema || '.' || rel_tblseq = ANY (v_tblseqs))        -- filtered or not by the user
              AND rel_sql_gen_pk_conditions IS NULL                                               -- no pk at assignment time
          ) as t;
      IF v_tblseqErr IS NOT NULL THEN
        RAISE EXCEPTION '_gen_sql_groups: % tables/sequences (%) had no pkey at % mark time.',
          v_count, v_tblseqErr, v_firstMark;
      END IF;
-- create a temporary table to hold the generated script
      DROP TABLE IF EXISTS emaj_temp_script CASCADE;
      CREATE TEMP TABLE emaj_temp_script (
        scr_emaj_gid           BIGINT,              -- the emaj_gid of the corresponding log row,
                                                    --   0 for initial technical statements,
                                                    --   NULL for final technical statements
        scr_subid              INT,                 -- used to distinguish several generated sql per log row
        scr_emaj_txid          BIGINT,              -- for future use, to insert commit statement at each txid change
        scr_sql                TEXT                 -- the generated sql text
      );
      GRANT SELECT ON emaj_temp_script TO PUBLIC;
-- test the supplied output file name by inserting a temporary line
      IF v_location IS NOT NULL THEN
        INSERT INTO emaj_temp_script SELECT 0, 1, 0, '-- SQL script generation in progress - started at ' || statement_timestamp();
        BEGIN
          PERFORM emaj._export_sql_script(v_location);
        EXCEPTION
          WHEN OTHERS THEN
            RAISE EXCEPTION '_gen_sql_groups: The file "%" cannot be used as script output file.', v_location;
        END;
        DELETE FROM emaj_temp_script;
      END IF;
-- end of checks
-- if there is no first mark for all groups, return quickly with a warning message
      IF v_firstMark IS NULL THEN
        RAISE WARNING '_gen_sql_groups: No mark exists for the group(s) "%".', array_to_string(v_groupNames,', ');
        INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
          VALUES (CASE WHEN v_multiGroup THEN 'GEN_SQL_GROUPS' ELSE 'GEN_SQL_GROUP' END, 'END',
                  array_to_string(v_groupNames,','), 'No mark in the group(s) => no file has been generated');
        RETURN 0;
      END IF;
-- retrieve the global sequence value of the supplied first mark
      SELECT time_last_emaj_gid INTO v_firstEmajGid
        FROM emaj.emaj_time_stamp WHERE time_id = v_firstMarkTimeId;
-- if last mark is NULL or empty, there is no timestamp to register
      IF v_lastMark IS NULL OR v_lastMark = '' THEN
        v_lastEmajGid = NULL;
      ELSE
-- else, retrieve the global sequence value of the supplied end mark
        SELECT time_last_emaj_gid INTO v_lastEmajGid
          FROM emaj.emaj_time_stamp WHERE time_id = v_lastMarkTimeId;
      END IF;
-- insert initial comments, define some session parameters:
--    - the standard_conforming_strings option to properly handle special characters,
--    - the DateStyle mode used at export time
-- and a transaction start
      IF v_lastMarkTimeId IS NOT NULL THEN
        v_endComment = ' and mark ' || v_lastMark;
      ELSE
        v_endComment = ' and the current situation';
      END IF;
      INSERT INTO emaj_temp_script SELECT 0, 1, 0, '-- SQL script generated by E-Maj at ' || statement_timestamp();
      INSERT INTO emaj_temp_script SELECT 0, 2, 0, '--    for tables group(s): ' || array_to_string(v_groupNames,',');
      INSERT INTO emaj_temp_script SELECT 0, 3, 0, '--    processing logs between mark ' || v_firstMark || v_endComment;
      IF v_tblseqs IS NOT NULL THEN
        INSERT INTO emaj_temp_script SELECT 0, 4, 0, '--    only for the following tables/sequences: ' || array_to_string(v_tblseqs,',');
      END IF;
      SELECT setting INTO v_dateStyle FROM pg_settings WHERE name = 'DateStyle';
      INSERT INTO emaj_temp_script SELECT 0, 10, 0, 'SET standard_conforming_strings = OFF;';
      INSERT INTO emaj_temp_script SELECT 0, 11, 0, 'SET escape_string_warning = OFF;';
      INSERT INTO emaj_temp_script SELECT 0, 12, 0, 'SET datestyle = ' || quote_literal(v_dateStyle) || ';';
      INSERT INTO emaj_temp_script SELECT 0, 20, 0, 'BEGIN TRANSACTION;';
-- process tables
      FOR r_rel IN
          SELECT * FROM emaj.emaj_relation
            WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r'                               -- tables belonging to the groups
              AND rel_time_range @> v_firstMarkTimeId                                             --   at the first mark time
              AND (v_tblseqs IS NULL OR rel_schema || '.' || rel_tblseq = ANY (v_tblseqs))        -- filtered or not by the user
              AND emaj._log_stat_tbl(emaj_relation, v_firstMarkTimeId,                            -- only tables having updates to process
                                    least(v_lastMarkTimeId, upper(rel_time_range))) > 0
            ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
-- for each application table referenced in the emaj_relation table, process the related log table, by calling the _gen_sql_tbl() function
        SELECT emaj._gen_sql_tbl(r_rel, v_firstEmajGid, v_lastEmajGid) INTO v_nbSQL;
        v_cumNbSQL = v_cumNbSQL + v_nbSQL;
      END LOOP;
-- process sequences
      v_nbSeq = 0;
      FOR r_rel IN
          SELECT * FROM emaj.emaj_relation
            WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'S'
              AND rel_time_range @> v_firstMarkTimeId                                -- sequences belonging to the groups at the start mark
              AND (v_tblseqs IS NULL OR rel_schema || '.' || rel_tblseq = ANY (v_tblseqs))         -- filtered or not by the user
            ORDER BY rel_schema DESC, rel_tblseq DESC
      LOOP
-- process each sequence and increment the sequence counter
        v_nbSeq = v_nbSeq + emaj._gen_sql_seq(r_rel, v_firstMarkTimeId, v_lastMarkTimeId, v_nbSeq);
      END LOOP;
-- add command to committhe transaction and reset the modified session parameters
      INSERT INTO emaj_temp_script SELECT NULL, 1, txid_current(), 'COMMIT;';
      INSERT INTO emaj_temp_script SELECT NULL, 10, txid_current(), 'RESET standard_conforming_strings;';
      INSERT INTO emaj_temp_script SELECT NULL, 11, txid_current(), 'RESET escape_string_warning;';
      INSERT INTO emaj_temp_script SELECT NULL, 11, txid_current(), 'RESET datestyle;';
-- if an output file is supplied, write the SQL script on the external file and drop the temporary table
      IF v_location IS NOT NULL THEN
        PERFORM emaj._export_sql_script(v_location);
        DROP TABLE IF EXISTS emaj_temp_script;
      ELSE
-- otherwise create a view to ease the generation script export
        CREATE TEMPORARY VIEW emaj_sql_script AS
          SELECT scr_sql FROM emaj_temp_script ORDER BY scr_emaj_gid NULLS LAST, scr_subid;
        GRANT SELECT ON emaj_sql_script TO PUBLIC;
      END IF;
-- return the number of sql verbs generated into the output file
      v_cumNbSQL = v_cumNbSQL + v_nbSeq;
    END IF;
-- insert end in the history and return
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'GEN_SQL_GROUPS' ELSE 'GEN_SQL_GROUP' END, 'END',
              array_to_string(v_groupNames,','), v_cumNbSQL || ' generated statements' ||
                CASE WHEN v_location IS NOT NULL THEN ' - script exported into ' || v_location ELSE ' - script not exported' END );
    RETURN v_cumNbSQL;
  END;
$_gen_sql_groups$;

CREATE OR REPLACE FUNCTION emaj._export_sql_script(v_location TEXT)
RETURNS VOID LANGUAGE plpgsql
SECURITY DEFINER SET standard_conforming_strings = ON SET search_path = pg_catalog, pg_temp AS
$_export_sql_script$
-- This function export a sql script generated by the _gen_sql_groups() function into a file
-- Input: - absolute pathname describing the file that will hold the result (NOT NULL)
-- The function is declared as SECURITY DEFINER to allow the use of the COPY SQL statement
  BEGIN
    EXECUTE format('COPY (SELECT scr_sql FROM emaj_temp_script ORDER BY scr_emaj_gid NULLS LAST, scr_subid ) TO %L',
                       v_location);
  END;
$_export_sql_script$;

------------------------------------
--                                --
-- Global purpose functions       --
--                                --
------------------------------------

CREATE OR REPLACE FUNCTION emaj._verify_all_groups()
RETURNS SETOF TEXT LANGUAGE plpgsql AS
$_verify_all_groups$
-- The function verifies the consistency of all E-Maj groups.
-- It returns a set of error or warning messages for discovered discrepancies.
-- If no error is detected, no row is returned.
  BEGIN
--
-- Errors detection
--
-- check the postgres version at groups creation time is compatible (i.e. >= 8.4)
    RETURN QUERY
      SELECT 'Error: The group "' || group_name || '" has been created with a non compatible postgresql version (' ||
               group_pg_version || '). It must be dropped and recreated.' AS msg
        FROM emaj.emaj_group
        WHERE cast(to_number(substring(group_pg_version FROM E'^(\\d+)'),'99') * 100 +
                   to_number(substring(group_pg_version FROM E'^\\d+\\.(\\d+)'),'99') AS INTEGER) < 804
        ORDER BY msg;
-- check all application schemas referenced in the emaj_relation table still exist
    RETURN QUERY
      SELECT 'Error: The application schema "' || rel_schema || '" does not exist any more.' AS msg
        FROM (
          SELECT DISTINCT rel_schema FROM emaj.emaj_relation
            WHERE upper_inf(rel_time_range)
            EXCEPT
          SELECT nspname FROM pg_catalog.pg_namespace
             ) AS t
        ORDER BY msg;
-- check all application relations referenced in the emaj_relation table still exist
    RETURN QUERY
      SELECT 'Error: In the group "' || r.rel_group || '", the ' ||
               CASE WHEN t.rel_kind = 'r' THEN 'table "' ELSE 'sequence "' END ||
               t.rel_schema || '"."' || t.rel_tblseq || '" does not exist any more.' AS msg
        FROM (                                        -- all expected application relations
          SELECT rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
            WHERE upper_inf(rel_time_range)
            EXCEPT                                    -- minus relations known by postgres
          SELECT nspname, relname, relkind FROM pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND relkind IN ('r','S')
             ) AS t, emaj.emaj_relation r             -- join with emaj_relation to get the group name
        WHERE t.rel_schema = r.rel_schema AND t.rel_tblseq = r.rel_tblseq AND upper_inf(r.rel_time_range)
        ORDER BY t.rel_schema, t.rel_tblseq, 1;
-- check the log table for all tables referenced in the emaj_relation table still exist
    RETURN QUERY
      SELECT 'Error: In the group "' || rel_group || '", the log table "' ||
               rel_log_schema || '"."' || rel_log_table || '" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_kind = 'r'
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_log_schema AND relname = rel_log_table
                   AND relnamespace = pg_namespace.oid)
        ORDER BY rel_schema, rel_tblseq, 1;
-- check the log sequence for all tables referenced in the emaj_relation table still exist
    RETURN QUERY
      SELECT 'Error: In the group "' || rel_group || '", the log sequence "' ||
               rel_log_schema || '"."' || rel_log_sequence || '" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE upper_inf(rel_time_range) AND rel_kind = 'r'
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_log_schema AND relname = rel_log_sequence
                   AND relnamespace = pg_namespace.oid)
        ORDER BY rel_schema, rel_tblseq, 1;
-- check the log function for each table referenced in the emaj_relation table still exist
    RETURN QUERY
      SELECT 'Error: In the group "' || rel_group || '", the log function "' ||
               rel_log_schema || '"."' || rel_log_function || '" is not found.'
             AS msg
        FROM emaj.emaj_relation
        WHERE upper_inf(rel_time_range) AND rel_kind = 'r'
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_proc, pg_catalog.pg_namespace
                 WHERE nspname = rel_log_schema AND proname = rel_log_function
                   AND pronamespace = pg_namespace.oid)
        ORDER BY rel_schema, rel_tblseq, 1;
-- check log and truncate triggers for all tables referenced in the emaj_relation table still exist
--   start with log triggers
    RETURN QUERY
      SELECT 'Error: In the group "' || rel_group || '", the log trigger "emaj_log_trg" on table "' ||
               rel_schema || '"."' || rel_tblseq || '" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE upper_inf(rel_time_range) AND rel_kind = 'r'
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND tgname = 'emaj_log_trg'
                   AND tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid)
                       -- do not issue a row if the application table does not exist,
                       -- this case has been already detected
          AND EXISTS
              (SELECT NULL FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND relnamespace = pg_namespace.oid)
        ORDER BY rel_schema, rel_tblseq, 1;
--   then truncate triggers
    RETURN QUERY
      SELECT 'Error: In the group "' || rel_group || '", the truncate trigger "emaj_trunc_trg" on table "' ||
             rel_schema || '"."' || rel_tblseq || '" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE upper_inf(rel_time_range) AND rel_kind = 'r'
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND tgname = 'emaj_trunc_trg'
                   AND tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid)
                       -- do not issue a row if the application table does not exist,
                       -- this case has been already detected
          AND EXISTS
              (SELECT NULL FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND relnamespace = pg_namespace.oid)
        ORDER BY rel_schema, rel_tblseq, 1;
-- check all log tables have a structure consistent with the application tables they reference
--      (same columns and same formats). It only returns one row per faulting table.
    RETURN QUERY
      SELECT msg FROM (
        WITH cte_app_tables_columns AS (                -- application table's columns
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
              FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
              WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
                AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = FALSE
                AND upper_inf(rel_time_range) AND rel_kind = 'r'),
             cte_log_tables_columns AS (                -- log table's columns
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
              FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
              WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema
                AND relname = rel_log_table
                AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = FALSE AND attnum < rel_emaj_verb_attnum
                AND upper_inf(rel_time_range) AND rel_kind = 'r')
        SELECT DISTINCT rel_schema, rel_tblseq,
               'Error: In the group "' || rel_group || '", the structure of the application table "' ||
                 rel_schema || '"."' || rel_tblseq || '" is not coherent with its log table ("' ||
               rel_log_schema || '"."' || rel_log_table || '").' AS msg
          FROM (
            (                                           -- application table's columns
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
              FROM cte_app_tables_columns
            EXCEPT                                      -- minus log table's columns
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
              FROM cte_log_tables_columns
            )
            UNION
            (                                           -- log table's columns
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
              FROM cte_log_tables_columns
            EXCEPT                                      --  minus application table's columns
            SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname, atttypid, attlen, atttypmod
              FROM cte_app_tables_columns
            )) AS t
                           -- do not issue a row if the log or application table does not exist,
                           -- these cases have been already detected
        WHERE (rel_log_schema, rel_log_table) IN
              (SELECT nspname, relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                 WHERE relnamespace = pg_namespace.oid)
          AND (rel_schema, rel_tblseq) IN
              (SELECT nspname, relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                 WHERE relnamespace = pg_namespace.oid)
        ORDER BY 1,2,3
        ) AS t;
-- check all tables of rollbackable groups have their primary key
    RETURN QUERY
      SELECT 'Error: In the rollbackable group "' || rel_group || '", the table "' ||
             rel_schema || '"."' || rel_tblseq || '" has no primary key any more.' AS msg
        FROM emaj.emaj_relation, emaj.emaj_group
        WHERE upper_inf(rel_time_range) AND rel_kind = 'r' AND rel_group = group_name AND group_is_rollbackable
          AND NOT EXISTS
              (SELECT NULL FROM pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_constraint
                 WHERE nspname = rel_schema AND relname = rel_tblseq
                   AND relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid
                   AND contype = 'p')
                       -- do not issue a row if the application table does not exist,
                       -- this case has been already detected
          AND EXISTS
              (SELECT NULL FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                 WHERE nspname = rel_schema AND relname = rel_tblseq AND relnamespace = pg_namespace.oid)
        ORDER BY rel_schema, rel_tblseq, 1;
-- for rollbackable groups, check no table has been altered as UNLOGGED or dropped and recreated as TEMP table after tables groups creation
    RETURN QUERY
      SELECT 'Error: In the rollbackable group "' || rel_group || '", the table "' ||
             rel_schema || '"."' || rel_tblseq || '" is UNLOGGED or TEMP.' AS msg
        FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_group
        WHERE upper_inf(rel_time_range) AND rel_kind = 'r'
          AND relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
          AND group_name = rel_group AND group_is_rollbackable
          AND relpersistence <> 'p'
        ORDER BY rel_schema, rel_tblseq, 1;
-- with PG 11-, check all tables are WITHOUT OIDS (i.e. have not been altered as WITH OIDS after their tables group creation)
    IF emaj._pg_version_num() < 120000 THEN
      RETURN QUERY
        SELECT 'Error: In the rollbackable group "' || rel_group || '", the table "' ||
               rel_schema || '"."' || rel_tblseq || '" is WITH OIDS.' AS msg
          FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_group
          WHERE upper_inf(rel_time_range) AND rel_kind = 'r'
            AND relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
            AND group_name = rel_group AND group_is_rollbackable
            AND relhasoids
          ORDER BY rel_schema, rel_tblseq, 1;
    END IF;
-- check the primary key structure of all tables belonging to rollbackable groups is unchanged
    RETURN QUERY
      SELECT 'Error: In the rollbackable group "' || rel_group || '", the primary key of the table "' ||
             rel_schema || '"."' || rel_tblseq || '" has changed (' ||
             rel_sql_rlbk_pk_columns || ' => ' || current_pk_columns || ').' AS msg
        FROM (
          SELECT rel_schema, rel_tblseq, rel_group, rel_sql_rlbk_pk_columns,
                 string_agg(quote_ident(attname), ',' ORDER BY attnum) AS current_pk_columns
            FROM emaj.emaj_relation, emaj.emaj_group, pg_catalog.pg_attribute, pg_catalog.pg_index, pg_catalog.pg_class,
                 pg_catalog.pg_namespace
            WHERE -- join conditions
                  rel_group = group_name
              AND relname = rel_tblseq AND nspname = rel_schema
              AND pg_attribute.attrelid = pg_index.indrelid
              AND indrelid = pg_class.oid AND relnamespace = pg_namespace.oid
                  -- filter conditions
              AND rel_kind = 'r' AND upper_inf(rel_time_range)
              AND group_is_rollbackable
              AND attnum = ANY (indkey)
              AND indisprimary
              AND attnum > 0 AND attisdropped = FALSE
            GROUP BY rel_schema, rel_tblseq, rel_group, rel_sql_rlbk_pk_columns
          ) AS t
          WHERE rel_sql_rlbk_pk_columns <> current_pk_columns
        ORDER BY rel_schema, rel_tblseq, 1;
-- check all log tables have the 6 required technical columns.
    RETURN QUERY
      SELECT msg FROM (
        SELECT DISTINCT rel_schema, rel_tblseq,
               'Error: In the group "' || rel_group || '", the log table "' ||
               rel_log_schema || '"."' || rel_log_table || '" miss some technical columns (' ||
               string_agg(attname,', ') || ').' AS msg
          FROM (
              SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname
                FROM emaj.emaj_relation,
                     (VALUES ('emaj_verb'), ('emaj_tuple'), ('emaj_gid'), ('emaj_changed'), ('emaj_txid'), ('emaj_user')) AS t(attname)
                WHERE rel_kind = 'r' AND upper_inf(rel_time_range)
                  AND EXISTS
                    (SELECT NULL FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                       WHERE nspname = rel_log_schema AND relname = rel_log_table
                         AND relnamespace = pg_namespace.oid)
            EXCEPT
              SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table, attname
                FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
                WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema
                  AND relname = rel_log_table
                  AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = FALSE
                  AND attname IN ('emaj_verb', 'emaj_tuple', 'emaj_gid', 'emaj_changed', 'emaj_txid', 'emaj_user')
                  AND rel_kind = 'r' AND upper_inf(rel_time_range)
             ) AS t2
          GROUP BY rel_group, rel_schema, rel_tblseq, rel_log_schema, rel_log_table
          ORDER BY 1,2,3
        ) AS t;
--
-- Warnings detection
--
-- detect all sequences associated to a serial or a "generated as identity" column have their related table in the same group
    RETURN QUERY
      SELECT msg FROM (
        WITH serial_dependencies AS (
          SELECT rs.rel_group AS seq_group, rs.rel_schema AS seq_schema, rs.rel_tblseq AS seq_name,
                 rt.rel_group AS tbl_group, nt.nspname AS tbl_schema, ct.relname AS tbl_name
            FROM emaj.emaj_relation rs
                 JOIN pg_catalog.pg_class cs ON cs.relname = rel_tblseq
                 JOIN pg_catalog.pg_namespace ns ON cs.relnamespace = ns.oid AND ns.nspname = rel_schema
                 JOIN pg_depend ON pg_depend.objid = cs.oid
                 JOIN pg_catalog.pg_class ct ON pg_depend.refobjid = ct.oid
                 JOIN pg_catalog.pg_namespace nt ON ct.relnamespace = nt.oid
                 LEFT OUTER JOIN emaj.emaj_relation rt ON rt.rel_schema = nt.nspname AND rt.rel_tblseq = ct.relname
            WHERE rs.rel_kind = 'S' AND upper_inf(rs.rel_time_range)
              AND (rt.rel_time_range IS NULL OR upper_inf(rt.rel_time_range))
              AND pg_depend.classid = pg_depend.refclassid             -- the classid et refclassid must be 'pg_class'
              AND pg_depend.classid = (SELECT oid FROM pg_catalog.pg_class WHERE relname = 'pg_class')
        )
        SELECT DISTINCT seq_schema, seq_name,
               'Warning: In the group "' || seq_group || '", the sequence "' || seq_schema || '"."' || seq_name ||
               '" is linked to the table "' || tbl_schema || '"."' || tbl_name ||
               '" but this table does not belong to any tables group.' AS msg
          FROM serial_dependencies
          WHERE tbl_group IS NULL
        UNION ALL
        SELECT DISTINCT seq_schema, seq_name,
               'Warning: In the group "' || seq_group || '", the sequence "' || seq_schema || '"."' || seq_name ||
               '" is linked to the table "' || tbl_schema || '"."' || tbl_name ||
               '" but this table belongs to another tables group (' || tbl_group || ').' AS msg
          FROM serial_dependencies
          WHERE tbl_group <> seq_group
        ORDER BY 1,2,3
        ) AS t;
-- detect tables linked by a foreign key but not belonging to the same tables group
    RETURN QUERY
      SELECT msg FROM (
        WITH fk_dependencies AS (           -- all foreign keys that link 2 tables at least one of both belongs to a tables group
          SELECT n.nspname AS tbl_schema, t.relname AS tbl_name, c.conname, nf.nspname AS reftbl_schema, tf.relname AS reftbl_name,
                 r.rel_group AS tbl_group, g.group_is_rollbackable AS tbl_group_is_rollbackable,
                 rf.rel_group AS reftbl_group, gf.group_is_rollbackable AS reftbl_group_is_rollbackable
            FROM pg_catalog.pg_constraint c
                 JOIN pg_catalog.pg_class t      ON t.oid = c.conrelid
                 JOIN pg_catalog.pg_namespace n  ON n.oid = t.relnamespace
                 JOIN pg_catalog.pg_class tf     ON tf.oid = c.confrelid
                 JOIN pg_catalog.pg_namespace nf ON nf.oid = tf.relnamespace
                 LEFT OUTER JOIN emaj.emaj_relation r ON r.rel_schema = n.nspname AND r.rel_tblseq = t.relname
                                                     AND upper_inf(r.rel_time_range)
                 LEFT OUTER JOIN emaj.emaj_group g ON g.group_name = r.rel_group
                 LEFT OUTER JOIN emaj.emaj_relation rf ON rf.rel_schema = nf.nspname AND rf.rel_tblseq = tf.relname
                                                     AND upper_inf(rf.rel_time_range)
                 LEFT OUTER JOIN emaj.emaj_group gf ON gf.group_name = rf.rel_group
            WHERE contype = 'f'                                         -- FK constraints only
              AND (r.rel_group IS NOT NULL OR rf.rel_group IS NOT NULL) -- at least the table or the referenced table belongs to
                                                                        -- a tables group
        )
        SELECT tbl_schema, tbl_name,
               'Warning: In the group "' || tbl_group || '", the foreign key "' || conname ||
               '" on the table "' || tbl_schema || '"."' || tbl_name ||
               '" references the table "' || reftbl_schema || '"."' || reftbl_name || '" that does not belong to any group.' AS msg
          FROM fk_dependencies
          WHERE tbl_group IS NOT NULL AND tbl_group_is_rollbackable
            AND reftbl_group IS NULL
        UNION ALL
        SELECT tbl_schema, tbl_name,
               'Warning: In the group "' || reftbl_group || '", the table "' || reftbl_schema || '"."' || reftbl_name ||
               '" is referenced by the the foreign key "' || conname ||
               '" of the table "' || tbl_schema || '"."' || tbl_name || '" that does not belong to any group.' AS msg
          FROM fk_dependencies
          WHERE reftbl_group IS NOT NULL AND reftbl_group_is_rollbackable
            AND tbl_group IS NULL
        UNION ALL
        SELECT tbl_schema, tbl_name,
               'Warning: In the group "' || tbl_group || '", the foreign key "' || conname ||
               '" on the table "' || tbl_schema || '"."' || tbl_name ||
               '" references the table "' || reftbl_schema || '"."' || reftbl_name || '" that belongs to another group ("' ||
               reftbl_group || '")' AS msg
          FROM fk_dependencies
          WHERE tbl_group IS NOT NULL AND reftbl_group IS NOT NULL
            AND tbl_group <> reftbl_group
            AND (tbl_group_is_rollbackable OR reftbl_group_is_rollbackable)
        ORDER BY 1,2,3
        ) AS t;
--
    RETURN;
  END;
$_verify_all_groups$;

CREATE OR REPLACE FUNCTION emaj._verify_all_schemas()
RETURNS SETOF TEXT LANGUAGE plpgsql AS
$_verify_all_schemas$
-- The function verifies that all E-Maj schemas only contains E-Maj objects.
-- It returns a set of warning messages for discovered discrepancies. If no error is detected, no row is returned.
  DECLARE
    v_emajSchema             TEXT = 'emaj';
  BEGIN
-- verify that the expected E-Maj schemas still exist
    RETURN QUERY
      SELECT DISTINCT 'Error: The E-Maj schema "' || sch_name || '" does not exist any more.' AS msg
        FROM emaj.emaj_schema
        WHERE NOT EXISTS (SELECT NULL FROM pg_catalog.pg_namespace WHERE nspname = sch_name)
        ORDER BY msg;
-- detect all objects that are not directly linked to a known table groups in all E-Maj schemas
-- scan pg_class, pg_proc, pg_type, pg_conversion, pg_operator, pg_opclass
    RETURN QUERY
      SELECT msg FROM (
-- look for unexpected tables
        SELECT nspname, 1, 'Error: In the schema "' || nspname ||
               '", the table "' || nspname || '"."' || relname || '" is not linked to any created tables group.' AS msg
           FROM pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND relnamespace = pg_namespace.oid AND relkind = 'r'
             AND (nspname <> v_emajSchema OR relname NOT LIKE E'emaj\\_%')    -- exclude emaj internal tables
             AND NOT EXISTS                                                   -- exclude emaj log tables
                (SELECT NULL FROM emaj.emaj_relation WHERE rel_log_schema = nspname AND rel_log_table = relname)
        UNION ALL
-- look for unexpected sequences
        SELECT nspname, 2, 'Error: In the schema "' || nspname ||
               '", the sequence "' || nspname || '"."' || relname || '" is not linked to any created tables group.' AS msg
           FROM pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND relnamespace = pg_namespace.oid AND relkind = 'S'
             AND (nspname <> v_emajSchema OR relname NOT LIKE E'emaj\\_%')    -- exclude emaj internal sequences
             AND NOT EXISTS                                                   -- exclude emaj log table sequences
                (SELECT NULL FROM emaj.emaj_relation WHERE rel_log_schema = nspname AND rel_log_sequence = relname)
        UNION ALL
-- look for unexpected functions
        SELECT nspname, 3, 'Error: In the schema "' || nspname ||
               '", the function "' || nspname || '"."' || proname  || '" is not linked to any created tables group.' AS msg
           FROM pg_catalog.pg_proc, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND pronamespace = pg_namespace.oid
             AND (nspname <> v_emajSchema OR (proname NOT LIKE E'emaj\\_%' AND proname NOT LIKE E'\\_%'))
                                                                              -- exclude emaj internal functions
             AND NOT EXISTS (                                                 -- exclude emaj log functions
               SELECT NULL FROM emaj.emaj_relation WHERE rel_log_schema = nspname AND rel_log_function = proname)
        UNION ALL
-- look for unexpected composite types
        SELECT nspname, 4, 'Error: In the schema "' || nspname ||
               '", the type "' || nspname || '"."' || relname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND relnamespace = pg_namespace.oid AND relkind = 'c'
             AND (nspname <> v_emajSchema OR (relname NOT LIKE E'emaj\\_%' AND relname NOT LIKE E'\\_%'))
                                                                              -- exclude emaj internal types
        UNION ALL
-- look for unexpected views
        SELECT nspname, 5, 'Error: In the schema "' || nspname ||
               '", the view "' || nspname || '"."' || relname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND relnamespace = pg_namespace.oid  AND relkind = 'v'
             AND (nspname <> v_emajSchema OR relname NOT LIKE E'emaj\\_%')    -- exclude emaj internal views
        UNION ALL
-- look for unexpected foreign tables
        SELECT nspname, 6, 'Error: In the schema "' || nspname ||
               '", the foreign table "' || nspname || '"."' || relname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND relnamespace = pg_namespace.oid  AND relkind = 'f'
        UNION ALL
-- look for unexpected domains
        SELECT nspname, 7, 'Error: In the schema "' || nspname ||
               '", the domain "' || nspname || '"."' || typname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_type, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND typnamespace = pg_namespace.oid AND typisdefined and typtype = 'd'
        UNION ALL
-- look for unexpected conversions
        SELECT nspname, 8, 'Error: In the schema "' || nspname ||
               '", the conversion "' || nspname || '"."' || conname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_conversion, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND connamespace = pg_namespace.oid
        UNION ALL
-- look for unexpected operators
        SELECT nspname, 9, 'Error: In the schema "' || nspname ||
               '", the operator "' || nspname || '"."' || oprname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_operator, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND oprnamespace = pg_namespace.oid
        UNION ALL
-- look for unexpected operator classes
        SELECT nspname, 10, 'Error: In the schema "' || nspname ||
               '", the operator class "' || nspname || '"."' || opcname || '" is not an E-Maj component.' AS msg
           FROM pg_catalog.pg_opclass, pg_catalog.pg_namespace, emaj.emaj_schema
           WHERE nspname = sch_name AND opcnamespace = pg_namespace.oid
        ORDER BY 1, 2, 3
      ) AS t;
    RETURN;
  END;
$_verify_all_schemas$;

CREATE OR REPLACE FUNCTION emaj.emaj_verify_all()
RETURNS SETOF TEXT LANGUAGE plpgsql AS
$emaj_verify_all$
-- The function verifies the consistency between all emaj objects present inside emaj schema and
-- emaj objects related to tables and sequences referenced in the emaj_relation table.
-- It returns a set of warning messages for discovered discrepancies. If no error is detected, a single row is returned.
  DECLARE
    v_errorFound             BOOLEAN = FALSE;
    v_nbMissingEventTrigger  INT;
    r_object                 RECORD;
  BEGIN
-- Global checks
-- detect if the current postgres version is at least 9.5
    IF emaj._pg_version_num() < 90500 THEN
      RETURN NEXT 'Error: The current postgres version (' || version()
               || ') is not compatible with this E-Maj version. It should be at least 9.5.';
      v_errorFound = TRUE;
    END IF;
-- check all E-Maj schemas
    FOR r_object IN
      SELECT msg FROM emaj._verify_all_schemas() msg
    LOOP
      RETURN NEXT r_object.msg;
      IF r_object.msg LIKE 'Error%' THEN
        v_errorFound = TRUE;
      END IF;
    END LOOP;
-- check all groups components
    FOR r_object IN
      SELECT msg FROM emaj._verify_all_groups() msg
    LOOP
      RETURN NEXT r_object.msg;
      IF r_object.msg LIKE 'Error%' THEN
        v_errorFound = TRUE;
      END IF;
    END LOOP;
-- check the emaj_ignored_app_trigger table content
    FOR r_object IN
      SELECT 'Error: No trigger "' || trg_name || '" found for table "' || trg_schema || '"."' || trg_table
          || '". Use the emaj_ignore_app_trigger() function to adjust the list of application triggers that should not be'
          || ' automatically disabled at rollback time.'
             AS msg
        FROM (
          SELECT trg_schema, trg_table, trg_name FROM emaj.emaj_ignored_app_trigger
            EXCEPT
          SELECT nspname, relname, tgname
            FROM pg_catalog.pg_namespace, pg_catalog.pg_class, pg_catalog.pg_trigger
            WHERE relnamespace = pg_namespace.oid AND tgrelid = pg_class.oid
        ) AS t
    LOOP
      RETURN NEXT r_object.msg;
      v_errorFound = TRUE;
    END LOOP;
-- report a warning if some E-Maj event triggers are missing
    SELECT 3 - count(*)
      INTO v_nbMissingEventTrigger FROM pg_catalog.pg_event_trigger
      WHERE evtname IN ('emaj_protection_trg','emaj_sql_drop_trg','emaj_table_rewrite_trg');
    IF v_nbMissingEventTrigger > 0 THEN
      RETURN NEXT 'Warning: Some E-Maj event triggers are missing. Your database administrator may (re)create them using the'
               || ' emaj_upgrade_after_postgres_upgrade.sql script.';
    END IF;
-- report a warning if some E-Maj event triggers exist but are not enabled
    PERFORM 1 FROM pg_catalog.pg_event_trigger WHERE evtname LIKE 'emaj%' AND evtenabled = 'D';
    IF FOUND THEN
      RETURN NEXT 'Warning: Some E-Maj event triggers exist but are disabled. You may enable them using the'
               || ' emaj_enable_protection_by_event_triggers() function.';
    END IF;
-- final message if no error has been yet detected
    IF NOT v_errorFound THEN
      RETURN NEXT 'No error detected';
    END IF;
-- check the value of the group_has_waiting_changes column of the emaj_group table, and reset it at the right value if needed
    PERFORM emaj._adjust_group_properties();
    RETURN;
  END;
$emaj_verify_all$;
COMMENT ON FUNCTION emaj.emaj_verify_all() IS
$$Verifies the consistency between existing E-Maj and application objects.$$;

CREATE OR REPLACE FUNCTION emaj._adjust_group_properties()
RETURNS INTEGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_adjust_group_properties$
-- The function adjusts the content of the emaj_group table.
-- It actualy only adjusts the group_has_waiting_changes column.
-- This group_has_waiting_changes column is normally set by a trigger on emaj_group_def.
-- But in some cases, its value may not correspond to the real situation. This function sets its value to the proper value.
-- It mainly joins the content of the emaj_group_def and the emaj_relation table to detect differences.
-- It also calls the _verify_groups() function to detect potential corrupted groups that would need to be altered.
-- If needed, the emaj_group table is updated.
-- The function is declared SECURITY DEFINER so that emaj_viewer roles can execute it when calling the emaj_verify_all() function
-- It returns the number of groups that have been updated.
  DECLARE
    v_nbAdjustedGroups       INT = 0;
  BEGIN
-- process the group_has_waiting_changes column using one big SQL statement
    WITH
      tblseq_with_changes AS (
        -- tables and sequences modified or deleted from emaj_group_def
        SELECT rel_group, rel_schema, rel_tblseq
          FROM emaj.emaj_relation
               LEFT OUTER JOIN emaj.emaj_group_def ON (rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq
                                                       AND rel_group = grpdef_group)
          WHERE upper_inf(rel_time_range)
            AND (
              -- the relations that do not belong to the groups anymore
                  grpdef_group IS NULL
              -- the tables whose log data tablespace in emaj_group_def has changed
              --         or whose log index tablespace in emaj_group_def has changed
               OR (rel_kind = 'r'
                  AND (coalesce(rel_log_dat_tsp,'') <> coalesce(grpdef_log_dat_tsp,'')
                    OR coalesce(rel_log_idx_tsp,'') <> coalesce(grpdef_log_idx_tsp,'')
                      ))
              -- the tables or sequences that change their group ownership
               OR (rel_group <> grpdef_group)
              -- the tables that change their priority level
               OR (rel_priority IS NULL AND grpdef_priority IS NOT NULL) OR
                  (rel_priority IS NOT NULL AND grpdef_priority IS NULL) OR
                  (rel_priority <> grpdef_priority)
                )
      UNION
        -- new tables or sequences in emaj_group_def
        SELECT grpdef_group, grpdef_schema, grpdef_tblseq
          FROM emaj.emaj_group_def, pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_group
          WHERE NOT EXISTS (
                SELECT NULL FROM emaj.emaj_relation
                  WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq AND upper_inf(rel_time_range))
            AND relnamespace = pg_namespace.oid AND nspname = grpdef_schema AND relname = grpdef_tblseq
            AND group_name = grpdef_group
      UNION
        -- dammaged tables
        SELECT ver_group, ver_schema, ver_tblseq
          FROM emaj._verify_groups(
                 (SELECT array_agg(group_name) FROM emaj.emaj_group)
                 , false)
          WHERE ver_group IS NOT NULL
      ),
      -- get the list of groups that would need to be altered
      group_with_changes AS (
        SELECT DISTINCT rel_group AS group_name
          FROM tblseq_with_changes
      ),
      -- adjust the group_has_waiting_changes column, only when needed
      modified_group AS (
        UPDATE emaj.emaj_group SET group_has_waiting_changes = NOT group_has_waiting_changes
          WHERE (group_has_waiting_changes = FALSE
                 AND group_name IN (SELECT group_name FROM group_with_changes))
             OR (group_has_waiting_changes = TRUE
                 AND NOT EXISTS (SELECT 0 FROM group_with_changes WHERE group_with_changes.group_name = emaj_group.group_name))
          RETURNING group_name, group_has_waiting_changes
      ),
      -- insert a row in the history for each flag change
      hist_insert AS (
        INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
          SELECT 'ADJUST_GROUP_PROPERTIES', group_name, 'Set the group_has_waiting_changes column to ' || group_has_waiting_changes
            FROM modified_group
            ORDER BY group_name
      )
      SELECT count(*) INTO v_nbAdjustedGroups FROM modified_group;
    RETURN v_nbAdjustedGroups;
  END;
$_adjust_group_properties$;

------------------------------------------
--                                      --
-- event trigger related functions      --
--                                      --
------------------------------------------

CREATE OR REPLACE FUNCTION public._emaj_protection_event_trigger_fnct()
 RETURNS EVENT_TRIGGER LANGUAGE plpgsql AS
$_emaj_protection_event_trigger_fnct$
-- This function is called by the emaj_protection_trg event trigger.
-- The function only blocks any attempt to drop the emaj schema or the emaj extension.
-- It is located into the public schema to be able to detect the emaj schema removal attempt.
-- It is also unlinked from the emaj extension to be able to detect the emaj extension removal attempt.
-- Another pair of function and event trigger handles all other drop attempts.
  DECLARE
    r_dropped                RECORD;
  BEGIN
-- scan all dropped objects
    FOR r_dropped IN
      SELECT object_type, object_name FROM pg_event_trigger_dropped_objects()
    LOOP
      IF r_dropped.object_type = 'schema' AND r_dropped.object_name = 'emaj' THEN
-- detecting an attempt to drop the emaj object
        RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the schema "emaj". Please use the emaj_uninstall.sql script if you'
                        ' really want to remove all E-Maj components.';
      END IF;
      IF r_dropped.object_type = 'extension' AND r_dropped.object_name = 'emaj' THEN
-- detecting an attempt to drop the emaj extension
        RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the emaj extension. Please use the emaj_uninstall.sql script if you'
                        ' really want to remove all E-Maj components.';
      END IF;
    END LOOP;
  END;
$_emaj_protection_event_trigger_fnct$;
COMMENT ON FUNCTION public._emaj_protection_event_trigger_fnct() IS
$$E-Maj extension: support of the emaj_protection_trg event trigger.$$;

CREATE OR REPLACE FUNCTION emaj._event_trigger_sql_drop_fnct()
RETURNS EVENT_TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_event_trigger_sql_drop_fnct$
-- This function is called by the emaj_sql_drop_trg event trigger.
-- The function blocks any ddl operation that leads to a drop of
--   - an application table or a sequence registered into an active (not stopped) E-Maj group, or a schema containing such tables/sequence
--   - an E-Maj schema, a log table, a log sequence, a log function or a log trigger
-- The drop of emaj schema or extension is managed by another event trigger.
-- The function is declared SECURITY DEFINER so that non emaj roles can access the emaj internal tables when dropping their objects.
  DECLARE
    v_groupName              TEXT;
    r_dropped                RECORD;
  BEGIN
-- scan all dropped objects
    FOR r_dropped IN
      SELECT object_type, schema_name, object_name, object_identity, original FROM pg_event_trigger_dropped_objects()
    LOOP
      CASE
        WHEN r_dropped.object_type = 'schema' THEN
-- the object is a schema
--   look at the emaj_relation table to verify that the schema being dropped does not belong to any active (not stopped) group
          SELECT string_agg(DISTINCT rel_group, ', ' ORDER BY rel_group) INTO v_groupName FROM emaj.emaj_relation, emaj.emaj_group
            WHERE rel_schema = r_dropped.object_name AND upper_inf(rel_time_range)
              AND group_name = rel_group AND group_is_logging;
          IF v_groupName IS NOT NULL THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the application schema "%". But it belongs to the active tables'
                            ' groups "%".', r_dropped.object_name, v_groupName;
          END IF;
--   look at the emaj_schema table to verify that the schema being dropped is not an E-Maj schema containing log tables
          PERFORM 1 FROM emaj.emaj_schema
            WHERE sch_name = r_dropped.object_name;
          IF FOUND THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the schema "%". But dropping an E-Maj schema is not allowed.',
              r_dropped.object_name;
          END IF;
        WHEN r_dropped.object_type = 'table' THEN
-- the object is a table
--   look at the emaj_relation table to verify that the table being dropped does not currently belong to any active (not stopped) group
          SELECT rel_group INTO v_groupName FROM emaj.emaj_relation, emaj.emaj_group
            WHERE rel_schema = r_dropped.schema_name AND rel_tblseq = r_dropped.object_name AND upper_inf(rel_time_range)
              AND group_name = rel_group AND group_is_logging;
          IF FOUND THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the application table "%.%". But it belongs to the active tables'
                            ' group "%".', r_dropped.schema_name, r_dropped.object_name, v_groupName;
          END IF;
--   look at the emaj_relation table to verify that the table being dropped is not a log table
          PERFORM 1 FROM emaj.emaj_relation
            WHERE rel_log_schema = r_dropped.schema_name AND rel_log_table = r_dropped.object_name;
          IF FOUND THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the log table "%.%". But dropping an E-Maj log table is not allowed.',
                            r_dropped.schema_name, r_dropped.object_name;
          END IF;
        WHEN r_dropped.object_type = 'sequence' THEN
-- the object is a sequence
--   look at the emaj_relation table to verify that the sequence being dropped does not currently belong to any active (not stopped) group
          SELECT rel_group INTO v_groupName FROM emaj.emaj_relation, emaj.emaj_group
            WHERE rel_schema = r_dropped.schema_name AND rel_tblseq = r_dropped.object_name AND upper_inf(rel_time_range)
              AND group_name = rel_group AND group_is_logging;
          IF FOUND THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the application sequence "%.%". But it belongs to the active'
                            ' tables group "%".', r_dropped.schema_name, r_dropped.object_name, v_groupName;
          END IF;
--   look at the emaj_relation table to verify that the sequence being dropped is not a log sequence
          PERFORM 1 FROM emaj.emaj_relation
            WHERE rel_log_schema = r_dropped.schema_name AND rel_log_sequence = r_dropped.object_name;
          IF FOUND THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the log sequence "%.%". But dropping an E-Maj sequence is not'
                           ' allowed.', r_dropped.schema_name, r_dropped.object_name;
          END IF;
        WHEN r_dropped.object_type = 'function' THEN
-- the object is a function
--   look at the emaj_relation table to verify that the function being dropped is not a log function
          PERFORM 1 FROM emaj.emaj_relation
            WHERE  r_dropped.object_identity = quote_ident(rel_log_schema) || '.' || quote_ident(rel_log_function) || '()';
          IF FOUND THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the log function "%". But dropping an E-Maj log function is not'
                            ' allowed.', r_dropped.object_identity;
          END IF;
        WHEN r_dropped.object_type = 'trigger' THEN
-- the object is a trigger
--   look at the trigger name pattern to identify emaj trigger
--   and do not raise an exception if the triggers drop is derived from a drop of a table or a function
          IF r_dropped.original AND
             (r_dropped.object_identity LIKE 'emaj_log_trg%' OR r_dropped.object_identity LIKE 'emaj_trunc_trg%') THEN
            RAISE EXCEPTION 'E-Maj event trigger: Attempting to drop the "%" E-Maj trigger. But dropping an E-Maj trigger is not allowed.',
              r_dropped.object_identity;
          END IF;
        ELSE
          CONTINUE;
      END CASE;
    END LOOP;
  END;
$_event_trigger_sql_drop_fnct$;
COMMENT ON FUNCTION emaj._event_trigger_sql_drop_fnct() IS
$$E-Maj extension: support of the emaj_sql_drop_trg event trigger.$$;

CREATE OR REPLACE FUNCTION emaj._event_trigger_table_rewrite_fnct()
RETURNS EVENT_TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_event_trigger_table_rewrite_fnct$
-- This function is called by the emaj_table_rewrite_trg event trigger.
-- The function blocks any ddl operation that leads to a table rewrite for:
--   - an application table registered into an active (not stopped) E-Maj group,
--   - an E-Maj log table.
-- The function is declared SECURITY DEFINER so that non emaj roles can access the emaj internal tables when altering their tables.
  DECLARE
    v_tableSchema            TEXT;
    v_tableName              TEXT;
    v_groupName              TEXT;
  BEGIN
-- get the schema and table names of the altered table
    SELECT nspname, relname INTO v_tableSchema, v_tableName FROM pg_catalog.pg_class, pg_catalog.pg_namespace
      WHERE relnamespace = pg_namespace.oid AND pg_class.oid = pg_event_trigger_table_rewrite_oid();
-- look at the emaj_relation table to verify that the table being rewritten does not belong to any active (not stopped) group
    SELECT rel_group INTO v_groupName FROM emaj.emaj_relation, emaj.emaj_group
      WHERE rel_schema = v_tableSchema AND rel_tblseq = v_tableName AND upper_inf(rel_time_range)
        AND group_name = rel_group AND group_is_logging;
    IF FOUND THEN
-- the table is an application table that belongs to a group, so raise an exception
      RAISE EXCEPTION 'E-Maj event trigger: Attempting to change the application table "%.%" structure. But the table belongs to the'
                      ' active tables group "%".', v_tableSchema, v_tableName , v_groupName;
    END IF;
-- look at the emaj_relation table to verify that the table being rewritten is not a known log table
    SELECT rel_group INTO v_groupName FROM emaj.emaj_relation
      WHERE rel_log_schema = v_tableSchema AND rel_log_table = v_tableName;
    IF FOUND THEN
-- the table is an E-Maj log table, so raise an exception
      RAISE EXCEPTION 'E-Maj event trigger: Attempting to change the log table "%.%" structure. But the table belongs to the tables'
                      ' group "%".', v_tableSchema, v_tableName , v_groupName;
    END IF;
  END;
$_event_trigger_table_rewrite_fnct$;
COMMENT ON FUNCTION emaj._event_trigger_table_rewrite_fnct() IS
$$E-Maj extension: support of the emaj_table_rewrite_trg event trigger.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_disable_protection_by_event_triggers()
RETURNS INT LANGUAGE plpgsql AS
$emaj_disable_protection_by_event_triggers$
-- This function disables all known E-Maj event triggers that are in enabled state.
-- It may be used by an emaj_adm role.
-- Output: number of effectively disabled event triggers.
  DECLARE
    v_eventTriggers          TEXT[];
  BEGIN
-- call the _disable_event_triggers() function and get the disabled event trigger names array
    SELECT emaj._disable_event_triggers() INTO v_eventTriggers;
-- insert a row into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES ('DISABLE_PROTECTION', 'EVENT TRIGGERS DISABLED',
              CASE WHEN v_eventTriggers <> ARRAY[]::TEXT[] THEN array_to_string(v_eventTriggers, ', ') ELSE '<none>' END);
-- return the number of disabled event triggers
    RETURN coalesce(array_length(v_eventTriggers,1),0);
  END;
$emaj_disable_protection_by_event_triggers$;
COMMENT ON FUNCTION emaj.emaj_disable_protection_by_event_triggers() IS
$$Disables the protection of E-Maj components by event triggers.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_enable_protection_by_event_triggers()
RETURNS INT LANGUAGE plpgsql AS
$emaj_enable_protection_by_event_triggers$
-- This function enables all known E-Maj event triggers that are in disabled state.
-- It may be used by an emaj_adm role.
-- Output: number of effectively enabled event triggers.
  DECLARE
    v_eventTriggers          TEXT[];
  BEGIN
-- build the event trigger names array from the pg_event_trigger table
    SELECT coalesce(array_agg(evtname  ORDER BY evtname),ARRAY[]::TEXT[]) INTO v_eventTriggers
      FROM pg_catalog.pg_event_trigger WHERE evtname LIKE 'emaj%' AND evtenabled = 'D';
-- call the _enable_event_triggers() function
    PERFORM emaj._enable_event_triggers(v_eventTriggers);
-- insert a row into the emaj_hist table
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_wording)
      VALUES ('ENABLE_PROTECTION', 'EVENT TRIGGERS ENABLED',
              CASE WHEN v_eventTriggers <> ARRAY[]::TEXT[] THEN array_to_string(v_eventTriggers, ', ') ELSE '<none>' END);
-- return the number of disabled event triggers
    RETURN coalesce(array_length(v_eventTriggers,1),0);
  END;
$emaj_enable_protection_by_event_triggers$;
COMMENT ON FUNCTION emaj.emaj_enable_protection_by_event_triggers() IS
$$Enables the protection of E-Maj components by event triggers.$$;

CREATE OR REPLACE FUNCTION emaj._disable_event_triggers()
RETURNS TEXT[] LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_disable_event_triggers$
-- This function disables all known E-Maj event triggers that are in enabled state.
-- The function is called by functions that alter or drop E-Maj components, such as
--   _drop_group(), _alter_groups(), _delete_before_mark_group() and _reset_groups().
-- It is also called by the user emaj_disable_event_triggers_protection() function.
-- Output: array of effectively disabled event trigger names. It can be reused as input when calling _enable_event_triggers().
  DECLARE
    v_eventTrigger           TEXT;
    v_eventTriggers          TEXT[] = ARRAY[]::TEXT[];
  BEGIN
-- build the event trigger names array from the pg_event_trigger table
-- (pg_event_trigger table doesn't exists in 9.2- postgres versions)
-- A single operation like emaj_alter_groups() may call the function several times. But this is not an issue as only enabled triggers are
-- disabled.
    SELECT coalesce(array_agg(evtname ORDER BY evtname),ARRAY[]::TEXT[]) INTO v_eventTriggers
      FROM pg_catalog.pg_event_trigger WHERE evtname LIKE 'emaj%' AND evtenabled <> 'D';
-- disable each event trigger
    FOREACH v_eventTrigger IN ARRAY v_eventTriggers
    LOOP
      EXECUTE format('ALTER EVENT TRIGGER %I DISABLE',
                     v_eventTrigger);
    END LOOP;
    RETURN v_eventTriggers;
  END;
$_disable_event_triggers$;

CREATE OR REPLACE FUNCTION emaj._enable_event_triggers(v_eventTriggers TEXT[])
RETURNS TEXT[] LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS
$_enable_event_triggers$
-- This function enables all event triggers supplied as parameter.
-- The function is called by functions that alter or drop E-Maj components, such as
--   _drop_group(), _alter_groups(), _delete_before_mark_group() and _reset_groups().
-- It is also called by the user emaj_enable_event_triggers_protection() function.
-- Input: array of event trigger names to enable.
-- Output: same array.
  DECLARE
    v_eventTrigger           TEXT;
  BEGIN
    FOREACH v_eventTrigger IN ARRAY v_eventTriggers
    LOOP
      EXECUTE format('ALTER EVENT TRIGGER %I ENABLE',
                     v_eventTrigger);
    END LOOP;
    RETURN v_eventTriggers;
  END;
$_enable_event_triggers$;

------------------------------------------
--                                      --
-- event triggers                       --
--                                      --
------------------------------------------
--
-- Event triggers creation depends on postgres version:
-- - sql_drop event trigger needs postgres 9.3+
-- - table_rewrite trigger needs postgres 9.5+
-- Now that the oldest supported postgres version is 9.5, all installations should have both event triggers.
-- If E-Maj has been installed with older postgres versions, and this version has then been upgraded, the
-- set_event_triggers_protection.sql script can be used to add the missing components.

-- sql_drop event triggers

CREATE EVENT TRIGGER emaj_protection_trg
  ON sql_drop
  WHEN TAG IN ('DROP EXTENSION','DROP SCHEMA')
  EXECUTE PROCEDURE public._emaj_protection_event_trigger_fnct();
COMMENT ON EVENT TRIGGER emaj_protection_trg IS
$$Blocks the removal of the emaj extension or schema.$$;

-- remove both event trigger components from the extension, so that they can fire the "DROP EXTENSION emaj"
ALTER EXTENSION emaj DROP FUNCTION public._emaj_protection_event_trigger_fnct();
ALTER EXTENSION emaj DROP EVENT TRIGGER emaj_protection_trg;

CREATE EVENT TRIGGER emaj_sql_drop_trg
  ON sql_drop
  WHEN TAG IN ('DROP FUNCTION','DROP SCHEMA','DROP SEQUENCE','DROP TABLE','DROP TRIGGER')
  EXECUTE PROCEDURE emaj._event_trigger_sql_drop_fnct();
COMMENT ON EVENT TRIGGER emaj_sql_drop_trg IS
$$Controls the removal of E-Maj components.$$;

-- table_rewrite event trigger

CREATE EVENT TRIGGER emaj_table_rewrite_trg
  ON table_rewrite
  EXECUTE PROCEDURE emaj._event_trigger_table_rewrite_fnct();
COMMENT ON EVENT TRIGGER emaj_table_rewrite_trg IS
$$Controls some changes in E-Maj tables structure.$$;

------------------------------------
--                                --
-- rights on emaj components      --
--                                --
------------------------------------

-- global rights on functions
--

-- revoke all rights on all created functions from PUBLIC
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA emaj FROM PUBLIC;

-- rights given to emaj_adm
--
-- emaj_adm can execute all emaj functions and access all emaj tables without any restrictions

GRANT ALL ON SCHEMA emaj TO emaj_adm;
GRANT ALL ON ALL TABLES IN SCHEMA emaj TO emaj_adm;
GRANT ALL ON ALL SEQUENCES IN SCHEMA emaj TO emaj_adm;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA emaj TO emaj_adm;

-- rights given to emaj_viewer
--
-- emaj_viewer can only
-- ... view the emaj objects, i.e. the content of emaj and log tables,
--     except the emaj_param table that emaj_viewer should only see through the emaj_visible_param view
--     that hides the password used by the configured dblink user

GRANT USAGE ON SCHEMA emaj TO emaj_viewer;
GRANT SELECT ON ALL TABLES IN SCHEMA emaj TO emaj_viewer;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA emaj TO emaj_viewer;

REVOKE SELECT ON TABLE emaj.emaj_param FROM emaj_viewer;

-- ... and execute a subset of emaj functions for which rights are explicitely granted
GRANT EXECUTE ON FUNCTION emaj._pg_version_num() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._check_group_names(v_groupNames TEXT[], v_mayBeNull BOOLEAN, v_lockGroups BOOLEAN, v_checkList TEXT)
                          TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._check_mark_name(v_groupNames TEXT[], v_mark TEXT, v_checkList TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._check_marks_range(v_groupNames TEXT[], INOUT v_firstMark TEXT, INOUT v_lastMark TEXT,
                          OUT v_firstMarkTimeId BIGINT, OUT v_lastMarkTimeId BIGINT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_get_current_log_table(v_app_schema TEXT, v_app_table TEXT,
                          OUT log_schema TEXT, OUT log_table TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._log_stat_tbl(r_rel emaj.emaj_relation, v_firstMarkTimeId BIGINT, v_lastMarkTimeId BIGINT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._verify_groups(v_groupNames TEXT[], v_onErrorStop boolean) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_datetime TIMESTAMPTZ) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_mark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._get_previous_mark_group(v_groupName TEXT, v_mark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._rlbk_check(v_groupNames TEXT[], v_mark TEXT, v_isAlterGroupAllowed BOOLEAN, isRollbackSimulation BOOLEAN)
                          TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._rlbk_planning(v_rlbkId INT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._rlbk_set_batch_number(v_rlbkId INT, v_batchNumber INT, v_schema TEXT, v_table TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_cleanup_rollback_state() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._cleanup_rollback_state() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_log_stat_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_log_stat_groups(v_groupNames TEXT[], v_firstMark TEXT, v_lastMark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._log_stat_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_firstMark TEXT, v_lastMark TEXT)
                          TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_detailed_log_stat_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_detailed_log_stat_groups(v_groupNames TEXT[], v_firstMark TEXT, v_lastMark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._detailed_log_stat_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_firstMark TEXT, v_lastMark TEXT)
                          TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_estimate_rollback_group(v_groupName TEXT, v_mark TEXT, v_isLoggedRlbk BOOLEAN) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_estimate_rollback_groups(v_groupNames TEXT[], v_mark TEXT, v_isLoggedRlbk BOOLEAN) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._estimate_rollback_groups(v_groupNames TEXT[], v_multiGroup BOOLEAN, v_mark TEXT, v_isLoggedRlbk BOOLEAN)
                          TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_rollback_activity() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._rollback_activity() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_get_consolidable_rollbacks() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._verify_all_groups() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._verify_all_schemas() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_verify_all() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._adjust_group_properties() TO emaj_viewer;

----------------------------------------
--                                    --
-- specific operations for extension  --
--                                    --
----------------------------------------
-- register emaj tables content as candidate for pg_dump
SELECT pg_catalog.pg_extension_config_dump('emaj_param','WHERE param_key <> ''emaj_version''');
SELECT pg_catalog.pg_extension_config_dump('emaj_hist','WHERE hist_id > 1');
SELECT pg_catalog.pg_extension_config_dump('emaj_group_def','');
SELECT pg_catalog.pg_extension_config_dump('emaj_time_stamp','');
SELECT pg_catalog.pg_extension_config_dump('emaj_group','');
SELECT pg_catalog.pg_extension_config_dump('emaj_schema','WHERE sch_name <> ''emaj''');
SELECT pg_catalog.pg_extension_config_dump('emaj_relation','');
SELECT pg_catalog.pg_extension_config_dump('emaj_rel_hist','');
SELECT pg_catalog.pg_extension_config_dump('emaj_mark','');
SELECT pg_catalog.pg_extension_config_dump('emaj_sequence','');
SELECT pg_catalog.pg_extension_config_dump('emaj_seq_hole','');
SELECT pg_catalog.pg_extension_config_dump('emaj_alter_plan','');
SELECT pg_catalog.pg_extension_config_dump('emaj_rlbk','');
SELECT pg_catalog.pg_extension_config_dump('emaj_rlbk_session','');
SELECT pg_catalog.pg_extension_config_dump('emaj_rlbk_plan','');
SELECT pg_catalog.pg_extension_config_dump('emaj_rlbk_stat','');
SELECT pg_catalog.pg_extension_config_dump('emaj_ignored_app_trigger','');

-- register emaj sequences values as candidate for pg_dump
SELECT pg_catalog.pg_extension_config_dump('emaj_global_seq','');
SELECT pg_catalog.pg_extension_config_dump('emaj.emaj_hist_hist_id_seq','');
SELECT pg_catalog.pg_extension_config_dump('emaj.emaj_time_stamp_time_id_seq','');
SELECT pg_catalog.pg_extension_config_dump('emaj.emaj_rlbk_rlbk_id_seq','');

-- insert the init record into the operation history
INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording) VALUES ('EMAJ_INSTALL','E-Maj <devel>', 'Initialisation completed');
-- insert the emaj schema into the emaj_schema table
INSERT INTO emaj.emaj_schema (sch_name) VALUES ('emaj');

-- Set comments for all internal functions,
-- by directly inserting a row in the pg_description table for all emaj functions that do not have yet a recorded comment
INSERT INTO pg_catalog.pg_description (objoid, classoid, objsubid, description)
  SELECT pg_proc.oid, pg_class.oid, 0 , 'E-Maj internal function'
    FROM pg_catalog.pg_proc, pg_catalog.pg_class
    WHERE pg_class.relname = 'pg_proc'
      AND pg_proc.oid IN               -- list all emaj functions that do not have yet a comment in pg_description
       (SELECT pg_proc.oid
          FROM pg_catalog.pg_proc
               JOIN pg_catalog.pg_namespace ON (pronamespace=pg_namespace.oid)
               LEFT OUTER JOIN pg_catalog.pg_description ON (pg_description.objoid = pg_proc.oid
                                     AND classoid = (SELECT oid FROM pg_catalog.pg_class WHERE relname = 'pg_proc')
                                     AND objsubid = 0)
          WHERE nspname = 'emaj' AND (proname LIKE E'emaj\\_%' OR proname LIKE E'\\_%')
            AND pg_description.description IS NULL
       );

-- final checks and messages
DO LANGUAGE plpgsql
$do$
  BEGIN
-- check the max_prepared_transactions GUC value and report a warning if its value is too low for parallel rollback
    IF current_setting('max_prepared_transactions')::INT <= 1 THEN
      RAISE WARNING 'E-Maj installation: As the max_prepared_transactions parameter value (%) on this cluster is too low, no parallel'
                    ' rollback is possible.', current_setting('max_prepared_transactions');
    END IF;
    RETURN;
  END;
$do$;
