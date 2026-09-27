#!/usr/bin/env python3
import pathlib, tarfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
ignore={'.git','.theos','obj','packages','out','build','__pycache__'}
with tarfile.open(ROOT/'out/PWvPWSpotify-corresponding-source.tar.gz','w:gz') as tar:
    for name in ['spotipw','eevee']:
        source=ROOT/'build'/name
        for p in sorted(source.rglob('*')):
            rel=p.relative_to(source)
            if any(part in ignore for part in rel.parts):continue
            if p.name=='SGFlagList.m' or p.suffix in ('.ipa','.p12','.mobileprovision'):continue
            if p.is_file():tar.add(p,arcname=f'{name}/{rel}',recursive=False)
    for name in ['README.md','LICENSE','upstreams.json','scripts','overlays']:
        tar.add(ROOT/name,arcname='fusion/'+name)
print('Corresponding source packaged (Spotify IPA excluded).')
