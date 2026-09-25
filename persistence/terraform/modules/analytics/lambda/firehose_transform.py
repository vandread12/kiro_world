"""Transformacion de Firehose: CDC de DynamoDB -> envelope plano para la capa bronze.

Contrato de salida: persistence/schemas/cdc-envelope.json. Las columnas de la tabla
Glue deben coincidir en nombre y tipo con ese esquema; si divergen, Firehose falla la
conversion a Parquet en silencio y los registros aterrizan en el prefijo de error.

Formato de entrada: "Kinesis Data Streams for DynamoDB", que NO es el mismo que el de
un DynamoDB Stream clasico. Las imagenes llegan en DynamoDB JSON (con tipos
explicitos) y hay que deserializarlas antes de escribirlas.
"""

import base64
import json
import os
from datetime import datetime, timezone
from decimal import Decimal

from boto3.dynamodb.types import TypeDeserializer

_DESER = TypeDeserializer()

# Los guardianes de idempotencia son ruido operativo: no describen progresion ni
# economia. Descartarlos aqui es el control de coste "el transform descarta lo
# irrelevante antes de S3", y evita pagar almacenamiento y escaneo por ellos.
DROP_ENTITIES = {
    e.strip().upper()
    for e in os.environ.get("DROP_ENTITIES", "IDEM").split(",")
    if e.strip()
}

# Margen frente al limite de 6 MB de la respuesta a Firehose. Un unico documento
# patologico no debe tumbar el lote completo.
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", "400000"))


def _derive_entity(pk: str, sk: str) -> str:
    """Fallback cuando el documento no trae entity_type (documentos pre-migracion)."""
    if pk.startswith("IDEM#"):
        return "IDEM"
    if pk.startswith("TRADE#"):
        return "TRADE"
    if pk.startswith("PLAYER#"):
        if sk == "PROFILE":
            return "PROFILE"
        if sk.startswith("STATS#"):
            return "PLAYER_STATS"
        if sk.startswith("ITEM#"):
            return "ITEM"
        if sk.startswith("CURRENCY#"):
            return "CURRENCY"
        if sk.startswith("MATCH#"):
            return "MATCH"
    if pk.startswith("SQUAD#"):
        if sk == "META":
            return "SQUAD"
        if sk.startswith("STATS#"):
            return "SQUAD_STATS_SHARD"
        if sk.startswith("MEMBER#"):
            return "MEMBER"
    # UNKNOWN en lugar de excepcion: un entity_type nuevo no debe provocar perdida
    # de datos. Aterriza en su propia particion y se revisa.
    return "UNKNOWN"


class _Encoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Decimal):
            return int(o) if o == o.to_integral_value() else float(o)
        if isinstance(o, (bytes, bytearray)):
            return base64.b64encode(o).decode("ascii")
        if isinstance(o, set):
            return sorted(o, key=str)
        if hasattr(o, "value"):  # boto3.dynamodb.types.Binary
            return base64.b64encode(o.value).decode("ascii")
        return super().default(o)


def _plain_image(image):
    if not image:
        return None
    try:
        decoded = {k: _DESER.deserialize(v) for k, v in image.items()}
    except Exception as exc:  # pragma: no cover - defensivo
        return json.dumps({"_deserialize_error": str(exc)})

    text = json.dumps(decoded, cls=_Encoder, separators=(",", ":"))
    if len(text) > MAX_IMAGE_BYTES:
        return json.dumps({"_truncated": True, "_size": len(text)})
    return text


def _normalize_ts(raw) -> int:
    """Devuelve milisegundos. Acepta segundos, milisegundos o microsegundos."""
    if raw is None:
        return int(datetime.now(tz=timezone.utc).timestamp() * 1000)
    value = int(float(raw))
    if value > 1_000_000_000_000_000:  # microsegundos
        return value // 1000
    if value > 1_000_000_000_000:  # milisegundos
        return value
    return value * 1000  # segundos


def _entity_type(new_plain, old_plain, pk, sk) -> str:
    for image in (new_plain, old_plain):
        if image:
            try:
                parsed = json.loads(image)
            except (TypeError, ValueError):
                continue
            declared = parsed.get("entity_type")
            if declared:
                return str(declared).upper()
    return _derive_entity(pk, sk)


def handler(event, _context):
    output = []

    for record in event.get("records", []):
        record_id = record["recordId"]

        try:
            payload = json.loads(base64.b64decode(record["data"]))
            body = payload.get("dynamodb", {})
            keys = body.get("Keys", {}) or {}

            pk = (keys.get("PK", {}) or {}).get("S", "")
            sk = (keys.get("SK", {}) or {}).get("S", "")

            new_plain = _plain_image(body.get("NewImage"))
            old_plain = _plain_image(body.get("OldImage"))
            entity = _entity_type(new_plain, old_plain, pk, sk)

            if entity in DROP_ENTITIES:
                output.append({"recordId": record_id, "result": "Dropped"})
                continue

            event_ts = _normalize_ts(body.get("ApproximateCreationDateTime"))
            meta = record.get("kinesisRecordMetadata") or {}

            envelope = {
                "event_id": payload.get("eventID") or record_id,
                "event_name": payload.get("eventName", "UNKNOWN"),
                "event_ts": event_ts,
                "table_name": payload.get("tableName", ""),
                "pk": pk,
                "sk": sk,
                "entity_type": entity,
                "new_image": new_plain,
                "old_image": old_plain,
                "sequence_number": meta.get("sequenceNumber"),
                "size_bytes": body.get("SizeBytes"),
            }

            # Salto de linea al final: la conversion a Parquet espera un objeto JSON
            # por registro y el delimitador evita concatenaciones ambiguas.
            data = json.dumps(envelope, separators=(",", ":")) + "\n"
            dt = datetime.fromtimestamp(event_ts / 1000, tz=timezone.utc).strftime("%Y-%m-%d")

            output.append(
                {
                    "recordId": record_id,
                    "result": "Ok",
                    "data": base64.b64encode(data.encode("utf-8")).decode("ascii"),
                    "metadata": {"partitionKeys": {"entity": entity, "dt": dt}},
                }
            )

        except Exception:
            # ProcessingFailed en lugar de Dropped: el registro va al prefijo de
            # error en S3 y es reprocesable. Descartarlo seria perdida silenciosa.
            output.append({"recordId": record_id, "result": "ProcessingFailed"})

    return {"records": output}
