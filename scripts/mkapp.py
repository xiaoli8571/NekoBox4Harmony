import zipfile, os, sys

stage, out = sys.argv[1], sys.argv[2]
names = ['entry-default.hap', 'pack.info', 'pac.json']
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for n in names:
        p = os.path.join(stage, n)
        if not os.path.exists(p):
            sys.exit('missing ' + p)
        z.write(p, n)
print('built', out, os.path.getsize(out))
