-- Create a test station
INSERT INTO stations (name, type, location_zone, status)
VALUES ('Test Station', 'test', 'zone-a', 'online')
ON CONFLICT (name) DO NOTHING;

-- Create sensor type
INSERT INTO sensor_types (name, unit, data_type, description)
VALUES ('Temperature Sensor', '°C', 'numeric', 'Generic temperature sensor')
ON CONFLICT (name) DO NOTHING;

-- Create a sensor linked to the station and sensor type
INSERT INTO sensors (station_id, sensor_type_id, name, is_active)
SELECT 
  s.id,
  st.id,
  'MyVariable_Sensor',
  true
FROM stations s, sensor_types st
WHERE s.name = 'Test Station'
  AND st.name = 'Temperature Sensor'
  AND NOT EXISTS (
    SELECT 1 FROM sensors
    WHERE station_id = s.id AND name = 'MyVariable_Sensor'
  );

-- Map the OPC UA source to the sensor
-- The node_id format comes from the translation layer (str(node.nodeid))
-- For the test config, it's: NodeId(Identifier=2, NamespaceIndex=2, NodeIdType=<NodeIdType.FourByte: 1>)
INSERT INTO sensor_source_map (sensor_id, endpoint, node_id, browse_path, mqtt_topic, is_active)
SELECT 
  s.id,
  'opc.tcp://mock-opcua:4840/example/server',
  'NodeId(Identifier=2, NamespaceIndex=2, NodeIdType=<NodeIdType.FourByte: 1>)',
  '/Objects/MyObject/MyVariable',
  'opcua/4840/MyObject/MyVariable',
  true
FROM sensors s
WHERE s.name = 'MyVariable_Sensor'
  AND NOT EXISTS (
    SELECT 1 FROM sensor_source_map
    WHERE endpoint = 'opc.tcp://mock-opcua:4840/example/server'
      AND browse_path = '/Objects/MyObject/MyVariable'
  );


