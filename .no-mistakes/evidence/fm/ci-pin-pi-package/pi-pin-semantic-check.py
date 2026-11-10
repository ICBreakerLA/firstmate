import re, sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text().splitlines()
job = None
step_name = None
run_indent = None
run_lines = []
installs = []

def flush():
    global run_lines, run_indent
    text = "\n".join(run_lines)
    for cmd in text.splitlines():
        if "npm install -g" in cmd and "@earendil-works/pi-coding-agent" in cmd:
            installs.append((job, step_name, cmd.strip()))
    run_lines = []
    run_indent = None

for raw in lines:
    if not raw.strip():
        if run_indent is not None:
            run_lines.append("")
        continue
    indent = len(raw) - len(raw.lstrip())
    stripped = raw.strip()
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", raw)
    if indent == 2 and m:
        if run_indent is not None:
            flush()
        job = m.group(1)
        step_name = None
        continue
    if run_indent is not None and indent <= run_indent:
        flush()
    m = re.match(r"^-\s+name:\s*(.+?)\s*$", stripped)
    if m:
        step_name = m.group(1)
        continue
    if stripped.startswith("run:"):
        run_indent = indent
        rest = stripped[len("run:"):].strip()
        run_lines = [rest] if rest and rest != "|" else []
        continue
    if run_indent is not None and indent > run_indent:
        run_lines.append(stripped)
if run_indent is not None:
    flush()

print(f"pi install steps found: {len(installs)}")
ok = True
for job, name, cmd in installs:
    match = re.search(r"npm install -g\s+@earendil-works/pi-coding-agent@(\S+)", cmd)
    spec = match.group(1) if match else None
    print(f"  job={job!r} step={name!r} spec={spec!r}")
    if spec != "1.5.0":
        ok = False
print("RESULT:", "PASS - every Pi install pins exact version 1.5.0" if ok and len(installs) == 2 else "FAIL")
sys.exit(0 if ok and len(installs) == 2 else 1)
