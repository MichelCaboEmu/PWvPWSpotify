#!/usr/bin/env python3
import pathlib, plistlib, sys, zipfile
ipa, extension=map(pathlib.Path,sys.argv[1:])
if not (extension/'Info.plist').is_file():raise SystemExit('Safari extension missing')
with zipfile.ZipFile(ipa,'a',compression=zipfile.ZIP_DEFLATED) as z:
    infos=[n for n in z.namelist() if n.startswith('Payload/') and n.count('/')==2 and n.endswith('.app/Info.plist')]
    if len(infos)!=1:raise SystemExit('Expected one app')
    app=infos[0].rsplit('/',1)[0];dest=f'{app}/PlugIns/{extension.name}'
    if any(n.startswith(dest+'/') for n in z.namelist()):raise SystemExit('Duplicate Safari extension')
    for p in sorted(extension.rglob('*')):
        if p.is_file():z.write(p,f'{dest}/{p.relative_to(extension).as_posix()}')
