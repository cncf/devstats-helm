SELECT name, setting, unit, context, source
FROM pg_settings
WHERE name IN (
  'autovacuum_max_workers',
  'autovacuum_naptime',
  'autovacuum_vacuum_cost_limit',
  'autovacuum_vacuum_threshold',
  'autovacuum_vacuum_scale_factor',
  'autovacuum_analyze_threshold',
  'autovacuum_analyze_scale_factor'
);
--               name               | setting | unit |  context   | source  
-- ---------------------------------+---------+------+------------+---------
--  autovacuum_analyze_scale_factor | 0.1     |      | sighup     | default
--  autovacuum_analyze_threshold    | 50      |      | sighup     | default
--  autovacuum_max_workers          | 3       |      | postmaster | default
--  autovacuum_naptime              | 60      | s    | sighup     | default
--  autovacuum_vacuum_cost_limit    | -1      |      | sighup     | default
--  autovacuum_vacuum_scale_factor  | 0.2     |      | sighup     | default
--  autovacuum_vacuum_threshold     | 50      |      | sighup     | default
