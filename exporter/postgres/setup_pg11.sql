DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ccp_monitoring') THEN
        CREATE ROLE ccp_monitoring WITH LOGIN;
    END IF;
END
$$;
 
GRANT pg_monitor to ccp_monitoring;

CREATE SCHEMA IF NOT EXISTS monitor AUTHORIZATION ccp_monitoring;

DROP TABLE IF EXISTS monitor.pgbackrest_info CASCADE;
CREATE TABLE IF NOT EXISTS monitor.pgbackrest_info (config_file text NOT NULL, data jsonb NOT NULL);

CREATE OR REPLACE FUNCTION monitor.pgbackrest_info() RETURNS SETOF monitor.pgbackrest_info
    LANGUAGE plpgsql SECURITY DEFINER
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
    LANGUAGE sql SECURITY DEFINER
AS $function$

WITH default_value_sequences AS (
    -- Get sequences defined as default values with related table
    SELECT s.seqrelid, c.oid 
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_attrdef ad on (ad.adrelid,ad.adnum) = (a.attrelid,a.attnum)
    JOIN pg_catalog.pg_class c on a.attrelid = c.oid
    JOIN pg_catalog.pg_sequence s ON s.seqrelid = regexp_replace(pg_get_expr(ad.adbin,ad.adrelid), $re$^nextval\('(.+?)'::regclass\)$$re$, $re$\1$re$)::regclass
    WHERE (pg_get_expr(ad.adbin,ad.adrelid)) ~ '^nextval\('
), dep_sequences AS (
    -- Get sequences set as dependencies with related tables (identities)    
    SELECT s.seqrelid, c.oid
    FROM pg_catalog.pg_sequence s 
    JOIN pg_catalog.pg_depend d ON s.seqrelid = d.objid
    JOIN pg_catalog.pg_class c ON d.refobjid = c.oid
    UNION
    SELECT seqrelid, oid FROM default_value_sequences
), all_sequences AS (
    -- Get any remaining sequences
    SELECT s.seqrelid AS sequence_oid, ds.oid AS table_oid
    FROM pg_catalog.pg_sequence s
    LEFT JOIN dep_sequences ds ON s.seqrelid = ds.seqrelid
)
SELECT sequence_name
    , last_value
    , slots
    , used
    , ROUND(used/slots*100)::int AS percent
    , cycle
    , CASE WHEN slots < used THEN 0 ELSE slots - used END AS numleft
    , table_usage
FROM (
     SELECT format('%I.%I',s.schemaname, s.sequencename)::text AS sequence_name
        , COALESCE(s.last_value,s.min_value) AS last_value
        , s.cycle
        , CEIL((s.max_value-min_value::NUMERIC+1)/s.increment_by::NUMERIC) AS slots
        , CEIL((COALESCE(s.last_value,s.min_value)-s.min_value::NUMERIC+1)/s.increment_by::NUMERIC) AS used
        , string_agg(a.table_oid::regclass::text, ', ') AS table_usage
    FROM pg_catalog.pg_sequences s
    JOIN all_sequences a ON (format('%I.%I', s.schemaname, s.sequencename))::regclass = a.sequence_oid
    GROUP BY 1,2,3,4,5
) x 
ORDER BY ROUND(used/slots*100) DESC

$function$;


GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA monitor TO ccp_monitoring;
GRANT ALL ON ALL TABLES IN SCHEMA monitor TO ccp_monitoring;
