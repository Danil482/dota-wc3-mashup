"""Parser for the KV3 text that VRF prints for resource blocks (-b ASEQ,
-b MDAT), and a splitter for VRF's multi-file block dumps."""
import re

_HEADER = re.compile(r"^\[\d+/\d+\] (.+?)\s*$")
_BLOCK = re.compile(r'^--- Data for block "(\w+)" ---\s*$')
_NUMBER = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*")


class Kv3Error(Exception):
    pass


def split_dump(text):
    """VRF `-b <block>` output for several files -> {vpk path: [block text]}."""
    out = {}
    lines, path = None, None
    for line in text.splitlines():
        m = _HEADER.match(line)
        if m:
            if lines is not None and path:
                out.setdefault(path, []).append("\n".join(lines))
            path, lines = m.group(1).strip().replace("\\", "/"), None
            continue
        if _BLOCK.match(line):
            if lines is not None and path:
                out.setdefault(path, []).append("\n".join(lines))
            lines = []
            continue
        if lines is not None:
            lines.append(line)
    if lines is not None and path:
        out.setdefault(path, []).append("\n".join(lines))
    return out


def loads(text):
    """Parse KV3 text into Python values (dict, list, str, int, float, bool, None)."""
    start = text.find("<!--")
    start = 0 if start < 0 else text.find("-->", start) + 3
    start = text.find("{", start)
    if start < 0:
        raise Kv3Error("no KV3 object found")
    value, pos = _value(text, start)
    return value


def _skip(text, pos):
    n = len(text)
    while pos < n:
        c = text[pos]
        if c in " \t\r\n,":
            pos += 1
        elif text.startswith("//", pos):
            end = text.find("\n", pos)
            pos = n if end < 0 else end + 1
        elif text.startswith("/*", pos):
            end = text.find("*/", pos)
            pos = n if end < 0 else end + 2
        elif text.startswith("<!--", pos):
            end = text.find("-->", pos)
            pos = n if end < 0 else end + 3
        else:
            break
    return pos


def _string(text, pos):
    if text.startswith('"""', pos):
        end = text.find('"""', pos + 3)
        if end < 0:
            raise Kv3Error("unterminated multi-line string")
        return text[pos + 3:end].strip("\r\n"), end + 3
    buf = []
    i = pos + 1
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            nxt = text[i + 1]
            buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
        elif c == '"':
            return "".join(buf), i + 1
        else:
            buf.append(c)
            i += 1
    raise Kv3Error("unterminated string")


def _value(text, pos):
    pos = _skip(text, pos)
    if pos >= len(text):
        raise Kv3Error("unexpected end of text")
    c = text[pos]
    if c == "{":
        obj = {}
        pos += 1
        while True:
            pos = _skip(text, pos)
            if pos >= len(text):
                raise Kv3Error("unterminated object")
            if text[pos] == "}":
                return obj, pos + 1
            if text[pos] == '"':
                key, pos = _string(text, pos)
            else:
                m = _WORD.match(text, pos)
                if not m:
                    raise Kv3Error(f"bad key at {pos}: {text[pos:pos + 20]!r}")
                key, pos = m.group(0), m.end()
            pos = _skip(text, pos)
            if pos >= len(text) or text[pos] != "=":
                raise Kv3Error(f"expected '=' after {key!r}")
            value, pos = _value(text, pos + 1)
            obj.setdefault(key, value)
    if c == "[":
        arr = []
        pos += 1
        while True:
            pos = _skip(text, pos)
            if pos >= len(text):
                raise Kv3Error("unterminated array")
            if text[pos] == "]":
                return arr, pos + 1
            value, pos = _value(text, pos)
            arr.append(value)
    if c == '"':
        return _string(text, pos)
    if c == "#" and text.startswith("#[", pos):
        end = text.find("]", pos)
        if end < 0:
            raise Kv3Error("unterminated binary blob")
        return bytes.fromhex(text[pos + 2:end].replace("\n", " ").replace("\r", " ")), end + 1
    m = _NUMBER.match(text, pos)
    if m and (c.isdigit() or c in "-."):
        s = m.group(0)
        if any(ch in s for ch in ".eE"):
            return float(s), m.end()
        return int(s), m.end()
    m = _WORD.match(text, pos)
    if m:
        word, end = m.group(0), m.end()
        if word == "true":
            return True, end
        if word == "false":
            return False, end
        if word == "null":
            return None, end
        if end < len(text) and text[end] == ":":
            # Flagged value such as resource_name:"..." or soundevent:"..."
            return _value(text, end + 1)
        return word, end
    raise Kv3Error(f"unexpected character at {pos}: {text[pos:pos + 20]!r}")
