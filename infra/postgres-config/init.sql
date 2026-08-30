CREATE DATABASE flags_db;
CREATE DATABASE targeting_db;

\connect flags_db
\i /opt/togglemaster/flags.sql

\connect targeting_db
\i /opt/togglemaster/targeting.sql