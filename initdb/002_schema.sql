-- ENUMs
DO $$ BEGIN
  CREATE TYPE station_status AS ENUM ('online','offline','maintenance','disabled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE run_status AS ENUM ('planned','running','paused','completed','aborted','failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE sensor_data_type AS ENUM ('numeric','text','boolean');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE quality_flag_enum AS ENUM ('ok','suspect','bad','missing');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE control_command_status AS ENUM ('requested','applied','failed','cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE auth_user_role AS ENUM ('viewer','operator','admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- auth schema
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username text NOT NULL,
  email text NOT NULL,
  password_hash text NOT NULL,
  role auth_user_role NOT NULL DEFAULT 'viewer',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_auth_users_username
  ON auth.users (username);

CREATE UNIQUE INDEX IF NOT EXISTS uq_auth_users_email
  ON auth.users (email);

-- recipes
CREATE TABLE IF NOT EXISTS recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  name text NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  author text,
  description text,
  targets jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  CONSTRAINT uq_recipe_code_version UNIQUE (code, version)
);

-- configurations
CREATE TABLE IF NOT EXISTS factory_configurations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipe_id uuid NOT NULL REFERENCES recipes(id) ON DELETE RESTRICT,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  author text,
  notes text,
  is_active boolean NOT NULL DEFAULT true
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_config_per_recipe_name
  ON factory_configurations (recipe_id, name);

-- stations
CREATE TABLE IF NOT EXISTS stations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  type text NOT NULL,
  location_zone text,
  status station_status NOT NULL DEFAULT 'online',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_stations_name ON stations(name);

-- configuration_stations
CREATE TABLE IF NOT EXISTS configuration_stations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_id uuid NOT NULL REFERENCES factory_configurations(id) ON DELETE CASCADE,
  station_id uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  sequence_order integer NOT NULL CHECK (sequence_order > 0),
  enabled boolean NOT NULL DEFAULT true,
  params jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_config_station
  ON configuration_stations (config_id, station_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_config_sequence
  ON configuration_stations (config_id, sequence_order);

CREATE INDEX IF NOT EXISTS ix_configuration_stations_station
  ON configuration_stations (station_id);

-- lots
CREATE TABLE IF NOT EXISTS lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lot_code text NOT NULL UNIQUE,
  product text,
  created_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

-- runs
CREATE TABLE IF NOT EXISTS runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_id uuid NOT NULL REFERENCES factory_configurations(id) ON DELETE RESTRICT,
  lot_id uuid REFERENCES lots(id) ON DELETE SET NULL,
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  status run_status NOT NULL DEFAULT 'planned',
  overrides jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT chk_run_time CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX IF NOT EXISTS ix_runs_config_started
  ON runs (config_id, started_at DESC);

CREATE INDEX IF NOT EXISTS ix_runs_lot_started
  ON runs (lot_id, started_at DESC);

CREATE INDEX IF NOT EXISTS ix_runs_status_started
  ON runs (status, started_at DESC);

CREATE INDEX IF NOT EXISTS ix_runs_active
  ON runs (config_id, started_at DESC)
  WHERE ended_at IS NULL;

-- run_stations
CREATE TABLE IF NOT EXISTS run_stations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  station_id uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  sequence_order integer NOT NULL CHECK (sequence_order > 0),
  enabled boolean NOT NULL DEFAULT true,
  params jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_config_station_id uuid REFERENCES configuration_stations(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_run_station
  ON run_stations (run_id, station_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_run_sequence
  ON run_stations (run_id, sequence_order);

CREATE INDEX IF NOT EXISTS ix_run_stations_station
  ON run_stations (station_id);

-- sensor_types
CREATE TABLE IF NOT EXISTS sensor_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  unit text,
  data_type sensor_data_type NOT NULL,
  description text
);

-- sensors
CREATE TABLE IF NOT EXISTS sensors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  sensor_type_id uuid NOT NULL REFERENCES sensor_types(id) ON DELETE RESTRICT,
  name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  config jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sensors_station_name
  ON sensors (station_id, name);

CREATE INDEX IF NOT EXISTS ix_sensors_station
  ON sensors (station_id);

CREATE INDEX IF NOT EXISTS ix_sensors_sensor_type
  ON sensors (sensor_type_id);

-- sensor_source_map: maps translator source identifiers to internal sensors
CREATE TABLE IF NOT EXISTS sensor_source_map (
  id bigserial PRIMARY KEY,
  sensor_id uuid NOT NULL REFERENCES sensors(id) ON DELETE CASCADE,
  endpoint text NOT NULL,
  node_id text NOT NULL,
  browse_path text,
  mqtt_topic text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_sensor_source_endpoint_node UNIQUE (endpoint, node_id)
);

CREATE INDEX IF NOT EXISTS ix_sensor_source_map_sensor
  ON sensor_source_map (sensor_id);

CREATE INDEX IF NOT EXISTS ix_sensor_source_map_active
  ON sensor_source_map (is_active);

-- station_variables: controllable machine/link variables that workers can set
CREATE TABLE IF NOT EXISTS station_variables (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id uuid NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
  variable_key text NOT NULL,
  display_name text NOT NULL,
  data_type sensor_data_type NOT NULL,
  unit text,
  min_value double precision,
  max_value double precision,
  is_writable boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT chk_station_variable_range CHECK (
    min_value IS NULL OR max_value IS NULL OR min_value <= max_value
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_station_variable
  ON station_variables (station_id, variable_key);

CREATE INDEX IF NOT EXISTS ix_station_variables_station
  ON station_variables (station_id);

-- control_commands: explicit command model + lifecycle for worker changes
CREATE TABLE IF NOT EXISTS control_commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid REFERENCES runs(id) ON DELETE SET NULL,
  station_variable_id uuid NOT NULL REFERENCES station_variables(id) ON DELETE RESTRICT,
  requested_by_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  requested_at timestamptz NOT NULL DEFAULT now(),
  status control_command_status NOT NULL DEFAULT 'requested',
  requested_numeric double precision,
  requested_text text,
  requested_boolean boolean,
  applied_at timestamptz,
  error_message text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT chk_control_requested_oneof CHECK (
    ((requested_numeric IS NOT NULL)::int + (requested_text IS NOT NULL)::int + (requested_boolean IS NOT NULL)::int) = 1
  ),
  CONSTRAINT chk_control_time_order CHECK (
    (applied_at IS NULL OR applied_at >= requested_at)
  )
);

CREATE INDEX IF NOT EXISTS ix_control_commands_status_requested
  ON control_commands (status, requested_at DESC);

CREATE INDEX IF NOT EXISTS ix_control_commands_run_requested
  ON control_commands (run_id, requested_at DESC);

CREATE INDEX IF NOT EXISTS ix_control_commands_variable_requested
  ON control_commands (station_variable_id, requested_at DESC);

-- measurements (Timescale hypertable)
CREATE TABLE IF NOT EXISTS measurements (
  ingest_id bigint GENERATED BY DEFAULT AS IDENTITY,
  ts timestamptz NOT NULL,
  sensor_id uuid NOT NULL REFERENCES sensors(id) ON DELETE RESTRICT,
  run_id uuid REFERENCES runs(id) ON DELETE SET NULL,
  value_numeric double precision,
  value_text text,
  value_boolean boolean,
  quality_flag quality_flag_enum NOT NULL DEFAULT 'ok',
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT chk_measure_value_valid CHECK (
    (
      quality_flag = 'missing'
      AND value_numeric IS NULL
      AND value_text IS NULL
      AND value_boolean IS NULL
    )
    OR
    (
      quality_flag IS DISTINCT FROM 'missing'
      AND ((value_numeric IS NOT NULL)::int + (value_text IS NOT NULL)::int + (value_boolean IS NOT NULL)::int) = 1
    )
  )
);

SELECT create_hypertable(
  'measurements',
  'ts',
  'sensor_id',
  4,
  chunk_time_interval => INTERVAL '1 day',
  if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS ix_measurements_sensor_ts
  ON measurements (sensor_id, ts DESC);

CREATE INDEX IF NOT EXISTS ix_measurements_run_ts
  ON measurements (run_id, ts DESC);

CREATE INDEX IF NOT EXISTS ix_measurements_ts_brin
  ON measurements USING brin (ts);

ALTER TABLE measurements SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'sensor_id,run_id',
  timescaledb.compress_orderby = 'ts DESC'
);

SELECT add_compression_policy('measurements', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('measurements', INTERVAL '180 days', if_not_exists => TRUE);

CREATE MATERIALIZED VIEW IF NOT EXISTS measurements_1m
WITH (timescaledb.continuous) AS
SELECT
  time_bucket(INTERVAL '1 minute', ts) AS bucket_1m,
  sensor_id,
  run_id,
  avg(value_numeric) FILTER (WHERE value_numeric IS NOT NULL) AS avg_numeric,
  min(value_numeric) FILTER (WHERE value_numeric IS NOT NULL) AS min_numeric,
  max(value_numeric) FILTER (WHERE value_numeric IS NOT NULL) AS max_numeric,
  count(*) AS sample_count,
  count(*) FILTER (WHERE quality_flag <> 'ok') AS non_ok_samples
FROM measurements
GROUP BY bucket_1m, sensor_id, run_id
WITH NO DATA;

CREATE INDEX IF NOT EXISTS ix_measurements_1m_sensor_bucket
  ON measurements_1m (sensor_id, bucket_1m DESC);

SELECT add_continuous_aggregate_policy(
  'measurements_1m',
  start_offset => INTERVAL '7 days',
  end_offset => INTERVAL '1 minute',
  schedule_interval => INTERVAL '1 minute',
  if_not_exists => TRUE
);

-- run_events (Timescale hypertable)
CREATE TABLE IF NOT EXISTS run_events (
  event_id bigint GENERATED BY DEFAULT AS IDENTITY,
  run_id uuid NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  ts timestamptz NOT NULL,
  event_type text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb
);

SELECT create_hypertable(
  'run_events',
  'ts',
  'run_id',
  2,
  chunk_time_interval => INTERVAL '7 days',
  if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS ix_run_events_run_ts
  ON run_events (run_id, ts DESC);

CREATE INDEX IF NOT EXISTS ix_run_events_type_ts
  ON run_events (event_type, ts DESC);

CREATE INDEX IF NOT EXISTS ix_run_events_ts_brin
  ON run_events USING brin (ts);

ALTER TABLE run_events SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'run_id',
  timescaledb.compress_orderby = 'ts DESC'
);

SELECT add_compression_policy('run_events', INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_retention_policy('run_events', INTERVAL '365 days', if_not_exists => TRUE);

-- Guard: sensor value type must match sensor_types.data_type
CREATE OR REPLACE FUNCTION enforce_measurement_sensor_type()
RETURNS trigger AS $$
DECLARE expected_type sensor_data_type;
BEGIN
  SELECT st.data_type INTO expected_type
  FROM sensors s
  JOIN sensor_types st ON st.id = s.sensor_type_id
  WHERE s.id = NEW.sensor_id;

  IF expected_type IS NULL THEN
    RAISE EXCEPTION 'Unknown sensor_id %', NEW.sensor_id;
  END IF;

  IF expected_type = 'numeric' THEN
    IF NEW.value_text IS NOT NULL THEN
      RAISE EXCEPTION 'Sensor % expects numeric values only', NEW.sensor_id;
    END IF;
    IF NEW.value_boolean IS NOT NULL THEN
      RAISE EXCEPTION 'Sensor % expects numeric values only', NEW.sensor_id;
    END IF;

    IF NEW.quality_flag IS DISTINCT FROM 'missing' AND NEW.value_numeric IS NULL THEN
      RAISE EXCEPTION 'Sensor % expects value_numeric when quality_flag is not missing', NEW.sensor_id;
    END IF;
  ELSIF expected_type = 'text' THEN
    IF NEW.value_numeric IS NOT NULL THEN
      RAISE EXCEPTION 'Sensor % expects text values only', NEW.sensor_id;
    END IF;
    IF NEW.value_boolean IS NOT NULL THEN
      RAISE EXCEPTION 'Sensor % expects text values only', NEW.sensor_id;
    END IF;

    IF NEW.quality_flag IS DISTINCT FROM 'missing' AND NEW.value_text IS NULL THEN
      RAISE EXCEPTION 'Sensor % expects value_text when quality_flag is not missing', NEW.sensor_id;
    END IF;
  ELSIF expected_type = 'boolean' THEN
    IF NEW.value_numeric IS NOT NULL OR NEW.value_text IS NOT NULL THEN
      RAISE EXCEPTION 'Sensor % expects boolean values only', NEW.sensor_id;
    END IF;

    IF NEW.quality_flag IS DISTINCT FROM 'missing' AND NEW.value_boolean IS NULL THEN
      RAISE EXCEPTION 'Sensor % expects value_boolean when quality_flag is not missing', NEW.sensor_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_measurements_sensor_type_guard ON measurements;

CREATE TRIGGER trg_measurements_sensor_type_guard
BEFORE INSERT OR UPDATE OF sensor_id, value_numeric, value_text, value_boolean, quality_flag ON measurements
FOR EACH ROW
EXECUTE FUNCTION enforce_measurement_sensor_type();

-- Guard: control command must match writable station variable + datatype/range
CREATE OR REPLACE FUNCTION enforce_control_command_validity()
RETURNS trigger AS $$
DECLARE
  variable_station_id uuid;
  variable_type sensor_data_type;
  variable_min double precision;
  variable_max double precision;
  variable_writable boolean;
BEGIN
  SELECT station_id, data_type, min_value, max_value, is_writable
    INTO variable_station_id, variable_type, variable_min, variable_max, variable_writable
  FROM station_variables
  WHERE id = NEW.station_variable_id;

  IF variable_station_id IS NULL THEN
    RAISE EXCEPTION 'Unknown station_variable_id %', NEW.station_variable_id;
  END IF;

  IF NOT variable_writable THEN
    RAISE EXCEPTION 'station_variable % is read-only', NEW.station_variable_id;
  END IF;

  IF variable_type = 'numeric' THEN
    IF NEW.requested_numeric IS NULL OR NEW.requested_text IS NOT NULL OR NEW.requested_boolean IS NOT NULL THEN
      RAISE EXCEPTION 'Numeric variable requires requested_numeric and forbids requested_text/requested_boolean';
    END IF;

    IF variable_min IS NOT NULL AND NEW.requested_numeric < variable_min THEN
      RAISE EXCEPTION 'requested_numeric % is below min_value %', NEW.requested_numeric, variable_min;
    END IF;

    IF variable_max IS NOT NULL AND NEW.requested_numeric > variable_max THEN
      RAISE EXCEPTION 'requested_numeric % is above max_value %', NEW.requested_numeric, variable_max;
    END IF;

  ELSIF variable_type = 'text' THEN
    IF NEW.requested_text IS NULL OR NEW.requested_numeric IS NOT NULL OR NEW.requested_boolean IS NOT NULL THEN
      RAISE EXCEPTION 'Text variable requires requested_text and forbids requested_numeric/requested_boolean';
    END IF;

  ELSIF variable_type = 'boolean' THEN
    IF NEW.requested_boolean IS NULL OR NEW.requested_numeric IS NOT NULL OR NEW.requested_text IS NOT NULL THEN
      RAISE EXCEPTION 'Boolean variable requires requested_boolean and forbids requested_numeric/requested_text';
    END IF;

  END IF;

  IF NEW.status = 'applied' AND NEW.applied_at IS NULL THEN
    NEW.applied_at := now();
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_control_commands_validity ON control_commands;

CREATE TRIGGER trg_control_commands_validity
BEFORE INSERT OR UPDATE ON control_commands
FOR EACH ROW
EXECUTE FUNCTION enforce_control_command_validity();
