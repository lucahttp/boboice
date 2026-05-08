import json, os
path = os.path.join(os.environ['APPDATA'], 'Buddy', 'models', 'whisper', 'tokenizer.json')
with open(path, encoding='utf-8') as f:
    t = json.load(f)

at = t['added_tokens']
# Find non-timestamp special tokens
nontime_specials = []
for tok in at:
    content = tok['content']
    if '<|' in content and not any(content.startswith(f'<|{x}') for x in [str(i) for i in range(100)]):
        nontime_specials.append(tok)

print('Non-timestamp special tokens:')
for tok in nontime_specials:
    print(f"  id={tok['id']} content={repr(tok['content'])} special={tok.get('special', False)}")

# Now search for the Whisper task/language tokens specifically
vocab = t['model']['vocab']
# Search for tokens containing "start", "transcri", "notime", "nospeech", language codes
import re
kw = ['start', 'transcri', 'notime', 'nospeech', 'en', 'prev', 'lm']
for k in kw:
    matches = [(v_id, k_str) for k_str, v_id in vocab.items() if k in k_str.lower()]
    if matches:
        print(f"\nTokens matching '{k}':")
        for v_id, k_str in matches[:5]:
            print(f"  id={v_id} content={repr(k_str)}")
