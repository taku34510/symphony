"""Deterministic app-server fixture; never starts a model or contacts a service."""
import json
import sys
import uuid
from pathlib import Path

trace = Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else "ok"
thread = None
tokens = 0


def send(value):
    print(json.dumps(value), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    with trace.open("a") as stream:
        stream.write(json.dumps(request) + "\n")
    method = request["method"]
    params = request.get("params", {})
    request_id = request.get("id")
    if method == "initialize":
        send({"id": request_id, "result": {}})
    elif method in ("thread/start", "thread/resume"):
        if method == "thread/resume" and mode != "ok":
            message = "no rollout found for id" if mode == "missing" else "permission denied"
            send({"id": request_id, "error": {"code": -32600, "message": message}})
            continue
        thread = params.get("threadId", str(uuid.uuid4()))
        send({"id": request_id, "result": {"thread": {"id": thread}}})
    elif method == "turn/start":
        turn = str(uuid.uuid4())
        send({"id": request_id, "result": {"turn": {"id": turn}}})
        tokens += 100
        send({"method": "thread/tokenUsage/updated", "params": {
            "threadId": thread,
            "tokenUsage": {"total": {"inputTokens": tokens, "cachedInputTokens": 40,
                                       "outputTokens": 10, "reasoningOutputTokens": 5,
                                       "totalTokens": tokens + 10},
                           "last": {"totalTokens": 110}, "modelContextWindow": 1000}}})
        send({"method": "turn/completed", "params": {"turn": {"id": turn, "status": "completed"}}})
