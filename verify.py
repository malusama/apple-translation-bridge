#!/usr/bin/env python3
"""Exercise the deployed loopback endpoint with real Apple language models."""
import concurrent.futures
import argparse
from contextlib import closing
import http.client
import json
import re
import time


def translate(rows, source="auto", target="zh-CN", connection=None, host="127.0.0.1", port=3210):
    started = time.monotonic()
    own_connection = connection is None
    conn = connection or http.client.HTTPConnection(host, port, timeout=90)
    try:
        body = json.dumps({"source_lang": source, "target_lang": target, "text_list": rows}, ensure_ascii=False).encode("utf-8")
        conn.request("POST", "/imme", body=body, headers={"Content-Type": "application/json"})
        response = conn.getresponse()
        value = json.loads(response.read())
        assert response.status == 200, (response.status, value)
        assert len(value["translations"]) == len(rows), value
        return value, round((time.monotonic() - started) * 1000)
    finally:
        if own_connection:
            conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3210)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--english-only", action="store_true")
    group.add_argument("--with-japanese", action="store_true")
    args = parser.parse_args()
    args.english_only = not args.with_japanese
    conn = http.client.HTTPConnection(args.host, args.port, timeout=15)
    conn.request("GET", "/health")
    response = conn.getresponse()
    health = json.loads(response.read())
    conn.close()
    required = ["en->zh-CN"] if args.english_only else ["en->zh-CN", "ja->zh-CN"]
    ready = all(health.get("language_pairs", {}).get(pair) == "installed" for pair in required)
    assert ready, "语言包尚未就绪：" + json.dumps(health.get("language_pairs"), ensure_ascii=False)

    rows = [
        "The translation runs entirely on your Mac, even when you are offline.",
        "Open {0} to read the documentation and select {1} to continue.",
        "Click <b0>Settings</b0> and visit https://example.com/help for more details.",
        "", "中文原文保持不变。",
    ]
    marker_index = 1
    if not args.english_only:
        rows.insert(1, "この翻訳はインターネット接続がなくても、Mac上で動作します。")
        marker_index = 2
    value, elapsed = translate(rows, host=args.host, port=args.port)
    outputs = [row["text"] for row in value["translations"]]
    assert all(re.search(r"[\u4e00-\u9fff]", outputs[index]) for index in range(marker_index + 2)), outputs
    for token in ["{0}", "{1}"]:
        assert token in outputs[marker_index], outputs[marker_index]
    for token in ["<b0>", "</b0>", "https://example.com/help"]:
        assert token in outputs[marker_index + 1], outputs[marker_index + 1]
    assert outputs[marker_index + 2:] == rows[marker_index + 2:], outputs
    print(json.dumps({"test": "mixed_batch_and_placeholders", "elapsed_ms": elapsed, "result": value}, ensure_ascii=False))

    long_text = ("The research team examined the available evidence and published the results. " * 30) + "The final sentence says that the launch date is October seventh."
    value, elapsed = translate([long_text], source="en", host=args.host, port=args.port)
    text = value["translations"][0]["text"]
    assert re.search(r"十月|10月", text) and re.search(r"七|7", text), text
    print(json.dumps({"test": "long_paragraph_tail", "input_characters": len(long_text), "elapsed_ms": elapsed, "translated_tail": text[-200:]}, ensure_ascii=False))

    with closing(http.client.HTTPConnection(args.host, args.port, timeout=90)) as connection:
        for index in range(2):
            value, elapsed = translate([rows[0]], source="en", connection=connection)
            print(json.dumps({"test": "keep_alive_" + str(index + 1), "elapsed_ms": elapsed, "text": value["translations"][0]["text"]}, ensure_ascii=False))

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(translate, [rows[0]] * 8, "en", host=args.host, port=args.port) for _ in range(4)]
        elapsed = [future.result()[1] for future in futures]
    print(json.dumps({"test": "four_parallel_batches", "rows": 32, "elapsed_ms_per_request": elapsed}, ensure_ascii=False))


if __name__ == "__main__":
    main()
