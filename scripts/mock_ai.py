"""A fake OpenAI-compatible endpoint for testing the phone app.

Why this exists: the AI panel is only worth having if the whole path works —
config screen, connection check, streaming render, and the note actually
reaching the model. Real endpoints need a paid key, so this stands in.

Two details matter for a useful test:

  * It reads the prompt it receives and quotes the note title back. If the app
    forgot to attach context, the reply says so out loud, which is exactly the
    bug we would otherwise miss by eyeballing a plausible answer.
  * It streams token by token with a delay, so the UI's incremental rendering
    and the "停止" button are exercised for real.

Usage:
    python mock_ai.py                 # port 8090
    python mock_ai.py --port 8090 --delay 0.05

From the emulator the endpoint is http://10.0.2.2:<port>/v1
"""

import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = [
    "mock-tolaria-1",
    "mock-tolaria-1-mini",
    "mock-long-context",
]


def find_note_title(system_prompt):
    match = re.search(r"标题：(.+)", system_prompt)
    return match.group(1).strip() if match else None


def find_note_count(system_prompt):
    match = re.search(r"共 (\d+) 篇笔记", system_prompt)
    return int(match.group(1)) if match else 0


def build_answer(body):
    messages = body.get("messages") or []
    system = "\n".join(
        m.get("content", "") for m in messages if m.get("role") == "system"
    )
    question = ""
    for message in reversed(messages):
        if message.get("role") == "user":
            question = message.get("content", "")
            break

    title = find_note_title(system)
    count = find_note_count(system)

    lines = ["**这是一段模拟回答**，用来验证链路，不是真的模型。", ""]
    lines.append(f"你问的是：`{question[:60]}`")
    lines.append("")

    if title:
        lines.append(f"我收到了当前笔记，标题是《{title}》。")
        if count:
            lines.append(f"还收到了包含 {count} 篇笔记的知识库目录。")
        lines.append("")
        lines.append("说明上下文确实拼进了 prompt，不是空跑。")
    elif count:
        lines.append(f"没有当前笔记，但收到了 {count} 篇的目录。")
    else:
        lines.append("没有收到任何笔记内容（上下文是关闭的，或知识库为空）。")

    lines.extend(
        [
            "",
            "---",
            "",
            "### 渲染自检",
            "",
            "1. 列表项",
            "2. 中文与 `incline code`",
            "",
            "```dart",
            "// 代码块应该有自己的背景色",
            "final note = Note(title: '示例');",
            "```",
            "",
            "| 协议 | 状态 |",
            "|---|---|",
            "| OpenAI 兼容 | 已验证 |",
            "| Anthropic | 已验证 |",
            "",
            "> 引用块也应该正常显示。",
        ]
    )
    return "\n".join(lines)


def build_agent_turn(body):
    """Scripts a short tool-using turn for the Agent mode.

    Round 1 always lists notes. Round 2 does something that writes — which is
    what makes the approval dialog appear — and round 3 answers in prose. The
    path comes from round 1's result, so the script keeps working whatever the
    vault contains.
    """
    messages = body.get("messages") or []
    results = [m for m in messages if m.get("role") == "tool"]
    question = ""
    for message in reversed(messages):
        if message.get("role") == "user":
            question = message.get("content", "")
            break

    if not results:
        return _tool_call("call_list", "list_notes", {"limit": 20})

    listed = results[0].get("content", "")
    path = ""
    for line in listed.splitlines():
        if "\t" in line:
            path = line.split("\t")[0].strip()
            break

    if len(results) == 1 and path:
        if "新建" in question:
            return _tool_call(
                "call_create",
                "create_note",
                {
                    "title": "AI 新建的示例笔记",
                    "body": "这篇是 mock 端点通过 create_note 工具建的，用来验证写操作链路。",
                    "type": "灵感素材",
                },
            )
        return _tool_call(
            "call_append",
            "append_note",
            {"path": path, "text": "\n> 今天把 Tolaria 搬到手机上了。\n"},
        )

    return {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": (
                        f"我先列了笔记，然后动了一篇（`{path or '（无）'}`）。\n\n"
                        f"你刚才问的是：{question[:60]}\n\n"
                        "上面每一步都是这台手机上的真实工具调用，不是模拟——"
                        "写之前那次确认也是真的会拦下来的。"
                    ),
                }
            }
        ]
    }


def _tool_call(call_id, name, arguments):
    return {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {
                            "id": call_id,
                            "type": "function",
                            "function": {
                                "name": name,
                                "arguments": json.dumps(arguments, ensure_ascii=False),
                            },
                        }
                    ],
                }
            }
        ]
    }


def read_body(handler):
    """Reads the request body, chunked or not.

    Dart's HttpClient streams the JSON body with `Transfer-Encoding: chunked`
    because the payload length is not known up front. A handler that only looks
    at Content-Length therefore sees an empty body and answers as if no prompt
    had been sent — which reads exactly like an app bug, so handle both.
    """
    encoding = (handler.headers.get("Transfer-Encoding") or "").lower()
    if "chunked" in encoding:
        data = b""
        while True:
            line = handler.rfile.readline().strip()
            if not line:
                break
            size = int(line.split(b";")[0], 16)
            if size == 0:
                handler.rfile.readline()
                break
            data += handler.rfile.read(size)
            handler.rfile.read(2)  # trailing CRLF
        return data or b"{}"

    length = int(handler.headers.get("Content-Length") or 0)
    return handler.rfile.read(length) if length else b"{}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    delay = 0.04

    def log_message(self, fmt, *args):  # keep the console readable
        print(f"  {self.address_string()} {fmt % args}")

    def _json(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json(200, {"data": [{"id": m, "object": "model"} for m in MODELS]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        raw = read_body(self)
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            self._json(400, {"error": {"message": "bad json"}})
            return

        if not self.path.rstrip("/").endswith("/chat/completions"):
            self._json(404, {"error": {"message": "not found"}})
            return

        messages = body.get("messages") or []
        system_len = sum(
            len(m.get("content", "")) for m in messages if m.get("role") == "system"
        )
        tools = body.get("tools") or []
        print(
            f"  body {len(raw)}B, messages={len(messages)}, "
            f"system={system_len} chars, model={body.get('model')}, "
            f"tools={len(tools)}, stream={body.get('stream')}"
        )

        # Agent mode sends tools and asks for a non-streamed answer, because
        # tool_calls cannot be reassembled reliably from SSE deltas.
        if tools:
            self._json(200, build_agent_turn(body))
            return

        answer = build_answer(body)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        # Stream in small slices so the UI has something to animate.
        step = 6
        for i in range(0, len(answer), step):
            chunk = answer[i : i + step]
            payload = {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "choices": [
                    {"index": 0, "delta": {"content": chunk}, "finish_reason": None}
                ],
            }
            self.wfile.write(
                ("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode(
                    "utf-8"
                )
            )
            self.wfile.flush()
            time.sleep(self.delay)

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--delay", type=float, default=0.04)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    Handler.delay = args.delay
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"mock AI listening on http://{args.host}:{args.port}/v1")
    print(f"from emulator: http://10.0.2.2:{args.port}/v1")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
