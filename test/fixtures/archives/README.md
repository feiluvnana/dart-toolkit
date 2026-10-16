# Archive fixtures

Archives made by tools this repo cannot run (WinRAR, and 7-Zip for the AES ones), from libarchive's
test suite (`libarchive/test/test_read_format_*.uu`, BSD 2-clause, Copyright (c) 2003-2024 Tim
Kientzle and the libarchive contributors), uudecoded. The 7z ones use the password `12345678`; the
RAR ones `password` (and `password2` for one member), as their libarchive tests say. `rar4_unicode`
is `test_read_format_rar_unicode`; `rar5_{unicode,symlink,hardlink,blake2,solid_encrypted}` are
`test_read_format_rar5_*`.

Made here with 7-Zip 26.04 (`7zz`), checked by archive_test.dart:
- `7z_arm64.7z` = `7zz a -mf=ARM64 -m0=LZMA2 7z_arm64.7z code.bin`, where `code.bin` is 2,048
  little-endian words, word `i` by `i % 4`: `0x94000000 | (i*7919 & 0x3FFFFFF)` (BL),
  `0x90000000 | (i*13 & 3) << 29 | (i*31 & 0x7FFF) << 5 | (i & 31)` and
  `0x90000000 | (i*5 & 3) << 29 | (i*977 & 0x7FFFF) << 5 | (i & 31)` (ADRP), `0xD503201F` (NOP).
- `7z_ppmd_restart.7z` = `7zz a -m0=PPMd:mem=64k:o=6 7z_ppmd_restart.7z mix4000.txt`: max-order
  contexts that see every symbol once and then one or two symbols hundreds of times (the rescale
  drops to one, then two symbols), then 4,000 random words that fill the 64 KiB model so it
  restarts. Made by this script (`python3 mix.py mix4000.txt 4000`):

```python
import sys, random
r = random.Random(5)
parts = []
alpha = 'qwertyuiopasdfghjklzxcvbnm0123456789'
for pre in ['@%', '@@@@@%']:
    for c in alpha: parts.append(pre + c)
    parts.append((pre + '!') * 600)
for pre in ['&%', '&&&&&%']:
    for c in alpha: parts.append(pre + c)
    parts.append((pre + '!' + pre + '?') * 400)
words = [''.join(r.choice('abcdefghij') for _ in range(r.randint(2, 7))) for _ in range(400)]
parts.append(' '.join(r.choice(words) for _ in range(int(sys.argv[2]))))
open(sys.argv[1], 'w').write(''.join(parts))
```
