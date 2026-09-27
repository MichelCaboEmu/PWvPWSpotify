#!/usr/bin/env python3
import pathlib, subprocess, sys
root=pathlib.Path(sys.argv[1])
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink():continue
    with path.open('rb') as f:magic=f.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):continue
    listing=subprocess.check_output(['otool','-L',str(path)],text=True)
    for line in listing.splitlines():
        if not line.startswith('\t'):continue
        dep=line.strip().split(' (compatibility',1)[0]
        new=None
        if 'libroot' in dep:raise RuntimeError('Unexpected libroot dependency')
        if 'orion' in dep.lower():new='@rpath/Orion.framework/Orion'
        elif 'substrate' in dep.lower():new='@rpath/CydiaSubstrate.framework/CydiaSubstrate'
        elif 'EeveeSwiftProtobuf.framework/' in dep:new='@rpath/EeveeSwiftProtobuf.framework/EeveeSwiftProtobuf'
        elif dep.startswith('/var/jb/'):raise RuntimeError(f'Unknown jailbreak dependency {dep}')
        if new and dep!=new:subprocess.run(['install_name_tool','-change',dep,new,str(path)],check=True)
