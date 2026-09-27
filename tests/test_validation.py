import importlib.util, pathlib, struct, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('validate',ROOT/'scripts/validate_ipa.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

def binary(cryptid=0, cpu=0x100000c):
    command=struct.pack('<IIIIII',0x2c,24,4096,4096,cryptid,0)
    return struct.pack('<IIIIIIII',0xfeedfacf,cpu,0,2,1,len(command),0,0)+command

class MachOTests(unittest.TestCase):
    def test_decrypted_arm64(self):self.assertEqual(module.macho(binary()),[])
    def test_encrypted_rejected(self):
        with self.assertRaisesRegex(ValueError,'Encrypted'):module.macho(binary(1))
    def test_other_arch_rejected(self):
        with self.assertRaisesRegex(ValueError,'arm64'):module.macho(binary(cpu=7))
    def test_truncation_rejected(self):
        with self.assertRaises(ValueError):module.macho(binary()[:-3])
    def test_invalid_command_size(self):
        b=bytearray(binary());struct.pack_into('<I',b,36,0)
        with self.assertRaisesRegex(ValueError,'size'):module.macho(b)
    def test_fat_arm64(self):
        b=binary();fat=struct.pack('>II',0xcafebabe,1)+struct.pack('>IIIII',0x100000c,0,28,len(b),0)+b
        self.assertEqual(module.macho(fat),[])

class FusionTests(unittest.TestCase):
    def test_activation_profile_has_no_duplicate_engines(self):
        text=(ROOT/'build/eevee/Sources/EeveeSpotify/Tweak.x.swift').read_text()
        start=text.index('    init() {');self.assertEqual(text[start:].strip(),'init() {\n        pwFusionStart()\n    }\n}')
        bridge=(ROOT/'overlays/eevee/PWFusion.swift').read_text().split('@objc(PWEeveeBridge)')[0]
        for forbidden in ['activateEeveePremiumForce','activateEeveeCrossfadeForce','activateKaraokeHooks',
                          'PremiumBootstrapGroup().activate','BaseLyricsGroup().activate','UniversalSettingsIntegration']:
            self.assertNotIn(forbidden,bridge)
    def test_orion_default_hooks_are_only_complements(self):
        import re
        root=ROOT/'build/eevee/Sources/EeveeSpotify';actual=set()
        for p in root.rglob('*.swift'):
            text=p.read_text()
            matches=list(re.finditer(r'^class (\w+): ClassHook[^\n]*\{',text,re.M))
            for m in matches:
                # Group declarations occur before the first hook method.
                prefix=text[m.end():].split('\n    func ',1)[0].split('\n    @objc',1)[0]
                if 'typealias Group =' not in prefix:actual.add(m.group(1))
        self.assertEqual(actual,{'UIOpenURLContextHook','UIPasteboardCleanShareLinksHook',
                               'UIActivityViewControllerCleanShareLinksHook','UIApplicationCleanShareLinksHook',
                               'UIApplicationLiveContainerSharingHook'})
    def test_single_lyrics_engine_gets_extra_sources(self):
        source=(ROOT/'build/spotipw/tweak/Sources/Shared/LyricsSources/LyricsSources.m').read_text()
        for key in ['genius','petitlyrics']:
            self.assertEqual(source.count(f'make(@"{key}"'),1)
    def test_no_jailbreak_root_dependency(self):
        text=(ROOT/'build/eevee/Sources/EeveeSpotifyC/Tweak.m').read_text()
        self.assertNotIn('libroot.h',text);self.assertNotIn('JBROOT_PATH',text)
if __name__=='__main__':unittest.main()
