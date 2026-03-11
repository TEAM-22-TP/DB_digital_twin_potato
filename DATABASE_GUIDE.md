# Potato Twin DB - jednoduchy prehlad


## 1) Co tato databaza robi

Databaza pokryva 4 hlavne veci:

1. Konfiguracia vyroby
- recepty (`recipes`)
- konfiguracie linky (`factory_configurations`)
- poradie stanic v konfiguracii (`configuration_stations`)

2. Realna vyroba (behy)
- konkretne spustenia linky (`runs`)
- stanice pouzite v danom behu (`run_stations`)
- volitelna sarza (`lots`)

3. Telemetria (casove data)
- senzory a ich typy (`sensor_types`, `sensors`)
- surove merania (`measurements`, hypertable)
- agregacie po minute (`measurements_1m`)
- eventy behu (`run_events`, hypertable)

4. Ovladanie linky
- nastavitelne premenne stanice (`station_variables`)
- poziadavky na zmenu hodnoty (`control_commands`)

A este:
- zakladny auth schema s pouzivatelmi a jednoduchou rolou (`auth.users`)

## 2) Hlavne tabulky - co znamenaju

## `recipes`
Technologicky predpis (napr. typ produktu + cielove parametre).

## `factory_configurations`
Konkretna konfiguracia linky pre recept.

## `configuration_stations`
Ktore stanice su v konfiguracii a v akom poradi.

## `runs`
Konkretne spustenie vyroby v case.

## `run_stations`
Snapshot stanic pre konkretny run (aby historia sedela, aj ked sa konfiguracia neskor zmeni).

## `sensor_types` + `sensors`
Katalog typov senzorov a konkretne senzory na staniciach.
Data typ senzora je: `numeric`, `text`, `boolean`.

## `measurements`
Surove merania zo senzorov (timestamp + hodnota).
Je to Timescale hypertable (optimalizovane na velke casove rady).

## `measurements_1m`
Kontinualna agregacia po 1 minute (avg/min/max/count pre numeric merania).

## `run_events`
Udalosti pocas runu (alarm, stop, zmena stavu, zasah operatora...).

## `station_variables`
Premenne, ktore sa daju nastavovat (napr. rychlost pasu, mod, zap/vyp).

## `control_commands`
Jednoduchy command flow:
- `requested` (ziadost vytvorena)
- `applied` (aplikovane)
- `failed` (zlyhalo)
- `cancelled` (zrusene)

## `auth.users`
Pouzivatelia systemu.

Ma jednoduchu rolu:
- `viewer` (len citanie)
- `operator` (moze zadavat control commandy)
- `admin` (plny pristup)

`control_commands.requested_by_user_id` ukazuje na pouzivatela.

## 3) Ako sa data naplnaju (realne flowy)

### Flow A: priprava technologie
1. Vytvoris `recipe`.
2. Vytvoris `factory_configuration` pre recipe.
3. Pridas stanice do `configuration_stations` s `sequence_order`.

### Flow B: start vyroby
1. Backend vytvori zaznam v `runs` (status napr. `running`).
2. Skopiruje stanice z `configuration_stations` do `run_stations`.
3. Od tejto chvile ide telemetria a eventy na tento run.

### Flow C: ingest merani
1. Translacna vrstva cita data z PLC/OPC-UA.
2. Posiela ich do message brokeru (napr. MQTT/Kafka/NATS), nie priamo cez REST.
3. Ingest worker cita spravy z topicu a dava batch insert do `measurements`.
4. Timescale automaticky buduje agregacie v `measurements_1m`.

Poznamka:
- trigger kontroluje, ze typ hodnoty sedi na typ senzora
  (numeric/text/boolean).

### Flow D: operator zmeni parameter
1. API vytvori `control_commands` so statusom `requested`.
2. Executor/connector to odosle do PLC.
3. Po vysledku update statusu:
   - `applied` + `applied_at`
   - alebo `failed` + `error_message`

### Flow E: eventy
Backend/connector zapisuje do `run_events` co sa dialo pocas runu.

## 4) Prakticke API endpointy a broker spravy (priklad)

Toto su navrhy endpointov. Nemusia byt final, ale su dobry start.

## Konfiguracia

### `POST /api/recipes`
Vytvori recept.

Priklad body:
```json
{
  "code": "FRIES_STD",
  "name": "Hranolky standard",
  "version": 1,
  "targets": {
    "line_speed_m_min": 12,
    "max_waste_pct": 8
  }
}
```

### `POST /api/configurations`
Vytvori konfiguraciu pre recept.

```json
{
  "recipe_id": "<uuid>",
  "name": "Linka A - jar 2026",
  "notes": "Zakladne nastavenie"
}
```

### `POST /api/configurations/{configId}/stations`
Prida stanicu do konfiguracie.

```json
{
  "station_id": "<uuid>",
  "sequence_order": 1,
  "enabled": true,
  "params": {"mode": "auto"}
}
```

## Runs

### `POST /api/runs/start`
Spusti run.

```json
{
  "config_id": "<uuid>",
  "lot_id": "<uuid or null>",
  "started_at": "2026-03-11T09:00:00Z"
}
```

Co endpoint urobi:
1. insert do `runs`
2. snapshot do `run_stations`
3. vrati `run_id`

### `POST /api/runs/{runId}/stop`
Zastavi run (nastavi `ended_at`, `status`).

## Merania a eventy (broker-first)

Primarna cesta pre telemetriu je broker, nie REST.

### Topic: `plant.measurements.raw`
Priklad spravy:
```json
{
  "ts": "2026-03-11T09:10:00Z",
  "sensor_id": "<uuid>",
  "run_id": "<uuid>",
  "value_numeric": 42.7,
  "quality_flag": "ok"
}
```

alebo boolean varianta:
```json
{
  "ts": "2026-03-11T09:10:01Z",
  "sensor_id": "<uuid>",
  "run_id": "<uuid>",
  "value_boolean": true,
  "quality_flag": "ok"
}
```

### Topic: `plant.runs.events`
Priklad spravy:
```json
{
  "run_id": "<uuid>",
  "ts": "2026-03-11T09:15:10Z",
  "event_type": "alarm",
  "details": {"code": "MOTOR_OVERTEMP", "severity": "high"}
}
```

Volitelne (fallback/backfill) mozes mat REST endpoint:

### `POST /api/measurements/bulk` (optional)
Pouzit len na backfill alebo servisne importy, nie ako hlavny realtime ingest.

## Ovladanie

### `POST /api/control-commands`
Vytvori command (status `requested`).

```json
{
  "run_id": "<uuid>",
  "station_variable_id": "<uuid>",
  "requested_by_user_id": "<uuid>",
  "requested_numeric": 10.5
}
```

### `POST /api/control-commands/{id}/apply-success`
Oznaci command ako uspesne aplikovany.

### `POST /api/control-commands/{id}/apply-failed`
Oznaci command ako neuspesny + doplni `error_message`.

## 5) Odporucane pravidla v backende

1. Pri starte runu vzdy vytvor snapshot do `run_stations`.
2. Pri ingestoch vzdy posielaj `run_id`, ak je run aktivny.
3. Na commandy pouzivaj idempotenciu v API vrstve (napr. request-id header).
4. Pre dashboard citaj hlavne `measurements_1m`, nie surove `measurements`.
5. Na detailne analyzy/debug citaj surove `measurements`.
6. Jednoduche MVP autorizacie:
   - `viewer`: iba GET endpointy
   - `operator`: GET + vytvaranie/apply/fail commandov
   - `admin`: vsetko (vratane konfiguracii a uzivatelov)
