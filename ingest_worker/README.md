# MQTT ingest worker (Python)

Tento worker cita surove MQTT spravy z translacnej vrstvy a uklada ich ako normalizovane merania do tabulky `measurements`.

## 1) Co worker robi

1. Prihlasi sa na MQTT topic (default: `plant.measurements.raw`).
2. Zo spravy zoberie `endpoint + node_id`.
3. Cez tabulku `sensor_source_map` najde interny `sensor_id`.
4. Hodnotu premapuje na jeden z typov:
- `value_numeric`
- `value_text`
- `value_boolean`
5. Zapise data po davkach (batch) do `measurements`.
6. Neplatne alebo nenamapovane spravy posle do DLQ topicu (default: `plant.measurements.dlq`).

## 2) Co musi byt pripravene v DB

V `initdb/002_schema.sql` je tabulka `sensor_source_map`.

Pre kazdy zdroj zo translatora treba mat mapovanie, napriklad:

```sql
INSERT INTO sensor_source_map (sensor_id, endpoint, node_id, browse_path, mqtt_topic)
VALUES
(
  '11111111-1111-1111-1111-111111111111',
  'opc.tcp://127.0.0.1:4840/example/server',
  'NodeId(Identifier=2, NamespaceIndex=2, NodeIdType=<NodeIdType.FourByte: 1>)',
  '/Objects/MyObject/MyVariable',
  'opcua/4840/MyObject/MyVariable'
);
```

Bez tohto mapovania worker nevie najst `sensor_id` a sprava skonci v DLQ.

## 3) Instalacia

```bash
cd /Users/romankosik/VsProjects/TP/ingest_worker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 4) Spustenie

```bash
cd /Users/romankosik/VsProjects/TP/ingest_worker
cp .env.example .env
set -a
source .env
set +a
python worker.py
```

## 5) Najdolezitejsie premenne prostredia

- `MQTT_HOST`, `MQTT_PORT`, `MQTT_TOPIC`
- `MQTT_DLQ_TOPIC`
- `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`
- `BATCH_SIZE` (default `500`)
- `FLUSH_INTERVAL_SEC` (default `0.5`)

Volitelne:
- `MQTT_USERNAME`, `MQTT_PASSWORD`
- `MQTT_QOS` (default `1`)
- `LOG_LEVEL` (default `INFO`)
- `PG_DSN` (ak je nastavene, prepise PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD)

## 6) Priklad spravy, ktoru worker spracuje

```json
{
  "ts": "2026-03-10T16:38:07.799Z",
  "mqtt_topic": "opcua/4840/MyObject/MyVariable",
  "endpoint": "opc.tcp://127.0.0.1:4840/example/server",
  "browse_path": "/Objects/MyObject/MyVariable",
  "node_id": "NodeId(Identifier=2, NamespaceIndex=2, NodeIdType=<NodeIdType.FourByte: 1>)",
  "value_json": 0.6543599899371922,
  "payload": {
    "timestamp_ms": 1773227887799,
    "source": {
      "endpoint": "opc.tcp://127.0.0.1:4840/example/server",
      "browse_path": "/Objects/MyObject/MyVariable",
      "node_id": "NodeId(Identifier=2, NamespaceIndex=2, NodeIdType=<NodeIdType.FourByte: 1>)"
    },
    "value": 0.6543599899371922
  }
}
```

## 7) Typicke problemy

1. `No sensor mapping for endpoint=...`:
- chyba zaznam v `sensor_source_map`.

2. `quality_flag` / typ hodnoty neprejde:
- hodnota nesedi na typ senzora (`numeric/text/boolean`).

3. Worker bezi, ale nic nezapisuje:
- skontroluj topic (`MQTT_TOPIC`), DB pristup a mapping tabulku.
