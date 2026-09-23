"""Print independent Python email results for synthetic corpus files only."""

import email.parser
import email.policy
import json
import pathlib
import sys

for name in sys.argv[1:]:
    path = pathlib.Path(name)
    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
        path.read_bytes()
    )
    body = message.get_body(preferencelist=("plain", "html"))
    try:
        text = body.get_content() if body is not None else ""
        print(
            json.dumps(
                {"fixture": path.name, "body": text, "headers": list(message.items())},
                ensure_ascii=False,
            )
        )
    except (LookupError, UnicodeError, ValueError):
        print(json.dumps({"fixture": path.name, "error": "decode failure"}))
