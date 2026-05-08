import json, os
path = os.path.join(os.environ['APPDATA'], 'Buddy', 'models', 'whisper', 'tokenizer.json')
with open(path, encoding='utf-8') as f:
    t = json.load(f)

at = t['added_tokens']
print('Total added tokens:', len(at))
specials = [tok for tok in at if '<|' in tok['content']]
print('Special tokens found:')
for tok in specials:
    print(' ', tok['content'], '->', tok['id'])

vocab = t['model']['vocab']
print()
print('Searching special tokens in vocab:')
for s in ['<|endoftext|>', '<|startoftranscript|>', '<|en|>', '<|transcribe|>', '<|notimestamps|>', '<|startoflm|>', '<|startofprev|>', '<|nospeech|>', '<|0.00|>']:
    print(f'  {s}: {vocab.get(s, "NOT FOUND")}')

# Get the first few non-timestamp vocab entries
nontime = [(k,v) for k,v in vocab.items() if not k.startswith('<|')]
print(f'\nFirst 10 non-timestamp tokens:')
for k, v in nontime[:10]:
    print(f'  {repr(k)} -> {v}')
print(f'Total non-timestamp: {len(nontime)}')
