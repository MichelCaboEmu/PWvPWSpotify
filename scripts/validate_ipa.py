#!/usr/bin/env python3
"""Validate a clean input IPA or the merged output, without extracting it."""
import argparse, hashlib, json, pathlib, plistlib, struct, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]

def macho(data):
    if len(data)<32: raise ValueError('Truncated Mach-O')
    magic=data[:4]
    if magic in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
        wide=magic[-1]==0xbf; count=struct.unpack_from('>I',data,4)[0]
        if count>32:raise ValueError('Invalid fat architecture count')
        for i in range(count):
            p=8+i*(32 if wide else 20)
            cpu=struct.unpack_from('>I',data,p)[0]
            off,size=struct.unpack_from('>QQ' if wide else '>II',data,p+8)
            if cpu==0x100000c:
                if off+size>len(data):raise ValueError('Truncated fat slice')
                return macho(data[off:off+size])
        raise ValueError('No arm64 slice')
    if magic!=b'\xcf\xfa\xed\xfe':raise ValueError('Expected arm64 Mach-O')
    cpu,_,_,ncmds,cmdsize=struct.unpack_from('<IIIII',data,4)
    if cpu!=0x100000c:raise ValueError('Expected arm64 CPU')
    if 32+cmdsize>len(data):raise ValueError('Truncated load commands')
    pos=32; crypt=[]; deps=[]
    for _ in range(ncmds):
        if pos+8>32+cmdsize:raise ValueError('Invalid load command')
        cmd,size=struct.unpack_from('<II',data,pos)
        if size<8 or pos+size>32+cmdsize:raise ValueError('Invalid load command size')
        if cmd in (0x21,0x2c):
            if size<20:raise ValueError('Truncated encryption command')
            crypt.append(struct.unpack_from('<I',data,pos+16)[0])
        if cmd in (0xc,0x80000018,0x8000001f,0x20,0x80000023):
            if size<24:raise ValueError('Truncated dylib command')
            start=struct.unpack_from('<I',data,pos+8)[0]
            if start<24 or start>=size:raise ValueError('Invalid dylib name')
            deps.append(data[pos+start:pos+size].split(b'\0',1)[0].decode())
        pos+=size
    if pos!=32+cmdsize:raise ValueError('Load command count mismatch')
    if any(crypt):raise ValueError('Encrypted executable (cryptid != 0)')
    return deps

def validate(path, output=False, expected_sha=None):
    digest=hashlib.file_digest(open(path,'rb'),'sha256').hexdigest()
    if expected_sha and digest!=expected_sha:raise ValueError('Input SHA-256 mismatch')
    with zipfile.ZipFile(path) as z:
        names=z.namelist()
        if len(names)!=len(set(names)):raise ValueError('Duplicate ZIP paths')
        for name in names:
            p=pathlib.PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or '\\' in name:raise ValueError('Unsafe ZIP path')
        bad=z.testzip()
        if bad:raise ValueError('ZIP CRC mismatch')
        infos=[n for n in names if n.count('/')==2 and n.startswith('Payload/') and n.endswith('.app/Info.plist')]
        if len(infos)!=1:raise ValueError('Expected exactly one top-level application')
        app=infos[0].rsplit('/',1)[0]; info=plistlib.loads(z.read(infos[0]))
        if info.get('CFBundleIdentifier')!='com.spotify.client':raise ValueError('Unexpected bundle identifier')
        if info.get('CFBundleShortVersionString')!='9.1.78':raise ValueError('Expected Spotify 9.1.78')
        if info.get('CFBundleVersion')!='917802214':raise ValueError('Unvalidated Spotify build number')
        exe=info['CFBundleExecutable']
        if '/' in exe or exe in ('.','..'):raise ValueError('Invalid executable name')
        data=z.read(f'{app}/{exe}'); deps=macho(data)
        if not output:
            extra=[n for n in names if n.endswith('.dylib')]
            if extra:raise ValueError('Input contains dylibs; provide the clean IPA')
            for dep in deps:
                if any(s in dep.lower() for s in ('eevee','spotifyglass','substrate','orion')):raise ValueError('Input already patched')
            required=['SPTPlayerServiceImplementation','addPlayerObserver:',
                      '_TtCO17NowPlaying_ECMKit11ProgressBar6Slider',
                      'SmartShuffleHandlerImplementation','checkRecommendationsEnabled',
                      'recommendationIsBeingAddedWithTrackID:']
            for symbol in required:
                if symbol.encode() not in data:raise ValueError(f'Missing required symbol: {symbol}')
        else:
            if info.get('CFBundleDisplayName')!='Spotify' or info.get('CFBundleName')!='Spotify':
                raise ValueError('Output application must be named Spotify')
            for lib in ['spotifyglass.dylib','EeveeSpotify.dylib','SpotifyGlassAppGroups.dylib']:
                full=f'{app}/Frameworks/{lib}'
                if full not in names or not any(d.endswith('/'+lib) for d in deps):raise ValueError(f'Missing loaded module: {lib}')
                for dep in macho(z.read(full)):
                    if dep.startswith(('/var/jb/','/Library/','@loader_path/.jbroot')):raise ValueError(f'Unresolved jailbreak dependency in {lib}: {dep}')
                    if dep.startswith('@rpath/') and f'{app}/Frameworks/{dep[7:]}' not in names:raise ValueError(f'Missing dependency: {dep}')
            for item in ['EeveeSpotify.bundle/Info.plist','PlugIns/SpotifyGlassLiveActivity.appex/Info.plist']:
                if f'{app}/{item}' not in names:raise ValueError(f'Missing bundled resource: {item}')
            # Swift's renamed protobuf framework must not collide with Spotify's module.
            if f'{app}/Frameworks/EeveeSwiftProtobuf.framework/EeveeSwiftProtobuf' not in names:raise ValueError('Missing EeveeSwiftProtobuf')
        return {'spotify_version':info['CFBundleShortVersionString'],'spotify_build':info['CFBundleVersion'],
                'minimum_ios':info.get('MinimumOSVersion'),'sha256':digest,'merged_output':output,
                'encrypted':False,'runtime_tested':False}

def main():
    p=argparse.ArgumentParser();p.add_argument('ipa',type=pathlib.Path);p.add_argument('--output',action='store_true')
    p.add_argument('--sha256');p.add_argument('--report',type=pathlib.Path);a=p.parse_args()
    result=validate(a.ipa,a.output,a.sha256);text=json.dumps(result,indent=2)
    print(text)
    if a.report:a.report.parent.mkdir(parents=True,exist_ok=True);a.report.write_text(text+'\n')
if __name__=='__main__':main()
