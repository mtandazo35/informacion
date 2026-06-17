#!/usr/bin/env python3
"""Replay the stream edit form with restart_on_edit=on to start a stream.

Uses the admin session cookie + X-Forwarded-For spoof to authenticate.
"""
import sys
import urllib.parse
from html.parser import HTMLParser
import urllib.request

PHPSESSID = "gdg4v4npim3fab02dsd5pa6o0o"
XFF = "10.110.110.2"
BASE = "http://127.0.0.1"


class FormParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.fields = []  # list of (name, value) preserving order and duplicates
        self.in_select = None  # current select name if inside <select>
        self.select_has_value = False
        self.in_textarea = None
        self.textarea_buf = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        name = a.get("name")
        if tag == "input":
            if not name:
                return
            t = a.get("type", "text").lower()
            if t in ("submit", "button", "reset", "image", "file"):
                return
            if t in ("checkbox", "radio"):
                if "checked" in a:
                    val = a.get("value", "on")
                    self.fields.append((name, val))
                return
            val = a.get("value", "")
            self.fields.append((name, val))
        elif tag == "select":
            self.in_select = name
            self.select_has_value = False
        elif tag == "option" and self.in_select is not None:
            if "selected" in a:
                val = a.get("value", "")
                self.fields.append((self.in_select, val))
                self.select_has_value = True
        elif tag == "textarea":
            self.in_textarea = name
            self.textarea_buf = []

    def handle_endtag(self, tag):
        if tag == "select":
            self.in_select = None
        elif tag == "textarea" and self.in_textarea is not None:
            self.fields.append((self.in_textarea, "".join(self.textarea_buf)))
            self.in_textarea = None

    def handle_data(self, data):
        if self.in_textarea is not None:
            self.textarea_buf.append(data)


def fetch_form(stream_id):
    url = f"{BASE}/administrador/stream?id={stream_id}&modal=1"
    req = urllib.request.Request(url, headers={
        "Cookie": f"PHPSESSID={PHPSESSID}",
        "X-Forwarded-For": XFF,
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read().decode("utf-8", errors="replace")


def submit_form(stream_id, fields):
    body = urllib.parse.urlencode(fields, doseq=True).encode()
    url = f"{BASE}/administrador/post.php?action=stream&referer="
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Cookie": f"PHPSESSID={PHPSESSID}",
        "X-Forwarded-For": XFF,
        "Content-Type": "application/x-www-form-urlencoded",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read().decode("utf-8", errors="replace")


SERVER_TREE_DEFAULT = (
    '[{"id":"1","parent":"source","text":"Main Server",'
    '"icon":"mdi mdi-server-network","state":{"opened":true}}]'
)


def restart_stream(stream_id):
    html = fetch_form(stream_id)
    p = FormParser()
    p.feed(html)
    fields = list(p.fields)

    # Strip fields we will override
    fields = [(n, v) for n, v in fields
              if n not in ("restart_on_edit", "server_tree_data", "od_tree_data")]
    # JS would populate server_tree_data with the Online subtree.
    # Main Server (id=1) is the only Online server for these streams.
    fields.append(("server_tree_data", SERVER_TREE_DEFAULT))
    fields.append(("od_tree_data", "[]"))
    fields.append(("restart_on_edit", "on"))
    if not any(n == "submit_stream" for n, _ in fields):
        fields.append(("submit_stream", "Save"))

    has_edit = any(n == "edit" and v == str(stream_id) for n, v in fields)
    if not has_edit:
        return False, f"edit field missing for {stream_id}", len(fields)

    status, body = submit_form(stream_id, fields)
    ok = (status == 200) and ('"result":true' in body or '"status":1' in body)
    return ok, body[:200], len(fields)


def main():
    ids = [int(x) for x in sys.argv[1:]]
    if not ids:
        print("usage: xui_start_streams.py ID [ID ...]")
        sys.exit(1)
    for sid in ids:
        try:
            ok, msg, nfields = restart_stream(sid)
            print(f"{sid}\t{'OK' if ok else 'FAIL'}\tfields={nfields}\t{msg}")
        except Exception as e:
            print(f"{sid}\tERROR\t{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
