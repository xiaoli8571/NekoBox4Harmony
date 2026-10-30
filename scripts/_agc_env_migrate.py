#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 TunBox_HarmonyOS/.env 里的 AGC 凭证搬到本工程 .env(不打印任何密钥)。
DEVECO_HOME 用正确的反斜杠路径重写(TunBox 那份已损坏)。
"""
import io
import os
import sys

SRC = r'C:\Worker\TunBox\TunBox_HarmonyOS\.env'
DST = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.env')
DEVECO = r'C:\Program Files\Huawei\DevEco Studio'

if not os.path.isfile(SRC):
    sys.exit('源文件不存在: %s' % SRC)

kv = {}
for ln in io.open(SRC, encoding='utf-8-sig').read().splitlines():
    ln = ln.strip()
    if not ln or ln.startswith('#') or '=' not in ln:
        continue
    k, v = ln.split('=', 1)
    kv[k.strip()] = v.strip().strip('"').strip("'")

need = ['AGC_AUTH_MODE', 'AGC_CLIENT_ID', 'AGC_CLIENT_SECRET']
missing = [k for k in need if not kv.get(k)]
if missing:
    sys.exit('缺少键: %s' % missing)

lines = ['# AGC 凭证(迁移自 TunBox_HarmonyOS/.env)']
for k in need:
    lines.append('%s=%s' % (k, kv[k]))
lines.append('DEVECO_HOME=%s' % DEVECO)

with io.open(DST, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(lines) + '\n')

print('.env 已写入:', DST)
print('键:', [l.split('=', 1)[0] for l in lines if '=' in l])
print('CLIENT_ID:', kv['AGC_CLIENT_ID'])
print('CLIENT_SECRET 长度:', len(kv['AGC_CLIENT_SECRET']))
