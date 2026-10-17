#!/usr/bin/env python3
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parents[1]
runtime = root / 'Sources/TopspinRuntime'
errors=[]
for p in runtime.glob('*.swift'):
    text=p.read_text()
    if re.search(r'import\s+TopspinServer|\b(ChatRequest|SSEFrame|TopspinServer)\b', text): errors.append(f'{p}: Runtime references Server wire types')
if errors:
    print('\n'.join(errors)); sys.exit(1)
print('architecture boundary: PASS')
