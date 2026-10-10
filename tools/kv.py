"""Minimal parser for Valve KeyValues (KV1) text files."""


def _tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c in "{}":
            yield c
            i += 1
        elif c == "[":  # platform conditional such as [$WIN32]
            j = text.find("]", i)
            i = n if j < 0 else j + 1
        elif c == '"':
            j, buf = i + 1, []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    nxt = text[j + 1]
                    buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, "\\" + nxt))
                    j += 2
                else:
                    buf.append(text[j])
                    j += 1
            yield ("s", "".join(buf))
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in ' \t\r\n{}"':
                j += 1
            yield ("s", text[i:j])
            i = j


def loads(text):
    """Parse KV text into nested dicts. Duplicate keys keep the first value."""
    root = {}
    stack, key = [root], None
    for tok in _tokens(text):
        if tok == "{":
            child = {}
            if key is not None and key not in stack[-1]:
                stack[-1][key] = child
            stack.append(child)
            key = None
        elif tok == "}":
            if len(stack) > 1:
                stack.pop()
            key = None
        elif key is None:
            key = tok[1]
        else:
            stack[-1].setdefault(key, tok[1])
            key = None
    return root


def load(path):
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return loads(f.read())
