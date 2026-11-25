"""Read check-in documents from the door activity and Mongo change-stream publishers."""
import ast
import json
import re

from bson import ObjectId, json_util

from .recent import Checkin
from .state import checkin_time


class CheckinFormatError(ValueError):
    """A diagnostic reason safe to log without echoing the check-in payload."""


def shell_value(node):
    """Decode data literals and the scalar constructors used in mongosh output."""
    if isinstance(node, ast.Dict):
        result = {}
        for key, value in zip(node.keys, node.values):
            field = key.id if isinstance(key, ast.Name) else shell_value(key)
            if not isinstance(field, str):
                raise CheckinFormatError("Expected a check-in field name")
            result[field] = shell_value(value)
        return result
    if isinstance(node, ast.Constant) and type(node.value) in (str, int, float, bool, type(None)):
        return node.value
    if isinstance(node, ast.Name) and node.id in ("null", "true", "false"):
        return {"null": None, "true": True, "false": False}[node.id]
    if isinstance(node, ast.List):
        return [shell_value(value) for value in node.elts]
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub) and isinstance(node.operand, ast.Constant):
        if type(node.operand.value) in (int, float):
            return -node.operand.value
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and len(node.args) == 1 and not node.keywords:
        constructor = {"ObjectId": ObjectId, "ISODate": str, "Double": float, "NumberInt": int,
                       "NumberLong": int}.get(node.func.id)
        arg = node.args[0]
        if constructor and isinstance(arg, ast.Constant) and type(arg.value) in (str, int, float):
            return constructor(arg.value)
    raise CheckinFormatError("Unsupported check-in literal")


def shell_document(body):
    # A check-in has a handful of scalar fields. Bound the parser's work
    # on a small Pi before asking Python to construct a literal syntax tree.
    if len(body) > 16 * 1024:
        raise CheckinFormatError("Shell check-in document is too large")
    try:
        return shell_value(ast.parse(body, mode="eval").body)
    except (SyntaxError, RecursionError) as error:
        raise CheckinFormatError("Malformed check-in document") from error


def document_body(body, operation):
    try:
        decoded = json_util.loads(body)
    except json.JSONDecodeError:
        # Some captured door messages escape _id or include a trailing line
        # continuation. Restrict the key repair to object keys.
        body = re.sub(r"""([,{]\s*["']?)\\_id(?=["']?\s*:)""", r"\1_id", body)
        body = re.sub(r"\\\r?\n", "\n", body).removesuffix("\\").rstrip()
        body = re.sub(r"(?m)^&#x20;(?=\s*\w+\s*:)", " ", body)
        try:
            decoded = json_util.loads(body)
        except json.JSONDecodeError:
            # The processed feed can omit the final brace of its document envelope.
            if operation == "processed" and re.match(r'^\{\s*"document"\s*:', body):
                decoded = json_util.loads(body + "}")
            else:
                decoded = shell_document(body)
    if isinstance(decoded, dict):
        decoded = decoded.get("document", decoded)
    if not isinstance(decoded, dict):
        raise CheckinFormatError("Expected a check-in document")
    return decoded


def parse_checkin(payload):
    text = payload.decode("utf-8").strip()
    # A broker monitor may prefix a payload with its own timestamp on a separate line.
    text = re.sub(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d:\d{3}\\?\r?\n", "", text)
    operation, epoch, body = text.removeprefix("&#x20;").split(None, 2)
    if operation not in ("welcome", "processed", "insert"):
        raise CheckinFormatError("Unexpected check-in operation")
    published = checkin_time({"time": int(epoch)})
    if published is None:
        raise CheckinFormatError("Invalid check-in publication timestamp")
    document = document_body(body, operation)
    identifier = document.get("_id")
    if not isinstance(identifier, (ObjectId, str, int)) or isinstance(identifier, bool):
        raise CheckinFormatError("Missing check-in record ID")
    stamp = checkin_time(document)
    if stamp is None and operation in ("welcome", "processed"):
        # The small welcome payload uses Unix time as its ID. Some devices
        # supply the publication time only.
        stamp = checkin_time({"time": str(identifier)}) or published
    if stamp is None:
        raise CheckinFormatError("Missing check-in timestamp")
    record = Checkin.from_document(document, stamp)
    if not (record.uid or record.name or record.member_id):
        raise CheckinFormatError("Missing check-in identity")
    # Different publishers can set timeOf when inserting into Mongo. The door's
    # own time is shared by the processed and inserted copies of the same tap.
    door_time = checkin_time({"time": document.get("time")}) or stamp
    return record, operation, published, identifier, door_time
