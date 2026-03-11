#!/usr/bin/env python3
import json
import logging
import os
import queue
import signal
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Optional, Tuple

import paho.mqtt.client as mqtt
import psycopg
from psycopg.types.json import Json


@dataclass
class Settings:
    mqtt_host: str
    mqtt_port: int
    mqtt_topic: str
    mqtt_client_id: str
    mqtt_username: Optional[str]
    mqtt_password: Optional[str]
    mqtt_qos: int
    mqtt_dlq_topic: Optional[str]
    pg_dsn: str
    batch_size: int
    flush_interval_sec: float
    log_level: str


def env(name: str, default: Optional[str] = None) -> str:
    value = os.getenv(name, default)
    if value is None:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def load_settings() -> Settings:
    pg_dsn = os.getenv("PG_DSN")
    if not pg_dsn:
        pg_host = env("PGHOST", "127.0.0.1")
        pg_port = env("PGPORT", "5432")
        pg_db = env("PGDATABASE", "potato_twin")
        pg_user = env("PGUSER", "potato")
        pg_password = env("PGPASSWORD", "")
        pg_dsn = (
            f"host={pg_host} port={pg_port} dbname={pg_db} "
            f"user={pg_user} password={pg_password}"
        )

    return Settings(
        mqtt_host=env("MQTT_HOST", "127.0.0.1"),
        mqtt_port=int(env("MQTT_PORT", "1883")),
        mqtt_topic=env("MQTT_TOPIC", "plant.measurements.raw"),
        mqtt_client_id=env("MQTT_CLIENT_ID", "potato-ingest-worker"),
        mqtt_username=os.getenv("MQTT_USERNAME"),
        mqtt_password=os.getenv("MQTT_PASSWORD"),
        mqtt_qos=int(env("MQTT_QOS", "1")),
        mqtt_dlq_topic=os.getenv("MQTT_DLQ_TOPIC", "plant.measurements.dlq"),
        pg_dsn=pg_dsn,
        batch_size=int(env("BATCH_SIZE", "500")),
        flush_interval_sec=float(env("FLUSH_INTERVAL_SEC", "0.5")),
        log_level=env("LOG_LEVEL", "INFO"),
    )


def parse_ts(value: Any) -> datetime:
    if isinstance(value, str) and value:
        ts = value.replace("Z", "+00:00")
        return datetime.fromisoformat(ts)
    return datetime.now(timezone.utc)


def normalize_value(value: Any) -> Tuple[Optional[float], Optional[str], Optional[bool]]:
    if isinstance(value, bool):
        return None, None, value
    if isinstance(value, (int, float)):
        return float(value), None, None
    if isinstance(value, str):
        return None, value, None
    if value is None:
        return None, None, None
    # Fallback for objects/arrays -> store as text
    return None, json.dumps(value, ensure_ascii=True), None


class IngestWorker:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.msg_queue: queue.Queue[bytes] = queue.Queue(maxsize=100_000)
        self.stop_event = threading.Event()
        self.db_conn: Optional[psycopg.Connection] = None
        self.sensor_cache: dict[Tuple[str, str], str] = {}

        self.mqtt_client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=settings.mqtt_client_id,
            clean_session=True,
        )
        if settings.mqtt_username:
            self.mqtt_client.username_pw_set(settings.mqtt_username, settings.mqtt_password)

        self.mqtt_client.on_connect = self.on_connect
        self.mqtt_client.on_message = self.on_message

    def connect_db(self) -> None:
        if self.db_conn is not None and not self.db_conn.closed:
            return
        self.db_conn = psycopg.connect(self.settings.pg_dsn)
        self.db_conn.autocommit = False
        logging.info("Connected to PostgreSQL")

    def close_db(self) -> None:
        if self.db_conn is not None and not self.db_conn.closed:
            self.db_conn.close()
            logging.info("Closed PostgreSQL connection")

    def on_connect(self, client: mqtt.Client, _userdata: Any, _flags: Any, reason_code: Any, _properties: Any) -> None:
        if int(reason_code) != 0:
            logging.error("MQTT connect failed: rc=%s", reason_code)
            return
        client.subscribe(self.settings.mqtt_topic, qos=self.settings.mqtt_qos)
        logging.info("Subscribed to topic=%s", self.settings.mqtt_topic)

    def on_message(self, _client: mqtt.Client, _userdata: Any, message: mqtt.MQTTMessage) -> None:
        try:
            self.msg_queue.put_nowait(message.payload)
        except queue.Full:
            logging.error("Queue full, dropping message")

    def publish_dlq(self, payload: bytes, error: str) -> None:
        if not self.settings.mqtt_dlq_topic:
            return
        try:
            dlq_message = json.dumps({
                "error": error,
                "received_at": datetime.now(timezone.utc).isoformat(),
                "raw": payload.decode("utf-8", errors="replace"),
            })
            self.mqtt_client.publish(self.settings.mqtt_dlq_topic, dlq_message, qos=1)
        except Exception as exc:
            logging.error("Failed to publish DLQ message: %s", exc)

    def resolve_sensor_id(self, endpoint: str, node_id: str) -> Optional[str]:
        key = (endpoint, node_id)
        cached = self.sensor_cache.get(key)
        if cached:
            return cached

        assert self.db_conn is not None
        with self.db_conn.cursor() as cur:
            cur.execute(
                """
                SELECT sensor_id
                FROM sensor_source_map
                WHERE endpoint = %s
                  AND node_id = %s
                  AND is_active = TRUE
                ORDER BY id DESC
                LIMIT 1
                """,
                (endpoint, node_id),
            )
            row = cur.fetchone()
            if not row:
                return None
            sensor_id = row[0]
            self.sensor_cache[key] = str(sensor_id)
            return str(sensor_id)

    def normalize_message(self, payload: bytes) -> Optional[tuple[Any, ...]]:
        data = json.loads(payload)
        source = data.get("payload", {}).get("source", {})

        endpoint = data.get("endpoint") or source.get("endpoint")
        node_id = data.get("node_id") or source.get("node_id")
        if not endpoint or not node_id:
            raise ValueError("Missing endpoint or node_id")

        ts = parse_ts(data.get("ts"))
        raw_value = data.get("value_json", data.get("payload", {}).get("value"))
        value_numeric, value_text, value_boolean = normalize_value(raw_value)

        quality_flag = data.get("quality_flag") or "ok"
        run_id = data.get("run_id") or data.get("payload", {}).get("run_id")

        sensor_id = self.resolve_sensor_id(endpoint, node_id)
        if not sensor_id:
            raise ValueError(f"No sensor mapping for endpoint={endpoint}, node_id={node_id}")

        return (
            ts,
            sensor_id,
            run_id,
            value_numeric,
            value_text,
            value_boolean,
            quality_flag,
            Json(data),
        )

    def flush_batch(self, batch: list[tuple[Any, ...]]) -> None:
        if not batch:
            return
        self.connect_db()
        assert self.db_conn is not None

        try:
            with self.db_conn.cursor() as cur:
                cur.executemany(
                    """
                    INSERT INTO measurements (
                        ts,
                        sensor_id,
                        run_id,
                        value_numeric,
                        value_text,
                        value_boolean,
                        quality_flag,
                        payload
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    batch,
                )
            self.db_conn.commit()
            logging.info("Inserted %d measurements", len(batch))
        except Exception:
            self.db_conn.rollback()
            raise

    def consume_loop(self) -> None:
        batch: list[tuple[Any, ...]] = []
        last_flush = time.monotonic()

        while not self.stop_event.is_set():
            timeout = max(0.0, self.settings.flush_interval_sec - (time.monotonic() - last_flush))
            try:
                raw = self.msg_queue.get(timeout=timeout)
                try:
                    record = self.normalize_message(raw)
                    if record:
                        batch.append(record)
                except Exception as exc:
                    logging.warning("Invalid message skipped: %s", exc)
                    self.publish_dlq(raw, str(exc))
            except queue.Empty:
                pass

            should_flush = (
                len(batch) >= self.settings.batch_size
                or (batch and time.monotonic() - last_flush >= self.settings.flush_interval_sec)
            )

            if should_flush:
                try:
                    self.flush_batch(batch)
                    batch.clear()
                    last_flush = time.monotonic()
                except Exception as exc:
                    logging.exception("Batch flush failed: %s", exc)
                    time.sleep(1.0)
                    self.close_db()

        # graceful drain
        if batch:
            try:
                self.flush_batch(batch)
            except Exception as exc:
                logging.exception("Final flush failed: %s", exc)

    def run(self) -> None:
        self.connect_db()
        self.mqtt_client.connect(self.settings.mqtt_host, self.settings.mqtt_port, keepalive=60)
        self.mqtt_client.loop_start()

        try:
            self.consume_loop()
        finally:
            self.mqtt_client.loop_stop()
            self.mqtt_client.disconnect()
            self.close_db()



def main() -> None:
    settings = load_settings()
    logging.basicConfig(
        level=getattr(logging, settings.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
    )

    worker = IngestWorker(settings)

    def handle_signal(_sig: int, _frame: Any) -> None:
        logging.info("Stopping ingest worker")
        worker.stop_event.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    worker.run()


if __name__ == "__main__":
    main()
