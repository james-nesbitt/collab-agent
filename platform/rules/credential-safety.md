---
alwaysApply: true
description: Prevent credentials and derived secret material from appearing in command output or context
---

Never print, echo, or otherwise emit the value of any environment variable that may contain credentials, tokens, secrets, or passwords — even indirectly.

This includes:
- Any variable whose name contains KEY, SECRET, TOKEN, PASSWORD, PASS, AUTH, CREDENTIAL, PRIVATE, or OAUTH
- Values derived from those variables (e.g. base64 encodings, HTTP headers, crumbs, or hashes computed from them)
- Intermediate pipeline outputs that expand those variables as part of a debug or echo step

Prohibited patterns:
- `echo $VAR` or `echo "$VAR"` on any credential variable
- `echo $CRUMB` or printing any value derived from a credential
- `env | grep ...` or any command that prints env var values
- Embedding a credential variable in a string that is then printed (e.g. `echo "token=$TOKEN"`)
- Any `printf`, `cat`, `python -c "print(...)"`, or equivalent that surfaces a secret value

**Never surface credentials through tool output or agent context.** This extends beyond echo/print commands to any tool invocation whose output would contain credential values:

- Never use `-v` / `--verbose` on HTTP commands that include authentication headers — verbose mode prints request headers, exposing bearer tokens and API keys in tool output
- Never run commands that would include Authorization, Cookie, or credential-bearing headers in their stdout/stderr output
- Never pipe authenticated HTTP responses through commands that log or display the raw request (e.g. `curl -v`, `wget --server-response`, `httpie` in verbose mode)
- The fact that the harness may partially redact output does not make it acceptable — do not rely on redaction as a safety net

When diagnosing HTTP issues on authenticated endpoints:
- Use `-o /dev/null -w "%{http_code}"` to check status codes without printing headers or body
- Use `-D -` to dump only response headers (not request headers), then read selectively
- Never use `-v` or `--trace` on wrapper scripts that inject credentials

Safe alternatives:
- Check presence: `[ -n "$VAR" ] && echo "set" || echo "unset"`
- Check length: `echo "${#VAR}"`
- Pass directly as an argument or header without echoing: `curl -u "$USER:$TOKEN" ...`

If a tool output contains a redacted placeholder (e.g. `#XXXX#`), treat it as opaque — do not attempt to reconstruct or display the underlying value.
