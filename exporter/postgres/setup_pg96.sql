DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ccp_monitoring') THEN
        CREATE ROLE ccp_monitoring WITH LOGIN;
    END IF;
END
$$;
 
CREATE SCHEMA IF NOT EXISTS monitor AUTHORIZATION ccp_monitoring;

DROP FUNCTION IF EXISTS monitor.pg_stat_activity();
CREATE OR REPLACE FUNCTION monitor.pg_stat_activity() RETURNS SETOF pg_catalog.pg_stat_activity
    LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN 
    RETURN query(SELECT * FROM pg_catalog.pg_stat_activity); 
END
$$; 

REVOKE ALL ON FUNCTION monitor.pg_stat_activity() FROM PUBLIC;


DROP FUNCTION IF EXISTS monitor.streaming_replica_check();
CREATE OR REPLACE FUNCTION monitor.streaming_replica_check() RETURNS TABLE (replica_hostname text, replica_addr inet, replica_port int, byte_lag numeric)
    LANGUAGE SQL SECURITY DEFINER
AS $$
    SELECT client_hostname as replica_hostname
        , client_addr as replica_addr
        , client_port as replica_port
            , pg_xlog_location_diff(pg_stat_replication.sent_location, pg_stat_replication.replay_location) AS byte_lag 
                FROM pg_catalog.pg_stat_replication;
$$;

REVOKE ALL ON FUNCTION monitor.streaming_replica_check() FROM PUBLIC;


-- Drop previously unused version of this function if it exists from older pgmonitor installs
DROP FUNCTION IF EXISTS monitor.pg_ls_wal_dir(text);

CREATE OR REPLACE FUNCTION monitor.pg_ls_waldir() RETURNS SETOF TEXT 
    LANGUAGE plpgsql SECURITY DEFINER
as $$
BEGIN 
    IF current_setting('server_version_num')::int >= 100000 THEN
       RAISE EXCEPTION 'Use version of this function included with core in PG10+';
    ELSE
        RETURN query(SELECT pg_catalog.pg_ls_dir('pg_xlog')); 
    END IF;
END
$$;
REVOKE ALL ON FUNCTION monitor.pg_ls_waldir() FROM PUBLIC;


DROP TABLE IF EXISTS monitor.pgbackrest_info CASCADE;
CREATE TABLE IF NOT EXISTS monitor.pgbackrest_info (config_file text NOT NULL, data jsonb NOT NULL);

CREATE OR REPLACE FUNCTION monitor.pgbackrest_info()
 RETURNS SETOF monitor.pgbackrest_info
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
BEGIN
    -- Get pgBackRest info in JSON format

    -- Ensure table is empty 
    TRUNCATE monitor.pgbackrest_info;

    -- Copy data into the table directory from the pgBackRest into command
    COPY monitor.pgbackrest_info (config_file, data) FROM program '/usr/bin/pgbackrest-info.sh' WITH (format text,DELIMITER '|');

    RETURN QUERY SELECT * FROM monitor.pgbackrest_info;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No backups being returned from pgbackrest info command';
    END IF;

    TRUNCATE monitor.pgbackrest_info;

END 
$function$;


DROP FUNCTION IF EXISTS monitor.sequence_status();
CREATE FUNCTION monitor.sequence_status() RETURNS TABLE (sequence_name text, last_value bigint, slots numeric, used numeric, percent int, cycle boolean, numleft numeric, table_usage text)  
    LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE

v_int_max   int8;
v_int2_max  int2 := 32767;
v_int4_max  int4 := 2147483647;
v_int8_max  int8 := 9223372036854775807;
v_row       record;
v_sql       text;

BEGIN

FOR v_row IN 
     WITH default_value_sequences AS (
        -- Get sequences defined as default values with related table
        SELECT s.oid AS seqrelid, c.oid, t.typname
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_attrdef ad ON (ad.adrelid,ad.adnum) = (a.attrelid,a.attnum)
        JOIN pg_catalog.pg_type t ON a.atttypid = t.oid
        JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
        JOIN pg_catalog.pg_class s ON s.oid = regexp_replace(pg_get_expr(ad.adbin,ad.adrelid), $re$^nextval\('(.+?)'::regclass\)$$re$, $re$\1$re$)::regclass
        WHERE (pg_get_expr(ad.adbin,ad.adrelid)) ~ '^nextval\('
        AND t.typname IN ('int2', 'int4', 'int8')
    ), dep_sequences AS (
        -- Get sequences set as dependencies with related tables (identities)    
        SELECT s.oid AS seqrelid, c.oid, t.typname
        FROM pg_catalog.pg_class s 
        JOIN pg_catalog.pg_depend d ON s.oid = d.objid
        JOIN pg_catalog.pg_attribute a ON (d.refobjid,d.refobjsubid) = (a.attrelid,a.attnum)
        JOIN pg_catalog.pg_type t ON a.atttypid = t.oid
        JOIN pg_catalog.pg_class c ON d.refobjid = c.oid
        WHERE s.relkind = ('S')
        AND t.typname IN ('int2', 'int4', 'int8')
        UNION
        SELECT seqrelid, oid, typname FROM default_value_sequences
    )
    -- Get any remaining sequences
    SELECT n.nspname AS schemaname
        , s.relname AS sequencename
        , CASE WHEN typname IS NULL THEN 'int8' ELSE typname::text END AS typname
        , string_agg(ds.oid::regclass::text, ', ') AS table_usage
    FROM pg_catalog.pg_class s
    JOIN pg_catalog.pg_namespace n ON s.relnamespace = n.oid
    LEFT JOIN dep_sequences ds ON s.oid = ds.seqrelid
    WHERE s.relkind = 'S'
    GROUP BY 1,2,3
LOOP
    IF v_row.typname = 'int2' THEN
        v_int_max := v_int2_max;
    ELSIF v_row.typname = 'int4' THEN
        v_int_max := v_int4_max;
    ELSIF v_row.typname = 'int8' THEN
        v_int_max := v_int8_max;
    ELSE
        RAISE EXCEPTION 'Unexpected datatype encountered: %', v_row.typname;
    END IF;


    v_sql := format ('SELECT sequence_name
                , last_value
                , slots
                , used
                , ROUND(used/slots*100)::int AS percent
                , cycle
                , CASE WHEN slots < used THEN 0 ELSE slots - used END AS numleft
                , table_usage
            FROM (
                 SELECT ''%1$s.%2$s''::text AS sequence_name
                    , COALESCE(s.last_value,s.min_value) AS last_value
                    , s.is_cycled AS cycle
                    , CEIL((%3$L-min_value::NUMERIC+1)/s.increment_by::NUMERIC) AS slots
                    , CEIL((COALESCE(s.last_value,s.min_value)-s.min_value::NUMERIC+1)/s.increment_by::NUMERIC) AS used
                    , %4$L::text AS table_usage
                FROM %1$I.%2$I s
            ) x 
            ORDER BY ROUND(used/slots*100) DESC'
        , v_row.schemaname
        , v_row.sequencename
        , v_int_max
        , v_row.table_usage);

    RETURN QUERY EXECUTE v_sql;

END LOOP;

END
$function$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA monitor TO ccp_monitoring;
GRANT ALL ON ALL TABLES IN SCHEMA monitor TO ccp_monitoring;
