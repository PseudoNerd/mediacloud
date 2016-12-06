--
-- This is a Media Cloud PostgreSQL schema difference file (a "diff") between schema
-- versions 4594 and 4595.
--
-- If you are running Media Cloud with a database that was set up with a schema version
-- 4594, and you would like to upgrade both the Media Cloud and the
-- database to be at version 4595, import this SQL file:
--
--     psql mediacloud < mediawords-4594-4595.sql
--
-- You might need to import some additional schema diff files to reach the desired version.
--
--
-- 1 of 2. Import the output of 'apgdiff':

-- notes for internal media cloud consumption (eg. 'added this for yochai')
alter table media add editor_notes                text null;

-- notes for public consumption (eg. 'leading dissident paper in anatarctica')
alter table media add public_notes                text null;

-- if true, indicates that media cloud closely monitors the health of this source
alter table media add is_monitored                boolean not null default false;

--
-- 2 of 2. Reset the database version.
--

CREATE OR REPLACE FUNCTION set_database_schema_version() RETURNS boolean AS $$
DECLARE

    -- Database schema version number (same as a SVN revision number)
    -- Increase it by 1 if you make major database schema changes.
    MEDIACLOUD_DATABASE_SCHEMA_VERSION CONSTANT INT := 4595;

BEGIN

    -- Update / set database schema version
    DELETE FROM database_variables WHERE name = 'database-schema-version';
    INSERT INTO database_variables (name, value) VALUES ('database-schema-version', MEDIACLOUD_DATABASE_SCHEMA_VERSION::int);

    return true;

END;
$$
LANGUAGE 'plpgsql';

SELECT set_database_schema_version();
